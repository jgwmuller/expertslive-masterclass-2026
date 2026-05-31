# Lab 2A: Sub-second AKS blue/green failover with Application Gateway for Containers

In this lab you'll deploy a real AKS cluster fronted by **Application Gateway for
Containers (AGC)**, run a weighted blue/green app behind it, and then kill the
active backend live while a traffic hammer is running. You'll watch traffic swing
to the standby in **under a second with zero dropped requests** — and you'll
understand *why* that's possible.

## What you'll learn

The old way to put Application Gateway in front of AKS was **AGIC** (the
Application Gateway Ingress Controller) driving a classic Application Gateway v2.
On a pod rollout or failure, AGIC reprogrammed the gateway in **30–60 seconds** —
long enough to drop requests on every deploy.

**Application Gateway for Containers (AGC)** changes the data path. Its managed
data plane sends traffic **straight to pod IPs** — not to the Kubernetes Service
ClusterIP — and it reprograms on endpoint changes in **under a second**. The
result is failover with **zero dropped requests**: blue/green and canary become a
weight on an `HTTPRoute`, not an outage.

There's a second lesson baked into how this lab is built: in **Managed-by-ALB**
mode the Azure gateway is **created from inside Kubernetes** by the ALB
controller. You don't `az network ... create` the gateway — you `kubectl apply`
an `ApplicationLoadBalancer` custom resource, and the controller provisions the
real Azure AGC for you. That's why this lab is "Bicep + a wrapper script" rather
than pure Bicep (more on that in [How it works under the hood](#how-it-works-under-the-hood)).

The lab uses a weighted `HTTPRoute`: the active service at `weight: 999` and a
hot standby at `weight: 1`. With a request hammer running, you scale the active
deployment to zero and watch AGC reconverge instantly.

## Architecture / topology

```
                         AKS cluster (Azure CNI Overlay)
   ┌───────────────────────────────────────────────────────────────────┐
   │                                                                     │
   │   ns: alb-test-infra            ns: test-infra                      │
   │   ┌────────────────┐            ┌──────────────────────────────┐    │
   │   │ ApplicationLB  │            │ Gateway gateway-01 (HTTP :80) │    │
   │   │  "alb-test"    │◄──────────►│   └─ HTTPRoute blue-green     │    │
   │   │ (Managed mode) │  programs  │        ├─ backend-v1  w=999 ──┼──► BLUE  pods
   │   └───────┬────────┘            │        └─ backend-v2  w=1   ──┼──► GREEN pods
   │           │ association                                        │    │
   └───────────┼─────────────────────────────────────────────────────────┘
               │ delegated subnet  (Microsoft.ServiceNetworking/trafficControllers)
               ▼
   Azure AGC data plane  ◄────────  client / hammer.sh   ──►  *.alb.azure.com (public FE)
   (2+ instances, managed)                                       sends to POD IPs directly
```

The ALB controller (running in `azure-alb-system`) sees the
`ApplicationLoadBalancer` custom resource and provisions the real Azure AGC
(`Microsoft.ServiceNetworking/trafficControllers`) for you — that's
**Managed-by-ALB** mode. See `agc-blue-green-convergence-diagram.svg` for the
slide-ready version.

## Prerequisites

- **Azure CLI (`az`)**, logged in (`az login`) to a subscription you can deploy
  into. You need rights to create an AKS cluster, a managed identity, and
  **role assignments** — i.e. **Owner** or **User Access Administrator** on the
  subscription/RG. The deploy script assigns the ALB controller three built-in
  roles, which requires this.
- **`kubectl`** and **`helm` 3** on your `PATH`. `az aks install-cli` gets you
  `kubectl`.
- **`envsubst`** (ships with GNU `gettext`) — used by `deploy.sh` to substitute
  the delegated-subnet ID into the AGC manifest.
- A region where **AGC is available**. The scripts default to `northeurope`.
  Check the supported list before changing it:
  <https://learn.microsoft.com/azure/application-gateway/for-containers/overview#supported-regions>

> **macOS users:** stock macOS ships neither `helm` nor GNU `envsubst`. Install
> them first:
>
> ```bash
> brew install helm gettext
> ```
>
> `deploy.sh` halts with a clear error if either is missing. (If you prefer
> PowerShell 7, `deploy.ps1` does the manifest substitution natively and does
> **not** need `envsubst` — but it still needs `az`, `kubectl`, and `helm`.)

## Cost — read this first

**AKS is the cost driver here, not AGC.** Approximate pay-as-you-go while the lab
is up:

| Resource | Qty | Rough cost |
|---|---|---|
| AKS nodes (Standard_D2s_v3) | 2 | ~$0.10 / hr each |
| AKS control plane (Free tier) | 1 | $0 |
| Application Gateway for Containers | 1 | ~$0.03 / hr + per-capacity-unit + data |
| Managed identity, VNet, public FE | — | negligible |

A single demo session is **well under a dollar**, but AKS keeps billing until you
delete it — run `cleanup.sh` when you're done. To trim node cost further, deploy
with a cheaper VM size via the `AKS_NAME`/Bicep parameters or by editing the node
SKU in `main.bicep`.

> **If you also run the APIM AI-gateway continuation** (the `apim/` sub-module):
> the **APIM Developer SKU is pricey and slow** — it takes **~30–45 minutes** to
> provision, longer than the rest of the module. That's why the parallel wrapper
> exists (see below). Note also that an APIM Developer-SKU instance is
> **non-deletable for ~30–45 minutes after create**, so its resource-group delete
> will block until that window lifts. See [`apim/README.md`](apim/README.md).

## Deploy

This lab ships **both** a Bash variant (`deploy.sh`, for macOS/Linux) and a
**PowerShell 7** variant (`deploy.ps1`, for Windows). They do the same thing and
take the same settings — expand the section for your shell throughout. (The
PowerShell path needs no `envsubst`; it does the manifest substitution natively.)

First-time prep:

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

Make the scripts executable once:

```bash
chmod +x deploy-both.sh deploy.sh cleanup.sh scripts/*.sh apim/*.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

No `chmod` needed. Just confirm you're on PowerShell 7+ (the scripts declare
`#Requires -Version 7.0`):

```powershell
$PSVersionTable.PSVersion
```
</details>

### Option A — AGC only

If you just want the blue/green failover lesson (no APIM AI-gateway module):

<details open>
<summary><b>Bash</b></summary>

```bash
./deploy.sh
```
</details>

<details>
<summary><b>PowerShell 7</b></summary>

```powershell
./deploy.ps1
```
</details>

Total time is roughly **12–18 min** — most of it is AKS creation (~5–8 min) and
the AGC reaching `Programmed` (~5–6 min). The script waits for each stage and
finally prints the **AGC frontend FQDN** plus the two commands you'll run to see
the failover.

### Option B — AGC **and** APIM in parallel

If you're also doing the APIM AI-gateway continuation, use the parallel wrapper.
The **APIM Developer SKU takes ~30–45 min by itself**, so it must start at **t=0**
or you'll never finish in a typical workshop slot. This wrapper fires both
deploys at once:

<details open>
<summary><b>Bash</b></summary>

```bash
./deploy-both.sh
```
</details>

<details>
<summary><b>PowerShell 7</b></summary>

```powershell
./deploy-both.ps1
```
</details>

It runs the AGC deploy (`deploy.sh` / `deploy.ps1`) and the APIM deploy
(`apim/deploy-apim.sh` / `.ps1`) in parallel, logging each to a temp file
(`/tmp/agc-deploy-*.log` on Bash; your `$TEMP` folder on PowerShell), prints
periodic status every 30s, and returns when both finish. AGC takes ~12–18 min;
APIM takes ~30–45 min. By the time APIM is ready you'll already have done the AGC
failover.

### Environment-variable overrides

Every setting has a sensible default. In **Bash** you set them as environment
variables; in **PowerShell** you can use the same environment variables *or* the
named `-Parameter` shown below. `deploy-both` (`.sh` / `.ps1`) passes overrides
through to both child deploys.

| Env var (Bash) | PowerShell param | Default | Purpose |
|---|---|---|---|
| `RG` | `-Rg` | `rg-agc-convergence-lab` | Resource group for the AGC lab. |
| `LOCATION` | `-Location` | `northeurope` | Region — **must be AGC-supported**. |
| `AKS_NAME` | `-AksName` | `aks-agc-lab` | AKS cluster name. |
| `ALB_IDENTITY_NAME` | `-AlbIdentityName` | `azure-alb-identity` | Managed identity for the ALB controller. |
| `ALB_SUBNET_NAME` | `-AlbSubnetName` | `subnet-alb` | Name of the delegated subnet created for AGC. |
| `ALB_SUBNET_PREFIX` | `-AlbSubnetPrefix` | `10.225.0.0/24` | Delegated-subnet CIDR. Must fit inside the AKS-managed VNet (`10.224.0.0/12`) and stay clear of the node subnet (`10.224.0.0/16`). |
| `ALB_CONTROLLER_VERSION` | `-AlbControllerVersion` | `1.10.28` | ALB controller Helm chart version. |
| `HELM_NAMESPACE` | `-HelmNamespace` | `azure-alb-system` | Namespace the controller is installed into. |

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
# Use a region closer to you (must support AGC):
LOCATION=westeurope ./deploy.sh

# Same, with the parallel wrapper:
LOCATION=westeurope ./deploy-both.sh

# Change the delegated-subnet prefix:
ALB_SUBNET_PREFIX=10.226.0.0/24 ./deploy.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
# Use a region closer to you (must support AGC):
./deploy.ps1 -Location westeurope

# Same, with the parallel wrapper:
./deploy-both.ps1 -Location westeurope

# Change the delegated-subnet prefix:
./deploy.ps1 -AlbSubnetPrefix 10.226.0.0/24

# The env-var form works too — and on deploy-both.ps1 it's the only way to
# override anything other than -Location (the child scripts inherit the env):
$env:ALB_SUBNET_PREFIX='10.226.0.0/24'; ./deploy-both.ps1
```
</details>

> If `ALB_SUBNET_PREFIX` falls outside the AKS-managed VNet's address space,
> both `deploy.sh` and `deploy.ps1` fail up front with a clear instruction rather
> than a cryptic ARM error mid-deploy.

## What you'll see — run the failover yourself

You'll need **two terminals**. Both can be on your own laptop — the AGC frontend
is a public `*.alb.azure.com` FQDN. The FQDN is printed at the end of the deploy
output (and you can re-fetch it with
`kubectl get gateway gateway-01 -n test-infra -o jsonpath='{.status.addresses[0].value}'`).

> The two demo drivers (`scripts/hammer.sh`, `scripts/kill-active.sh`) are Bash
> only — there's no PowerShell variant. On Windows, run them from **WSL** or
> **Git Bash** (the `deploy.ps1` output reminds you of this). Everything else in
> this section is `kubectl`, which is identical on every shell.

**Terminal A — start the traffic hammer:**

```bash
scripts/hammer.sh <AGC_FQDN>
```

`hammer.sh` fires a request every ~0.1s (override with `INTERVAL=0.05` to hammer
harder) and shows a live tally. Each request uses a short timeout, so a real
outage would immediately show up as `FAIL`:

```
 total=842   OK=842   FAIL=0   | BLUE=841   GREEN=1   | last=BLUE
```

With weights 999:1, ~99.9% of traffic hits **BLUE** (`backend-v1`) and the
occasional request warms **GREEN** (`backend-v2`, the standby).

**Terminal B — kill the active backend, live:**

```bash
scripts/kill-active.sh
```

This scales `backend-v1` (BLUE) to zero replicas, ripping every BLUE endpoint out
from under AGC. Flip back to Terminal A and watch:

```
 total=1190  OK=1190  FAIL=0   | BLUE=903   GREEN=287  | last=GREEN
```

**The result.** The instant BLUE's pods disappear, the **BLUE counter freezes**,
**GREEN takes off**, and **FAIL never leaves 0**. AGC noticed the endpoints vanish
and reprogrammed its data plane in well under a second — no dropped requests, no
502s, no rollout window. That's the whole point of the lab.

Press `Ctrl-C` in Terminal A to stop the hammer and print a final tally (the
`FAIL` line is the number that should still read 0).

**Reset and run it again** as many times as you like:

```bash
kubectl scale deploy/backend-v1 -n test-infra --replicas=2
```

## Cleanup

AKS keeps billing until you delete it, so tear the lab down when you're finished:

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
RG=rg-agc-convergence-lab ./cleanup.sh      # prompts for confirmation
# or, scripted (no prompt):
CONFIRM=1 ./cleanup.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./cleanup.ps1                   # prompts for confirmation
./cleanup.ps1 -Confirm1 1       # scripted (no prompt)
# env-var form also works:
$env:CONFIRM='1'; ./cleanup.ps1
```
</details>

Deleting the resource group removes the AKS cluster, the managed identity, and —
via the AKS **node** resource group, which AKS deletes with the cluster — the AGC
and its association in one shot. The delete runs in the background (`--no-wait`).

If you ran the APIM module too, tear it down separately — `./apim/cleanup-apim.sh`
(Bash) or `./apim/cleanup-apim.ps1` (PowerShell). Remember the APIM Developer-SKU
instance is non-deletable for ~30–45 min after create, so that delete may block
until the window lifts.

## How it works under the hood

This lab is split into declarative Bicep plus an imperative wrapper, for a real
reason: **AGC Managed mode can't be fully expressed in ARM**. The Azure gateway
is created *from inside Kubernetes* by the ALB controller, so responsibilities
split like this:

- **`main.bicep`** — the declarative infrastructure: the AKS cluster
  (**Azure CNI Overlay**, OIDC issuer + Workload Identity), the ALB controller's
  **managed identity**, and the **federated credential** that links the
  identity to the controller's Kubernetes service account.
- **`deploy.sh`** — the imperative steps Microsoft's quickstart requires, in
  order:
  1. Register providers (`Microsoft.ContainerService`, `Microsoft.Network`,
     `Microsoft.NetworkFunction`, `Microsoft.ServiceNetworking`) and add the
     `alb` CLI extension.
  2. Deploy `main.bicep`.
  3. Find the **AKS-managed VNet** and carve a **delegated subnet** for AGC
     (delegation: `Microsoft.ServiceNetworking/trafficControllers`).
  4. Assign the controller identity its **three roles**: *Reader* and
     *AppGw for Containers Configuration Manager* on the node resource group,
     and *Network Contributor* on the delegated subnet. (These are retried,
     because a freshly created identity takes a moment to replicate.)
  5. `helm install` the **ALB controller** and wait for the
     `azure-alb-external` GatewayClass to be `Accepted`.
  6. `kubectl apply` the Gateway API objects and wait for each to be
     `Programmed`.

The Kubernetes objects applied are:

| File | What it creates |
|---|---|
| `k8s/00-alb.yaml` | `ApplicationLoadBalancer` (Managed mode) — this is what makes the controller provision the real Azure AGC. |
| `k8s/10-app-bluegreen.yaml` | Blue (`backend-v1`) and green (`backend-v2`) deployments + services. |
| `k8s/20-gateway.yaml` | `Gateway` bound to the AGC via the `azure-alb-external` GatewayClass. |
| `k8s/30-httproute.yaml` | Weighted `HTTPRoute` — `backend-v1` w=999, `backend-v2` w=1. |

The key data-path fact: AGC load-balances across **pod IPs** directly. When you
scale BLUE to zero, the controller sees the endpoints vanish and reprograms the
managed AGC data plane sub-second — that reconvergence, not any kube-proxy/Service
failover, is what you're watching in the hammer.

## Troubleshooting / FAQ

**Q: Is this just kube-proxy / Service failover?**
A: No. AGC bypasses the Service ClusterIP and load-balances across **pod IPs**
itself. The reconvergence you watch is the AGC data plane reprogramming, not
iptables/IPVS.

**Q: Would AGIC really have dropped requests here?**
A: Yes — classic Application Gateway reprogramming on backend-pool changes is the
documented 30–60s pain point AGC was built to fix. That's the whole reason AGC
sends to pod IPs.

**Q: Azure CNI Overlay — isn't there an encapsulation tax?**
A: No. Overlay pods get a non-VNet `podCidr`, but Azure SDN forwards to them
**unencapsulated** — clean L3, still visible in VNet Flow Logs. This lab uses
Overlay precisely because AGC supports it.

**Q: Why is the frontend public-only?**
A: AGC's GatewayClass here is `azure-alb-external`; public frontends are the only
option today.

**Q: The deploy printed `<pending — re-check in a minute>` instead of an FQDN.**
A: The Gateway listener hadn't finished programming yet. Re-fetch it with:
```bash
kubectl get gateway gateway-01 -n test-infra -o jsonpath='{.status.addresses[0].value}'
# or inspect the full status:
kubectl get gateway gateway-01 -n test-infra -o yaml
```

**Q: A role assignment failed during deploy.**
A: You likely lack **Owner** / **User Access Administrator** on the scope, or the
managed identity hadn't replicated yet. The script already retries six times at
15s intervals for replication delay; if it still fails, check your RBAC rights.

**Q: `ALB_SUBNET_PREFIX is not inside the AKS-managed VNet` error.**
A: Pick a `/24` inside the managed VNet's address space (default
`10.224.0.0/12`) and clear of the node subnet, e.g.
`ALB_SUBNET_PREFIX=10.226.0.0/24 ./deploy.sh`.

## What's next: the APIM AI-gateway module

Track A continues with an **APIM AI-gateway module** that fronts Azure OpenAI
**privately** and demonstrates the four GenAI-gateway controls (token
rate-limiting, semantic caching, weighted load-balancing, circuit breaker). It
runs as its own setup in its own resource group. If you're doing both, start it
in parallel with `./deploy-both.sh` (above) so the slow APIM provisioning
overlaps the AGC lab.

➡️ See **[`apim/README.md`](apim/README.md)** for the full module.


## Further reading

- Microsoft Learn — [Deploy ALB Controller (Helm)](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-helm)
- Microsoft Learn — [Create AGC managed by ALB Controller](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-create-application-gateway-for-containers-managed-by-alb-controller)
- Microsoft Learn — [Traffic splitting with AGC (Gateway API)](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/how-to-traffic-splitting-gateway-api)
</content>
</invoke>

result
The file /Users/mark-s/Repos/ExpertsLive/azure-networking-ai-labs/labs/agc-blue-green-convergence/SPEAKER.md does not exist. Did you find this file path in the agc-blue-green-convergence directory? Wait — I need to verify this is correct.
The file /Users/mark-s/Repos/ExpertsLive/azure-networking-ai-labs/labs/agc-blue-green-convergence/README.md has been overwritten successfully.
(Note: the system reminder about SPEAKER.md is informational — that file will be created next.)
