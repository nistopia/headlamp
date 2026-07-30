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
 * manage-aksarc-wsl.js
 *
 * Runtime helper shipped with the `aksarc-wsl` Headlamp plugin. It is executed
 * by the Headlamp desktop app via the `scriptjs` run-command mechanism
 * (see app/electron/runCmd.ts), which runs it with the app/Electron binary as
 * the Node runtime -- so no separate Node install is required.
 *
 * It reuses the hardened Windows orchestrator `aks-arc-on-wsl.ps1` (bundled in
 * ./scripts) rather than reimplementing the WSL/az bring-up logic.
 *
 * Invocation (from the plugin UI):
 *   scriptjs aksarc-wsl/manage-aksarc-wsl.js <action> <base64-json-config>
 *
 *   action = up | down | status
 *
 * All stdout/stderr is streamed back to the plugin UI in real time.
 */

'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

// wsl-config.env keys we know how to serialize. Anything else in the payload
// is ignored so the UI can never inject arbitrary lines into the env file.
const KNOWN_KEYS = [
  'DISTRIBUTION',
  'CMP_SUB',
  'CMP_RG',
  'CMP_AKS',
  'CMP_CONN',
  'CMP_LOCATION',
  'EDGE_LOCATION',
  'TENANT_ID',
  'K8S_VERSION',
  'AKSARC_WHEEL_PATH',
  'ENABLE_GPU',
  'ENABLE_BMAGENT_HOTSWAP',
];

// Values are wrapped in shell single quotes when written to the env file, so
// paths with spaces/parentheses (e.g. OneDrive paths) survive `source`. We only
// reject newline/null to prevent injecting extra lines into the env file.
const FORBIDDEN_RE = /[\r\n\0]/;

/** Shell single-quote a value so it is preserved literally when sourced. */
function shSingleQuote(v) {
  return "'" + String(v).replace(/'/g, "'\\''") + "'";
}

/**
 * Convert a Windows path (C:\a\b) to its WSL drvfs form (/mnt/c/a/b) so it can
 * be handed to `az extension add --source` running inside the WSL distro.
 * Non-drive paths are returned unchanged.
 */
function winToWslPath(p) {
  const m = /^([A-Za-z]):[\\/](.*)$/.exec(p);
  if (!m) {
    return p;
  }
  return '/mnt/' + m[1].toLowerCase() + '/' + m[2].replace(/\\/g, '/');
}

/**
 * If an aksarc CLI wheel (*.whl) is bundled in scripts/, return its WSL path so
 * the setup script installs it. Returns null when none is shipped (the setup
 * script then just verifies the currently-installed az aksarc extension).
 */
function bundledWheelWslPath(scriptsDir) {
  let entries;
  try {
    entries = fs.readdirSync(scriptsDir);
  } catch {
    return null;
  }
  const whl = entries.find(f => f.toLowerCase().endsWith('.whl'));
  return whl ? winToWslPath(path.join(scriptsDir, whl)) : null;
}

function fail(msg) {
  process.stderr.write(`ERROR: ${msg}\n`);
  process.exit(1);
}

function parseConfig(b64) {
  let json;
  try {
    json = Buffer.from(b64, 'base64').toString('utf8');
  } catch (e) {
    fail(`could not base64-decode config: ${e.message}`);
  }
  let obj;
  try {
    obj = JSON.parse(json);
  } catch (e) {
    fail(`config is not valid JSON: ${e.message}`);
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
    value = String(value);
    if (FORBIDDEN_RE.test(value)) {
      fail(`value for ${key} must be a single line (no newlines)`);
    }
    lines.push(`${key}=${shSingleQuote(value)}`);
  }
  return lines.join('\n') + '\n';
}

function main() {
  const action = process.argv[2];
  const payload = process.argv[3];

  if (!action || !payload) {
    fail('usage: manage-aksarc-wsl.js <up|down|status> <base64-config>');
  }

  // Map the plugin action to the orchestrator verb + target.
  //  - up:   full idempotent bring-up (prepare = distro + systemd + boot
  //          hardening, then create = provision). Bare `up` so a fresh machine
  //          works end-to-end; re-runs are idempotent.
  //  - down: fast cluster delete, keep the WSL node for a quick re-create.
  const verbMap = {
    up: ['up'],
    down: ['down', 'cluster'],
    status: ['status'],
  };
  const verbArgs = verbMap[action];
  if (!verbArgs) {
    fail(`unknown action '${action}' (expected up | down | status)`);
  }

  if (process.platform !== 'win32') {
    fail(
      'AKS Arc on WSL is only supported on Windows (needs wsl.exe + PowerShell). ' +
        `Detected platform: ${process.platform}.`
    );
  }

  const config = parseConfig(payload);
  const scriptsDir = path.join(__dirname, 'scripts');
  const ps1 = path.join(scriptsDir, 'aks-arc-on-wsl.ps1');
  if (!fs.existsSync(ps1)) {
    fail(`orchestrator not found at ${ps1}`);
  }

  // Prefer a bundled aksarc CLI wheel (shipped in scripts/) over anything the
  // caller passed, so the UI does not need to ask for a wheel path.
  const wheel = bundledWheelWslPath(scriptsDir);
  if (wheel) {
    config.AKSARC_WHEEL_PATH = wheel;
    process.stdout.write(`>>> Using bundled aksarc CLI wheel: ${wheel}\n`);
  }

  // Write the generated wsl-config.env to a per-run temp file with locked-down
  // permissions (it can contain subscription/tenant identifiers).
  const cfgDir = fs.mkdtempSync(path.join(os.tmpdir(), 'aksarc-wsl-'));
  const cfgFile = path.join(cfgDir, 'wsl-config.env');
  fs.writeFileSync(cfgFile, serializeEnv(config), { mode: 0o600 });

  const psArgs = [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    ps1,
    ...verbArgs,
    '-ConfigFile',
    cfgFile,
  ];

  process.stdout.write(`>>> Running: powershell.exe ${verbArgs.join(' ')} (config: ${cfgFile})\n`);

  const child = spawn('powershell.exe', psArgs, {
    windowsHide: true,
    // stdout/stderr are piped so we can forward them to the plugin UI stream.
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  child.stdout.on('data', d => process.stdout.write(d));
  child.stderr.on('data', d => process.stderr.write(d));

  child.on('error', err => {
    process.stderr.write(`ERROR: failed to launch PowerShell: ${err.message}\n`);
    cleanup(cfgDir);
    process.exit(1);
  });

  child.on('exit', code => {
    cleanup(cfgDir);
    process.exit(code === null ? 1 : code);
  });
}

function cleanup(dir) {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch {
    /* best-effort temp cleanup */
  }
}

main();
