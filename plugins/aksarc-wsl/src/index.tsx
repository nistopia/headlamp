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

import { Headlamp, registerAddClusterProvider, registerRoute } from '@kinvolk/headlamp-plugin/lib';
import { SectionBox } from '@kinvolk/headlamp-plugin/lib/CommonComponents';
import {
  Alert,
  Box,
  Button,
  Checkbox,
  FormControl,
  FormControlLabel,
  Grid,
  InputLabel,
  MenuItem,
  Paper,
  Select,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import React, { useEffect, useRef, useState } from 'react';

/**
 * `pluginRunCommand` is injected into this plugin's execution scope by the
 * Headlamp app loader (see frontend/src/plugin/index.ts -> getArgValues).
 * It is only available in the Headlamp desktop (Electron) app. In the web
 * build it is undefined and the create/delete actions are disabled.
 *
 * The signature mirrors frontend/src/components/App/runCommand.ts.
 */
declare const pluginRunCommand:
  | ((
      command: 'scriptjs' | 'az',
      args: string[],
      options: {}
    ) => {
      stdout: { on: (event: string, listener: (chunk: any) => void) => void };
      stderr: { on: (event: string, listener: (chunk: any) => void) => void };
      on: (event: string, listener: (code: number | null) => void) => void;
    })
  | undefined;

const SCRIPT = 'aksarc-wsl/manage-aksarc-wsl.js';

/** The configuration collected from the form. Mirrors wsl-config.env keys. */
interface AksArcWslConfig {
  DISTRIBUTION: string;
  CMP_SUB: string;
  CMP_RG: string;
  CMP_AKS: string;
  CMP_CONN: string;
  CMP_LOCATION: string;
  EDGE_LOCATION: string;
  TENANT_ID: string;
  K8S_VERSION: string;
  ENABLE_GPU: boolean;
  ENABLE_BMAGENT_HOTSWAP: boolean;
}

const DEFAULT_CONFIG: AksArcWslConfig = {
  DISTRIBUTION: 'k8s',
  CMP_SUB: '',
  CMP_RG: '',
  CMP_AKS: 'aks-cl',
  CMP_CONN: 'aks-conn-cl',
  CMP_LOCATION: 'eastus2euap',
  EDGE_LOCATION: 'eastus2euap',
  TENANT_ID: '',
  K8S_VERSION: '1.33.3-20251001',
  ENABLE_GPU: false,
  ENABLE_BMAGENT_HOTSWAP: false,
};

const STORAGE_KEY = 'aksarc-wsl-config';

/** Base64-encode a JSON payload so it survives argv without quoting issues. */
function encodePayload(obj: unknown): string {
  return btoa(unescape(encodeURIComponent(JSON.stringify(obj))));
}

/** The required fields that must be filled before create/delete is allowed. */
const REQUIRED_FIELDS: (keyof AksArcWslConfig)[] = [
  'CMP_SUB',
  'CMP_RG',
  'CMP_AKS',
  'CMP_CONN',
  'TENANT_ID',
  'K8S_VERSION',
];

function CreateAksArcOnWsl() {
  const [config, setConfig] = useState<AksArcWslConfig>(() => {
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved) {
        return { ...DEFAULT_CONFIG, ...JSON.parse(saved) };
      }
    } catch {
      /* ignore malformed saved config */
    }
    return DEFAULT_CONFIG;
  });
  const [running, setRunning] = useState(false);
  const [log, setLog] = useState('');
  const [exitCode, setExitCode] = useState<number | null | undefined>(undefined);
  const logRef = useRef<HTMLPreElement>(null);

  const isDesktop = typeof pluginRunCommand !== 'undefined';

  useEffect(() => {
    if (logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight;
    }
  }, [log]);

  const setField = (key: keyof AksArcWslConfig, value: string | boolean) => {
    setConfig(prev => {
      const next = { ...prev, [key]: value };
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      } catch {
        /* storage may be unavailable */
      }
      return next;
    });
  };

  const missing = REQUIRED_FIELDS.filter(f => !String(config[f]).trim());

  const append = (chunk: string) => setLog(prev => prev + chunk);

  /**
   * After a successful create, read the cluster's admin.conf out of the WSL
   * distro and register it with Headlamp (Headlamp.setCluster expects a
   * base64-encoded kubeconfig) so the new cluster shows up on the Home page and
   * its details are browsable — no manual "Load from KubeConfig" step.
   */
  const autoLoadCluster = () => {
    if (!pluginRunCommand) {
      return;
    }
    append('\n>>> Registering the cluster in Headlamp (reading kubeconfig)...\n');
    let kubeconfig = '';
    const proc = pluginRunCommand('scriptjs', [SCRIPT, 'kubeconfig', encodePayload(config)], {});
    proc.stdout.on('data', (d: string) => {
      kubeconfig += d;
    });
    proc.stderr.on('data', (d: string) => append(d));
    proc.on('exit', (code: number | null) => {
      if (code !== 0 || !kubeconfig.includes('apiVersion')) {
        append(
          '>>> Could not read the kubeconfig automatically. Use "Load from KubeConfig" ' +
            'with /etc/kubernetes/admin.conf from the aks-edge distro.\n'
        );
        return;
      }
      try {
        const b64 = btoa(unescape(encodeURIComponent(kubeconfig.trim())));
        Promise.resolve(Headlamp.setCluster({ kubeconfig: b64 }))
          .then(() => append('>>> Cluster registered. Open it from the Home page.\n'))
          .catch((e: any) =>
            append(`>>> Failed to register cluster in Headlamp: ${e?.message ?? e}\n`)
          );
      } catch (e: any) {
        append(`>>> Failed to encode kubeconfig: ${e?.message ?? e}\n`);
      }
    });
  };

  const run = (action: 'up' | 'down' | 'status') => {
    if (!pluginRunCommand) {
      append('ERROR: This action only works in the Headlamp desktop app.\n');
      return;
    }
    if (action !== 'status' && missing.length > 0) {
      append(`ERROR: Fill in required fields first: ${missing.join(', ')}\n`);
      return;
    }
    setRunning(true);
    setExitCode(undefined);
    setLog(`>>> aksarc-wsl: ${action} (this can take 15-30 minutes)\n`);

    const payload = encodePayload(config);
    const proc = pluginRunCommand('scriptjs', [SCRIPT, action, payload], {});
    proc.stdout.on('data', (d: string) => append(d));
    proc.stderr.on('data', (d: string) => append(d));
    proc.on('exit', (code: number | null) => {
      setExitCode(code);
      setRunning(false);
      append(`\n>>> Process exited with code ${code}\n`);
      if (action === 'up' && code === 0) {
        autoLoadCluster();
      }
    });
  };

  const fields: {
    key: keyof AksArcWslConfig;
    label: string;
    required?: boolean;
    helper?: string;
  }[] = [
    { key: 'CMP_SUB', label: 'CMP Subscription ID', required: true },
    { key: 'CMP_RG', label: 'CMP Resource Group', required: true },
    { key: 'CMP_AKS', label: 'CMP AKS cluster name', required: true },
    { key: 'CMP_CONN', label: 'CMP connected-cluster name', required: true },
    { key: 'CMP_LOCATION', label: 'CMP location' },
    { key: 'EDGE_LOCATION', label: 'Edge location' },
    { key: 'TENANT_ID', label: 'Tenant ID', required: true },
    { key: 'K8S_VERSION', label: 'Kubernetes version', required: true },
  ];

  return (
    <SectionBox title="Create AKS Arc on WSL" textAlign="left" paddingTop={2}>
      <Typography variant="body2" color="textSecondary" paragraph>
        Provision an AKS Arc (SFF/BareMetal) edge cluster using WSL2 as the edge node. This drives
        the hardened <code>aks-arc-on-wsl.ps1</code> orchestrator in a WSL distro on this machine.
        The first run also prepares the WSL node (creates the distro, enables systemd, applies boot
        hardening) before provisioning; re-runs are idempotent.
      </Typography>

      {!isDesktop && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          Running local commands requires the Headlamp <b>desktop app on Windows</b>. In the web
          build the Create / Delete actions are disabled.
        </Alert>
      )}

      <Paper variant="outlined" sx={{ p: 2, mb: 2 }}>
        <Grid container spacing={2}>
          <Grid item xs={12} sm={6}>
            <FormControl fullWidth size="small">
              <InputLabel id="distribution-label">Distribution</InputLabel>
              <Select
                labelId="distribution-label"
                label="Distribution"
                value={config.DISTRIBUTION}
                onChange={e => setField('DISTRIBUTION', e.target.value)}
                disabled={running}
              >
                <MenuItem value="k8s">k8s (kubeadm)</MenuItem>
                <MenuItem value="k3s">k3s</MenuItem>
              </Select>
            </FormControl>
          </Grid>
          {fields.map(f => (
            <Grid item xs={12} sm={6} key={f.key}>
              <TextField
                fullWidth
                size="small"
                label={f.label}
                required={f.required}
                helperText={f.helper}
                value={String(config[f.key])}
                onChange={e => setField(f.key, e.target.value)}
                error={!!f.required && !String(config[f.key]).trim()}
                disabled={running}
              />
            </Grid>
          ))}
          <Grid item xs={12} sm={6}>
            <FormControlLabel
              control={
                <Checkbox
                  checked={config.ENABLE_GPU}
                  onChange={e => setField('ENABLE_GPU', e.target.checked)}
                  disabled={running}
                />
              }
              label="Enable GPU"
            />
          </Grid>
        </Grid>

        <Stack direction="row" spacing={2} sx={{ mt: 2 }}>
          <Button
            variant="contained"
            color="primary"
            disabled={!isDesktop || running || missing.length > 0}
            onClick={() => run('up')}
          >
            Create cluster
          </Button>
          <Button
            variant="outlined"
            color="error"
            disabled={!isDesktop || running || missing.length > 0}
            onClick={() => run('down')}
          >
            Delete cluster
          </Button>
          <Button
            variant="text"
            disabled={!isDesktop || running}
            onClick={() => run('status')}
          >
            Status
          </Button>
        </Stack>
      </Paper>

      {(log || running) && (
        <Paper variant="outlined" sx={{ p: 2 }}>
          <Typography variant="subtitle2" gutterBottom>
            Output {running ? '(running...)' : exitCode === 0 ? '(success)' : ''}
          </Typography>
          <Box
            component="pre"
            ref={logRef}
            sx={{
              m: 0,
              p: 1.5,
              maxHeight: 400,
              overflow: 'auto',
              fontFamily: 'monospace',
              fontSize: '0.8rem',
              whiteSpace: 'pre-wrap',
              bgcolor: theme => (theme.palette.mode === 'dark' ? '#0d1117' : '#f6f8fa'),
              borderRadius: 1,
            }}
          >
            {log}
          </Box>
        </Paper>
      )}
    </SectionBox>
  );
}

/** Simple inline SVG icon for the Add Cluster provider card. */
function AksArcWslIcon(props: React.SVGAttributes<SVGElement>) {
  return (
    <svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor" {...props}>
      <path d="M12 2 3 6.5v11L12 22l9-4.5v-11L12 2Zm0 2.3 6 3-6 3-6-3 6-3ZM5 8.6l6 3v7l-6-3v-7Zm14 0v7l-6 3v-7l6-3Z" />
    </svg>
  );
}

registerRoute({
  path: '/aksarc-wsl',
  sidebar: null,
  useClusterURL: false,
  noAuthRequired: true,
  name: 'aksarc-wsl',
  exact: true,
  component: () => <CreateAksArcOnWsl />,
});

registerAddClusterProvider({
  title: 'AKS Arc BareMetal (connected) — WSL',
  icon: AksArcWslIcon,
  description:
    'Provision an AKS Arc (SFF/BareMetal, Azure Arc-connected) edge cluster using ' +
    'WSL2 as the edge node. Drives the hardened aks-arc-on-wsl.ps1 orchestrator on ' +
    'this machine, then registers the new cluster in Headlamp. Windows desktop app only.',
  url: '/aksarc-wsl',
});
