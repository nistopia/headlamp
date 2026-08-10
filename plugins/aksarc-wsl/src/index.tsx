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
  Grid,
  MenuItem,
  Paper,
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
  SUBSCRIPTION: string;
  RESOURCE_GROUP: string;
  TENANT_ID: string;
  LOCATION: string;
  DISTRIBUTION: string;
  CMP_SUBSCRIPTION: string;
  CMP_RESOURCE_GROUP: string;
  CMP_NAME: string;
  AKSARC_WHEEL_PATH: string;
  AKSARC_BUILD_ID: string;
  AUTH_MODE: string;
}

const DEFAULT_CONFIG: AksArcWslConfig = {
  SUBSCRIPTION: '',
  RESOURCE_GROUP: '',
  TENANT_ID: '',
  LOCATION: 'eastus',
  DISTRIBUTION: 'k8s',
  CMP_SUBSCRIPTION: '',
  CMP_RESOURCE_GROUP: '',
  CMP_NAME: '',
  AKSARC_WHEEL_PATH: '',
  AKSARC_BUILD_ID: '174772467',
  AUTH_MODE: 'browser',
};

const STORAGE_KEY = 'aksarc-wsl-deploy-config';

/** Base64-encode a JSON payload so it survives argv without quoting issues. */
function encodePayload(obj: unknown): string {
  return btoa(unescape(encodeURIComponent(JSON.stringify(obj))));
}

/** The required fields that must be filled before create/delete is allowed. */
const REQUIRED_FIELDS: (keyof AksArcWslConfig)[] = ['SUBSCRIPTION', 'RESOURCE_GROUP', 'TENANT_ID'];

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

  const isK3s = String(config.DISTRIBUTION).trim().toLowerCase() === 'k3s';
  // A local wheel override (AKSARC_WHEEL_PATH) takes precedence over the ADO build id in
  // the deploy script, so the build id is only required when no local wheel is supplied.
  const hasLocalWheel = Boolean(String(config.AKSARC_WHEEL_PATH).trim());
  const requiredFields: (keyof AksArcWslConfig)[] = isK3s
    ? [
        ...REQUIRED_FIELDS,
        'CMP_SUBSCRIPTION',
        'CMP_RESOURCE_GROUP',
        'CMP_NAME',
        ...(hasLocalWheel ? [] : (['AKSARC_BUILD_ID'] as (keyof AksArcWslConfig)[])),
      ]
    : REQUIRED_FIELDS;
  const missing = requiredFields.filter(f => !String(config[f]).trim());

  const append = (chunk: string) => setLog(prev => prev + chunk);

  /**
   * Read the cluster's admin.conf out of the WSL distro and register it with
   * Headlamp (Headlamp.setCluster expects a base64-encoded kubeconfig) so the
   * cluster shows up on the Home page and its details are browsable — no
   * manual "Load from KubeConfig" step. Run after "up" (new cluster) and also
   * after "status" (re-registers a fresh kubeconfig any time the cluster is
   * checked, so a stale/missing Home page entry self-heals without the user
   * needing to click "up" again).
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
        append(`>>> Sending kubeconfig to Headlamp.setCluster() (${kubeconfig.trim().length} chars decoded)...\n`);
        Promise.resolve(Headlamp.setCluster({ kubeconfig: b64 }))
          .then((result: any) => {
            append(
              `>>> Headlamp.setCluster() result: ${JSON.stringify(result)?.slice(0, 500)}\n`
            );
            const parsedClusters = result?.clusters;
            if (Array.isArray(parsedClusters) && parsedClusters.length > 0) {
              append(
                `>>> Cluster registered (${parsedClusters
                  .map((c: any) => c?.name)
                  .join(', ')}). Open it from the Home page.\n`
              );
            } else {
              append(
                '>>> setCluster() returned no parsed clusters — the kubeconfig may not have been ' +
                  'accepted. Try "Load from KubeConfig" manually with /etc/kubernetes/admin.conf.\n'
              );
            }
          })
          .catch((e: any) =>
            append(`>>> Failed to register cluster in Headlamp: ${e?.message ?? e}\n`)
          );
      } catch (e: any) {
        append(`>>> Failed to encode kubeconfig: ${e?.message ?? e}\n`);
      }
    });
  };

  const run = (action: 'up' | 'down' | 'status' | 'validate') => {
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
    setLog(`>>> aksarc-wsl: ${action}\n`);

    // The k3s-only fields (wheel build id / local wheel path / private CMP routing) are only
    // rendered when Distribution = k3s, but their defaults still live in `config` (and may be
    // persisted in localStorage). In the public k8s flow they must NOT be sent, otherwise a
    // stale AKSARC_BUILD_ID forces the deploy script down the internal ADO wheel path instead
    // of the public wheel URL. Strip them for k8s so the public defaults apply.
    const payloadConfig = isK3s
      ? config
      : (() => {
          const c = { ...config };
          c.AKSARC_BUILD_ID = '';
          c.AKSARC_WHEEL_PATH = '';
          c.CMP_SUBSCRIPTION = '';
          c.CMP_RESOURCE_GROUP = '';
          c.CMP_NAME = '';
          return c;
        })();

    const payload = encodePayload(payloadConfig);
    const proc = pluginRunCommand('scriptjs', [SCRIPT, action, payload], {});
    proc.stdout.on('data', (d: string) => append(d));
    proc.stderr.on('data', (d: string) => append(d));
    proc.on('exit', (code: number | null) => {
      setExitCode(code);
      setRunning(false);
      append(`\n>>> Process exited with code ${code}\n`);
      if ((action === 'up' || action === 'status') && code === 0) {
        autoLoadCluster();
      }
      if (action === 'down' && code === 0) {
        // The cluster, Arc machine, and WSL distro are all gone at this
        // point, but Headlamp's plugin API only exposes `setCluster` (add /
        // update) — there is no `deleteCluster` counterpart a plugin can
        // call, so we can't programmatically remove the now-dead entry from
        // the Home page / sidebar. Tell the user exactly where to remove it.
        append(
          '\n>>> Cluster, Arc machine, and WSL distro were fully torn down.\n' +
            '>>> Headlamp cannot remove a registered cluster entry from a plugin, so if the ' +
            'cluster still shows on the Home page, remove it there via its Settings (gear icon) ' +
            '> Delete Cluster, or it will simply show as unreachable.\n'
        );
      }
    });
  };

  const fields: {
    key: keyof AksArcWslConfig;
    label: string;
    required?: boolean;
    helper?: string;
  }[] = [
    { key: 'SUBSCRIPTION', label: 'Subscription ID', required: true },
    {
      key: 'RESOURCE_GROUP',
      label: 'Resource group (must be in eastus)',
      required: true,
      helper: 'Created if it does not exist. Public preview supports eastus only.',
    },
    { key: 'TENANT_ID', label: 'Tenant ID', required: true },
    { key: 'LOCATION', label: 'Region', helper: 'Public preview: eastus only.' },
  ];

  // Shown only when Distribution = k3s. k3s needs the pipeline-built wheel (the public
  // wheel has no --distribution/--cmp-* flags yet) and routing to a private CMP. The
  // wheel is pulled automatically from the given ADO build's drop_Build_main artifact,
  // unless a local wheel path override is supplied below.
  const k3sFields: typeof fields = [
    {
      key: 'AKSARC_BUILD_ID',
      label: 'aksarc CLI build id',
      required: !hasLocalWheel,
      helper: 'ADO build whose wheel (with k3s/--cmp-* support) is installed automatically, e.g. 174744438. Ignored when a local wheel path is set below.',
    },
    {
      key: 'AKSARC_WHEEL_PATH',
      label: 'aksarc CLI wheel path (local override, optional)',
      helper:
        'Optional. WSL-visible path to a locally built .whl — e.g. ' +
        '/mnt/c/Users/<you>/aksarc-cli/aksarc-2.0.0b6-py3-none-any.whl. When set, this ' +
        'wheel is installed instead of the build id above (takes precedence).',
    },
    { key: 'CMP_SUBSCRIPTION', label: 'CMP subscription', required: true, helper: 'Private CMP subscription id.' },
    { key: 'CMP_RESOURCE_GROUP', label: 'CMP resource group', required: true, helper: 'Private CMP resource group.' },
    {
      key: 'CMP_NAME',
      label: 'CMP name',
      required: true,
      helper: 'Private CMP cluster name (the AKS managed cluster and its Arc-connected cluster share this name).',
    },
  ];

  return (
    <SectionBox title="Create AKS Arc on WSL" textAlign="left" paddingTop={2}>
      <Typography variant="body2" color="textSecondary" paragraph>
        Provision an AKS Arc (BareMetal, Azure Arc-connected) cluster using WSL2 as the edge node,
        via the public <code>az aksarc deploy</code> flow (no dev CMP). The first run prepares the
        WSL node (distro, systemd, boot hardening), Arc-enables it, and runs <code>az aksarc deploy</code>.
        Requires a preview-enrolled subscription and an <b>eastus</b> resource group.
      </Typography>

      {!isDesktop && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          Running local commands requires the Headlamp <b>desktop app on Windows</b>. In the web
          build the Create / Delete actions are disabled.
        </Alert>
      )}

      <Paper variant="outlined" sx={{ p: 2, mb: 2 }}>
        <Grid container spacing={2}>
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
            <TextField
              select
              fullWidth
              size="small"
              label="Distribution"
              helperText={
                isK3s
                  ? 'Routes to a private CMP; installs the CLI wheel from the build below.'
                  : 'Public managed-CMP flow (no extra fields needed).'
              }
              value={config.DISTRIBUTION}
              onChange={e => setField('DISTRIBUTION', e.target.value)}
              disabled={running}
            >
              <MenuItem value="k8s">k8s (public managed CMP)</MenuItem>
              <MenuItem value="k3s">k3s (private CMP)</MenuItem>
            </TextField>
          </Grid>

          {isK3s &&
            k3sFields.map(f => (
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
        </Grid>

        <Stack direction="row" spacing={2} sx={{ mt: 2 }}>
          <Button
            variant="outlined"
            color="primary"
            disabled={!isDesktop || running || missing.length > 0}
            onClick={() => run('validate')}
          >
            Validate (dry-run)
          </Button>
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
    'Provision an AKS Arc (BareMetal, Azure Arc-connected) cluster using WSL2 as the ' +
    'edge node, via the public `az aksarc deploy` flow. Prepares the WSL node, ' +
    'Arc-enables it, deploys, then registers the cluster in Headlamp. Requires a ' +
    'preview-enrolled subscription + eastus RG. Windows desktop app only.',
  url: '/aksarc-wsl',
});
