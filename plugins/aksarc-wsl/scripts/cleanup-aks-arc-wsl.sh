#!/bin/bash
# =============================================================================
# cleanup-aks-arc-wsl.sh — tear down the Azure resources created by setup-aks-arc-wsl.sh
# -----------------------------------------------------------------------------
# Runs INSIDE the WSL Ubuntu distro (the Arc-connected edge host), as root:
#   wsl -d <distro> -u root -- bash ~/.aksarc-wsl/cleanup-aks-arc-wsl.sh --config ~/.aksarc-wsl/wsl-config.env
#
# Deletes ONLY the resources this machine created (names derived from the
# hostname, exactly like setup-aks-arc-wsl.sh), in the SFF-safe delete order:
#   provisioned cluster(s) -> LogicalNetwork -> DevicePool (CustomLocation
#   auto-deleted with it) -> CustomLocation (if it lingers) -> EdgeMachine
#   -> Arc machine (azcmagent disconnect, which removes the HybridCompute
#      resource + its auto-installed extensions).
#
# It NEVER touches the CMP (aks-cl / aks-conn-cl) or any resource whose name
# doesn't start with this host's derived prefix.
#
# Idempotent: every resource is skipped if already gone; stuck deletes are
# retried and, if still stuck after the timeout, reported (not fatal).
#
# Flags:
#   --config <file>   config file (default: ./wsl-config.env). Only CMP_SUB /
#                     CMP_RG / EDGE_LOCATION are needed for cleanup.
#   --cluster-only    delete ONLY the provisioned cluster(s); keep LogicalNetwork,
#                     DevicePool, CustomLocation, EdgeMachine and Arc. Fastest
#                     path to iterate (re-run provision goes straight to create).
#   --keep-node       keep the EdgeMachine + Arc machine + WSL distro (so the
#                     same node can be re-claimed by a NEW CMP). Only deletes
#                     the provisioned cluster(s), LogicalNetwork, DevicePool
#                     and CustomLocation.
#   --yes             don't prompt for confirmation.
#   --timeout <sec>   per-resource delete wait (default 900).
#
# This is POC-quality. NOT a supported product.
# =============================================================================
set -euo pipefail
umask 077   # restrict perms on any temp files we create (stderr captures, etc.)

CONFIG_FILE="$(dirname "$0")/wsl-config.env"
KEEP_NODE=0
CLUSTER_ONLY=0
ASSUME_YES=0
DEL_TIMEOUT=900

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)       CONFIG_FILE="${2:-}"; shift 2 ;;
    --keep-node)    KEEP_NODE=1; shift ;;
    --cluster-only) CLUSTER_ONLY=1; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --timeout)      DEL_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)      usage 0 ;;
    *) echo "ERROR: unknown arg '$1'" >&2; usage 1 ;;
  esac
done

log()  { echo ">>> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
# shellcheck disable=SC1090
set -a; source "$CONFIG_FILE"; set +a

: "${CMP_SUB:?CMP_SUB must be set in config}"
: "${CMP_RG:?CMP_RG must be set in config}"

command -v az >/dev/null 2>&1 || die "az not found (install the Linux azure-cli)"
case "$(command -v az)" in
  /mnt/*) die "az resolves to the Windows CLI ($(command -v az)); use the Linux az" ;;
esac
az account show >/dev/null 2>&1 || die "not logged in — run 'az login' first"
az account set --subscription "$CMP_SUB"

# ---- Derived IDs (identical derivation to setup-aks-arc-wsl.sh) ---------------------
MACHINE_NAME="$(hostname -s | tr '[:upper:]' '[:lower:]')"
EDGE_SUB="$CMP_SUB"; EDGE_RG="$CMP_RG"
CUSTOM_LOCATION_NAME="${MACHINE_NAME}-cl"
DEVICE_POOL_NAME="${MACHINE_NAME}-dp"
LNET_NAME="${MACHINE_NAME}-lnet"
CLUSTER_NAME="${MACHINE_NAME}-cluster"

EM_API="${EM_API:-2025-12-01-preview}"
DP_API="${DP_API:-2024-11-01-preview}"
CL_API="${CL_API:-2021-08-15}"
LNET_API="${LNET_API:-2024-11-01-preview}"
ARC_API_DEL="${ARC_API:-2024-07-10}"
CC_API="${CC_API:-2024-07-15-preview}"

base="https://management.azure.com/subscriptions/${EDGE_SUB}/resourceGroups/${EDGE_RG}/providers"

# Delete a resource by full URL and poll until it is gone (GET -> 404).
# Re-issues DELETE periodically to nudge stuck deletes. Non-fatal on timeout.
az_delete_wait() {
  local name="$1" url="$2" timeout="${3:-$DEL_TIMEOUT}"
  if ! az rest --method GET --url "$url" >/dev/null 2>&1; then
    log "  $name: already gone"; return 0
  fi
  log "  deleting $name ..."
  az rest --method DELETE --url "$url" >/dev/null 2>&1 || true
  local waited=0
  while (( waited < timeout )); do
    sleep 15; waited=$((waited+15))
    if ! az rest --method GET --url "$url" >/dev/null 2>&1; then
      log "  $name: deleted (${waited}s)"; return 0
    fi
    if (( waited % 120 == 0 )); then
      log "  $name still present after ${waited}s — re-issuing DELETE"
      az rest --method DELETE --url "$url" >/dev/null 2>&1 || true
    fi
  done
  warn "  $name: still present after ${timeout}s (delete may be stuck; check the portal / retry later)"
  return 1
}

# ---- Plan -------------------------------------------------------------------
log "=== cleanup plan (subscription $EDGE_SUB, resource group $EDGE_RG) ==="
log "  machine prefix : $MACHINE_NAME"
log "  provisioned clusters : ${CLUSTER_NAME}, ${CLUSTER_NAME}2 (+ any ${CLUSTER_NAME}* found)"
if [[ "$CLUSTER_ONLY" == "1" ]]; then
  log "  logical network      : KEPT (--cluster-only)"
  log "  device pool + CL     : KEPT (--cluster-only)"
  log "  edge machine + Arc   : KEPT (--cluster-only)"
elif [[ "$KEEP_NODE" == "1" ]]; then
  log "  logical network      : $LNET_NAME"
  log "  device pool          : $DEVICE_POOL_NAME  (custom location $CUSTOM_LOCATION_NAME auto-deleted)"
  log "  edge machine + Arc   : KEPT (--keep-node) — reusable by a new CMP"
else
  log "  logical network      : $LNET_NAME"
  log "  device pool          : $DEVICE_POOL_NAME  (custom location $CUSTOM_LOCATION_NAME auto-deleted)"
  log "  edge machine         : $MACHINE_NAME"
  log "  Arc machine          : $(hostname -s)  (azcmagent disconnect + resource delete)"
fi
echo

if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "Proceed with deletion? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { log "aborted."; exit 0; }
fi

rc=0

# 1) Provisioned clusters (connectedClusters of kind ProvisionedCluster).
log "[1/5] Provisioned clusters"
DELETED_CLUSTER=0
# Run discovery WITHOUT swallowing errors: a failed query (wrong sub/RG/API,
# auth) must NOT be silently treated as "no clusters" — that once made a
# config/RG mismatch masquerade as a successful delete.
if ! CC_JSON="$(az rest --method GET \
    --url "${base}/Microsoft.Kubernetes/connectedClusters?api-version=${CC_API}" \
    --query "value[?starts_with(name, '${CLUSTER_NAME}')].name" -o tsv 2>/tmp/cc_query.err)"; then
  die "connectedClusters query failed (sub $EDGE_SUB, RG $EDGE_RG): $(cat /tmp/cc_query.err)"
fi
mapfile -t CC_NAMES < <(printf '%s\n' "$CC_JSON" | sed '/^$/d')
if [[ "${#CC_NAMES[@]}" -eq 0 ]]; then
  log "  no cluster matching '${CLUSTER_NAME}*' found in RG $EDGE_RG — nothing to delete"
  log "  (verify RG/sub in your config: CMP_RG=$EDGE_RG, CMP_SUB=$EDGE_SUB)"
else
  for cc in "${CC_NAMES[@]}"; do
    [[ -n "$cc" ]] || continue
    # Delete the child provisionedClusterInstance FIRST — a stuck/Failed
    # ProvisionedCluster connectedCluster won't delete until its HybridContainer
    # Service instance is removed (verified: deleting the instance first unblocks
    # an otherwise un-deletable Failed cluster).
    az rest --method DELETE \
      --url "${base}/Microsoft.Kubernetes/connectedClusters/${cc}/providers/Microsoft.HybridContainerService/provisionedClusterInstances/default?api-version=2024-01-01" \
      >/dev/null 2>&1 || true
    az_delete_wait "connectedCluster/$cc" \
      "${base}/Microsoft.Kubernetes/connectedClusters/${cc}?api-version=${CC_API}" || rc=1
    DELETED_CLUSTER=1
  done
fi

if [[ "$CLUSTER_ONLY" == "1" ]]; then
  log "[cluster-only] Kept LogicalNetwork, DevicePool, CustomLocation, EdgeMachine and Arc."
  if [[ "$DELETED_CLUSTER" == "1" ]]; then
    log "=== cluster deleted. Re-create with:"
    log "    setup-aks-arc-wsl.sh --phase provision --config <config>"
    log "    (provision skips the already-Succeeded DevicePool/CL/LNet and goes straight to cluster create) ==="
  else
    log "=== no cluster was deleted (none matched). If you expected one, check CMP_RG/CMP_SUB in your config. ==="
  fi
  exit "$rc"
fi

# 2) LogicalNetwork (referenced by the cluster; delete after clusters).
log "[2/5] LogicalNetwork"
az_delete_wait "logicalNetwork/$LNET_NAME" \
  "${base}/Microsoft.AzureStackHCI/logicalNetworks/${LNET_NAME}?api-version=${LNET_API}" || rc=1

# 3) DevicePool (deleting it auto-removes the CustomLocation).
log "[3/5] DevicePool (auto-removes CustomLocation)"
az_delete_wait "devicePool/$DEVICE_POOL_NAME" \
  "${base}/Microsoft.AzureStackHCI/DevicePools/${DEVICE_POOL_NAME}?api-version=${DP_API}" || rc=1

# 3b) CustomLocation — normally auto-deleted with the DevicePool.
az_delete_wait "customLocation/$CUSTOM_LOCATION_NAME" \
  "${base}/Microsoft.ExtendedLocation/customLocations/${CUSTOM_LOCATION_NAME}?api-version=${CL_API}" || rc=1

if [[ "$KEEP_NODE" == "1" ]]; then
  log "[4/5] EdgeMachine — SKIPPED (--keep-node)"
  log "[5/5] Arc machine — SKIPPED (--keep-node)"
  log "=== cleanup complete (node kept). To reuse with a new CMP, re-run"
  log "    setup-aks-arc-wsl.sh --phase provision after pointing wsl-config.env at the new CMP. ==="
  exit "$rc"
fi

# 4) EdgeMachine.
log "[4/5] EdgeMachine"
az_delete_wait "edgeMachine/$MACHINE_NAME" \
  "${base}/Microsoft.AzureStackHCI/EdgeMachines/${MACHINE_NAME}?api-version=${EM_API}" || rc=1

# 5) Arc machine — azcmagent disconnect removes the HybridCompute resource.
log "[5/5] Arc machine (azcmagent disconnect)"
if command -v azcmagent >/dev/null 2>&1 && azcmagent show 2>/dev/null | grep -q 'Agent Status *: *Connected'; then
  sudo azcmagent disconnect || warn "  azcmagent disconnect failed; will try ARM delete"
else
  log "  azcmagent not connected (or not installed) — skipping disconnect"
fi
ARC_NAME="$(hostname -s)"
az_delete_wait "arcMachine/$ARC_NAME" \
  "${base}/Microsoft.HybridCompute/machines/${ARC_NAME}?api-version=${ARC_API_DEL}" || rc=1

echo
log "=== cleanup complete ==="
if [[ "$rc" != "0" ]]; then
  warn "one or more deletes did not confirm — re-run this script, or check the portal."
fi
log "To also remove the WSL distro itself, run THIS from the Windows host (not WSL):"
log "    wsl --unregister aks-edge"
exit "$rc"
