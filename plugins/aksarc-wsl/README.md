# AKS Arc on WSL — Headlamp plugin

Create an **AKS Arc** (SFF / BareMetal edge) cluster that uses **WSL2 as the edge
node**, directly from the Headlamp UI. The plugin drives the hardened
`aks-arc-on-wsl.ps1` orchestrator (bundled in `scripts/`) instead of
reimplementing the WSL/`az` bring-up logic.

## Requirements

- **Headlamp desktop app on Windows.** Running local commands (`wsl.exe`,
  PowerShell, `az`) is only possible in the Electron desktop build via the
  `run-command` IPC. In the browser/server build the Create/Delete actions are
  disabled.
- WSL2 with an Ubuntu distro, and the prerequisites documented in the AKS Arc
  on WSL guide (`docs/wsl/` in the `Aks-Arc-Assembly` repo).

## How it works

```
Headlamp UI (src/index.tsx)
  -> pluginRunCommand('scriptjs', ['aksarc-wsl/manage-aksarc-wsl.js', <action>, <b64 config>])
      -> Electron run-command IPC (permission secret + user consent)
          -> manage-aksarc-wsl.js  (runs on the app/Electron node runtime)
              -> writes a temp wsl-config.env
              -> powershell.exe -File scripts/aks-arc-on-wsl.ps1 up create -ConfigFile <tmp>
                  -> setup-aks-arc-wsl.sh inside WSL  -> az aksarc create
```

- **Actions:** `Create cluster` (`up create`), `Delete cluster`
  (`down cluster`), `Status` (`status`).
- Form values map 1:1 to `wsl-config.env` keys. They are validated and
  serialized into a temporary, `0600`-mode env file for the run; the file is
  removed afterwards.
- All PowerShell/WSL output streams live back into the UI log panel.

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

Restart the app (or, in `make run-app` watch mode, reload). Open **AKS Arc on WSL**
on the Home sidebar. The first Create/Delete run shows a one-time consent dialog.

## Keeping the bundled scripts in sync
