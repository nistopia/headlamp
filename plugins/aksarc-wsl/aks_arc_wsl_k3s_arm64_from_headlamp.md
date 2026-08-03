# AKS Arc k3s on WSL2 (ARM64) — driven from Headlamp

Running AKS Arc's **k3s edge node inside a WSL2 Ubuntu distro (`aks-edge`)** on an ARM64
Windows laptop, instead of on real bare-metal hardware. A **Headlamp plugin** drives it,
calling `az aksarc deploy` (a preview *brownfield* ARM template) that routes to a **private
CMP** (`aks-cl` in `sfflinux-dev-174748483`).

## Big picture

```
Headlamp UI (form: wheel path, distro, k3s)
   └─ manage-aksarc-wsl.js  (Node runner on Windows)
        ├─ ensureDistro()      → create/import aks-edge WSL distro
        ├─ stage scripts       → ~/.aksarc-deploy inside aks-edge
        └─ actionUp()          → runs setup-aks-arc-deploy.sh in 2 phases
                                    ├─ PREP   (harden the WSL node)
                                    └─ DEPLOY (az aksarc deploy → CMP)
```

## Phase 1 — get a WSL node that behaves like an edge host

`manage-aksarc-wsl.js`:
1. **ensureDistro** — if `aks-edge` doesn't exist, `wsl --install`. When GitHub's
   `DistributionInfo.json` fetch times out (WinINET bug), it **falls back to
   `importDistro()`**: curl the Ubuntu 24.04 arm64 `.wsl` image + `wsl --import`. This keeps
   `aks-edge` **separate** from the daily `Ubuntu-24.04`.
2. **stage** the shell scripts into the distro.

Ubuntu arm64 image URL (from DistributionInfo.json):
`https://cdimages.ubuntu.com/releases/24.04.4/release/ubuntu-24.04.4-wsl-arm64.wsl`

## Phase 2 — PREP (`setup-aks-arc-deploy.sh → run_prep`)

Makes the WSL distro survivable and Arc-ready:
- `prep_wsl_conf` — enable systemd + rshared mounts (Arc/kubelet need these).
- `prep_waagent_perms` — fix `/var/lib/waagent` race.
- **`prep_wsl_interop`** — self-heal `WSLInterop` so `wslview` can open the Windows browser
  for `az login`. Fixes the AADSTS70008 login failures. Writes a systemd drop-in
  (`systemd-binfmt.service.d/keep-wslinterop.conf`) that re-registers `WSLInterop` after
  every boot/resume, and also registers it immediately during prep.
- `prep_boot_hardening` — systemd unit re-applies swapoff + containerd on every WSL
  restart/sleep.
- `prep_azcli` — install Azure CLI + `aksarc` extension (**local wheel**, not the ADO build).
- Then a **systemd restart** so all this takes effect.

## Phase 3 — DEPLOY (`run_deploy`)

1. **Login** — browser `az login` via `wslview` (reliable after the interop fix).
2. **`az aksarc deploy`** → the brownfield ARM template creates, in the CMP's RG:
   `EdgeMachine` (the WSL node) → `DevicePool` → `CustomLocation` → `LogicalNetwork` →
   `ConnectedCluster` → **`ProvisionedClusterInstance`** (the actual k3s cluster).

## The CMP side (after PCI is submitted)

The CMP (`aks-cl`, branch with k3s POC bits) reconciles the cluster:
- **k3s providers**: `KThreesControlPlane` (CACP3) + `KThreesConfig` (CABP3).
- **Shared infra**: `AzureEdgeCluster` (CAPE) — runs `AllocateVIP`, `NodeInit`, then installs
  k3s. `AllocateVIP` is a *shared* infra step, not k3s-specific.

## Fixes baked in (each was a blocker we hit)

| Blocker | Fix | Where |
|---|---|---|
| RBAC 1005 (Azure RBAC on ConnectedCluster) | `skipRoleAssignments=true`, empty `clusterAdminAadObjectId` | wheel `custom.py` `_build_cmp_routing_parameters` |
| observability exit-52 (arm64: azure-mdsd/metricsext2 unavailable) | disable Linux observability on arm64 | wheel `custom.py` `aksarc_deploy` (`installLinuxObservability` gated off) |
| networkPolicy wrong for k3s | `flannel` for k3s | wheel + `brownfield_deployment_template.json` allowedValues |
| **AllocateVIP timeout** (`CapeOperationTimeoutAtAllocateVIP`) | pre-set `controlPlane.controlPlaneEndpoint.hostIP` = node IP so CAPE skips gateway derivation (WSL `eth0` has no default gateway) | wheel (`_detect_edge_node_ip`) + template (`controlPlaneObj` var, `controlPlaneEndpointHostIp` param, no `port`) |
| `wsl --install` GitHub timeout | import fallback | `manage-aksarc-wsl.js` `importDistro()` + `ensureDistro` |
| **interop / login drop** (AADSTS70008) | self-heal WSLInterop drop-in + immediate register | `setup-aks-arc-deploy.sh` `prep_wsl_interop` |
| AksArcPrereqs extension wedge (HCRP409) | keep laptop awake during deploy (sleep loses terminal extension status) | operational |

## Root-cause notes

- **AllocateVIP mechanism**: `azureedgecluster_controller.go` `initializeClusterInfoInternal`
  reads `provisionedCluster.Spec.ControlPlane.ControlPlaneEndpoint.HostIP` → sets
  `InfraCluster.Spec.ControlPlaneEndpoint`; `reconcileAllocateVIPInternal` then SKIPS
  derivation if the endpoint is set. Webhook defaults `Port` to `6443`.
  `IsManagementCandidate()` requires a non-empty valid Gateway — WSL `eth0` lacks it, so the
  NIC status is empty and derivation fails without the pre-set hostIP.
- **Interop root cause**: `systemd-binfmt.service` flushes `binfmt_misc` on VM restart/sleep;
  WSL's re-register drop-in flakily fails → `WSLInterop` gone → `cmd.exe`/`az.exe`/`wslview`
  fail with `Exec format error`. Restore:
  `echo ':WSLInterop:M::MZ::/init:PF' > /proc/sys/fs/binfmt_misc/register` (as root).
- **AksArcPrereqs wedge**: CustomScript extension reports `statusTime: null` — terminal
  status lost when the laptop sleeps mid-report; an `extd` restart does NOT force re-report.

## Key IDs / paths

- Subscription: `b9e38f20-7c9c-4497-a25d-1a0c5eef2108`
- Tenant: `72f988bf-86f1-41af-91ab-2d7cd011db47`
- CMP: `sfflinux-dev-174748483` / cluster `aks-cl` (branch `nishat/k3s-preview-hold-cmp`)
- Node IP (shared across WSL2 distros): `172.29.103.154`
- Wheel: `/mnt/c/Users/nishatislam/aksarc-cli/aksarc-2.0.0b6-py3-none-any.whl`

### Files

- Plugin: `headlamp/plugins/aksarc-wsl/`
  - `manage-aksarc-wsl.js` — runner (`importDistro`/`ensureDistro`, `actionUp`, `STAGE=~/.aksarc-deploy`)
  - `scripts/setup-aks-arc-deploy.sh` — prep + deploy phases
  - `src/index.tsx` — form (wheel path field, k3s validation)
- Wheel: `hu-trees/aksarc-deploy-cmp-k3s/azcli/aksarc/azext_aksarc/`
  - `custom.py`, `brownfield_deployment_template.json`
- Standalone scripts: `trees/wsl-arm64-support/docs/wsl/scripts/` (also copied to
  `C:\Users\nishatislam\Documents\wsl-aksarc-scripts\`): `cleanup-aks-arc-wsl.sh`,
  `setup-aks-arc-wsl.sh`, `aks-arc-on-wsl.ps1`, `restore-interop.sh`, `wsl-config.env`

## Current state

All fixes staged. The remaining fragile step is the **interactive browser login during
deploy** — the interop fix should make it reliable, but be present to click through so the
token doesn't expire (AADSTS70008). Keep the laptop awake for the full ~40-min deploy.

---

# Known Issues & Root Causes — k3s-on-WSL cluster bring-up (2026-08-03)

Deep-dive from a failed deploy where the PCI ended `Failed` with 4 addons at
`InstallHelmError`. The addon/taint/relay failures were all **downstream symptoms**; the
real blockers were two WSL-specific problems that kept **k3s from ever staying up**. Issues
are listed bottom-of-stack first.

## Issue 1 — WSL boot-timeout reboot loop (k3s starting at boot)

**Symptom:** `aks-edge` distro restarts every ~1–2 min; k3s never stabilizes (`systemctl
is-active k3s` = `activating` forever; 534 "Starting k3s" events; etcd raft term 160+).

**Root cause:** `k3s.service` is `Type=notify`, `TimeoutStartSec=0`, and starts at boot.
systemd's boot target waits for k3s to signal ready; k3s (etcd + apiserver bootstrap) makes
systemd take **~13.4 s**, which exceeds WSL's **10 s `WaitForBootProcess` watchdog**. WSL
declares the boot failed and force-reboots the distro:
```
WSL (init-systemd(aks-edge)) ERROR: WaitForBootProcess:3488: /sbin/init failed to start within 10000ms
WSL (init-systemd(aks-edge)) ERROR: InitTerminateInstanceInternal:2763: systemctl poweroff did not
     terminate the instance in 10000 ms, calling reboot(RB_POWER_OFF)
```
→ reboot → systemd slow again → watchdog fires → **infinite loop**.

**Fix (validated):** take k3s off the boot path so systemd reaches its target in <10 s
(measured **1.78 s** after `systemctl disable k3s`), then start k3s **after** boot.

**Diagnose:**
```bash
systemctl disable --now k3s          # off boot
systemd-analyze time                 # want << 10s
journalctl -o short-iso | grep -E "RB_POWER_OFF|WaitForBootProcess"
```

## Issue 2 — Interop drops in OTHER WSL distros (shared kernel binfmt_misc)

**Symptom:** `WSLInterop` disappears in an unrelated distro (e.g. `Ubuntu-24.04`) every
~1–2 min; `wsl.exe`/`az.exe` run as shell scripts (`MZ… not found`, `Exec format error`).
That distro's own `systemd-binfmt` only ran a couple times, yet `WSLInterop` keeps vanishing.

**Root cause:** WSL2 runs all distros in **one VM sharing one kernel**, and `binfmt_misc`
(where `WSLInterop` is registered) is **kernel-global**. Every time `aks-edge` reboots
(Issue 1), its `systemd-binfmt` **flushes `binfmt_misc`** (`echo -1 > .../status`) and
re-registers only its own — wiping every other distro's `WSLInterop`.

**Fix:** eliminate the `aks-edge` reboot loop (Issues 1 & 3). Interop has been stable since.
Stop-gap self-heal drop-in (`prep_wsl_interop`) re-registers on each boot but does NOT stop
the flushing; fixing the loop is the real cure.

**Restore manually (from Windows PowerShell, as root):**
```powershell
wsl -d <distro> -u root -- sh -c 'echo ":WSLInterop:M::MZ::/init:PF" > /proc/sys/fs/binfmt_misc/register'
```

## Issue 3 — Idle-termination reboot (poweroff hang) once k3s is off-boot

**Symptom:** even after Issue 1 is fixed (fast boot), `aks-edge` still cycles ~every 2 min
via the shutdown path: `systemctl poweroff did not terminate in 10000ms → RB_POWER_OFF`.

**Root cause:** with no long-running foreground process holding it, WSL idle-terminates the
distro after each command exits; `systemctl poweroff` hangs >10 s → WSL force-reboots.

**Fix (validated):** pin the distro open with a persistent keep-alive so WSL never
idle-terminates it:
```bash
# detached, survives; run from Windows for durability:
wsl -d aks-edge -u root -- sh -c 'while true; do sleep 3600; done'
```
After pinning: 0 reboots, 0 `RB_POWER_OFF`, interop stayed present.

## Issue 4 — Stale `cilium_vxlan` interface blocks flannel (VXLAN port 8472)

**Symptom:** k3s reaches `active` briefly then self-restarts; log:
```
Shutdown request received: flannel exited: failed to register flannel network:
failed to configure interface flannel.1: failed to set interface flannel.1 to UP state: address already in use
```

**Root cause:** a leftover **`cilium_vxlan`** interface (UP) from a **prior Cilium/k8s
cluster on the same reused distro** holds VXLAN UDP **8472**. k3s uses **flannel** for k3s
(`--network-policy flannel`; Cilium is skipped for k3s per addon-mutator Step 5.1), and
`flannel.1` also needs 8472 → "address already in use" → flannel exits → k3s shuts down.
Interfaces seen: `cilium_net@cilium_host`, `cilium_host@cilium_net`, `cilium_vxlan`, stale
`flannel.1 DOWN`.

**Fix (validated):** delete stale CNI interfaces before starting k3s, then start:
```bash
systemctl stop k3s
for i in cilium_vxlan cilium_host cilium_net flannel.1 flannel-v6.1 cni0; do ip link delete "$i" 2>/dev/null; done
for i in $(ip -o link show | awk -F': ' '/lxc/{print $2}' | cut -d@ -f1); do ip link delete "$i" 2>/dev/null; done
ss -ulnp | grep 8472 || echo "8472 free"
systemctl start k3s
```
Result: k3s `active`, node `Ready`, pods created. (A truly fresh imported distro won't have
cilium leftovers — this bites when reusing a distro across k8s↔k3s.)

## Issue 5 — `uninitialized` NoSchedule taint blocks all pods (downstream)

**Symptom:** k3s stable, node Ready, but `kubectl get pods -A` = 0 pods, or all `Pending`;
ReplicaSets DESIRED=1 / CURRENT=0.

**Root cause:** k3s config defaults `--kubelet-arg cloud-provider=external` (taint
`node.cloudprovider.kubernetes.io/uninitialized:NoSchedule`) **and**
`disable-cloud-controller: true` — so nothing local removes the taint. CAPE removes it in
`setupCloudProvider`→`NodeUpdate` (over the ClusterRelay), but that step runs **after**
`SetupClusterRelay`, which never completed here (Issues 1/4 kept k3s/relay down). k8s
(`cape-k8s-v2.0`) never sets `cloud-provider=external`, so k8s never hits this taint — which
is why **k8s worked on WSL but k3s didn't**.

**Fix (validated stop-gap):** local de-taint (edge can reach its own apiserver):
```bash
k3s kubectl taint node <node> node.cloudprovider.kubernetes.io/uninitialized-
```
→ all pods (coredns/metrics-server/local-path/etcd-proxy) went `Running`.

**Proper fix (deploy):** `disableExternalCloudProvider: true` in `cape-k3s-v2.0` (no taint,
mirrors k8s), or a WSL-local de-taint during NodeInit — so it doesn't depend on the
CMP-driven de-taint that is gated behind the relay.

## Downstream cascade (all symptoms of Issues 1 & 4)

```
k3s never stays up (Issue 1 boot loop  +  Issue 4 cilium/flannel conflict)
  → 0 pods (or Pending on Issue 5 taint)
    → sni-proxy relay listener pod never runs → NodeRelay :7777/available = EOF
        ("there are no listeners connected") → ClusterRelay unreachable
          → CAPE SetupClusterRelay 30-min TERMINAL timeout (CapeActivityFailAtSetupClusterRelay)
            → setupCloudProvider (de-taint) never runs → taint persists
              → PCI Failed, 4 addons InstallHelmError
```

## How the POC worked (and why our run diverged)

`docs/wsl/k3s/wsl-edge-setup.md` shows the working flow. It (a) **omits `--control-plane-ip`**
(k3s uses the node IP; CAPE handles the endpoint), and (b) passes **`--disable-nfs-driver
--disable-smb-driver`** (CSI drivers unsupported on k3s → `Pending` otherwise). The taint is
never a manual step because CAPE de-taints automatically over the relay **once the cluster is
up**. Our run failed because k3s never stayed up (Issues 1/4) — not because of the guide's
steps. The guide never covers Issues 1–4 (validated: no mention of boot loop, binfmt,
cilium_vxlan, or the taint in any `docs/wsl/**` file).

## Deploy-script changes to bake in (`setup-aks-arc-deploy.sh`)

1. **k3s off-boot + post-boot start** — never let k3s block WSL's 10 s boot window.
2. **Persistent keep-alive** — pin `aks-edge` so WSL never idle-terminates it.
3. **Stale-CNI cleanup** — delete leftover `cilium_*`/`flannel.1`/`lxc*` before k3s start.
4. **(CMP-side / optional)** `disableExternalCloudProvider: true` in `cape-k3s-v2.0`, or a
   local de-taint during NodeInit.
