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
const wslRoot = cmd => run('wsl.exe', ['-d', DISTRO, '-u', 'root', '--', 'bash', '-lc', cmd]);

async function distroExists() {
  // `wsl -d <name> -- true` exits 0 iff the distro exists.
  const { code } = await capture('wsl.exe', ['-d', DISTRO, '--', 'true']);
  return code === 0;
}

async function systemdIsPid1() {
  const { code, out } = await capture('wsl.exe', ['-d', DISTRO, '--', 'ps', '-p', '1', '-o', 'comm=']);
  return code === 0 && out.trim() === 'systemd';
}

async function ensureDistro() {
  if (await distroExists()) {
    return;
  }
  log(`>>> Creating distro '${DISTRO}' from '${BASE_DISTRO}' (--no-launch)`);
  const code = await wsl('--install', BASE_DISTRO, '--name', DISTRO, '--no-launch');
  if (code !== 0) {
    fail(`failed to create distro '${DISTRO}' (exit ${code})`);
  }
  await capture('wsl.exe', ['-d', DISTRO, '-u', 'root', '--', 'true']); // first boot
  if (!(await distroExists())) {
    fail(`distro '${DISTRO}' still not present after install`);
  }
}

/**
 * Keep the WSL2 utility VM alive for the whole (~40 min) deploy. Without this,
 * WSL idles the VM down after ~60s of no in-distro activity, which stops the Arc
 * agent — and the deploy's on-host AksArcPrereqs extension then wedges in
 * "Creating" because there is no agent to run it. vmIdleTimeout is a VM-level
 * (.wslconfig [wsl2]) setting, so applying a change needs a `wsl --shutdown`.
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
  if (next === orig) {
    return; // already keeping the VM alive
  }
  try {
    fs.writeFileSync(cfgPath, next);
  } catch (e) {
    log(`>>> WARN: could not write ${cfgPath} (${e.message}); the WSL VM may idle down mid-deploy`);
    return;
  }
  log('>>> Set vmIdleTimeout=-1 in .wslconfig (keeps the WSL VM alive during the deploy)');
  // Apply the VM-level setting. This restarts the WSL2 utility VM; the next wsl
  // command re-boots the distro with the new timeout in effect.
  await wsl('--shutdown');
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

async function actionDown(config) {
  if (!(await distroExists())) {
    fail(`distro '${DISTRO}' not present — nothing to delete`);
  }
  const rg = config.RESOURCE_GROUP;
  const machine = '$(hostname -s | tr "[:upper:]" "[:lower:]")';
  // Cluster-only delete (keep the Arc machine + any reusable infra) for a fast
  // re-deploy loop: find the provisioned cluster in the RG and delete just it.
  log('>>> Deleting the provisioned cluster (cluster-only; keeps Arc machine)');
  const script =
    `set -e; az account set --subscription ${shSingleQuote(config.SUBSCRIPTION)}; ` +
    `name=$(az aksarc list -g ${shSingleQuote(rg)} --query "[0].name" -o tsv 2>/dev/null); ` +
    `if [ -z "$name" ]; then echo ">>> no provisioned cluster found in ${rg}"; exit 0; fi; ` +
    `echo ">>> deleting cluster $name"; az aksarc delete -g ${shSingleQuote(rg)} -n "$name" --yes`;
  const code = await wslRoot(script);
  process.exit(code === null ? 1 : code);
}

async function actionStatus(config) {
  if (!(await distroExists())) {
    log(`distro '${DISTRO}': NOT PRESENT`);
    return;
  }
  await wslRoot(
    `echo "== distro =="; ps -p 1 -o comm= | sed "s/^/init: /"; ` +
      `echo "== arc =="; azcmagent show 2>/dev/null | grep -E "Agent Status|Resource Name" || echo "not connected"; ` +
      `echo "== cluster =="; az aksarc list -g ${shSingleQuote(config.RESOURCE_GROUP)} ` +
      `--query "[].{name:name,state:provisioningState}" -o table 2>/dev/null || echo "(az not ready / not logged in)"`
  );
}

/** Stream the cluster kubeconfig for Headlamp auto-load. */
async function actionKubeconfig(config) {
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
