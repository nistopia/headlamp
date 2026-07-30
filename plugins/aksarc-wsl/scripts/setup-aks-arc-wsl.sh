#!/bin/bash
# =============================================================================
# setup-aks-arc-wsl.sh — AKS Arc on WSL, Phase 1 POC setup (Linux side)
# -----------------------------------------------------------------------------
# Runs INSIDE the WSL Ubuntu distro. Automates the WSL-edge setup documented in
# docs/wsl/k8s/wsl-edge-setup.md (k8s) and docs/wsl/k3s/wsl-edge-setup.md (k3s).
#
# Two phases (because enabling systemd needs a `wsl --shutdown`, which a script
# inside WSL cannot survive):
#   --phase prep       OS prep that must precede the systemd restart
#   --phase provision  everything after systemd is PID 1 (Arc → cluster create)
#   --phase all        prep, then (if systemd already PID 1) provision
#
# The Windows-host orchestrator (aks-arc-on-wsl.ps1) normally drives this:
#   prep → `wsl --shutdown` → provision.
#
# Idempotent: every step checks "already done?" so re-runs resume safely.
#
# Usage:
#   ./setup-aks-arc-wsl.sh --phase prep      [--config ./wsl-config.env]
#   ./setup-aks-arc-wsl.sh --phase provision [--config ./wsl-config.env]
#
# This is POC-quality (single-session for k8s). NOT a supported product.
# =============================================================================
set -euo pipefail
umask 077   # restrict perms on any temp files we create (tokens, staged artifacts)

# -----------------------------------------------------------------------------
# Args & config
# -----------------------------------------------------------------------------
PHASE=""
CONFIG_FILE="$(dirname "$0")/wsl-config.env"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)  PHASE="${2:-}"; shift 2 ;;
    --config) CONFIG_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "ERROR: unknown arg '$1'" >&2; usage 1 ;;
  esac
done

case "$PHASE" in
  prep|provision|all) ;;
  *) echo "ERROR: --phase must be one of: prep | provision | all" >&2; exit 2 ;;
esac

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config file not found: $CONFIG_FILE" >&2
  echo "       Copy wsl-config.env.example to wsl-config.env and fill it in." >&2
  exit 2
fi
# shellcheck disable=SC1090
set -a; source "$CONFIG_FILE"; set +a

DISTRIBUTION="${DISTRIBUTION:-k8s}"
K8S_VERSION="${K8S_VERSION:?K8S_VERSION must be set in config}"

# Detect the Debian package architecture (amd64 / arm64) so we install native
# packages/binaries instead of hard-coding amd64. dpkg's names (amd64, arm64)
# match both the Microsoft apt repo `arch=` value and the dl.k8s.io path segment.
DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

log()  { echo ">>> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# -----------------------------------------------------------------------------
# Phase: PREP  (must run before the systemd `wsl --shutdown`)
# -----------------------------------------------------------------------------
prep_wsl_conf() {
  log "[prep] Configuring /etc/wsl.conf (systemd, rshared mount, hostname)"
  local hn; hn="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  # Rewrite if ANY required setting is missing — not just systemd. A partial
  # wsl.conf (systemd on but no rshared mount / hostname) would otherwise be
  # reported OK while the kubelet mount-propagation and hostname deps are absent.
  if grep -qs '^systemd *= *true' /etc/wsl.conf 2>/dev/null \
     && grep -qs 'make-rshared' /etc/wsl.conf 2>/dev/null \
     && grep -qs "^hostname *= *${hn}\b" /etc/wsl.conf 2>/dev/null; then
    log "[prep] /etc/wsl.conf already has systemd + rshared mount + hostname (ok)"
    return
  fi
  sudo tee /etc/wsl.conf >/dev/null <<EOF
[boot]
systemd = true
command = "mount --make-rshared /"

[network]
hostname = ${hn}
generateHosts = true
EOF
  log "[prep] /etc/wsl.conf written — a 'wsl --shutdown' is REQUIRED to apply systemd"
  NEEDS_RESTART=1
}

prep_waagent_perms() {
  log "[prep] Ensuring /var/lib/waagent exists and is world-writable (extension race fix)"
  sudo mkdir -p /var/lib/waagent
  sudo chmod 777 /var/lib/waagent
}

prep_boot_hardening() {
  # Harden the node against WSL VM restarts (which happen on vmIdleTimeout when
  # all WSL sessions close, or on Windows reboot/sleep — not just explicit
  # `wsl --shutdown`). Three things must be re-applied on EVERY boot or the k8s
  # control plane / CNI break, and the wsl.conf boot command alone isn't enough
  # (a plain runtime restart, or systemctl restart, loses them):
  #   1. swapoff -a          — kubelet refuses to start with swap on (WSL re-adds
  #                            its swap file every boot).
  #   2. mount --make-rshared /  — cilium's CNI fails to create containers
  #                            ("path /var/run/netns ... not a shared or slave
  #                            mount") without shared mount propagation.
  #   3. enable containerd   — kubelet crash-loops on a missing containerd.sock
  #                            if containerd didn't start.
  # Install one systemd unit that does all three, ordered before kubelet.
  # (k3s tolerates swap and uses flannel, but the unit is harmless there.)
  if [[ "$DISTRIBUTION" != "k8s" ]]; then
    log "[prep] Skipping WSL boot-hardening unit (k3s)"
    return
  fi
  log "[prep] Installing wsl-k8s-boot systemd unit (swapoff + rshared mount + containerd)"
  sudo swapoff -a || true
  sudo mount --make-rshared / 2>/dev/null || true
  sudo tee /etc/systemd/system/wsl-k8s-boot.service >/dev/null <<'EOF'
[Unit]
Description=WSL k8s boot hardening (swapoff, rshared mount, containerd) for kubelet
DefaultDependencies=no
Wants=containerd.service
Before=kubelet.service
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/swapoff -a
ExecStart=/bin/mount --make-rshared /
ExecStart=/bin/systemctl start containerd.service
[Install]
WantedBy=multi-user.target
EOF
  # Remove the older swapoff-only unit if a previous prep installed it.
  sudo systemctl disable wsl-swapoff.service >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/wsl-swapoff.service 2>/dev/null || true
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable wsl-k8s-boot.service >/dev/null 2>&1 || true
}

prep_apt_repos() {
  log "[prep] Adding Microsoft prod + Fluent Bit apt repos"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl apt-transport-https gpg

  if [[ ! -f /usr/share/keyrings/microsoft-prod.gpg ]]; then
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
      | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
  fi
  # Always (re)write the list so the arch is correct even if the key already
  # existed from an earlier run (e.g. an amd64 pin left over on an arm64 host).
  echo "deb [arch=${DEB_ARCH} signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main" \
    | sudo tee /etc/apt/sources.list.d/microsoft-prod.list >/dev/null

  if [[ ! -f /usr/share/keyrings/fluentbit-keyring.gpg ]]; then
    curl -fsSL https://packages.fluentbit.io/fluentbit.key \
      | sudo gpg --dearmor -o /usr/share/keyrings/fluentbit-keyring.gpg
  fi
  echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/ubuntu/noble noble main" \
    | sudo tee /etc/apt/sources.list.d/fluent-bit.list >/dev/null
  sudo apt-get update
}

prep_azcli() {
  # The provision phase drives everything through `az`. Install the native Linux
  # azure-cli so `az` does NOT fall through to the Windows CLI via WSL interop
  # (which fails with "Invalid argument" inside WSL).
  if command -v az >/dev/null 2>&1 && [[ "$(command -v az)" == /usr/bin/* || "$(command -v az)" == /opt/* ]]; then
    log "[prep] Linux azure-cli already present ($(command -v az))"
    hash -r
    return
  fi
  log "[prep] Installing native Linux azure-cli"
  # Prefer apt (fast, if the azure-cli repo is present). The Microsoft *prod*
  # repo doesn't reliably carry azure-cli for Noble, so fall back to Microsoft's
  # official installer script, which adds the dedicated azure-cli repo itself.
  if ! sudo apt-get install -y azure-cli 2>/dev/null; then
    log "[prep]   apt couldn't find azure-cli; using official installer (aka.ms/InstallAzureCLIDeb)"
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  fi
  command -v az >/dev/null 2>&1 || die "azure-cli install failed — 'az' not found after install"
  hash -r
}

prep_hci_ext_deps() {
  log "[prep] Installing HCI extension dependencies (BMAgent / observability)"
  # Observability + device-management deps (LinuxEdgeObservability etc.). These
  # are available on both amd64 and arm64 (dotnet from Ubuntu, fluent-bit from
  # the fluentbit.io repo) and are always required.
  sudo apt-get install -y aspnetcore-runtime-8.0 dotnet-runtime-8.0 \
                          fluent-bit lttng-tools liblttng-ust1 inotify-tools

  # libkmpp (libkmpp.so.1) was needed by OLDER AksArcBareMetalAgent extension
  # builds. Microsoft publishes it for amd64 ONLY (no arm64 Ubuntu .deb exists;
  # its SymCrypt dep isn't packaged for arm64 Ubuntu). Per the BMAgent owner the
  # LATEST extension no longer requires it, so on arm64 we skip it rather than
  # fail. On amd64 we still install it to preserve behaviour for older CMPs.
  if [[ "$DEB_ARCH" == "amd64" ]]; then
    sudo apt-get install -y libkmpp
  else
    log "[prep] Skipping libkmpp on $DEB_ARCH (no arm64 build; latest BMAgent extension does not require it)"
  fi
}

prep_k8s_tools() {
  # k3s bundles its own networking; only kubeadm/k8s needs the preflight tools.
  if [[ "$DISTRIBUTION" == "k8s" ]]; then
    log "[prep] Installing kubeadm preflight tools (iptables/conntrack/socat/ebtables/ethtool)"
    sudo apt-get install -y iptables conntrack socat ebtables ethtool
  else
    log "[prep] Skipping kubeadm preflight tools (k3s)"
  fi
}

prep_prepull_images() {
  if [[ "$DISTRIBUTION" != "k8s" ]]; then
    log "[prep] Skipping control-plane image pre-pull (k3s is a single binary)"
    return
  fi
  log "[prep] Installing containerd and pre-pulling control-plane images (imagePullPolicy=Never)"
  sudo apt-get install -y containerd
  sudo systemctl enable --now containerd || true   # systemd may not be PID1 yet; re-ensured in provision

  local ver="v${K8S_VERSION%%-*}"     # 1.33.3-20251001 -> v1.33.3
  local repo="mcr.microsoft.com/oss/v2/kubernetes"
  local kubeadm=/tmp/kubeadm-prepull

  curl -fsSL --output "$kubeadm" "https://dl.k8s.io/release/${ver}/bin/linux/${DEB_ARCH}/kubeadm"
  chmod +x "$kubeadm"

  # Pull each image kubeadm expects (skip etcd; BMAgent rewrites the tag — pulled explicitly below).
  "$kubeadm" config images list --kubernetes-version="${ver}" --image-repository="${repo}" | while read -r img; do
    case "$img" in *etcd*) continue ;; esac
    log "[prep]   pulling $img"
    sudo ctr -n k8s.io image pull "$img"
  done

  # Explicit etcd/pause tags BMAgent's kubeadm config rewrites to (see versions.go).
  sudo ctr -n k8s.io image pull mcr.microsoft.com/oss/v2/etcd-io/etcd:v3.6.7
  sudo ctr -n k8s.io image pull mcr.microsoft.com/oss/v2/kubernetes/pause:3.9
  rm -f "$kubeadm"
}

run_prep() {
  log "=== PHASE: prep (distribution=$DISTRIBUTION) ==="
  NEEDS_RESTART=0
  prep_wsl_conf
  prep_waagent_perms
  prep_boot_hardening
  prep_apt_repos
  prep_azcli
  prep_hci_ext_deps
  prep_k8s_tools
  prep_prepull_images
  log "=== prep complete ==="
  if [[ "${NEEDS_RESTART:-0}" == "1" ]]; then
    echo
    echo "  ACTION REQUIRED: systemd was just enabled. From the Windows host run:"
    echo "      wsl --shutdown"
    echo "  then re-enter WSL and run:  ./setup-aks-arc-wsl.sh --phase provision"
    echo "  (The aks-arc-on-wsl.ps1 orchestrator does this automatically.)"
  fi
}

# -----------------------------------------------------------------------------
# Phase: PROVISION  (after systemd is PID 1)
# Implements docs/wsl/k8s/wsl-edge-setup.md steps 1(Part B)-14. Idempotent + fail-fast.
# -----------------------------------------------------------------------------

# ---- Constants (read from config; defaults from the guide) ------------------
C2E_TRUSTED_APP_ID="${C2E_TRUSTED_APP_ID:-89ad4ee6-8387-4829-9ce1-885479863c60}"   # CAPE C2E appId (Step 7)
EM_API="${EM_API:-2025-12-01-preview}"
DP_API="${DP_API:-2024-11-01-preview}"
EXT_API="${EXT_API:-2024-07-10}"
ARC_API="${ARC_API:-2023-03-15-preview}"
ADO_RESOURCE_ID="${ADO_RESOURCE_ID:-499b84ac-1321-427f-aa17-267ca6975798}"          # Azure DevOps AAD app
ADO_BASE_URL="${ADO_BASE_URL:-https://dev.azure.com/msazure/msk8s/_apis}"
BMAGENT_ARTIFACT="${BMAGENT_ARTIFACT:-drop_unifiedBuild_bmagent}"
BMAGENT_REPLACE_SCRIPT_PATH="${BMAGENT_REPLACE_SCRIPT_PATH:-/.pipelines/aksarc-bmlinux/scripts/bmagent-replace-phase2.sh}"
BMAGENT_BUILD_DEFINITION="${BMAGENT_BUILD_DEFINITION:-428700}"                      # unified-build pipeline (hot-swap only)
DNS="${DNS:-8.8.8.8}"                                                               # LogicalNetwork DNS (schema paperwork on WSL)
VM_SWITCH="${VM_SWITCH:-wsl-noop}"                                                  # placeholder vm-switch (SFF provisions no VMs)
# HCI_ROLES is a '|'-delimited list in config; parse into an array here.
IFS='|' read -r -a HCI_ROLES <<< "${HCI_ROLES:-Azure Stack HCI Device Management Role|Azure Stack HCI Edge Machine Contributor Role|Key Vault Secrets User}"

set_derived_ids() {
  MACHINE_NAME="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  CUSTOM_LOCATION_NAME="${MACHINE_NAME}-cl"
  DEVICE_POOL_NAME="${MACHINE_NAME}-dp"
  LNET_NAME="${MACHINE_NAME}-lnet"
  CLUSTER_NAME="${MACHINE_NAME}-cluster"
  EDGE_SUB="${CMP_SUB}"; EDGE_RG="${CMP_RG}"; EDGE_LOCATION="${EDGE_LOCATION:-eastus2euap}"
  ARC_MACHINE_ID="/subscriptions/${EDGE_SUB}/resourceGroups/${EDGE_RG}/providers/Microsoft.HybridCompute/machines/${MACHINE_NAME}"
  EM_ID="/subscriptions/${EDGE_SUB}/resourceGroups/${EDGE_RG}/providers/Microsoft.AzureStackHCI/EdgeMachines/${MACHINE_NAME}"
  DP_ID="/subscriptions/${EDGE_SUB}/resourceGroups/${EDGE_RG}/providers/Microsoft.AzureStackHCI/DevicePools/${DEVICE_POOL_NAME}"
  CUSTOM_LOCATION_ID="/subscriptions/${EDGE_SUB}/resourceGroups/${EDGE_RG}/providers/Microsoft.ExtendedLocation/customLocations/${CUSTOM_LOCATION_NAME}"
  LNET_ID="/subscriptions/${EDGE_SUB}/resourceGroups/${EDGE_RG}/providers/Microsoft.AzureStackHCI/logicalNetworks/${LNET_NAME}"
  # DevicePool routing tags → the CMP
  CMP_AKS_ARM_ID="/subscriptions/${CMP_SUB}/resourceGroups/${CMP_RG}/providers/Microsoft.ContainerService/managedClusters/${CMP_AKS}"
  CMP_CONN_ID="/subscriptions/${CMP_SUB}/resourceGroups/${CMP_RG}/providers/Microsoft.Kubernetes/connectedClusters/${CMP_CONN}"
  # ExtensionIDs uses RELATIVE extension paths (not full ARM IDs) — this is both
  # what CAPE/HCI RP expects and required to stay under Azure's 256-char tag-value
  # limit. See docs/wsl/k8s/wsl-edge-setup.md and the create-aksarc-cluster skill.
  CMP_EXT_IDS="/providers/Microsoft.KubernetesConfiguration/extensions/aksarc,/providers/Microsoft.KubernetesConfiguration/extensions/cloud2edgeconnectivity,/providers/Microsoft.KubernetesConfiguration/extensions/azurelocalnetworking"
}

verify_systemd() {
  log "[provision] Verifying systemd is PID 1"
  local pid1; pid1="$(ps -p 1 -o comm= || true)"
  [[ "$pid1" == "systemd" ]] || die "systemd is not PID 1 (got '$pid1'). Run 'wsl --shutdown' from Windows, re-enter, and retry --phase provision."
  sudo nsenter -t 1 -m -- mount --make-rshared / 2>/dev/null || true   # idempotent
  # Reliably enable containerd HERE (systemd is confirmed PID 1 now). The prep
  # phase runs before the systemd restart, so its `systemctl enable containerd`
  # can silently no-op — leaving containerd not-started after a WSL VM restart,
  # which crash-loops kubelet ("containerd.sock: no such file or directory") and
  # takes the whole cluster to Unknown. Enabling it here makes it survive the
  # WSL restarts (vmIdleTimeout / sleep) that this POC is subject to.
  if [[ "$DISTRIBUTION" == "k8s" ]]; then
    sudo systemctl enable --now containerd >/dev/null 2>&1 \
      || die "failed to enable/start containerd (required by kubelet). Check 'systemctl status containerd'."
  fi
}

# The aksarc extension depends on asyncssh; on bleeding-edge az/Python, `az
# extension add` pulls asyncssh>=2.18 which hard-imports `mlkem` (ML-KEM PQ).
# That symbol only exists in cryptography>=50 (unreleased), and bumping
# cryptography that high breaks az's pyopenssl(<47)/msal(<49) pins. So instead
# we pin asyncssh back to the last pre-ML-KEM release (2.17.0) inside the
# extension dir, which works with az's shipped cryptography. Idempotent.
ASYNCSSH_SAFE_VERSION="2.17.0"
fix_aksarc_asyncssh() {
  local azpy=/opt/az/bin/python3
  if [[ ! -x "$azpy" ]]; then
    azpy="$(az --version 2>/dev/null | sed -n "s/.*Python location '\([^']*\)'.*/\1/p" | head -1)"
  fi
  [[ -x "${azpy:-}" ]] || { warn "[provision] could not locate az's Python; skipping asyncssh pin"; return 0; }
  local extdir="$HOME/.azure/cliextensions/aksarc"
  [[ -d "$extdir" ]] || return 0
  # Determine the asyncssh version currently bundled in the extension dir. The
  # wheel install re-pulls the latest asyncssh (>=2.18 hard-imports ML-KEM), so
  # gate purely on the version file — an import probe is unreliable here.
  local cur=""
  [[ -f "$extdir/asyncssh/version.py" ]] && \
    cur="$(sed -n "s/.*__version__ = '\([^']*\)'.*/\1/p" "$extdir/asyncssh/version.py" | head -1)"
  if [[ "$cur" == "$ASYNCSSH_SAFE_VERSION" ]]; then
    log "[provision] aksarc asyncssh already pinned to $ASYNCSSH_SAFE_VERSION"
    return 0
  fi
  # Re-pin if the bundled asyncssh is >= 2.18 (ML-KEM) or unknown.
  if [[ -n "$cur" ]] && printf '%s\n%s\n' "2.18.0" "$cur" | sort -V -C 2>/dev/null; then
    : # cur >= 2.18.0 → needs downgrade (fall through)
  elif [[ -z "$cur" ]]; then
    : # unknown → force a known-good pin
  else
    log "[provision] aksarc asyncssh $cur predates ML-KEM; leaving as-is"
    return 0
  fi
  log "[provision] Pinning asyncssh==$ASYNCSSH_SAFE_VERSION in $extdir (was '${cur:-none}'; avoids ML-KEM/cryptography>=50 crash)"
  rm -rf "$extdir"/asyncssh "$extdir"/asyncssh-*.dist-info
  "$azpy" -m pip install --no-deps --target "$extdir" "asyncssh==$ASYNCSSH_SAFE_VERSION" \
    || die "failed to pin asyncssh==$ASYNCSSH_SAFE_VERSION into $extdir"
}

verify_prereqs() {
  log "[provision] Verifying prerequisites"
  require_cmd az
  # Guard against WSL interop resolving `az` to the Windows CLI, which cannot run
  # inside WSL (fails with "Invalid argument"). Require a native Linux az.
  case "$(command -v az)" in
    /mnt/*) die "az resolves to the Windows CLI ($(command -v az)); install Linux azure-cli (rerun --phase prep) and 'hash -r'" ;;
  esac
  az account show >/dev/null 2>&1 || die "not logged in — run 'az login' inside WSL first"
  [[ -n "${CMP_RG:-}" && "$CMP_RG" != "REPLACE-WITH-YOUR-DEV-CMP-RG" ]] || die "CMP_RG is not set in config"
  az account set --subscription "$CMP_SUB"
  # Re-validate the token is still usable (it can expire mid-session, ~12h);
  # otherwise the health check below silently returns 0 and looks like an
  # unhealthy CMP. Fail fast with a clear message instead.
  az rest --method GET --url "https://management.azure.com/subscriptions/${CMP_SUB}?api-version=2022-12-01" >/dev/null 2>&1 \
    || die "az token expired or invalid (re-run 'az login --use-device-code' and set the subscription), then retry"
  # CMP must be healthy (3 extensions Succeeded). Use az rest (not
  # 'az k8s-extension list', which needs the k8s-extension CLI ext and can
  # dynamic-install-prompt) for a dependency-free, deterministic check.
  local n
  n="$(az rest --method GET \
        --url "https://management.azure.com/subscriptions/${CMP_SUB}/resourceGroups/${CMP_RG}/providers/Microsoft.Kubernetes/connectedClusters/${CMP_CONN}/providers/Microsoft.KubernetesConfiguration/extensions?api-version=2023-05-01" \
        --query "length(value[?properties.provisioningState=='Succeeded' && (properties.extensionType=='microsoft.aksarc' || properties.extensionType=='microsoft.cloud2edgeconnectivity' || properties.extensionType=='microsoft.azurelocalnetworking')])" -o tsv 2>/dev/null || echo 0)"
  [[ "$n" == "3" ]] || die "CMP $CMP_RG does not have all 3 extensions Succeeded (found $n). Pick a healthy main-branch CMP (or re-check 'az login')."
  # aksarc CLI: install the private wheel from config path (if provided), then
  # verify --network-policy is present (the SFF webhook requires it).
  if [[ -n "${AKSARC_WHEEL_PATH:-}" ]]; then
    [[ -f "$AKSARC_WHEEL_PATH" ]] || die "AKSARC_WHEEL_PATH set but file not found: $AKSARC_WHEEL_PATH"
    log "[provision] Installing aksarc CLI extension from $AKSARC_WHEEL_PATH"
    az extension remove --name aksarc 2>/dev/null || true
    az extension add --source "$AKSARC_WHEEL_PATH" --yes
  fi
  fix_aksarc_asyncssh
  local netpol; netpol="$(az aksarc create --help 2>/dev/null | grep -c -- '--network-policy' || true)"
  if [[ "$netpol" -lt 1 ]]; then
    # Surface the real error (e.g. a dependency ImportError) instead of the
    # misleading "lacks --network-policy" when --help crashed before arg-load.
    az aksarc create --help >/dev/null 2>/tmp/aksarc-help.err || true
    [[ -s /tmp/aksarc-help.err ]] && { warn "[provision] 'az aksarc create --help' errored:"; sed 's/^/    /' /tmp/aksarc-help.err >&2; }
    die "aksarc CLI lacks --network-policy (or --help crashed; see error above). Ensure AKSARC_WHEEL_PATH points to the private wheel (hybridaks-utils branch users/lumbaeshaan/add-flannel-network-policy) and that az deps are compatible, then re-run."
  fi
  if [[ ! -f "$HOME/.ssh/id_rsa.pub" ]]; then
    log "[provision] Generating SSH keypair"; ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N ""
  fi
}

# Step 1 Part B — discover WSL networking, compute LNet params
discover_network() {
  log "[provision] (Step 1B) Discovering WSL networking"
  local iface last vip_last
  iface="$(ip -4 route | awk '/^default/ {print $5; exit}')"
  [[ -n "$iface" ]] || die "could not determine default interface"
  WSL_IP="$(ip -o -4 addr show "$iface" | awk '{split($4,a,"/"); print a[1]}')"
  WSL_SUBNET_CIDR="$(ip -4 route show dev "$iface" | awk '/\// && !/default/ {print $1; exit}')"
  WSL_GATEWAY="$(ip -4 route | awk '/^default/ {print $3; exit}')"
  last="$(echo "$WSL_IP" | awk -F. '{print $4}')"
  if [[ "$last" -ge 255 ]]; then vip_last=$((last-1)); else vip_last=$((last+1)); fi
  WSL_VIP="$(echo "$WSL_IP" | awk -F. -v n="$vip_last" '{print $1"."$2"."$3"."n}')"
  ADDRESS_PREFIX="$WSL_SUBNET_CIDR"; VM_IP="$WSL_IP"; VIP="$WSL_VIP"; GATEWAY="$WSL_GATEWAY"
  [[ "$VM_IP" != "$VIP" ]] || die "VM_IP and VIP must differ"
  log "[provision]   iface=$iface IP=$WSL_IP VIP=$WSL_VIP subnet=$WSL_SUBNET_CIDR gw=$WSL_GATEWAY"
}

# Resolve AZURE_VM_HOST=auto by probing IMDS (reachable through WSL NAT if the
# Windows host is an Azure VM / Dev Box). The PS1 orchestrator may also set this.
resolve_azure_vm_host() {
  AZURE_VM_HOST="${AZURE_VM_HOST:-auto}"
  if [[ "$AZURE_VM_HOST" == "auto" ]]; then
    if curl -s -m 3 -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" >/dev/null 2>&1; then
      AZURE_VM_HOST="true";  log "[provision] Azure-VM host detected → MSFT_ARC_TEST + IMDS blackhole enabled"
    else
      AZURE_VM_HOST="false"; log "[provision] Physical host (no IMDS) → skipping MSFT_ARC_TEST/IMDS"
    fi
  fi
}

# Step 3 — blackhole IMDS (only on Azure-VM hosts)
provision_block_imds() {
  if [[ "${AZURE_VM_HOST}" == "true" ]]; then
    log "[provision] (Step 3) Azure-VM host → blackholing IMDS"
    sudo ip route add blackhole 169.254.169.254 2>/dev/null || true   # idempotent (may already exist)
  fi
}

# Step 4 — Arc-connect the WSL host
provision_arc_connect() {
  log "[provision] (Step 4) Arc-connect"
  if azcmagent show 2>/dev/null | grep -q 'Agent Status *: *Connected'; then
    log "[provision]   already Connected (ok)"; return
  fi
  local arc_env=""; [[ "$AZURE_VM_HOST" == "true" ]] && arc_env="MSFT_ARC_TEST=true"
  if ! command -v azcmagent >/dev/null 2>&1; then
    log "[provision]   installing azcmagent"
    curl -sSL -o /tmp/install_linux_azcmagent.sh https://aka.ms/azcmagent
    sudo env $arc_env bash /tmp/install_linux_azcmagent.sh
  fi
  local token; token="$(az account get-access-token --query accessToken -o tsv | tr -cd '[:print:]')"
  [[ -n "$token" ]] || die "failed to acquire access token"
  log "[provision]   connecting as machine '$MACHINE_NAME'"
  sudo env $arc_env azcmagent connect \
    --resource-group "$EDGE_RG" --tenant-id "$TENANT_ID" --location "$EDGE_LOCATION" \
    --subscription-id "$EDGE_SUB" --cloud AzureCloud --correlation-id "$(cat /proc/sys/kernel/random/uuid)" \
    --access-token "$token"
  azcmagent show | grep -q 'Agent Status *: *Connected' || die "azcmagent connect did not reach Connected"
}

# Step 5-6 — EdgeMachine PUT + poll
provision_edgemachine() {
  log "[provision] (Step 5-6) EdgeMachine"
  local body; body="$(cat <<JSON
{ "location": "$EDGE_LOCATION", "identity": { "type": "SystemAssigned" },
  "properties": { "arcMachineResourceId": "$ARC_MACHINE_ID", "edgeMachineKind": "Dedicated" },
  "tags": { "purpose": "wsl-poc" } }
JSON
)"
  az rest --method PUT --resource "https://management.azure.com/" \
    --url "https://management.azure.com${EM_ID}?api-version=${EM_API}" --body "$body" >/dev/null
  log "[provision]   polling EdgeMachine provisioningState (5-20 min)..."
  local state
  for _ in $(seq 1 80); do
    state="$(az rest --method GET --resource "https://management.azure.com/" \
      --url "https://management.azure.com${EM_ID}?api-version=${EM_API}" --query "properties.provisioningState" -o tsv 2>/dev/null || true)"
    log "[provision]   EdgeMachine: ${state:-<none>}"
    [[ "$state" == "Succeeded" ]] && return
    [[ "$state" == "Failed" ]] && die "EdgeMachine provisioning Failed"
    sleep 30
  done
  die "EdgeMachine did not reach Succeeded in time"
}

# Step 7 — BMAgent C2E trustedCloudSideAppId patch (best-effort).
# On the SFF VHD flow HCI RP pre-installs BMAgent (sometimes with the wrong
# trustedCloudSideAppId), so this patch corrects it. On the WSL/Ubuntu flow HCI
# RP does NOT pre-install BMAgent — CAPE installs it later during the DevicePool
# /CustomLocation reconcile (Step 10) with the cert AND the correct
# trustedCloudSideAppId already applied (edgemachine_impl2.go). So if the
# extension isn't present yet, skip rather than fail: Step 10 handles it.
provision_bmagent_patch() {
  log "[provision] (Step 7) Patch BMAgent trustedCloudSideAppId (best-effort)"
  local ext; ext="$(az rest --method GET --resource "https://management.azure.com/" \
    --url "https://management.azure.com${ARC_MACHINE_ID}/extensions?api-version=${EXT_API}" \
    --query "value[?contains(name, 'BareMetalAgent')] | [0].name" -o tsv 2>/dev/null || true)"
  if [[ -z "$ext" ]]; then
    log "[provision]   BMAgent extension not present yet — HCI RP didn't pre-install it (expected on WSL)."
    log "[provision]   CAPE will install it with the correct settings during Step 10 (DevicePool/CustomLocation). Skipping patch."
    return 0
  fi
  local body; body="$(cat <<JSON
{ "properties": { "settings": { "BareMetalAgentConfiguration": {
    "trustedCloudSideAppId": "$C2E_TRUSTED_APP_ID", "trustedTenantId": "$TENANT_ID",
    "taskExecutionTimeoutInMinutes": 20, "taskExecutionTimeoutWhenUpgradeInMinutes": 5 } } } }
JSON
)"
  az rest --method PATCH --resource "https://management.azure.com/" \
    --url "https://management.azure.com${ARC_MACHINE_ID}/extensions/${ext}?api-version=${EXT_API}" --body "$body" >/dev/null
  BMA_EXT_NAME="$ext"
  log "[provision]   patched BMAgent extension '$ext'"
}

# Step 8 — RBAC on the edge RG
provision_rbac() {
  log "[provision] (Step 8) RBAC on edge RG"
  local oid; oid="$(az rest --method GET --resource "https://management.azure.com/" \
    --url "https://management.azure.com${ARC_MACHINE_ID}?api-version=${ARC_API}" --query "identity.principalId" -o tsv)"
  [[ -n "$oid" ]] || die "could not read Arc machine MI principalId"
  local scope="/subscriptions/${EDGE_SUB}/resourceGroups/${EDGE_RG}"
  az role assignment create --assignee-object-id "$oid" --assignee-principal-type ServicePrincipal \
    --role Contributor --scope "$scope" 2>/dev/null || log "[provision]   Contributor already assigned"
  local role
  for role in "${HCI_ROLES[@]}"; do
    az role assignment create --assignee-object-id "$oid" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" 2>/dev/null || log "[provision]   '$role' already assigned"
  done
}

# Step 9 — BMAgent hot-swap with the unified build (OPTIONAL, gated by config)
provision_bmagent_hotswap() {
  if [[ "${ENABLE_BMAGENT_HOTSWAP:-false}" != "true" ]]; then
    # For k3s the marketplace BMAgent rejects k3s's /etc/rancher/k3s/config.yaml
    # ("error 4003: file path rejected"), so the hot-swap is effectively required —
    # fail fast with a clear message instead of marching into the known failure.
    if [[ "$DISTRIBUTION" == "k3s" ]]; then
      die "DISTRIBUTION=k3s requires ENABLE_BMAGENT_HOTSWAP=true (marketplace BMAgent rejects k3s config.yaml, error 4003). Set it in wsl-config.env and re-run."
    fi
    log "[provision] (Step 9) BMAgent hot-swap DISABLED (ENABLE_BMAGENT_HOTSWAP=false) — using marketplace BMAgent."
    log "[provision]   If cluster create fails at node init (NeedNodeInit 404 / file path rejected), set ENABLE_BMAGENT_HOTSWAP=true and re-run."
    return
  fi
  # BMAgent hot-swap applies to BOTH k8s and k3s. For k3s it is effectively
  # required: the marketplace BMAgent rejects k3s's /etc/rancher/k3s/config.yaml
  # with "error 4003: file path rejected" — the unified-build binary has the
  # updated allowlist (see docs/wsl/k3s/wsl-edge-setup.md). Enable via
  # ENABLE_BMAGENT_HOTSWAP=true (recommended-on for k3s).
  log "[provision] (Step 9) BMAgent hot-swap (unified build ${BMAGENT_BUILD_DEFINITION})"
  local adotok base build url
  adotok="$(az account get-access-token --resource "$ADO_RESOURCE_ID" --query accessToken -o tsv)"
  base="$ADO_BASE_URL"
  build="$(curl -sSL -H "Authorization: Bearer $adotok" \
    "${base}/build/builds?definitions=${BMAGENT_BUILD_DEFINITION}&branchName=refs/heads/main&statusFilter=completed&resultFilter=succeeded&\$top=1&api-version=7.0" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['value'][0]['id'])")"
  [[ -n "$build" ]] || die "no successful BMAgent unified build found"
  url="$(curl -sSL -H "Authorization: Bearer $adotok" \
    "${base}/build/builds/${build}/artifacts?artifactName=${BMAGENT_ARTIFACT}&api-version=7.0" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['resource']['downloadUrl'])")"
  sudo curl -sSL -H "Authorization: Bearer $adotok" -o /tmp/bmagent-staged.zip "$url"
  curl -sSL -H "Authorization: Bearer $adotok" \
    "${base}/git/repositories/Aks-Arc-Assembly/items?path=${BMAGENT_REPLACE_SCRIPT_PATH}&versionType=branch&version=main&api-version=7.0" \
    -o /tmp/bmagent-replace-phase2.sh
  head -1 /tmp/bmagent-replace-phase2.sh | grep -q '^#!' || die "bmagent-replace-phase2.sh download looks invalid"
  sudo bash /tmp/bmagent-replace-phase2.sh
}

# Step 10 — DevicePool (creates the CustomLocation), poll
provision_devicepool() {
  log "[provision] (Step 10) DevicePool + CustomLocation"
  # Skip the PUT if the DevicePool is already Succeeded — re-PUTting re-runs a
  # full ARM reconcile (~9 min back to Succeeded) for no benefit on retries.
  local cur; cur="$(az rest --method GET --resource "https://management.azure.com/" \
    --url "https://management.azure.com${DP_ID}?api-version=${DP_API}" --query "properties.provisioningState" -o tsv 2>/dev/null || true)"
  if [[ "$cur" == "Succeeded" ]]; then
    log "[provision]   DevicePool already Succeeded — skipping PUT"
    return 0
  fi
  local body; body="$(cat <<JSON
{ "location": "$EDGE_LOCATION", "identity": { "type": "SystemAssigned" },
  "properties": { "devices": [ { "deviceResourceId": "$EM_ID" } ], "customLocationName": "$CUSTOM_LOCATION_NAME" },
  "tags": { "Region": "$EDGE_LOCATION", "TenantID": "$TENANT_ID",
    "AksArmID": "$CMP_AKS_ARM_ID", "ConnectedClusterID": "$CMP_CONN_ID", "ExtensionIDs": "$CMP_EXT_IDS" } }
JSON
)"
  az rest --method PUT --resource "https://management.azure.com/" \
    --url "https://management.azure.com${DP_ID}?api-version=${DP_API}" --body "$body" >/dev/null
  local state
  for _ in $(seq 1 150); do
    state="$(az rest --method GET --resource "https://management.azure.com/" \
      --url "https://management.azure.com${DP_ID}?api-version=${DP_API}" --query "properties.provisioningState" -o tsv 2>/dev/null || true)"
    log "[provision]   DevicePool: ${state:-<none>}"
    [[ "$state" == "Succeeded" ]] && return
    [[ "$state" == "Failed" ]] && die "DevicePool provisioning Failed"
    sleep 10
  done
  die "DevicePool did not reach Succeeded in time (waited 25 min)"
}

# Step 10b — best-effort BMAgent check. NOTE: on this flow BMAgent is installed
# by CAPE during the EdgeMachine reconcile that runs at CLUSTER CREATE (Step 13),
# NOT at DevicePool creation — verified empirically (DevicePool + CustomLocation
# both Succeeded with no BMAgent extension present). So this is a quick, non-fatal
# probe: if BMAgent already exists we verify its trust settings; otherwise we log
# and continue — cluster create will install it with the correct
# trustedCloudSideAppId (edgemachine_impl2.go sets 89ad… itself).
provision_wait_bmagent() {
  log "[provision] (Step 10b) Best-effort BMAgent check (installed by CAPE at cluster create)"
  local ext state
  for _ in $(seq 1 6); do
    ext="$(az rest --method GET --resource "https://management.azure.com/" \
      --url "https://management.azure.com${ARC_MACHINE_ID}/extensions?api-version=${EXT_API}" \
      --query "value[?contains(name, 'BareMetalAgent')] | [0].name" -o tsv 2>/dev/null || true)"
    if [[ -n "$ext" ]]; then
      state="$(az rest --method GET --resource "https://management.azure.com/" \
        --url "https://management.azure.com${ARC_MACHINE_ID}/extensions/${ext}?api-version=${EXT_API}" \
        --query "properties.provisioningState" -o tsv 2>/dev/null || true)"
      log "[provision]   BMAgent '$ext': ${state:-<none>}"
      if [[ "$state" == "Succeeded" ]]; then
        BMA_EXT_NAME="$ext"
        local body; body="$(cat <<JSON
{ "properties": { "settings": { "BareMetalAgentConfiguration": {
    "trustedCloudSideAppId": "$C2E_TRUSTED_APP_ID", "trustedTenantId": "$TENANT_ID",
    "taskExecutionTimeoutInMinutes": 20, "taskExecutionTimeoutWhenUpgradeInMinutes": 5 } } } }
JSON
)"
        az rest --method PATCH --resource "https://management.azure.com/" \
          --url "https://management.azure.com${ARC_MACHINE_ID}/extensions/${ext}?api-version=${EXT_API}" --body "$body" >/dev/null 2>&1 \
          && log "[provision]   verified/patched BMAgent trustedCloudSideAppId" \
          || warn "[provision]   BMAgent settings patch failed (CAPE-applied settings likely already correct)"
        return 0
      fi
    fi
    sleep 10
  done
  log "[provision]   BMAgent not present yet — expected; CAPE installs it during cluster create (Step 13). Continuing."
}

# Step 11 — LogicalNetwork
provision_lnet() {
  log "[provision] (Step 11) LogicalNetwork"
  az extension add --name stack-hci-vm --only-show-errors 2>/dev/null || true
  local pools; pools="$(cat <<JSON
[ {"start":"$VM_IP","end":"$VM_IP","ip_pool_type":"vm"}, {"start":"$VIP","end":"$VIP","ip_pool_type":"vippool"} ]
JSON
)"
  local pf; pf="$(mktemp)"; printf '%s' "$pools" > "$pf"
  az stack-hci-vm network lnet create \
    --resource-group "$EDGE_RG" --custom-location "$CUSTOM_LOCATION_ID" --location "$EDGE_LOCATION" \
    --name "$LNET_NAME" --ip-allocation-method Static --address-prefixes "$ADDRESS_PREFIX" \
    --ip-pools "@$pf" --gateway "$GATEWAY" --vm-switch-name "$VM_SWITCH" --dns-servers "$DNS" \
    --subscription "$EDGE_SUB"
  rm -f "$pf"
}

# Step 13 — az aksarc create
provision_cluster() {
  log "[provision] (Step 13) az aksarc create"
  local netpol="cilium"; [[ "$DISTRIBUTION" == "k3s" ]] && netpol="flannel"
  local ssh; ssh="$(tr -d '\r\n' < "$HOME/.ssh/id_rsa.pub")"
  az aksarc create \
    --resource-group "$EDGE_RG" --name "$CLUSTER_NAME" --location "$EDGE_LOCATION" \
    --custom-location "$CUSTOM_LOCATION_ID" --vnet-ids "$LNET_ID" \
    --control-plane-count 1 --kubernetes-version "$K8S_VERSION" \
    --ssh-key-value "$ssh" --network-policy "$netpol" \
    --disable-nfs-driver --disable-smb-driver --subscription "$EDGE_SUB"
}

# Step 14 — verify
provision_verify() {
  log "[provision] (Step 14) Verify node readiness"
  local kc="/etc/kubernetes/admin.conf"; [[ "$DISTRIBUTION" == "k3s" ]] && kc="/etc/rancher/k3s/k3s.yaml"

  # Distribution sanity check: the CMP decides the distribution (its operator's
  # default — K8s, or K3s if the CMP was installed with distribution.default=K3s;
  # see ADO Task 38680149). If we asked for k3s but the node came up k8s (or vice
  # versa), the CMP wasn't configured for the distribution we expect — surface it
  # clearly instead of leaving a confusing half-broken cluster.
  local actual="unknown"
  if systemctl is-active --quiet k3s 2>/dev/null || [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    actual="k3s"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    actual="k8s"
  fi
  if [[ "$actual" != "unknown" && "$actual" != "$DISTRIBUTION" ]]; then
    warn "[provision]   DISTRIBUTION=$DISTRIBUTION but the node came up as '$actual'."
    warn "[provision]   The CMP's default distribution likely doesn't match. For k3s the CMP"
    warn "[provision]   must be installed with the aksarc extension config distribution.default=K3s"
    warn "[provision]   (ADO Task 38680149). Point at a k3s-configured CMP, or set DISTRIBUTION=$actual."
    kc="/etc/kubernetes/admin.conf"; [[ "$actual" == "k3s" ]] && kc="/etc/rancher/k3s/k3s.yaml"
  elif [[ "$actual" != "unknown" ]]; then
    log "[provision]   distribution confirmed: $actual"
  fi

  if [[ -f "$kc" ]]; then
    sudo KUBECONFIG="$kc" kubectl get nodes -o wide || warn "kubectl get nodes failed (cluster may still be settling)"
  else
    warn "kubeconfig $kc not found yet — check 'az aksarc show' / CMP DevicePool namespace"
  fi
  log "[provision] DONE — cluster '$CLUSTER_NAME' create submitted."
  echo "  From Windows:  wsl -d ${WSL_DISTRO_NAME:-<distro>} -- sudo KUBECONFIG=$kc kubectl get nodes"
}

run_provision() {
  log "=== PHASE: provision (distribution=$DISTRIBUTION) ==="
  verify_systemd
  set_derived_ids
  verify_prereqs
  resolve_azure_vm_host
  discover_network
  provision_block_imds
  provision_arc_connect
  provision_edgemachine
  provision_bmagent_patch
  provision_rbac
  provision_bmagent_hotswap
  provision_devicepool
  provision_wait_bmagent
  provision_lnet
  provision_cluster
  provision_verify
  log "=== provision complete ==="
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
case "$PHASE" in
  prep)      run_prep ;;
  provision) run_provision ;;
  all)
    run_prep
    if [[ "$(ps -p 1 -o comm= || true)" == "systemd" ]]; then
      run_provision
    else
      warn "systemd not yet PID 1 — run 'wsl --shutdown' then re-run with --phase provision"
    fi
    ;;
esac
