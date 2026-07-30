<#
.SYNOPSIS
    AKS Arc on WSL -- Windows-host orchestrator (up / down).

.DESCRIPTION
    Drives the WSL edge-node lifecycle from the Windows host so it survives the
    `wsl --terminate <distro>` that enabling systemd requires (an in-WSL script
    cannot restart its own PID 1 and keep running -- the host process can). Only
    the dedicated distro is terminated, so other WSL distros stay running.

    Two main verbs, each with optional subverbs:

      up  [prepare|create]   Bring the edge node + cluster up.
            (no subverb)  Full bring-up: prepare, then create.
            prepare       Ensure the dedicated distro exists, stage the scripts,
                          run OS prep (`--phase prep`, enables systemd), and
                          restart WSL *only if* systemd isn't PID 1 yet.
            create        Provision the edge node + create the AKS Arc cluster
                          (`--phase provision`). Requires systemd PID 1.

      down [all|cluster|node]   Tear it back down (cleanup-aks-arc-wsl.sh).
            all (default) Full teardown: cluster -> LNet -> DevicePool/CL ->
                          EdgeMachine -> Arc disconnect.
            cluster       Only the provisioned cluster (--cluster-only, fastest
                          path to re-create with `up create`).
            node          LNet/DevicePool/CL but keep EdgeMachine+Arc
                          (--keep-node, reusable by a new CMP).

      status   Read-only: distro presence, systemd PID 1, Arc connection, nodes.

      configure   Interactively set the wsl-config.env values (creates it from
                  wsl-config.env.example if missing).

    Everything is idempotent -- re-run `up` after a transient failure and it
    resumes (the restart is skipped once systemd is already PID 1).

    POC-quality tooling that mirrors docs/wsl/k8s/wsl-edge-setup.md. NOT a supported
    product; it is the scripted precursor to `az aksarc up`.

.PARAMETER Action
    Main verb: up | down | status | configure.

.PARAMETER Target
    Subverb. For 'up': prepare | create (omit for full). For 'down':
    all | cluster | node (omit for all). Not used by 'status' / 'configure'.

.PARAMETER Distro
    Dedicated WSL edge distro to target/create (default: aks-edge). A separate
    instance so your daily-driver distro is never touched.

.PARAMETER BaseDistro
    Image the dedicated distro is created from (default: Ubuntu-24.04).

.PARAMETER ConfigFile
    Path to wsl-config.env (default: .\wsl-config.env next to this script).

.PARAMETER NoCreateDistro
    (up) Fail instead of auto-creating the dedicated distro if it is missing.

.PARAMETER UnregisterDistro
    (down all) After teardown, also `wsl --unregister <distro>`.

.PARAMETER Yes
    (down) Do not prompt for confirmation (passes --yes to the cleanup script).

.EXAMPLE
    .\aks-arc-on-wsl.ps1 up
.EXAMPLE
    .\aks-arc-on-wsl.ps1 configure
.EXAMPLE
    .\aks-arc-on-wsl.ps1 up prepare
.EXAMPLE
    .\aks-arc-on-wsl.ps1 up create
.EXAMPLE
    .\aks-arc-on-wsl.ps1 down cluster            # fast delete -> re-create with 'up create'
.EXAMPLE
    .\aks-arc-on-wsl.ps1 down all -UnregisterDistro -Yes
.EXAMPLE
    .\aks-arc-on-wsl.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("up", "down", "status", "configure")]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Target,

    [string]$Distro = "aks-edge",
    [string]$BaseDistro = "Ubuntu-24.04",
    [string]$ConfigFile = "$PSScriptRoot\wsl-config.env",
    [switch]$NoCreateDistro,

    # down
    [switch]$UnregisterDistro,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Msg) Write-Host ">>> $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "!!! $Msg" -ForegroundColor Yellow }
function Throw-IfFailed { param([string]$What) if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" } }

$scriptSh  = Join-Path $PSScriptRoot "setup-aks-arc-wsl.sh"
$cleanupSh = Join-Path $PSScriptRoot "cleanup-aks-arc-wsl.sh"

# --- Preconditions ----------------------------------------------------------
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe not found. Install WSL2 first (wsl --install)."
}

# Convert a Windows path (C:\a\b) to its WSL mount path (/mnt/c/a/b) without
# relying on `wsl wslpath` (backslashes get eaten across the wsl arg boundary).
function ConvertTo-WslPath {
    param([string]$WinPath)
    $full = (Resolve-Path -LiteralPath $WinPath).Path
    $drive = $full.Substring(0, 1).ToLower()
    $rest = ($full.Substring(2) -replace '\\', '/')
    return "/mnt/$drive$rest"
}

function Get-Distros {
    # `wsl --list` emits UTF-16LE with a leading BOM, which mangles the first
    # entry when captured. WSL_UTF8=1 makes wsl emit clean UTF-8; we also strip
    # any stray NUL/BOM defensively for older WSL builds that ignore it.
    $prev = $env:WSL_UTF8
    $env:WSL_UTF8 = "1"
    try {
        wsl.exe --list --quiet 2>$null |
            ForEach-Object { (($_ -replace "`0", "").TrimStart([char]0xFEFF)).Trim() } |
            Where-Object { $_ }
    } finally {
        $env:WSL_UTF8 = $prev
    }
}
function Test-DistroExists {
    # Probe the distro directly instead of parsing `wsl --list` text (whose
    # UTF-16LE + BOM output is mangled across WSL versions / console encodings /
    # PowerShell 5 vs 7). `wsl -d <name> -- true` exits 0 iff the distro exists.
    $null = & wsl.exe -d $Distro -- true 2>&1
    return ($LASTEXITCODE -eq 0)
}
function Test-SystemdPid1 {
    $pid1 = (wsl.exe -d $Distro -- ps -p 1 -o comm= 2>$null | Out-String).Trim()
    return ($pid1 -eq "systemd")
}

# Ensure the dedicated edge distro exists (create a separate instance so the
# user's daily-driver distro is never touched). Requires WSL >= 2.4.4 for --name.
function Confirm-Distro {
    if (Test-DistroExists) { return }
    if ($NoCreateDistro) {
        throw "WSL distro '$Distro' not found and -NoCreateDistro set. Available: $((Get-Distros) -join ', ')."
    }
    Write-Step "Creating dedicated distro '$Distro' from '$BaseDistro' (your other distros are untouched)"
    # --no-launch: create the distro WITHOUT dropping into an interactive first-run
    # shell (which would pause this orchestrator until the user typed `exit`). We
    # run everything as -u root and stage as root, so no default UNIX user is needed.
    wsl.exe --install $BaseDistro --name $Distro --no-launch
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create distro '$Distro'. If your WSL predates --name/--no-launch, import a rootfs manually: wsl --import $Distro <dir> <ubuntu-24.04-rootfs.tar>"
    }
    # First boot after --no-launch: initialize the distro (root, non-interactive)
    # so systemd/user setup is done before we stage + prep.
    wsl.exe -d $Distro -u root -- true 2>$null
    if (-not (Test-DistroExists)) { throw "Distro '$Distro' still not present after install." }
}

# Detect whether the Windows host is an Azure VM (Dev Box) -> Azure-VM-host path.
function Get-AzureVmHost {
    try {
        $c = (Invoke-RestMethod -Headers @{Metadata = "true"} -TimeoutSec 3 `
              -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01").compute
        if ($c -and $c.vmId) { return "true" }
    } catch { }
    return "false"
}

# --- Stage files into WSL (~/.aksarc-wsl) -----------------------------------
function Copy-IntoWsl {
    param([switch]$IncludeCleanup)
    if (-not (Test-Path $ConfigFile)) {
        throw "Config file not found: $ConfigFile. Copy wsl-config.env.example to wsl-config.env and fill it in."
    }
    if (-not (Test-Path $scriptSh)) { throw "setup-aks-arc-wsl.sh not found next to this script." }

    $azureVmHost = Get-AzureVmHost
    $vmMsg = if ($azureVmHost -eq "true") { "ON" } else { "OFF" }
    Write-Step "Azure-VM host (Dev Box) detected: $azureVmHost  -> MSFT_ARC_TEST/IMDS handling $vmMsg"

    Write-Step "Staging scripts into WSL (~/.aksarc-wsl)"
    $shWsl  = ConvertTo-WslPath $scriptSh
    $cfgWsl = ConvertTo-WslPath $ConfigFile
    $cleanupLine = ""
    $cleanupNorm = ""
    if ($IncludeCleanup) {
        if (-not (Test-Path $cleanupSh)) { throw "cleanup-aks-arc-wsl.sh not found next to this script." }
        $clWsl = ConvertTo-WslPath $cleanupSh
        $cleanupLine = "cp '$clWsl' ~/.aksarc-wsl/cleanup-aks-arc-wsl.sh`nchmod +x ~/.aksarc-wsl/cleanup-aks-arc-wsl.sh"
        $cleanupNorm = " ~/.aksarc-wsl/cleanup-aks-arc-wsl.sh"
    }
    # Copy in, normalize line endings (in case files were touched on Windows),
    # make executable, then inject the host-detected Azure-VM-host value.
    $stage = @"
mkdir -p ~/.aksarc-wsl
cp '$shWsl' ~/.aksarc-wsl/setup-aks-arc-wsl.sh
cp '$cfgWsl' ~/.aksarc-wsl/wsl-config.env
$cleanupLine
sed -i 's/\r`$//' ~/.aksarc-wsl/setup-aks-arc-wsl.sh ~/.aksarc-wsl/wsl-config.env$cleanupNorm
chmod +x ~/.aksarc-wsl/setup-aks-arc-wsl.sh
sed -i '/^AZURE_VM_HOST=/d' ~/.aksarc-wsl/wsl-config.env
echo 'AZURE_VM_HOST=$azureVmHost' >> ~/.aksarc-wsl/wsl-config.env
"@
    wsl.exe -d $Distro -u root -- bash -lc $stage
    Throw-IfFailed "stage files into WSL"
}

function Invoke-Phase {
    param([string]$Phase)
    Write-Step "Running setup-aks-arc-wsl.sh --phase $Phase in WSL"
    # -u root for non-interactive sudo; the script also uses sudo internally.
    wsl.exe -d $Distro -u root -- bash -lc "cd ~/.aksarc-wsl && ./setup-aks-arc-wsl.sh --phase $Phase --config ~/.aksarc-wsl/wsl-config.env"
    Throw-IfFailed "phase '$Phase'"
}

function Ensure-SystemdPid1 {
    # Apply systemd only if it isn't PID 1 yet (skips the restart on re-runs).
    if (Test-SystemdPid1) {
        Write-Step "systemd already PID 1 -- no restart needed"
        return
    }
    Write-Step "Restarting distro '$Distro' to apply systemd (wsl --terminate $Distro)"
    wsl.exe --terminate $Distro
    Throw-IfFailed "wsl --terminate $Distro"
    Start-Sleep -Seconds 3
    if (-not (Test-SystemdPid1)) {
        $pid1 = (wsl.exe -d $Distro -- ps -p 1 -o comm= 2>$null | Out-String).Trim()
        throw "After restart, PID 1 is '$pid1', expected 'systemd'. Check /etc/wsl.conf."
    }
    Write-Step "systemd confirmed as PID 1"
}

function Ensure-AzLogin {
    # Drive `az login` inside the distro (as root, since provision runs as root)
    # instead of failing the provision prereq check and making the user re-run.
    # NOTE: `az account show` writes "Please run 'az login'" to stderr when logged
    # out. With the script-level $ErrorActionPreference = 'Stop', PowerShell turns
    # that native stderr into a TERMINATING NativeCommandError before we can branch
    # to the login path -- and a plain 2>&1/2>$null redirect does NOT prevent it on
    # PS 5.1. So we locally set EAP=SilentlyContinue, redirect all streams, and
    # gate on $LASTEXITCODE (also guarded by try/catch for total safety).
    $loggedIn = $false
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        wsl.exe -d $Distro -u root -- az account show --only-show-errors *> $null
        $loggedIn = ($LASTEXITCODE -eq 0)
    } catch {
        $loggedIn = $false
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    if ($loggedIn) {
        Write-Step "az already logged in (root context)"
    } else {
        Write-Step "az not logged in -- launching device-code login (root context)"
        Write-Host "    Open the URL below and enter the code to sign in." -ForegroundColor Yellow
        # `az login --use-device-code` prints the device-code prompt to stderr.
        # Under EAP='Stop' that native stderr would terminate before login can
        # finish, so run under EAP='Continue' and merge stderr->stdout (2>&1) so
        # the code stays VISIBLE in the streamed log. Gate success on exit code.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            wsl.exe -d $Distro -u root -- az login --use-device-code 2>&1 | Write-Host
        } finally {
            $ErrorActionPreference = $prevEAP
        }
        Throw-IfFailed "az login"
    }
    # Pin the subscription from the config (CMP_SUB) so provision targets the
    # right sub regardless of the account's default.
    if (Test-Path $ConfigFile) {
        $sub = Get-EnvValue -Lines (Get-Content -LiteralPath $ConfigFile) -Key "CMP_SUB"
        if ($sub) {
            wsl.exe -d $Distro -u root -- az account set --subscription $sub
            Throw-IfFailed "az account set --subscription $sub"
            Write-Step "az subscription set to $sub"
        }
    }
}

# --- up subverbs ------------------------------------------------------------
function Up-Prepare {
    Confirm-Distro
    Copy-IntoWsl
    Invoke-Phase -Phase "prep"
    Ensure-SystemdPid1
    Write-Step "up prepare complete -- OS prepped, systemd active."
}

function Up-Create {
    if (-not (Test-DistroExists)) { throw "Distro '$Distro' does not exist. Run 'up prepare' (or 'up') first." }
    if (-not (Test-SystemdPid1)) { throw "systemd is not PID 1 in '$Distro'. Run 'up prepare' (or 'up') first." }
    Ensure-AzLogin
    Copy-IntoWsl               # re-stage so we run the latest script/config
    Invoke-Phase -Phase "provision"
    Write-Step "up create complete -- cluster create submitted."
    Write-Host "Verify: .\aks-arc-on-wsl.ps1 status" -ForegroundColor Green
}

function Do-Up {
    switch ($Target) {
        "prepare" { Up-Prepare; return }
        "create"  { Up-Create;  return }
        default {
            # Full bring-up. Prepare handles staging + systemd; create re-stages
            # (harmless) and provisions. Idempotent end-to-end.
            Up-Prepare
            Up-Create
            Write-Step "up complete (prepare + create)."
        }
    }
}

# --- down subverbs ----------------------------------------------------------
function Do-Down {
    if (-not (Test-DistroExists)) { throw "Distro '$Distro' does not exist -- nothing to bring down. Available: $((Get-Distros) -join ', ')." }
    Copy-IntoWsl -IncludeCleanup
    $scope = if ([string]::IsNullOrEmpty($Target)) { "all" } else { $Target }
    $cargs = @("--config", "~/.aksarc-wsl/wsl-config.env")
    switch ($scope) {
        "all"     { }   # full teardown (no scope flag)
        "cluster" { $cargs += "--cluster-only" }
        "node"    { $cargs += "--keep-node" }
    }
    if ($Yes) { $cargs += "--yes" }
    Write-Step "Running cleanup-aks-arc-wsl.sh ($scope) in WSL"
    wsl.exe -d $Distro -u root -- bash -lc "cd ~/.aksarc-wsl && ./cleanup-aks-arc-wsl.sh $($cargs -join ' ')"
    Throw-IfFailed "down ($scope)"

    if ($UnregisterDistro) {
        if ($scope -ne "all") { throw "-UnregisterDistro requires the 'all' scope (refusing to unregister after a partial delete)." }
        Write-Warn "Unregistering distro '$Distro' (wsl --unregister) -- this destroys the WSL node entirely."
        wsl.exe --unregister $Distro
        Throw-IfFailed "wsl --unregister $Distro"
    }
    Write-Step "down complete ($scope)."
}

function Do-Status {
    Write-Step "Status for distro '$Distro'"
    if (-not (Test-DistroExists)) {
        Write-Host "  distro : NOT PRESENT (run 'up')" -ForegroundColor Yellow
        return
    }
    Write-Host "  distro : present"
    if (Test-SystemdPid1) { Write-Host "  init   : systemd (PID 1) OK" }
    else {
        $pid1 = (wsl.exe -d $Distro -- ps -p 1 -o comm= 2>$null | Out-String).Trim()
        Write-Host "  init   : PID 1 = '$pid1' (re-run 'up' to apply systemd)" -ForegroundColor Yellow
    }
    $arc = (wsl.exe -d $Distro -u root -- bash -lc "azcmagent show 2>/dev/null | grep -E 'Agent Status|Resource Name' || echo 'not connected'" | Out-String).Trim()
    Write-Host "  arc    : $arc"
    Write-Host "  nodes  :"
    wsl.exe -d $Distro -u root -- bash -lc "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide 2>/dev/null || sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes -o wide 2>/dev/null || echo '    (no kubeconfig yet -- cluster not created)'"
}

# --- configure --------------------------------------------------------------
# Read/write a bash KEY=VALUE line in-place (the config is `source`d as bash,
# so values with spaces or shell-special chars must be double-quoted).
function Get-EnvValue {
    param([string[]]$Lines, [string]$Key)
    $line = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))=" } | Select-Object -First 1
    if (-not $line) { return "" }
    $v = ($line -replace "^\s*$([regex]::Escape($Key))=", "").Trim()
    # Strip a matching pair of surrounding quotes (single OR double). The config
    # file is bash-sourced, so values may be single-quoted (e.g. paths with
    # spaces) -- those quotes must not leak into `az ... --subscription`.
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
        $v = $v.Substring(1, $v.Length - 2)
    }
    return $v
}
function Set-EnvValue {
    param([ref]$Lines, [string]$Key, [string]$Value)
    # Quote if the value contains whitespace or shell-special chars.
    $out = if ($Value -match '[\s|"'']' ) { '"' + ($Value -replace '"', '\"') + '"' } else { $Value }
    $found = $false
    for ($i = 0; $i -lt $Lines.Value.Count; $i++) {
        if ($Lines.Value[$i] -match "^\s*$([regex]::Escape($Key))=") { $Lines.Value[$i] = "$Key=$out"; $found = $true; break }
    }
    if (-not $found) { $Lines.Value += "$Key=$out" }
}

function Do-Configure {
    $examplePath = Join-Path $PSScriptRoot "wsl-config.env.example"
    if (-not (Test-Path $ConfigFile)) {
        if (-not (Test-Path $examplePath)) { throw "Neither $ConfigFile nor wsl-config.env.example found." }
        Write-Step "Creating $ConfigFile from wsl-config.env.example"
        Copy-Item $examplePath $ConfigFile
    }
    $lines = [System.Collections.ArrayList]@(Get-Content -LiteralPath $ConfigFile)

    # key, prompt text, allowed-values (or $null), advanced-only.
    # Constants (API versions, HCI roles, C2E appId, ADO/BMAgent paths, DNS,
    # VM_SWITCH, BMAGENT_BUILD_DEFINITION) have script defaults and aren't prompted;
    # AZURE_VM_HOST is auto-detected/injected at stage time.
    $fields = @(
        @{ Key = "DISTRIBUTION";           Prompt = "Kubernetes distribution";                 Set = @("k8s", "k3s") },
        @{ Key = "CMP_SUB";                Prompt = "CMP subscription ID";                     Set = $null },
        @{ Key = "CMP_RG";                 Prompt = "CMP resource group";                      Set = $null },
        @{ Key = "CMP_AKS";                Prompt = "CMP AKS cluster name";                    Set = $null },
        @{ Key = "CMP_CONN";               Prompt = "CMP connected-cluster name";              Set = $null },
        @{ Key = "CMP_LOCATION";           Prompt = "CMP location";                            Set = $null },
        @{ Key = "EDGE_LOCATION";          Prompt = "Edge location";                           Set = $null },
        @{ Key = "TENANT_ID";              Prompt = "Tenant ID";                               Set = $null },
        @{ Key = "K8S_VERSION";            Prompt = "Kubernetes version (<semver>-<date>)";    Set = $null },
        @{ Key = "AKSARC_WHEEL_PATH";      Prompt = "Private aksarc wheel path (blank=skip)";  Set = $null },
        @{ Key = "ENABLE_GPU";             Prompt = "Enable GPU + Foundry Local";              Set = @("true", "false") },
        @{ Key = "ENABLE_BMAGENT_HOTSWAP"; Prompt = "Force BMAgent hot-swap up front";         Set = @("true", "false") }
    )

    Write-Step "Configuring $ConfigFile  (Enter = keep current value)"

    foreach ($f in $fields) {
        $cur = Get-EnvValue -Lines $lines -Key $f.Key
        $hint = if ($f.Set) { " [" + ($f.Set -join "/") + "]" } else { "" }
        while ($true) {
            $ans = Read-Host "  $($f.Prompt)$hint (current: '$cur')"
            if ([string]::IsNullOrEmpty($ans)) { $ans = $cur }        # keep current
            if ($f.Set -and $ans -and ($ans -notin $f.Set)) {
                Write-Warn "must be one of: $($f.Set -join ', ')"
                continue
            }
            break
        }
        Set-EnvValue -Lines ([ref]$lines) -Key $f.Key -Value $ans
    }

    # Write UTF-8 WITHOUT a BOM. Windows PowerShell 5's Set-Content/-Encoding UTF8
    # emits a BOM (and its default is the ANSI codepage), either of which can break
    # bash `source` of the config inside WSL. Use .NET with a no-BOM UTF8Encoding.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines((Resolve-Path -LiteralPath $ConfigFile), [string[]]$lines, $utf8NoBom)
    Write-Step "Saved $ConfigFile"
    Write-Host "Next: .\aks-arc-on-wsl.ps1 up" -ForegroundColor Green
}

# --- Validate subverb + dispatch --------------------------------------------
switch ($Action) {
    "up" {
        if ($Target -and $Target -notin @("prepare", "create")) { throw "Invalid subverb '$Target' for 'up'. Use: prepare | create (or omit for full)." }
        Do-Up
    }
    "down" {
        if ($Target -and $Target -notin @("all", "cluster", "node")) { throw "Invalid subverb '$Target' for 'down'. Use: all | cluster | node (or omit for all)." }
        Do-Down
    }
    "status" {
        if ($Target) { throw "'status' takes no subverb." }
        Do-Status
    }
    "configure" {
        if ($Target) { throw "'configure' takes no subverb." }
        Do-Configure
    }
}
