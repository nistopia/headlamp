#!/usr/bin/env bash
# =============================================================================
# setup-aks-arc-deploy.sh  —  AKS Arc on WSL via the PUBLIC `az aksarc deploy`
# =============================================================================
# Runs INSIDE the WSL Ubuntu distro. Provisions an AKS Arc (BareMetal) cluster
# using the productized public-preview flow (no dev CMP): the AKS/HCI resource
# providers create the EdgeMachine/DevicePool/CustomLocation/LogicalNetwork/
# cluster from a single `az aksarc deploy`.
#
# Phases (driven from the Node orchestrator, which handles the systemd restart):
#   --phase prep     OS prep that must precede the systemd restart
#   --phase deploy   Arc-connect the host + `az aksarc deploy`
#   --phase all      prep, then (if systemd already PID 1) deploy
#
# Config file (KEY=VALUE), sourced:
#   SUBSCRIPTION       Azure subscription ID                        (required)
#   RESOURCE_GROUP     Resource group (MUST be in eastus)           (required)
#   TENANT_ID          Microsoft Entra tenant ID                    (required)
#   LOCATION           Region (public preview: eastus only)         (default eastus)
#   AKSARC_WHEEL_PATH  Local .whl to install (e.g. a pipeline build) (optional)
#   AKSARC_BUILD_ID    ADO build id to pull drop_Build_main/dist/*.whl from (optional; needs ADO auth)
#   AKSARC_WHEEL_URL   Public aksarc CLI wheel                       (fallback default)
#   DISTRIBUTION       k8s (default) | k3s (k3s requires a private CMP)
#   CMP_SUBSCRIPTION   Private CMP subscription id                   (k3s/private-CMP)
#   CMP_RESOURCE_GROUP Private CMP resource group                    (k3s/private-CMP)
#   CMP_NAME           Private CMP cluster name (AKS + connected)    (k3s/private-CMP)
#   AUTH_MODE          browser (default) | sp | device-code          (how az/azcmagent sign in)
#   AZURE_CLIENT_ID    Service-principal appId                       (AUTH_MODE=sp)
#   AZURE_CLIENT_SECRET Service-principal secret                     (AUTH_MODE=sp)
#   VALIDATE_ONLY      "true" => `az aksarc deploy --validate` dry-run only
# -----------------------------------------------------------------------------
set -euo pipefail

PHASE=""
CONFIG_FILE="$(dirname "$0")/deploy-config.env"

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
  prep|deploy|all) ;;
  *) echo "ERROR: --phase must be one of: prep | deploy | all" >&2; exit 2 ;;
esac

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config file not found: $CONFIG_FILE" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; source "$CONFIG_FILE"; set +a

SUBSCRIPTION="${SUBSCRIPTION:?SUBSCRIPTION must be set in config}"
RESOURCE_GROUP="${RESOURCE_GROUP:?RESOURCE_GROUP must be set in config}"
TENANT_ID="${TENANT_ID:?TENANT_ID must be set in config}"
LOCATION="${LOCATION:-eastus}"
# aksarc wheel source, in precedence order: local path > ADO build artifact > public URL.
AKSARC_WHEEL_PATH="${AKSARC_WHEEL_PATH:-}"
AKSARC_BUILD_ID="${AKSARC_BUILD_ID:-}"
AKSARC_WHEEL_URL="${AKSARC_WHEEL_URL:-https://hybridaksstorage.z13.web.core.windows.net/HybridAKS/CLI/aksarc-2.0.0b21-py3-none-any.whl}"
VALIDATE_ONLY="${VALIDATE_ONLY:-false}"
# Cluster distribution + private-CMP routing. k3s (and any private CMP) requires the
# pipeline-built wheel that exposes --distribution/--cmp-*; the public wheel does not.
DISTRIBUTION="${DISTRIBUTION:-k8s}"
CMP_SUBSCRIPTION="${CMP_SUBSCRIPTION:-}"
CMP_RESOURCE_GROUP="${CMP_RESOURCE_GROUP:-}"
CMP_NAME="${CMP_NAME:-}"
# Sign-in method. Default 'browser' avoids device-code: az opens the Windows browser
# via wslview so auth happens on the (Conditional-Access-compliant) Windows device,
# and azcmagent reuses that token. 'sp' is fully non-interactive. 'device-code' is the
# old behavior (blocked by CA that requires a compliant device).
AUTH_MODE="${AUTH_MODE:-browser}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}"
AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET:-}"
ASYNCSSH_SAFE_VERSION="2.17.0"

# Well-known appId of the Microsoft.AzureStackHCI resource provider (same in
# every tenant). Its per-tenant object ID is resolved at run time.
HCIRP_APP_ID="1412d89f-b8a8-4111-b4fd-e82905cbd85d"
HCIRP_ROLES=("Azure Connected Machine Resource Manager" "Azure Resource Bridge Deployment Role" "User Access Administrator")

log()  { echo ">>> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Arc machine name = the distro hostname (azcmagent registers under it).
ARC_MACHINE_NAME="$(hostname -s | tr '[:upper:]' '[:lower:]')"
NEEDS_RESTART=0

# -----------------------------------------------------------------------------
# PHASE: prep  (must run before the systemd restart)
# -----------------------------------------------------------------------------
prep_wsl_conf() {
  log "[prep] Configuring /etc/wsl.conf (systemd, rshared mount, hostname)"
  local hn="$ARC_MACHINE_NAME"
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
  log "[prep] /etc/wsl.conf written — a distro restart is REQUIRED to apply systemd"
  NEEDS_RESTART=1
}

prep_waagent_perms() {
  log "[prep] Ensuring /var/lib/waagent exists and is world-writable (extension race fix)"
  sudo mkdir -p /var/lib/waagent
  sudo chmod 777 /var/lib/waagent
}

prep_wsl_interop() {
  # WSL2's systemd-binfmt flushes binfmt_misc on every VM boot/resume and flakily
  # fails to re-register the WSLInterop handler that lets Linux run Windows .exe
  # (cmd.exe / powershell). Without it, wslview can't open the Windows browser, so the
  # interactive `az login` browser flow never completes (AADSTS70008). Install a
  # systemd drop-in that re-adds WSLInterop AFTER systemd-binfmt runs, so it self-heals
  # on every boot. Written now; takes effect after the systemd-applying restart.
  log "[prep] Installing WSLInterop self-heal drop-in (keeps Windows-interop/wslview/az-login working)"
  sudo mkdir -p /etc/systemd/system/systemd-binfmt.service.d
  sudo tee /etc/systemd/system/systemd-binfmt.service.d/keep-wslinterop.conf >/dev/null <<'EOF'
[Service]
ExecStartPost=-/bin/sh -c '[ -e /proc/sys/fs/binfmt_misc/WSLInterop ] || echo ":WSLInterop:M::MZ::/init:PF" > /proc/sys/fs/binfmt_misc/register'
EOF
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  # Also register right now (covers the case where this prep run doesn't trigger a
  # systemd restart, so the currently-running distro regains Windows interop / wslview
  # immediately rather than only on the next boot).
  if [[ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
    echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null 2>&1 || true
  fi
}

prep_boot_hardening() {
  # The deployed cluster's kubelet/containerd/CNI must survive WSL VM restarts
  # (vmIdleTimeout / sleep). Install one systemd unit that re-applies swapoff +
  # rshared mount + containerd on every boot, ordered before kubelet.
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
ExecStart=-/bin/systemctl start containerd.service
[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable wsl-k8s-boot.service >/dev/null 2>&1 || true
}

prep_k3s_wsl_boot() {
  # Two WSL-specific k3s bring-up fixes (see docs/wsl/k3s/k3s-wsl-troubleshooting.md).
  # k3s.service is installed later by BMAgent (NodeInit); these drop-ins/scripts are
  # pre-staged now and take effect once systemd loads that unit.
  #
  # (1) WSL boot-timeout reboot loop: WSL force-reboots the distro (RB_POWER_OFF) if
  #     systemd's boot target isn't reached within ~10s (WaitForBootProcess). k3s is
  #     Type=notify with TimeoutStartSec=0 and starts at boot; etcd+apiserver bootstrap
  #     takes ~13s, so the boot target waits on it and blows past the 10s watchdog ->
  #     reboot loop (never stabilizes; also flushes shared kernel binfmt_misc, killing
  #     interop in other distros). Override Type=exec so systemd considers k3s "started"
  #     as soon as the binary execs (boot completes in <2s); k3s keeps bootstrapping in
  #     the background. BMAgent polls node readiness via kubectl, so it's unaffected.
  #
  # (2) Stale CNI VXLAN conflict: a leftover cilium_vxlan (from a prior Cilium/k8s
  #     cluster on a reused distro) holds VXLAN UDP 8472, so k3s's flannel fails with
  #     "flannel.1 ... address already in use" and k3s crash-loops. Clean stale
  #     cilium/flannel/lxc interfaces before every k3s start via ExecStartPre.
  #
  # k3s-ONLY: these would be HARMFUL under k8s (the CNI cleanup deletes cilium_*
  # interfaces that k8s uses, and the drop-in targets k3s.service which only exists on
  # the k3s path), so gate on DISTRIBUTION=k3s.
  if [[ "${DISTRIBUTION:-k8s}" != "k3s" ]]; then
    log "[prep] Skipping k3s WSL boot fixes (distribution=${DISTRIBUTION:-k8s})"
    return
  fi
  log "[prep] Installing k3s WSL boot fixes (Type=exec vs 10s boot watchdog; stale-CNI cleanup)"
  sudo tee /usr/local/bin/wsl-cni-cleanup.sh >/dev/null <<'EOF'
#!/bin/sh
# Remove stale CNI/VXLAN interfaces that conflict with k3s flannel (UDP 8472).
for i in cilium_vxlan cilium_host cilium_net flannel.1 flannel-v6.1 cni0; do
  ip link delete "$i" 2>/dev/null || true
done
for i in $(ip -o link show 2>/dev/null | awk -F': ' '/lxc/{print $2}' | cut -d@ -f1); do
  ip link delete "$i" 2>/dev/null || true
done
exit 0
EOF
  sudo chmod +x /usr/local/bin/wsl-cni-cleanup.sh
  sudo mkdir -p /etc/systemd/system/k3s.service.d
  sudo tee /etc/systemd/system/k3s.service.d/10-wsl.conf >/dev/null <<'EOF'
[Service]
Type=exec
ExecStartPre=-/usr/local/bin/wsl-cni-cleanup.sh
EOF
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
}

prep_wsl_keepalive() {
  # Defense-in-depth for the WSL idle-termination cycle (Issue 3 in
  # docs/wsl/k3s/k3s-wsl-troubleshooting.md): keep at least one long-running process
  # alive in the distro so it always has work, complementing vmIdleTimeout=-1 set on the
  # Windows side. NOTE: the most reliable pin is a persistent Windows-side
  # `wsl -d aks-edge` holder session; this service is a lightweight in-distro backstop.
  log "[prep] Installing wsl-keepalive systemd service (pin distro / avoid idle-termination)"
  sudo tee /etc/systemd/system/wsl-keepalive.service >/dev/null <<'EOF'
[Unit]
Description=Keep the WSL distro alive (prevent idle-termination reboot loop)
After=multi-user.target
[Service]
ExecStart=/bin/sh -c 'while true; do sleep 3600; done'
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable --now wsl-keepalive.service >/dev/null 2>&1 || true
}

prep_azcli() {
  # Everything is driven through `az`; install the native Linux azure-cli so it
  # does NOT fall through to the Windows CLI via WSL interop.
  if command -v az >/dev/null 2>&1 && [[ "$(command -v az)" == /usr/bin/* || "$(command -v az)" == /opt/* ]]; then
    log "[prep] Linux azure-cli already present ($(command -v az))"
    hash -r
    return
  fi
  log "[prep] Installing native Linux azure-cli"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl apt-transport-https gpg
  if ! sudo apt-get install -y azure-cli 2>/dev/null; then
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  fi
  command -v az >/dev/null 2>&1 || die "azure-cli install failed — 'az' not found"
  hash -r
}

install_observability_deps() {
  # The platform-pushed LinuxEdgeObservability / AzureEdgeLinuxTelemetryAndDiagnostics
  # extension bundles azure-mdsd (the Geneva MDS daemon) only for x86_64. On arm64
  # (aarch64) its Install fails with exit code 52 unless azure-mdsd is ALREADY present
  # on the host ("not shipped with the extension for the Arm64 architecture ... must be
  # pre-installed on the image"). Pre-install the arm64 build from the azurecore feed so
  # the extension — and therefore EdgeMachine provisioning — succeeds.
  # Called from run_deploy (systemd is PID 1 there), NOT prep: the mdsd postinst
  # enables/starts a systemd service and only behaves when systemd is up.
  local arch; arch="$(dpkg --print-architecture)"
  if [[ "$arch" != "arm64" ]]; then
    log "[deploy] arch=$arch — azure-mdsd is bundled by the observability extension; skipping pre-install"
    return
  fi
  if dpkg -s azure-mdsd >/dev/null 2>&1; then
    log "[deploy] azure-mdsd already installed ($(dpkg-query -W -f='${Version}' azure-mdsd)) — ok"
    return
  fi
  log "[deploy] Pre-installing arm64 azure-mdsd (required by the LinuxEdgeObservability extension on aarch64)"
  local base="https://packages.microsoft.com/repos/azurecore"
  # Resolve the current arm64 .deb path from the noble (Ubuntu 24.04) index so we don't
  # hard-pin a version that rots out of the pool. NOTE: awk must NOT `exit` early here —
  # doing so closes the pipe and SIGPIPEs curl (exit 23), which under `set -euo pipefail`
  # aborts the whole script. Read the full stream and print only the first match.
  local relpath
  relpath="$(curl -fsSL "$base/dists/noble/main/binary-arm64/Packages" \
    | awk '/^Package: azure-mdsd$/{f=1} f && /^Filename:/ && !seen {print $2; seen=1; f=0}')"
  [[ -n "$relpath" ]] || die "could not resolve azure-mdsd arm64 package from $base (noble index)"
  # Download to a UNIQUE temp file. A fixed /tmp path can collide with a leftover owned
  # by another user, making root's 'curl -o' fail with CURLE_WRITE_ERROR (rc=23) and
  # abort prep — the actual bug this replaces.
  local deb; deb="$(mktemp --suffix=.deb)" || die "could not create temp file for azure-mdsd download"
  # shellcheck disable=SC2064
  trap "rm -f '$deb'" RETURN
  curl -fsSL -o "$deb" "$base/$relpath" || die "failed to download azure-mdsd from $base/$relpath"
  sudo apt-get update
  # The mdsd postinst enables/starts the systemd service. During prep systemd may not be
  # PID 1 yet (the systemd-applying restart happens after prep), and we only need the
  # binaries staged for the extension — so block service startup for this one install
  # with a policy-rc.d shim (standard chroot/container practice), then remove it.
  printf '#!/bin/sh\nexit 101\n' | sudo tee /usr/sbin/policy-rc.d >/dev/null
  sudo chmod +x /usr/sbin/policy-rc.d
  local install_rc=0
  sudo apt-get install -y "$deb" || install_rc=$?
  sudo rm -f /usr/sbin/policy-rc.d
  [[ "$install_rc" -eq 0 ]] || die "azure-mdsd install failed (rc=$install_rc; needed by the arm64 observability extension)"
  dpkg -s azure-mdsd >/dev/null 2>&1 || die "azure-mdsd not registered after install"
  log "[deploy] azure-mdsd installed ($(dpkg-query -W -f='${Version}' azure-mdsd))"
}

run_prep() {
  log "=== PHASE: prep ==="
  NEEDS_RESTART=0
  prep_wsl_conf
  prep_waagent_perms
  prep_wsl_interop
  prep_boot_hardening
  prep_k3s_wsl_boot
  prep_wsl_keepalive
  prep_azcli
  log "=== prep complete ==="
  if [[ "${NEEDS_RESTART:-0}" == "1" ]]; then
    echo
    echo "  ACTION REQUIRED: systemd was just enabled. Restart the distro"
    echo "  (the Node orchestrator does 'wsl --terminate' automatically), then"
    echo "  re-run with --phase deploy."
  fi
}

# -----------------------------------------------------------------------------
# PHASE: deploy  (after systemd is PID 1)
# -----------------------------------------------------------------------------
verify_systemd() {
  log "[deploy] Verifying systemd is PID 1"
  local pid1; pid1="$(ps -p 1 -o comm= || true)"
  [[ "$pid1" == "systemd" ]] || die "systemd is not PID 1 (got '$pid1'). Restart the distro and retry --phase deploy."
  sudo nsenter -t 1 -m -- mount --make-rshared / 2>/dev/null || true
}

tokens_ok() {
  # Returns 0 only if the tokens the deploy actually needs can be acquired — which
  # exercises the refresh token. A cached-but-stale access token with a dead refresh
  # token (AADSTS70008) returns non-zero, so ensure_login forces a fresh interactive
  # sign-in instead of failing mid-deploy.
  az account set --subscription "$SUBSCRIPTION" >/dev/null 2>&1 || return 1
  az account get-access-token --resource https://management.azure.com/ -o none 2>/dev/null || return 1
  if [[ -n "$AKSARC_BUILD_ID" ]]; then
    # Azure DevOps resource — needed by 'az pipelines runs artifact download'.
    az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 -o none 2>/dev/null || return 1
  fi
  return 0
}

ensure_login() {
  log "[deploy] Ensuring az login (subscription $SUBSCRIPTION, auth=$AUTH_MODE)"
  if tokens_ok; then
    log "[deploy]   already logged in; subscription set to $SUBSCRIPTION"
    return
  fi
  # Clear any stale/expired cached credentials (avoids AADSTS70008 from a dead refresh
  # token in the reused distro) so the fresh login starts clean.
  az logout >/dev/null 2>&1 || true
  case "$AUTH_MODE" in
    browser)
      # Interactive browser login (NOT device-code): az starts a localhost redirect and
      # opens the Windows default browser via wslview. Auth completes on the compliant
      # Windows device, satisfying Conditional Access; the redirect returns to WSL localhost.
      if ! command -v wslview >/dev/null 2>&1; then
        log "[deploy]   installing wslu (provides wslview) for browser login"
        sudo apt-get update -qq && sudo apt-get install -y -qq wslu
      fi
      BROWSER="$(command -v wslview)" az login --tenant "$TENANT_ID" --only-show-errors
      ;;
    sp)
      [[ -n "$AZURE_CLIENT_ID" && -n "$AZURE_CLIENT_SECRET" ]] \
        || die "AUTH_MODE=sp requires AZURE_CLIENT_ID and AZURE_CLIENT_SECRET"
      az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" \
        --tenant "$TENANT_ID" --only-show-errors
      ;;
    device-code)
      warn "AUTH_MODE=device-code may be blocked by Conditional Access (AADSTS53003)"
      az login --use-device-code --tenant "$TENANT_ID"
      ;;
    *) die "AUTH_MODE must be one of: browser | sp | device-code" ;;
  esac
  az account set --subscription "$SUBSCRIPTION"
  log "[deploy]   subscription set to $SUBSCRIPTION"
}

register_providers() {
  log "[deploy] Registering resource providers + HybridConnectivity feature"
  local rp
  for rp in Microsoft.HybridCompute Microsoft.HybridContainerService Microsoft.Kubernetes Microsoft.ExtendedLocation Microsoft.HybridConnectivity; do
    az provider register --namespace "$rp" --subscription "$SUBSCRIPTION" >/dev/null 2>&1 || warn "  provider register $rp returned non-zero (may already be registered)"
  done
  az feature register --namespace Microsoft.HybridConnectivity --name hiddenPreviewAccess --subscription "$SUBSCRIPTION" >/dev/null 2>&1 \
    || warn "  feature register hiddenPreviewAccess returned non-zero (may already be registered)"
}

install_extensions() {
  log "[deploy] Installing az CLI extensions (connectedk8s, connectedmachine, aksarc)"
  az extension add --name connectedk8s --only-show-errors 2>/dev/null || az extension update --name connectedk8s --only-show-errors 2>/dev/null || true
  az extension add --name connectedmachine --only-show-errors 2>/dev/null || az extension update --name connectedmachine --only-show-errors 2>/dev/null || true
  az extension remove --name aksarc 2>/dev/null || true

  # Resolve the wheel source (local path > ADO build artifact > public URL).
  local whl=""
  if [[ -n "$AKSARC_WHEEL_PATH" ]]; then
    [[ -f "$AKSARC_WHEEL_PATH" ]] || die "AKSARC_WHEEL_PATH set but file not found: $AKSARC_WHEEL_PATH"
    whl="$AKSARC_WHEEL_PATH"
  elif [[ -n "$AKSARC_BUILD_ID" ]]; then
    log "[deploy]   downloading aksarc wheel from ADO build $AKSARC_BUILD_ID (drop_Build_main)"
    local dl="/tmp/aksarc-whl-$AKSARC_BUILD_ID"
    rm -rf "$dl"; mkdir -p "$dl"
    az pipelines runs artifact download --org https://dev.azure.com/msazure --project msk8s \
      --run-id "$AKSARC_BUILD_ID" --artifact-name drop_Build_main --path "$dl" \
      || die "could not download build $AKSARC_BUILD_ID artifact (need 'az devops login' or AZURE_DEVOPS_EXT_PAT)"
    whl="$(find "$dl" -name 'aksarc-*.whl' | head -1)"
    [[ -n "$whl" ]] || die "no aksarc-*.whl found in build $AKSARC_BUILD_ID drop_Build_main"
  else
    whl="$AKSARC_WHEEL_URL"
  fi

  log "[deploy]   installing aksarc from $whl"
  az extension add --source "$whl" --yes
  fixup_asyncssh
  local ver; ver="$(az extension show --name aksarc --query version -o tsv 2>/dev/null || echo '?')"
  log "[deploy]   aksarc extension version: $ver"
}

fixup_asyncssh() {
  # aksarc depends on asyncssh; bleeding-edge az pulls asyncssh>=2.18 which
  # hard-imports mlkem (needs cryptography>=50). Pin asyncssh back to 2.17.0.
  local azpy extdir
  azpy="$(az --version 2>/dev/null | sed -n "s/.*Python location '\([^']*\)'.*/\1/p" | head -1)"
  extdir="$HOME/.azure/cliextensions/aksarc"
  [[ -n "$azpy" && -d "$extdir" ]] || return 0
  if [[ -f "$extdir/asyncssh/version.py" ]]; then
    local cur; cur="$(sed -n "s/.*__version__ = '\([^']*\)'.*/\1/p" "$extdir/asyncssh/version.py" | head -1)"
    [[ "$cur" == "$ASYNCSSH_SAFE_VERSION" ]] && return 0
  fi
  "$azpy" -m pip install --no-deps --target "$extdir" "asyncssh==$ASYNCSSH_SAFE_VERSION" >/dev/null 2>&1 || true
}

ensure_rg() {
  log "[deploy] Ensuring resource group $RESOURCE_GROUP ($LOCATION)"
  [[ "$LOCATION" == "eastus" ]] || warn "  LOCATION=$LOCATION but public preview only supports eastus — deploy may fail."
  az group show --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION" >/dev/null 2>&1 \
    || az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --subscription "$SUBSCRIPTION" >/dev/null
}

arc_connect() {
  log "[deploy] Arc-enabling the host ($ARC_MACHINE_NAME)"
  if ! command -v azcmagent >/dev/null 2>&1; then
    log "[deploy]   installing azcmagent"
    curl -sSL -o /tmp/install_azcmagent.sh https://gbl.his.arc.azure.com/azcmagent-linux
    sudo bash /tmp/install_azcmagent.sh
  fi

  # azcmagent auth (token or SP) — needed for both connect and any disconnect.
  local -a arc_auth
  if [[ "$AUTH_MODE" == "sp" ]]; then
    arc_auth=(--service-principal-id "$AZURE_CLIENT_ID" --service-principal-secret "$AZURE_CLIENT_SECRET")
  else
    local tok
    tok="$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)"
    [[ -n "$tok" ]] || die "could not obtain an ARM access token for azcmagent"
    arc_auth=(--access-token "$tok")
  fi

  # If already Connected, make sure it is to THIS subscription+RG. A host left
  # connected to a different/old RG makes the deploy fail with ParentResourceNotFound,
  # because Microsoft.HybridCompute/machines/<host> won't exist in the deploy RG.
  if azcmagent show 2>/dev/null | grep -q 'Agent Status *: *Connected'; then
    local cur_rg cur_sub
    cur_rg="$(azcmagent show 2>/dev/null | grep -i 'resource group' | head -1 | sed 's/^[^:]*: *//' | tr -d '\r' | sed 's/[[:space:]]*$//')"
    cur_sub="$(azcmagent show 2>/dev/null | grep -i 'subscription id' | head -1 | sed 's/^[^:]*: *//' | tr -d '\r' | sed 's/[[:space:]]*$//')"
    if [[ "$cur_rg" == "$RESOURCE_GROUP" && "$cur_sub" == "$SUBSCRIPTION" ]]; then
      log "[deploy]   azcmagent already Connected to $SUBSCRIPTION/$RESOURCE_GROUP"
      return
    fi
    warn "  azcmagent Connected to ${cur_sub:-?}/${cur_rg:-?}, not $SUBSCRIPTION/$RESOURCE_GROUP — reconnecting"
    sudo azcmagent disconnect "${arc_auth[@]}" 2>/dev/null \
      || sudo azcmagent disconnect --force-local-only 2>/dev/null \
      || warn "  disconnect returned non-zero; continuing to connect"
  fi

  sudo azcmagent connect \
    --subscription-id "$SUBSCRIPTION" \
    --resource-group  "$RESOURCE_GROUP" \
    --tenant-id       "$TENANT_ID" \
    --location        "$LOCATION" \
    --cloud           "AzureCloud" \
    "${arc_auth[@]}"
  azcmagent show | grep -q 'Agent Status *: *Connected' || die "azcmagent connect did not reach Connected"
}

grant_hcirp_roles() {
  log "[deploy] Granting the Azure Stack HCI RP the required roles on the RG"
  local oid scope role
  oid="$(az ad sp show --id "$HCIRP_APP_ID" --query id -o tsv 2>/dev/null || true)"
  [[ -n "$oid" ]] || { warn "  could not resolve HCI RP object id (need Directory read); skipping — deploy may 403 at DevicePool"; return 0; }
  scope="$(az group show --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION" --query id -o tsv)"
  for role in "${HCIRP_ROLES[@]}"; do
    az role assignment create --assignee-object-id "$oid" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" 2>/dev/null || log "[deploy]   '$role' already assigned"
  done
}

deploy_cluster() {
  local -a args=(-g "$RESOURCE_GROUP" --arc-machine-names "$ARC_MACHINE_NAME" --subscription "$SUBSCRIPTION")
  # Only pass --distribution/--cmp-* when opting into k3s or a private CMP — these flags
  # exist only in the pipeline-built wheel, so the default public-CMPS k8s flow stays
  # compatible with the public wheel.
  if [[ "$DISTRIBUTION" != "k8s" || -n "$CMP_NAME" ]]; then
    args+=(--distribution "$DISTRIBUTION")
    [[ -n "$CMP_SUBSCRIPTION" ]]   && args+=(--cmp-subscription "$CMP_SUBSCRIPTION")
    [[ -n "$CMP_RESOURCE_GROUP" ]] && args+=(--cmp-resource-group "$CMP_RESOURCE_GROUP")
    [[ -n "$CMP_NAME" ]]           && args+=(--cmp-name "$CMP_NAME")
  fi

  if [[ "$VALIDATE_ONLY" == "true" ]]; then
    log "[deploy] Validating (dry-run) az aksarc deploy for machine '$ARC_MACHINE_NAME' (distribution=$DISTRIBUTION)"
    az aksarc deploy "${args[@]}" --validate
    log "[deploy] Validation complete (no resources created)."
    return
  fi
  log "[deploy] Running az aksarc deploy (machine '$ARC_MACHINE_NAME', distribution=$DISTRIBUTION) — this can take ~40 min"
  az aksarc deploy "${args[@]}" --yes
  log "[deploy] DONE — cluster deploy submitted for '$ARC_MACHINE_NAME'."
}

run_deploy() {
  log "=== PHASE: deploy ==="
  verify_systemd
  # Install arm64 azure-mdsd HERE (after verify_systemd), NOT in prep: the mdsd
  # postinst enables/starts its systemd service, which only works cleanly once
  # systemd is PID 1. During prep systemd isn't up yet, so the postinst's SysV
  # fallback start hangs/fails.
  install_observability_deps
  ensure_login
  register_providers
  install_extensions
  ensure_rg
  arc_connect
  grant_hcirp_roles
  deploy_cluster
  log "=== deploy complete ==="
}

case "$PHASE" in
  prep)   run_prep ;;
  deploy) run_deploy ;;
  all)
    run_prep
    if [[ "$(ps -p 1 -o comm= || true)" == "systemd" ]]; then
      run_deploy
    else
      warn "systemd not yet PID 1 — restart the distro then re-run with --phase deploy"
    fi
    ;;
esac
