# AKS Arc on WSL — Headlamp plugin

Create an **AKS Arc** (SFF / BareMetal edge) cluster that uses **WSL2 as the edge
node**, directly from the Headlamp UI. The plugin drives `manage-aksarc-wsl.js` →
`setup-aks-arc-deploy.sh` (`az aksarc deploy` / `undeploy`) instead of
reimplementing the WSL/`az` bring-up logic.

> **Just want to create a cluster?** See the **[User Guide](./USER-GUIDE.md)** —
> prerequisites, the form fields, k8s vs k3s, GPU, actions, and troubleshooting.

## Requirements

- **Headlamp desktop app on Windows.** Running local commands (`wsl.exe`,
  PowerShell, `az`) is only possible in the Electron desktop build via the
  `run-command` IPC. In the browser/server build the Create/Delete actions are
  disabled.
- WSL2 with an Ubuntu distro, and the prerequisites documented in the AKS Arc
  on WSL guide (`docs/wsl/` in the `Aks-Arc-Assembly` repo).

## How it works

The plugin registers an **Add Cluster provider card** ("AKS Arc BareMetal
(connected) — WSL") via `registerAddClusterProvider`, so it appears under
**Home → Add Cluster → Providers** (next to "Load from KubeConfig"). Clicking it
opens the create form at `/aksarc-wsl`.

```
Headlamp UI (src/index.tsx)
  -> pluginRunCommand('scriptjs', ['aksarc-wsl/manage-aksarc-wsl.js', <action>, <b64 config>])
      -> Electron run-command IPC (permission secret + user consent)
          -> manage-aksarc-wsl.js  (runs on the app/Electron node runtime)
              -> writes a temp wsl-config.env
              -> powershell.exe -File scripts/aks-arc-on-wsl.ps1 up -ConfigFile <tmp>
                  -> setup-aks-arc-wsl.sh inside WSL  -> az aksarc create
```

- **Actions:** `Create cluster` (full idempotent `up` = prepare + create),
  `Delete cluster` (`down cluster`), `Status` (`status`).
- **Auto-load:** after a successful create, the plugin reads the cluster's
  `admin.conf` from the WSL distro (`kubeconfig` action → `wsl -d aks-edge -u root
  -- cat /etc/kubernetes/admin.conf`) and registers it with Headlamp via
  `Headlamp.setCluster({ kubeconfig })` (base64), so the new cluster shows up on
  the Home page and its details are immediately browsable — no manual
  "Load from KubeConfig" step.
- Form values map 1:1 to `wsl-config.env` keys. They are validated and
  serialized into a temporary, `0600`-mode env file for the run; the file is
  removed afterwards.
- All PowerShell/WSL output streams live back into the UI log panel.

> The apiserver in `admin.conf` is the WSL eth0 IP (e.g. `172.x:6443`), reachable
> from the Windows host via the WSL vEthernet. Set `vmIdleTimeout=-1` in
> `%USERPROFILE%\.wslconfig` so the VM (and apiserver) stays up — otherwise WSL
> idles the VM down and the cluster shows "connection refused". See the AKS Arc on
> WSL `KNOWN-ISSUES.md` §6.

## Security model

Headlamp only lets whitelisted plugins run local commands. This plugin is
whitelisted exactly like the `minikube` plugin, in three places in the core app:

| File | Addition |
|------|----------|
| `frontend/src/plugin/runPlugin.ts` | `identifyPackages` entry for `aksarc-wsl` |
| `frontend/src/plugin/index.ts` | `getAllowedPermissions` + `getArgValues` inject `pluginRunCommand` |
| `app/electron/runCmd.ts` | `permissionSecrets`, `COMMANDS_WITH_CONSENT`, consent add/remove |

The top-level command is always `scriptjs` (a bundled Node script) — `wsl.exe`
and `powershell.exe` are spawned by that script, not passed directly through the
IPC allowlist. The user still gets a one-time consent dialog on first run.

## Develop

```bash
npm install
npm run tsc      # type-check
npm run lint
npm run build    # builds dist/ and copies manage-aksarc-wsl.js + scripts/
npm start        # dev: builds and links into ~/.config/Headlamp/plugins/aksarc-wsl
```

`npm run build` copies the plugin into
`~/.config/Headlamp/plugins/aksarc-wsl/` (via Headlamp's static-copy step),
including `manage-aksarc-wsl.js` and the `scripts/` folder.

## Running on Windows when the repo lives in WSL

You can **build the plugin in WSL**, but the modified Headlamp **desktop app must
run on Windows** (it spawns `powershell.exe` -> `wsl.exe`, and the runtime script
guards on `process.platform === 'win32'`). Because `node_modules` and the Electron
binaries are OS-specific, do the app build from a **Windows-side checkout** — not
over `\\wsl$`.

> The default Headlamp plugins directory on Windows is
> `%APPDATA%\Headlamp\Config\plugins` (i.e.
> `C:\Users\<you>\AppData\Roaming\Headlamp\Config\plugins`), per the backend's
> `defaultPluginDir()`.

### 1. In WSL — commit the work to a branch

```bash
cd /home/nishat/repos/headlamp
git checkout -b nishat/aksarc-wsl-plugin
git add plugins/aksarc-wsl \
        app/electron/runCmd.ts \
        frontend/src/plugin/index.ts \
        frontend/src/plugin/runPlugin.ts
git commit -m "Add aksarc-wsl plugin + core allowlist for WSL cluster creation"
```

### 2. On Windows — get the code (PowerShell)

Clone directly from the WSL working copy (WSL must be running). Replace
`Ubuntu-24.04` with your distro name (`wsl -l -v`):

```powershell
git clone \\wsl.localhost\Ubuntu-24.04\home\nishat\repos\headlamp C:\src\headlamp
cd C:\src\headlamp
git checkout nishat/aksarc-wsl-plugin
```

(On older Windows use `\\wsl$\Ubuntu-24.04\...`. Alternatively, push the branch to
your GitHub fork from WSL and clone the fork on Windows.)

### 3. On Windows — prerequisites

Node.js LTS, Go, and `make` (e.g. `choco install nodejs-lts golang make`).
`make run-app` builds the Go backend + frontend and launches Electron, so run it
from **Git Bash** (or any shell with `make`).

### 4. On Windows — build + run the modified desktop app

```bash
cd /c/src/headlamp
make run-app          # builds backend/frontend as needed, launches modified Electron app
```

### 5. On Windows — install this plugin

```powershell
cd C:\src\headlamp\plugins\aksarc-wsl
npm install
npm run build
# copy the COMPLETE dist (main.js + manage-aksarc-wsl.js + scripts/) into the plugins dir
robocopy dist "$env:APPDATA\Headlamp\Config\plugins\aksarc-wsl" /E
```

Restart the app (or, in `make run-app` watch mode, reload). Open **Home → Add
Cluster → Providers → AKS Arc BareMetal (connected) — WSL**. The first
Create/Delete run shows a one-time consent dialog.

## Bundled aksarc CLI wheel

If an aksarc CLI wheel (`*.whl`) is placed in `scripts/`, the runtime script
auto-detects it, converts its path to the WSL `/mnt/...` form, and sets
`AKSARC_WHEEL_PATH` — so the UI does **not** ask for a wheel path. If no wheel is
bundled, the setup script just verifies the currently-installed `az aksarc`
extension (and fails if it lacks `--network-policy`).

> The wheel is **gitignored** (`scripts/*.whl`) because it is an internal build —
> it is bundled into the local install but never committed/pushed. Anyone else
> building the plugin must drop their own `aksarc-*.whl` into `scripts/`.

## Keeping the bundled scripts in sync
