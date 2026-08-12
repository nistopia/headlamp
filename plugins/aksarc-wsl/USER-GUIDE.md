# AKS Arc on WSL — User Guide (deploy edition)

Create an **AKS Arc** (SFF / BareMetal edge) Kubernetes cluster that uses your
**WSL2 Ubuntu distro as the edge node** — from the Headlamp UI. This plugin uses
the **`az aksarc deploy` / `undeploy`** flow: **Create** provisions the whole
deployment; **Delete** tears down *all* of its Azure resources (not just the
cluster object).

> This guide is for **using** the plugin. For building/installing it or its
> security model, see [`README.md`](./README.md).

---

## 1. Before you start (prerequisites)

| Need | Details |
|------|---------|
| **Headlamp desktop app on Windows** | Local commands (`wsl.exe`, `az`) only run in the Electron **desktop** build. |
| **WSL2 + Ubuntu 24.04** | `wsl --install`, then an Ubuntu 24.04 distro. ARM64 (Windows on ARM) is supported. |
| **Azure sign-in** | The deploy runs `az login` inside WSL automatically (browser device-code) if you're not signed in. |
| **A resource group in `eastus`** | Public preview supports **eastus only**. Created for you if it doesn't exist. |
| **(k3s only) a private CMP** | k3s routes to a private CMP — you supply its subscription/RG/name + an `aksarc` CLI build id. |
| **(GPU only) NVIDIA driver** | For **GPU = Enable**, the Windows host needs the **NVIDIA Data Center (Tesla) DCH** driver so the GPU projects into WSL (`nvidia-smi -L` works inside WSL). |

---

## 2. Quick start (k8s)

1. Open **AKS Arc on WSL** from the Headlamp Home sidebar (or **Home → Add
   Cluster → Providers**).
2. Fill in the required fields: **Subscription ID**, **Resource group** (eastus),
   **Tenant ID**. Leave **Distribution = k8s**.
3. *(Optional)* Set **GPU = Enable** if the host has an NVIDIA GPU.
4. Click **Validate (dry-run)** to sanity-check, then **Create cluster**.
5. Approve the one-time **consent dialog** on first run. Watch the log panel;
   `az aksarc deploy` takes **~40 min**. On success the cluster is auto-loaded
   into Headlamp.

---

## 3. Form field reference

| Field | Required | Notes |
|-------|:--------:|-------|
| **Subscription ID** | ✓ | Azure subscription the edge resources deploy into. |
| **Resource group** | ✓ | Must be in **eastus**; created if missing. |
| **Tenant ID** | ✓ | Your Azure AD tenant. |
| **Region** | | Public preview: `eastus` only. |
| **Distribution** | ✓ | `k8s (public managed CMP)` or `k3s (private CMP)`. |
| **GPU** | | `Off` (default) or `Enable GPU (Kubernetes device plugin)`. **k8s only** — disabled for k3s. |
| **aksarc CLI build id** *(k3s)* | ✓ (k3s) | ADO build whose wheel has k3s/`--cmp-*` support (e.g. `174744438`). |
| **aksarc CLI wheel path** *(k3s)* | | Local `.whl` override; takes precedence over the build id. |
| **CMP subscription / resource group / name** *(k3s)* | ✓ (k3s) | The private CMP the cluster routes to. |

Values are saved locally and serialized into a temporary `deploy-config.env`
(mode `0600`) for each run.

---

## 4. Choosing k8s vs k3s

| | **k8s** | **k3s** |
|---|---|---|
| Distribution | `k8s (public managed CMP)` | `k3s (private CMP)` |
| CLI wheel | Public wheel (no ADO auth) | Pipeline wheel (build id or local `.whl`) |
| Extra fields | none | CMP sub/RG/name + build id |
| **BMAgent hot-swap** | not needed | **on by default** — the marketplace BMAgent panics on k3s NodeInit, so the deploy auto-swaps it for the unified build (`ENABLE_BMAGENT_HOTSWAP=true`). |
| Kubeconfig | `/etc/kubernetes/admin.conf` | `/etc/rancher/k3s/k3s.yaml` |

You don't set the BMAgent hot-swap in the UI — it's enabled automatically for
k3s. (To opt out, set `ENABLE_BMAGENT_HOTSWAP=false` in `deploy-config.env`.)

---

## 5. GPU workloads

Set **GPU = Enable** (k8s only). After `az aksarc deploy`, the plugin runs
`enable-gpu-wsl.sh`, which installs the NVIDIA container toolkit, wires it into
containerd, deploys the **NVIDIA device plugin**, and smoke-tests a GPU pod — so
the node advertises `nvidia.com/gpu`.

- **No-op** if there's no GPU; **fails loudly** if the driver is present but
  broken (e.g. a vGPU/GRID host driver).
- **k8s only** — the GPU dropdown is disabled for k3s (k3s embeds its own
  containerd).
- The GPU must already be usable in WSL first (`nvidia-smi -L`). If not, install
  the host NVIDIA Data Center driver and `wsl --shutdown` **before** creating.

Run a GPU workload with:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

> Want to serve an **LLM** on the GPU? See
> [§9 — Deploy an LLM with Foundry Local](#9-deploy-an-llm-with-foundry-local-optional).

---

## 6. Actions

| Button | Does |
|--------|------|
| **Validate (dry-run)** | `az aksarc deploy --validate` — checks config, creates nothing. |
| **Create cluster** | `up` = OS prep + `az aksarc deploy` (+ GPU if enabled). |
| **Delete cluster** | `down` = **`az aksarc undeploy`** (removes *all* deployed Azure resources) + disconnect the Arc machine. |
| **Status** | Distro / systemd / Arc connection / `kubectl get nodes`. |

---

## 7. Verify

Use **Status**, or from a terminal:

```bash
# k8s
wsl -d <distro> -- sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
# k3s
wsl -d <distro> -- sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes -o wide
```

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `unrecognized arguments: --distribution` on delete | Old build passed `--distribution` to `undeploy` | Fixed — pull latest and rebuild the plugin. |
| k3s node init panics / crash-loops | Marketplace BMAgent rejects k3s | BMAgent hot-swap is on by default for k3s; ensure `ENABLE_BMAGENT_HOTSWAP=true`. |
| `MissingSubscriptionRegistration` | RPs not registered | The deploy registers them; if it fails, `az provider register --namespace Microsoft.KubernetesConfiguration` (+ `Microsoft.ExtendedLocation`, `Microsoft.Kubernetes`). |
| `connection refused` to `:6443` after it worked | WSL VM idled down | `vmIdleTimeout=-1` in `%USERPROFILE%\.wslconfig`, then `wsl --shutdown` once. |
| GPU: *"nvidia-smi is present but FAILED"* | vGPU/GRID host driver (no WSL CUDA) | Install the Data Center (Tesla) **DCH** driver. |
| Delete says "could not resolve the Arc machine name … refuses to guess" | RG has resources but no Arc machine | Run `az resource list -g <rg>` and clean up manually, or `az aksarc undeploy` with an explicit `--arc-machine-names`. |

---

## 9. Deploy an LLM with Foundry Local (optional)

Once the cluster is up **with GPU enabled** (node shows `nvidia.com/gpu`), you can
serve an OpenAI-compatible LLM on the GPU with **Foundry Local**. This is a manual
follow-on — the plugin doesn't do it for you. All commands run **inside `aks-edge`
as root** (`wsl -d aks-edge -u root`), against `/etc/kubernetes/admin.conf`.

> Full reference (with rationale for every step): `docs/wsl/k8s/wsl-gpu-foundry-local.md`
> in the `Aks-Arc-Assembly` repo. Two fixes below are **required, not optional**:
> the model-store `chmod 777` and — on **multi-GPU hosts** — the SIGPIPE patch.

Let `KC=/etc/kubernetes/admin.conf` in each shell.

### 9.1 cert-manager (operator dependency)

Easiest via the Arc extension (needs your connected-cluster name + RG —
`az connectedk8s list -o table`):

```bash
az k8s-extension create --cluster-name "<ARC_CLUSTER>" --name azure-cert-manager \
  --resource-group "<RG>" --cluster-type connectedClusters \
  --extension-type Microsoft.CertManagement --scope cluster --release-train stable \
  --config config.enableGatewayAPI=true --config cert-manager.crds.keep=true \
  --config trust-manager.defaultPackage.enabled=false \
  --config trust-manager.secretTargets.enabled=true \
  --config trust-manager.secretTargets.authorizedSecretsAll=true
# first time only: az provider register --namespace Microsoft.KubernetesConfiguration
kubectl --kubeconfig $KC get pods -n cert-manager   # cert-manager, cainjector, webhook, trust-manager Running
```

### 9.2 Storage for the model-store

WSL has no CSI driver, so supply a default StorageClass + a hostPath PV:

```bash
kubectl --kubeconfig $KC apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
  annotations: { storageclass.kubernetes.io/is-default-class: "true" }
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF
sudo mkdir -p /mnt/foundry-models
kubectl --kubeconfig $KC apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata: { name: foundry-model-store-pv }
spec:
  capacity: { storage: 100Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  hostPath: { path: /mnt/foundry-models }
EOF
```

### 9.3 Foundry Local operator + REQUIRED hostPath fix

```bash
# helm if missing: curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
helm --kubeconfig $KC upgrade --install inference-operator \
  oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator \
  --version 0.260430.8 --namespace foundry-local-operator --create-namespace \
  --set entraAuth.enabled=false --set global.telemetry.enabled=false --wait --timeout 10m

# REQUIRED: hostPath ignores fsGroup, so the model-store can't write without this
sudo chmod -R 777 /mnt/foundry-models
kubectl --kubeconfig $KC rollout restart deploy/inference-operator-model-store -n foundry-local-operator
kubectl --kubeconfig $KC get pods -n foundry-local-operator   # operator, model-store, telemetry Running
```

### 9.4 Deploy a model on GPU

```bash
kubectl --kubeconfig $KC apply -f - <<'EOF'
apiVersion: foundrylocal.azure.com/v1
kind: ModelDeployment
metadata: { name: qwen-coder-gpu, namespace: foundry-local-operator }
spec:
  displayName: "Qwen2.5 Coder 0.5B (GPU)"
  model: { catalog: { name: "qwen2.5-coder-0.5b" } }
  workloadType: generative
  compute: gpu
  runtime: onnx-genai
  replicas: 1
  resources:
    requests: { cpu: "500m", memory: "2Gi" }
    limits:   { cpu: "4000m", memory: "4Gi", gpu: 1 }
EOF
```

The operator caches the model (a few min), then creates the serving Deployment.

#### ⚠️ REQUIRED on multi-GPU hosts (e.g. 2× A2) — SIGPIPE patch

The GPU image's `startup.sh` runs `nvidia-smi --query-gpu ... | head -1` under
`set -euo pipefail`; with 2+ GPUs `head` closes the pipe after line 1 → SIGPIPE →
the `inference` container crash-loops at exit 141. Patch it once the serving
Deployment exists:

```bash
DEP=qwen-coder-gpu
for i in $(seq 1 120); do kubectl --kubeconfig $KC get deploy "$DEP" -n foundry-local-operator >/dev/null 2>&1 && break; sleep 5; done
# confirm 'inference' is container 0:
kubectl --kubeconfig $KC get deploy $DEP -n foundry-local-operator -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}'
kubectl --kubeconfig $KC patch deploy $DEP -n foundry-local-operator --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/command","value":["/bin/bash","-c",
   "cp /usr/local/bin/startup.sh /tmp/s.sh && sed -i \"s/set -euo pipefail/set -eu/\" /tmp/s.sh && exec /bin/bash /tmp/s.sh"]}]'
kubectl --kubeconfig $KC rollout status deploy/$DEP -n foundry-local-operator --timeout=180s
```

> The kopf operator may revert this patch on reconcile — if the pod crash-loops
> again at 141, re-apply it. Verify the model is on the GPU:
> `POD=$(kubectl --kubeconfig $KC get pods -n foundry-local-operator --no-headers | awk '/qwen-coder-gpu/{print $1; exit}'); kubectl --kubeconfig $KC exec $POD -c inference -n foundry-local-operator -- nvidia-smi --query-gpu=name,memory.used --format=csv,noheader`
> — expect one GPU with non-zero memory in use.

### 9.5 Send a prompt

```bash
NS=foundry-local-operator; DEP=qwen-coder-gpu
API_KEY=$(kubectl --kubeconfig $KC get secret ${DEP}-api-keys -n $NS -o jsonpath='{.data.primary-key}' | base64 -d)
kubectl --kubeconfig $KC port-forward svc/${DEP} 5000:5000 -n $NS >/tmp/pf.log 2>&1 &
pf_pid=$!; sleep 3
curl -sS --insecure https://localhost:5000/v1/chat/completions \
  -H "api-key: ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-0.5b","messages":[{"role":"user","content":"Write a Python function to reverse a string."}],"max_tokens":120}' | python3 -m json.tool
kill "$pf_pid" 2>/dev/null
```

A response with `finish_reason: "stop"` and a `model` of `...-cuda-gpu:*` confirms
the full round-trip: prompt → Foundry Local → model on the GPU → OpenAI reply.

> **No GPU / CPU fallback:** deploy with `compute: cpu` + `runtime: onnx-genai`
> (model resolves the `...-generic-cpu` variant); no SIGPIPE patch needed.

---

## 10. Delete / tear down

**Delete cluster** runs `az aksarc undeploy` — the true counterpart of deploy —
which removes **all** associated Azure resources (cluster, DevicePool,
EdgeMachine, CustomLocation, LogicalNetwork, extensions), then disconnects the
Arc machine. It's idempotent and auto-retries once (an EdgeMachine can need a
second pass after the DevicePool is gone). The WSL distro is kept.

---

## 11. Where things live

| What | Where |
|------|-------|
| Runtime bridge | `manage-aksarc-wsl.js` (Node, runs on the app runtime) |
| Deploy worker | `scripts/setup-aks-arc-deploy.sh` (staged into `~/.aksarc-deploy`) |
| GPU helper | `scripts/enable-gpu-wsl.sh` (staged alongside; runs on `Enable GPU`) |
| Your config for a run | temporary `~/.aksarc-deploy/deploy-config.env` (mode `0600`) |
| Run output | the plugin's log panel |
