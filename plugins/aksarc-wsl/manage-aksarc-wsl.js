/*
 * Copyright 2025 The Kubernetes Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * manage-aksarc-wsl.js  (deploy branch)
 *
 * Node.js orchestrator for the PUBLIC `az aksarc deploy` flow on WSL. It runs on
 * the Headlamp app/Electron node runtime (via the `scriptjs` run-command) and
 * replaces the previous PowerShell orchestrator entirely: it drives wsl.exe
 * directly to create the distro, apply systemd (which requires a restart from
 * OUTSIDE the distro), and run the bundled bash phases
 * (setup-aks-arc-deploy.sh) that do the OS prep and `az aksarc deploy`.
 *
 *   scriptjs aksarc-wsl/manage-aksarc-wsl.js <action> <base64-json-config>
 *   action = up | down | status | kubeconfig | validate
 */

'use strict';

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

// Dedicated WSL distro + base image for the edge node.
const DISTRO = 'aks-edge';
const BASE_DISTRO = 'Ubuntu-24.04';
// Staging dir inside the distro.
const STAGE = '~/.aksarc-deploy';

// deploy-config.env keys the bash script understands. Anything else is ignored.
const KNOWN_KEYS = [
  'SUBSCRIPTION',
  'RESOURCE_GROUP',
  'TENANT_ID',
  'LOCATION',
  'AKSARC_WHEEL_PATH',
  'AKSARC_BUILD_ID',
  'AKSARC_WHEEL_URL',
  'DISTRIBUTION',
  'CMP_SUBSCRIPTION',
  'CMP_RESOURCE_GROUP',
  'CMP_NAME',
  'AUTH_MODE',
  'AZURE_CLIENT_ID',
  'AZURE_CLIENT_SECRET',
  'VALIDATE_ONLY',
];
const FORBIDDEN_RE = /[\r\n\0]/;

function log(msg) {
  process.stdout.write(msg.endsWith('\n') ? msg : msg + '\n');
}
function fail(msg) {
  process.stderr.write(`ERROR: ${msg}\n`);
  process.exit(1);
}
function shSingleQuote(v) {
  return "'" + String(v).replace(/'/g, "'\\''") + "'";
}

function parseConfig(b64) {
  let obj;
  try {
    obj = JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
  } catch (e) {
    fail(`config is not valid base64 JSON: ${e.message}`);
  }
  if (!obj || typeof obj !== 'object') {
    fail('config must be a JSON object');
  }
  return obj;
}

function serializeEnv(config) {
  const lines = [];
  for (const key of KNOWN_KEYS) {
    if (!(key in config)) {
      continue;
    }
    let value = config[key];
    if (typeof value === 'boolean') {
      value = value ? 'true' : 'false';
    }
    value = String(value).trim();
    if (FORBIDDEN_RE.test(value)) {
      fail(`value for ${key} must be a single line`);
    }
    lines.push(`${key}=${shSingleQuote(value)}`);
  }
  return lines.join('\n') + '\n';
}

/** Convert a Windows path (C:\a\b) to its WSL drvfs form (/mnt/c/a/b). */
function winToWslPath(p) {
  const m = /^([A-Za-z]):[\\/](.*)$/.exec(p);
  if (!m) {
    return p;
  }
  return '/mnt/' + m[1].toLowerCase() + '/' + m[2].replace(/\\/g, '/');
}

/** Run a command, streaming stdout/stderr; resolves with the exit code. */
function run(cmd, args, opts = {}) {
  return new Promise(resolve => {
    const child = spawn(cmd, args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'], ...opts });
    if (opts.input !== undefined) {
      child.stdin.write(opts.input);
    }
    child.stdin.end();
    child.stdout.on('data', d => process.stdout.write(d));
    child.stderr.on('data', d => process.stderr.write(d));
    child.on('error', err => {
      process.stderr.write(`ERROR: failed to launch ${cmd}: ${err.message}\n`);
      resolve(-1);
    });
    child.on('exit', code => resolve(code === null ? 1 : code));
  });
}

/** Run a command; resolves with { code, out } capturing stdout (still streamed off). */
function capture(cmd, args) {
  return new Promise(resolve => {
    let out = '';
    const child = spawn(cmd, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', d => (out += d.toString()));
    child.stderr.on('data', () => {});
    child.on('error', () => resolve({ code: -1, out: '' }));
    child.on('exit', code => resolve({ code: code === null ? 1 : code, out }));
  });
}

const wsl = (...args) => run('wsl.exe', args);
// Run a bash command as root inside DISTRO/runDistro. IMPORTANT: pass the
// script base64-encoded rather than as a literal `bash -lc "<script>"` arg.
// The literal-arg form has to survive re-quoting across the Windows spawn ->
// wsl.exe -> Linux bash boundary, and complex scripts (nested double-quotes,
// $(...) command substitutions, parens) do NOT survive that intact — e.g.
// observed "syntax error near unexpected token '('" even though the JS
// string itself was correct, because wsl.exe's own argv marshalling mangled
// it before bash ever saw it. Base64 has no shell-special characters, so it
// passes through every layer unchanged and is decoded back to the exact
// original script on the other side.
const wslRoot = cmd =>
  run('wsl.exe', ['-d', DISTRO, '-u', 'root', '--', 'bash', '-c', `echo ${Buffer.from(cmd).toString('base64')} | base64 -d | bash -l`]);

/**
 * Launch (or confirm) a long-lived, host-side `wsl.exe` process attached to
 * DISTRO. This is the ONLY thing that actually prevents the shared WSL2
 * utility VM from powering itself off ~10-25s after the last attached
 * Windows-side `wsl.exe` session disconnects — `vmIdleTimeout` in
 * `.wslconfig` does NOT prevent this teardown (verified ineffective at both
 * `-1` and its documented max value), and an in-guest systemd unit (e.g. a
 * `sleep`-loop service) does not count either, because it isn't a host-side
 * attached session. See docs/wsl/KNOWN-ISSUES.md issue #6, Cause D.
 *
 * Detached + unref'd so it survives after this Node process (and the
 * Headlamp plugin invocation that spawned it) exits — otherwise the cluster
 * would go unreachable again the moment `up`/`kubeconfig` finishes. Tracks
 * the spawned pid in a lock file so repeated calls (e.g. every time the
 * plugin loads the kubeconfig) don't pile up duplicate keepalive processes.
 */
function ensureHostKeepAliveProcess() {
  const lockPath = path.join(os.tmpdir(), `aksarc-wsl-keepalive-${DISTRO}.pid`);
  try {
    const existingPid = parseInt(fs.readFileSync(lockPath, 'utf8').trim(), 10);
    if (existingPid) {
      // process.kill(pid, 0) throws if the pid does not exist; succeeds (no-op) if it does.
      process.kill(existingPid, 0);
      log(`>>> Keepalive process already running (pid ${existingPid}); not starting another`);
      return;
    }
  } catch (e) {
    // No lock file, unreadable, or the pid is dead — fall through and (re)start it.
  }
  const child = spawn('wsl.exe', ['-d', DISTRO, '--', 'sleep', 'infinity'], {
    windowsHide: true,
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  try {
    fs.writeFileSync(lockPath, String(child.pid));
  } catch (e) {
    // Non-fatal — worst case we spawn a redundant keepalive next time.
  }
  log(`>>> Started a persistent 'wsl -d ${DISTRO} -- sleep infinity' keepalive process (pid ${child.pid}) so the WSL VM stays up while Headlamp is used`);
}

async function distroExists() {
  // `wsl -d <name> -- true` exits 0 iff the distro exists.
  const { code } = await capture('wsl.exe', ['-d', DISTRO, '--', 'true']);
  return code === 0;
}

async function systemdIsPid1() {
  const { code, out } = await capture('wsl.exe', ['-d', DISTRO, '--', 'ps', '-p', '1', '-o', 'comm=']);
  return code === 0 && out.trim() === 'systemd';
}

async function importDistro() {
  // Fallback when `wsl --install --name` fails — e.g. its WinINET-based downloader
  // can't reach raw.githubusercontent.com on some (corp) networks even though the
  // rest of the internet is fine. Download the Ubuntu 24.04 WSL image directly with
  // curl.exe (a working network path) and import it as a FRESH, SEPARATE distro:
  // no dependency on WSL's built-in downloader, and no clone of any existing distro.
  // Detect target arch by probing the base distro's kernel — process.arch is
  // unreliable under x64 emulation on ARM64 Windows.
  let arm64 = false;
  const probe = await capture('wsl.exe', ['-d', BASE_DISTRO, '--', 'uname', '-m']);
  if (probe.code === 0) {
    arm64 = probe.out.trim() === 'aarch64';
  } else {
    arm64 = process.env.PROCESSOR_ARCHITECTURE === 'ARM64' || process.env.PROCESSOR_ARCHITEW6432 === 'ARM64';
  }
  const url = arm64
    ? 'https://cdimages.ubuntu.com/releases/24.04.4/release/ubuntu-24.04.4-wsl-arm64.wsl'
    : 'https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-wsl-amd64.wsl';
  const tmp = path.join(os.tmpdir(), `aksedge-ubuntu-2404-${arm64 ? 'arm64' : 'amd64'}.wsl`);
  const installDir = path.join(process.env.LOCALAPPDATA || os.homedir(), 'WSL', DISTRO);
  log(`>>> Downloading Ubuntu 24.04 image (${arm64 ? 'arm64' : 'amd64'}) via curl — WSL's own downloader failed`);
  let code = await run('curl.exe', ['-fSL', '--retry', '3', '-o', tmp, url]);
  if (code !== 0) {
    fail(`failed to download Ubuntu image from ${url} (curl exit ${code})`);
  }
  fs.mkdirSync(installDir, { recursive: true });
  log(`>>> Importing fresh distro '${DISTRO}' from the downloaded image`);
  code = await wsl('--import', DISTRO, installDir, tmp);
  if (code !== 0) {
    fail(`failed to import distro '${DISTRO}' (exit ${code})`);
  }
}

async function ensureDistro() {
  if (await distroExists()) {
    return;
  }
  log(`>>> Creating distro '${DISTRO}' from '${BASE_DISTRO}' (--no-launch)`);
  const code = await wsl('--install', BASE_DISTRO, '--name', DISTRO, '--no-launch');
  if (code !== 0) {
    log(`>>> 'wsl --install' failed (exit ${code}) — falling back to direct image download + import`);
    await importDistro();
  }
  await capture('wsl.exe', ['-d', DISTRO, '-u', 'root', '--', 'true']); // first boot
  if (!(await distroExists())) {
    fail(`distro '${DISTRO}' still not present after install/import`);
  }
}

/**
 * Keep the WSL2 utility VM alive for the whole (~40 min) deploy, AND for as
 * long as the user wants to keep using the cluster from Headlamp afterwards.
 *
 * NOTE: `vmIdleTimeout=-1` in `.wslconfig` alone is NOT sufficient — it was
 * verified (both at `-1` and at its documented max value, 4294967295) to NOT
 * prevent the shared WSL2 utility VM from powering itself off within
 * ~10-25s of the last attached host-side `wsl.exe` process disconnecting.
 * The only thing that reliably prevents this is keeping an actual `wsl.exe`
 * process attached to the distro (see `ensureHostKeepAliveProcess`). We still
 * set `vmIdleTimeout=-1` too (harmless, and helps in case a future WSL
 * version fixes/honors it), but do not rely on it alone.
 * See docs/wsl/KNOWN-ISSUES.md issue #6, Cause D, for the full investigation.
 */
async function ensureWslKeepAlive() {
  const cfgPath = path.join(os.homedir(), '.wslconfig');
  let orig = '';
  try {
    orig = fs.readFileSync(cfgPath, 'utf8');
  } catch (e) {
    orig = '';
  }
  let next;
  if (/^\s*vmIdleTimeout\s*=/m.test(orig)) {
    next = orig.replace(/^\s*vmIdleTimeout\s*=.*$/m, 'vmIdleTimeout=-1');
  } else if (/^\s*\[wsl2\]/m.test(orig)) {
    next = orig.replace(/^(\s*\[wsl2\][^\n]*\n)/m, '$1vmIdleTimeout=-1\n');
  } else {
    next = (orig.trim() ? orig.replace(/\s*$/, '') + '\n\n' : '') + '[wsl2]\nvmIdleTimeout=-1\n';
  }
  if (next !== orig) {
    try {
      fs.writeFileSync(cfgPath, next);
      log('>>> Set vmIdleTimeout=-1 in .wslconfig (best-effort; see keepalive process for the real fix)');
      // Apply the VM-level setting. This restarts the WSL2 utility VM; the next wsl
      // command re-boots the distro with the new timeout in effect.
      await wsl('--shutdown');
    } catch (e) {
      log(`>>> WARN: could not write ${cfgPath} (${e.message}); continuing anyway`);
    }
  }
  // The actual fix: keep a real attached host-side session alive.
  ensureHostKeepAliveProcess();
}

/** Copy the bundled deploy script + write the config into the distro. */
async function stage(config) {
  const scriptWin = path.join(__dirname, 'scripts', 'setup-aks-arc-deploy.sh');
  const scriptWsl = winToWslPath(scriptWin);
  log('>>> Staging deploy script + config into WSL');
  let code = await wslRoot(
    `mkdir -p ${STAGE} && cp ${shSingleQuote(scriptWsl)} ${STAGE}/setup-aks-arc-deploy.sh && ` +
      `sed -i 's/\\r$//' ${STAGE}/setup-aks-arc-deploy.sh && chmod +x ${STAGE}/setup-aks-arc-deploy.sh`
  );
  if (code !== 0) {
    fail('failed to stage the deploy script into WSL');
  }
  // Write the config via stdin (avoids putting secrets on the command line).
  code = await run(
    'wsl.exe',
    ['-d', DISTRO, '-u', 'root', '--', 'bash', '-lc', `umask 077; cat > ${STAGE}/deploy-config.env`],
    { input: serializeEnv(config) }
  );
  if (code !== 0) {
    fail('failed to write the deploy config into WSL');
  }
}

const runPhase = phase =>
  wslRoot(`cd ${STAGE} && ./setup-aks-arc-deploy.sh --phase ${phase} --config ${STAGE}/deploy-config.env`);

async function actionUp(config) {
  await ensureWslKeepAlive();
  await ensureDistro();
  await stage(config);

  log('>>> Phase: prep');
  if ((await runPhase('prep')) !== 0) {
    fail('prep phase failed');
  }

  // systemd is applied only on a cold boot of the distro; an in-WSL script
  // cannot restart its own PID 1, so we terminate it from here (leaves other
  // distros running) and let the next command re-boot it.
  if (!(await systemdIsPid1())) {
    log(`>>> Restarting distro '${DISTRO}' to apply systemd (wsl --terminate)`);
    await wsl('--terminate', DISTRO);
    await capture('wsl.exe', ['-d', DISTRO, '-u', 'root', '--', 'true']); // re-boot
    if (!(await systemdIsPid1())) {
      fail('systemd is not PID 1 after restart — check /etc/wsl.conf');
    }
    log('>>> systemd confirmed as PID 1');
  }

  log('>>> Phase: deploy');
  const code = await runPhase('deploy');
  if (code !== 0) {
    fail(`deploy phase failed (exit ${code})`);
  }
  log('>>> up complete.');
}

/** Stop and remove the host-side keepalive process + its lock file, if any. */
function stopHostKeepAliveProcess() {
  const lockPath = path.join(os.tmpdir(), `aksarc-wsl-keepalive-${DISTRO}.pid`);
  try {
    const pid = parseInt(fs.readFileSync(lockPath, 'utf8').trim(), 10);
    if (pid) {
      try {
        process.kill(pid);
        log(`>>> Stopped keepalive process (pid ${pid})`);
      } catch (e) {
        // Already dead — fine.
      }
    }
  } catch (e) {
    // No lock file — nothing to stop.
  }
  try {
    fs.unlinkSync(lockPath);
  } catch (e) {
    // Ignore if already gone.
  }
}

async function actionDown(config) {
  // The '${DISTRO}' distro may already be gone — e.g. a prior "Delete cluster"
  // run got as far as `wsl --unregister` despite leaving Azure resources
  // orphaned (the exact bug this file was just fixed for), or the user
  // manually removed it. Azure-side cleanup still needs to run in that case,
  // so fall back to running `az`/`azcmagent` inside BASE_DISTRO instead of
  // hard-failing with "nothing to delete" — that message is only true for the
  // WSL side, not the Azure side.
  const haveAksEdge = await distroExists();
  let runDistro = DISTRO;
  if (!haveAksEdge) {
    const { code: baseCode } = await capture('wsl.exe', ['-d', BASE_DISTRO, '--', 'true']);
    if (baseCode !== 0) {
      stopHostKeepAliveProcess();
      fail(
        `distro '${DISTRO}' not present, and fallback distro '${BASE_DISTRO}' is also not available — ` +
          `cannot run 'az aksarc undeploy' to clean up Azure resources. Re-import/reinstall a distro, ` +
          `or run 'az aksarc undeploy' manually against resource group '${config.RESOURCE_GROUP}'.`
      );
    }
    log(
      `>>> distro '${DISTRO}' is not present (likely left over from a prior incomplete teardown); ` +
        `falling back to '${BASE_DISTRO}' to run the Azure-side cleanup (az aksarc undeploy / azcmagent disconnect)`
    );
    runDistro = BASE_DISTRO;
  }
  const wslRootOn = cmd =>
    run('wsl.exe', ['-d', runDistro, '-u', 'root', '--', 'bash', '-c', `echo ${Buffer.from(cmd).toString('base64')} | base64 -d | bash -l`]);
  const rg = config.RESOURCE_GROUP;
  const distribution = config.DISTRIBUTION || 'k8s';
  // Full teardown, mirroring `deploy_cluster()` in setup-aks-arc-deploy.sh:
  // `az aksarc undeploy` is the true counterpart of `az aksarc deploy` (used
  // by `up`) — unlike `az aksarc delete` (which only deletes the provisioned
  // cluster object), `undeploy` tears down ALL of the associated Azure
  // resources that `deploy` created for this Arc machine (DevicePool,
  // EdgeMachine, CustomLocation, etc.), not just the cluster. It takes the
  // same --arc-machine-names the deploy step used (derived the same way:
  // lower-cased short hostname) and is safe/idempotent to re-run if a prior
  // teardown was left incomplete.
  log('>>> Tearing down the AKS Arc deployment (az aksarc undeploy — removes all associated Azure resources, not just the cluster)');
  // IMPORTANT: do NOT re-derive the Arc machine name via `hostname -s` here.
  // A prior version did that and it returned an EMPTY string in some runs
  // (root non-interactive shell / hostname quirk), which silently corrupted
  // the whole teardown: `az aksarc undeploy` derives ALL resource names from
  // --arc-machine-names, so an empty name made it compute wrong resource ids
  // (e.g. "-cluster" instead of "cpc-xxxx-cluster"), 404 on each of those,
  // and treat every 404 as "already deleted" — reporting exit 0 while
  // leaving every real resource (cluster, DevicePool, CustomLocation,
  // LogicalNetwork, EdgeMachine, extensions) orphaned in Azure. Instead,
  // look up the ACTUAL registered Arc machine name from Azure itself (the
  // same RG the cluster was deployed into), and hard-fail before calling
  // undeploy if we can't resolve it — better to stop than to silently
  // corrupt every derived resource name again.
  const undeployScript =
    `set -e; az account set --subscription ${shSingleQuote(config.SUBSCRIPTION)}; ` +
    `machine=$(az connectedmachine list -g ${shSingleQuote(rg)} --query "[0].name" -o tsv 2>/dev/null); ` +
    `if [ -z "$machine" ]; then ` +
    `  remaining=$(az resource list -g ${shSingleQuote(rg)} --query "length([])" -o tsv 2>/dev/null || echo 0); ` +
    `  if [ "$remaining" = "0" ]; then echo ">>> no Arc machine found in ${rg} and the resource group is already empty — nothing to undeploy"; exit 0; fi; ` +
    `  echo ">>> ERROR: could not resolve the Arc machine name in ${rg} via az connectedmachine list, but ${rg} still has $remaining resource(s) left — refusing to guess; run 'az resource list -g ${rg}' and clean up manually, or 'az aksarc undeploy' with an explicit --arc-machine-names" >&2; exit 1; fi; ` +
    `echo ">>> Arc machine: $machine"; ` +
    `az aksarc undeploy -g ${shSingleQuote(rg)} --arc-machine-names "$machine" ` +
    `--distribution ${shSingleQuote(distribution)} --yes`;
  let undeployCode = await wslRootOn(undeployScript);
  if (undeployCode !== 0) {
    // Per `az aksarc undeploy`'s own guidance: an EdgeMachine can be left in
    // a transient Failed state on the first pass (still claimed by the
    // DevicePool at the moment it's deleted) and just needs a second,
    // idempotent run once the DevicePool is fully gone. Retry once
    // automatically instead of leaving the user with an incomplete teardown.
    log(`>>> az aksarc undeploy exited ${undeployCode}; retrying once (EdgeMachine may need a second pass once DevicePool is gone)`);
    undeployCode = await wslRootOn(undeployScript);
  }
  if (undeployCode !== 0) {
    fail(
      `az aksarc undeploy failed after retry (exit ${undeployCode}) — Azure resources in ` +
        `'${rg}' may still be partially deployed. Not proceeding to disconnect the Arc machine ` +
        `or unregister the WSL distro; re-run "Delete cluster" once the underlying issue is fixed, ` +
        `or run 'az aksarc undeploy' manually.`
    );
  }

  log('>>> Disconnecting the Arc-enabled machine (deletes the Microsoft.HybridCompute machine resource in Azure)');
  // `undeploy` tears down the DevicePool/EdgeMachine/CustomLocation resources
  // it created, but NOT the underlying Arc machine registration itself (that
  // was created separately by `azcmagent connect`, not `az aksarc deploy`) —
  // so we still disconnect it explicitly to avoid leaving that resource
  // behind. Plain `azcmagent disconnect` (no flags) reuses the already-logged-
  // in `az` CLI session in the distro to delete the ARM resource, THEN clears
  // local agent state. Do NOT use --force-local-only here — per `azcmagent
  // disconnect --help` that flag deliberately skips contacting Azure and only
  // clears local state, which would leave the Arc machine resource orphaned
  // in the resource group — the opposite of a full teardown. Fall back to
  // --force-local-only only if Azure is unreachable, so we still clear local
  // state rather than leaving the agent half-torn-down.
  //
  // IMPORTANT: plain `azcmagent disconnect` does NOT reuse the az CLI login —
  // it falls back to its own interactive device-code flow, which then times
  // out in this non-interactive context (observed: "context deadline
  // exceeded" after ~device-code timeout) and only THEN falls through to
  // --force-local-only, leaving the Arc machine resource orphaned exactly as
  // the flag's own warning says it will. Pass an explicit ARM access token
  // (the same approach setup-aks-arc-deploy.sh's ensure_arc_connect() uses
  // for `azcmagent connect`) so disconnect authenticates non-interactively
  // too.
  const disconnectScript =
    `set -e; az account set --subscription ${shSingleQuote(config.SUBSCRIPTION)} >/dev/null 2>&1 || true; ` +
    `tok=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv 2>/dev/null); ` +
    `if [ -n "$tok" ]; then azcmagent disconnect --access-token "$tok" 2>&1; else azcmagent disconnect 2>&1; fi ` +
    `|| azcmagent disconnect --force-local-only 2>&1 ` +
    `|| echo ">>> azcmagent disconnect failed (non-fatal; Arc machine resource may be orphaned — check the resource group)"`;
  await wslRootOn(disconnectScript);

  // Stop the host-side keepalive process BEFORE unregistering — otherwise the
  // detached `wsl.exe -d ... sleep infinity` process would itself keep a
  // reference/handle open on the distro we're about to delete. Only relevant
  // if 'aks-edge' actually existed (keepalive always targets DISTRO).
  stopHostKeepAliveProcess();

  if (haveAksEdge) {
    log(`>>> Unregistering WSL distro '${DISTRO}' (deletes its virtual disk)`);
    const { code: unregisterCode } = await capture('wsl.exe', ['--unregister', DISTRO]);
    if (unregisterCode !== 0) {
      fail(`wsl --unregister ${DISTRO} failed (exit ${unregisterCode})`);
    }
    log('>>> down complete: cluster deleted, Arc machine disconnected, WSL distro unregistered.');
  } else {
    log(`>>> down complete: cluster deleted, Arc machine disconnected. (distro '${DISTRO}' was already gone.)`);
  }
  process.exit(0);
}

async function actionStatus(config) {
  if (!(await distroExists())) {
    log(`distro '${DISTRO}': NOT PRESENT`);
    return;
  }
  // Self-heal: if a prior keepalive process died (e.g. after a Windows
  // reboot/sleep), re-arm it whenever the user checks status.
  ensureHostKeepAliveProcess();
  await wslRoot(
    `echo "== distro =="; ps -p 1 -o comm= | sed "s/^/init: /"; ` +
      `echo "== arc =="; azcmagent show 2>/dev/null | grep -E "Agent Status|Resource Name" || echo "not connected"; ` +
      `echo "== cluster =="; az aksarc list -g ${shSingleQuote(config.RESOURCE_GROUP)} ` +
      `--query "[].{name:name,state:provisioningState}" -o table 2>/dev/null || echo "(az not ready / not logged in)"`
  );
}

/** Stream the cluster kubeconfig for Headlamp auto-load. */
async function actionKubeconfig(config) {
  // Self-heal here too: this is called every time the plugin (re-)registers
  // the cluster with Headlamp, so it's the most reliable place to guarantee
  // the VM stays reachable for the session that's about to use it.
  ensureHostKeepAliveProcess();
  // Prefer az aksarc get-credentials (works for the RP-managed cluster); fall
  // back to the node-local admin.conf.
  const rg = config.RESOURCE_GROUP;
  const code = await wslRoot(
    `set -e; az account set --subscription ${shSingleQuote(config.SUBSCRIPTION)} >/dev/null 2>&1 || true; ` +
      `name=$(az aksarc list -g ${shSingleQuote(rg)} --query "[0].name" -o tsv 2>/dev/null); ` +
      `if [ -n "$name" ]; then az aksarc get-credentials -g ${shSingleQuote(rg)} -n "$name" --file /tmp/kc >/dev/null 2>&1 && cat /tmp/kc && exit 0; fi; ` +
      `cat /etc/kubernetes/admin.conf`
  );
  process.exit(code === null ? 1 : code);
}

async function main() {
  const action = process.argv[2];
  const payload = process.argv[3];
  if (!action || !payload) {
    fail('usage: manage-aksarc-wsl.js <up|down|status|kubeconfig|validate> <base64-config>');
  }
  if (process.platform !== 'win32') {
    fail(`AKS Arc on WSL is only supported on Windows (needs wsl.exe). Detected: ${process.platform}.`);
  }
  const config = parseConfig(payload);

  switch (action) {
    case 'validate':
      config.VALIDATE_ONLY = 'true';
      await actionUp(config);
      break;
    case 'up':
      await actionUp(config);
      break;
    case 'down':
      await actionDown(config);
      break;
    case 'status':
      await actionStatus(config);
      break;
    case 'kubeconfig':
      await actionKubeconfig(config);
      break;
    default:
      fail(`unknown action '${action}' (expected up | down | status | kubeconfig | validate)`);
  }
}

main().catch(err => fail(err && err.stack ? err.stack : String(err)));
