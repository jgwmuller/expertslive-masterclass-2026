# APIM as an AI gateway (Track A — continues the AGC lab)

In this module you'll put **Azure API Management in front of Azure OpenAI, privately**,
and apply the four GenAI-gateway controls that turn a raw model endpoint into a governed,
resilient AI platform: **token rate-limiting, semantic caching, weighted load-balancing,
and a circuit breaker**. It's the second half of Track A: you've already seen
Application Gateway for Containers reconverge sub-second on AKS with zero dropped requests,
and you'll now see the same resilience idea applied to the AI egress. Deploy it yourself,
fire real requests at it, and watch each policy change the behaviour.

---

## What you'll learn

This module teaches two foundational AI-networking patterns.

**Pattern 1 — reach Azure OpenAI only over a Private Endpoint.** The OpenAI accounts have
`publicNetworkAccess = Disabled`. The only way to reach them is a **Private Endpoint (PE)**,
and the only reason their hostnames resolve at all is the `privatelink.openai.azure.com`
private DNS zone linked to the VNet. The first thing you'll verify is that
`<account>.openai.azure.com` resolves to a **private** IP — the same private-DNS lesson from
the Private Link lab, now applied to AI. The gateway-to-model leg never touches the public
internet.

**Pattern 2 — APIM as the AI gateway.** A bare OpenAI endpoint gives you no spend control,
no cross-region resilience, and a single key every client holds. Putting APIM in front turns
the model into a **governed product**, and you'll prove four controls one at a time:

- **Token rate-limiting.** `azure-openai-token-limit` meters the *actual* tokens the model
  reports and caps them per consumer. Request-count rate limiting can't do this — one fat
  prompt outspends a hundred small ones, and tokens are what you actually pay for.
- **Semantic caching.** Most "new" prompts are reworded old ones.
  `azure-openai-semantic-cache-lookup`/`-store` answers a paraphrased repeat from cache for
  ~0 tokens and single-digit-millisecond latency — a *semantic* hit, not an exact string match.
- **Weighted load-balancing.** One deployment has finite tokens-per-minute (TPM). A backend
  **pool** spreads traffic across two OpenAI accounts in two regions (weighted 50/50), and
  the emitted token metric (dimensioned by `Backend ID`) lets you watch the split.
- **Circuit breaker.** 429s happen. A per-backend circuit breaker trips a throttled account
  out of rotation for a cooldown and serves 100% from the healthy one — no client-visible
  failures. It's the AI-gateway echo of the AGC zero-drop reveal.

---

## Architecture / topology

```
   Resource group: rg-apim-ai-gw-lab

   ┌──────────────────────────── vnet-apim-ai (10.226.0.0/24) ───────────────────────────┐
   │                                                                                       │
   │   snet-pe (10.226.0.0/26)                       snet-apim (10.226.0.64/26)            │
   │   ┌───────────────────────────────┐             (reserved: optional APIM VNet         │
   │   │ PE -> OpenAI primary  (region A)│              integration / future PEs)           │
   │   │ PE -> OpenAI secondary(region B)│                                                  │
   │   └──────────────┬────────────────┘                                                   │
   │                  │ A-records in privatelink.openai.azure.com (linked to this VNet)     │
   └──────────────────┼────────────────────────────────────────────────────────────────────┘
                      │  (optional) VNet peering ──────►  AKS-managed VNet (the AGC lab)
                      ▼
   APIM (Developer SKU)  ──set-backend-service──►  POOL "openai-pool"  ──►  openai-primary  (region A)
   *.azure-api.net/openai     weighted 50/50 + circuit breaker on 429  └──►  openai-secondary(region B)
        ▲
        │  caller (curl / inference pod) with subscription key
```

APIM resolves `*.openai.azure.com` through the linked private zone to the PE IPs, so the
gateway-to-model leg stays private. See the parent lab's
`agc-blue-green-convergence-diagram.svg` for the AKS+AGC half of Track A.

### Networking choice (and what to VERIFY-IN-TEST)

The Developer-SKU APIM here is **not VNet-injected** — it stays on its public control plane
(simplest, fastest) and reaches OpenAI **outbound** via the PEs + private DNS. A small
dedicated VNet holds the PEs; it is peerable to the AKS-managed VNet (`PeerAksVnet 1` /
`PEER_AKS_VNET=1`) for the optional inference-pod stretch goal.

> **VERIFY-IN-TEST — the one thing to confirm live:** that APIM's *outbound* name resolution
> returns the PE private IP for `*.openai.azure.com`. It should, because the private zone is
> linked in-tenant. If APIM instead resolves to a public IP (and is then blocked by
> `publicNetworkAccess = Disabled`), switch APIM to VNet integration on `snet-apim`. This is
> called out in `main.bicep` on the backend resources.

---

## Prerequisites

- **The AKS+AGC lab deployed** (the parent `../` lab) — or at least its resource group name
  handy (`rg-agc-convergence-lab` by default) if you want the optional VNet peering.
- **Azure CLI (`az`) logged in** (`az login`), with rights to create APIM, Cognitive Services
  accounts, Private Endpoints, and **role assignments** (Owner or User Access Administrator —
  the deploy grants the APIM managed identity *Cognitive Services OpenAI User* on both accounts).
- **Model capacity in BOTH chosen regions.** VERIFY-IN-TEST: model + version availability is
  region-specific — confirm your `ModelName` / `ModelVersion` (e.g. `gpt-4o-mini`) exists in
  **both** `OpenAiPrimaryLocation` and `OpenAiSecondaryLocation` before you run.
- **PowerShell 7** if you're on Windows (the `.ps1` scripts require it).

---

## Cost — read this first

APIM Developer is the cost floor here, and it's cheap; OpenAI spend is per token (a demo is
pennies). Approximate pay-as-you-go while the module is up:

| Resource | Qty | Rough cost |
|---|---|---|
| API Management (Developer SKU) | 1 | ~$0.07 / hr |
| Azure OpenAI (PAYG) | 2 | per-token only; demo = pennies |
| Private Endpoints | 2 | ~$0.01 / hr each + data |
| Private DNS zone, VNet, peering | — | negligible |
| (optional) Redis Enterprise for semantic cache | 1 | **not cheap** — only spin up for the cache demo, tear down after |

The whole module is **well under a dollar/hr** — *unless* you add **Redis Enterprise** for the
semantic-cache demo. That is the one meaningful add: bring it up only for that segment and
delete it after.

---

## Deploy

APIM Developer SKU takes **~30–45 minutes** to provision — longer than the rest of this module
combined. So the deploy script fires the APIM Bicep **async first** (`--no-wait`), then builds
the fast pieces (OpenAI accounts + PEs + DNS) while APIM bakes, and only waits for APIM near
the end. **Start this at t=0**, right after you kick off the parent `../deploy.*` build, so APIM
is ready by the time you've finished the AGC blue/green work.

The script walks **7 steps** and **waits at Step 5** for APIM. Steps 1–4 (resource group,
async Bicep launch, OpenAI + PE creation, the private-DNS check, optional peering) complete in
a few minutes; Step 5 is the long poll for APIM; Steps 6–7 grant the managed identity,
IP-allowlist APIM's outbound IPs on the OpenAI accounts, import the OpenAI OpenAPI spec, create
a demo subscription key, and print the policy runbook.

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
cd labs/agc-blue-green-convergence/apim
chmod +x deploy-apim.sh cleanup-apim.sh

# Start this RIGHT AFTER you kick off ../deploy.sh, so APIM bakes in parallel.
./deploy-apim.sh

# Override anything via env vars:
LOCATION=westeurope OPENAI_SECONDARY_LOCATION=francecentral ./deploy-apim.sh

# Peer the APIM VNet to the AKS lab VNet (for the inference-pod stretch):
PEER_AKS_VNET=1 AKS_RG=rg-agc-convergence-lab ./deploy-apim.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
cd labs/agc-blue-green-convergence/apim

# Start this RIGHT AFTER you kick off ../deploy.ps1, so APIM bakes in parallel.
./deploy-apim.ps1

# Override anything via named params:
./deploy-apim.ps1 -Location westeurope -OpenAiSecondaryLocation francecentral

# Peer the APIM VNet to the AKS lab VNet (for the inference-pod stretch):
./deploy-apim.ps1 -PeerAksVnet 1 -AksRg rg-agc-convergence-lab
```
</details>

### Configuration overrides

Every setting is an environment variable (Bash) or a named parameter (PowerShell) with a
sensible default:

| Env var (Bash) | PowerShell param | Default | What it controls |
|---|---|---|---|
| `RG` | `-Rg` | `rg-apim-ai-gw-lab` | Resource group for this module |
| `LOCATION` | `-Location` | `northeurope` | Region for the RG / APIM / VNet |
| `OPENAI_PRIMARY_LOCATION` | `-OpenAiPrimaryLocation` | `swedencentral` | Region A OpenAI account |
| `OPENAI_SECONDARY_LOCATION` | `-OpenAiSecondaryLocation` | `eastus2` | Region B OpenAI account |
| `PUBLISHER_EMAIL` | `-PublisherEmail` | `admin@contoso.com` | APIM publisher email |
| `PUBLISHER_NAME` | `-PublisherName` | `Experts Live Masterclass` | APIM publisher name |
| `MODEL_NAME` | `-ModelName` | `gpt-4o` | Model deployed in both regions |
| `MODEL_VERSION` | `-ModelVersion` | `2024-11-20` | Model version (region-specific!) |
| `PEER_AKS_VNET` | `-PeerAksVnet` | `0` | `1` = peer the APIM VNet to the AKS VNet |
| `AKS_RG` | `-AksRg` | `rg-agc-convergence-lab` | The parent AGC lab's resource group |
| `AKS_NAME` | `-AksName` | `aks-agc-lab` | The parent AGC lab's AKS cluster |
| `OPENAI_API_VERSION` | `-OpenAiApiVersion` | `2024-10-21` | OpenAI data-plane API version (spec import + smoke test) |

When the deploy finishes it prints the **APIM name**, **gateway URL**, both **OpenAI account
names**, the **model deployment name**, and a **demo subscription key** (`ai-gw-demo`), plus a
ready-to-paste smoke-test `curl` and the four policy-apply commands.

---

## What you'll see — run it yourself

### 0) Baseline — the private-DNS check (Step 3 of the deploy)

Before any policy, prove the network. From a host that can see the private zone (the AKS
cluster if you peered, or anywhere with access to the linked VNet — the deploy prints the
manual command):

```bash
nslookup <openai-primary-name>.openai.azure.com
# Answer in 10.226.0.x — the Private Endpoint. NOT a public IP.
```

Then smoke-test the gateway with the printed `curl` (no policy applied yet) — you should get a
completion back through APIM, over the private leg:

```bash
curl -s "<gateway-url>/openai/deployments/<model-deployment>/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: <demo-key>" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hi in 3 words"}]}'
```

> APIM's default subscription-key header on this API is `Ocp-Apim-Subscription-Key`. The native
> Azure OpenAI SDK uses `api-key` — add `api-key` as a subscription header in the Portal if you
> want SDK code to work unchanged.

Now apply the four policies **one at a time** and observe each. The `az apim api policy create`
commands are identical regardless of which shell you deployed from, so they're shown as plain
shell-agnostic blocks below. (Re-run the command after editing an XML file to push your changes.)

### 1) Token rate-limit

```sh
az apim api policy create -g rg-apim-ai-gw-lab --service-name <apim> \
  --api-id azure-openai --xml-path policies/token-rate-limit.xml
```

**Do this:** fire several chat calls in a row.
**Observe:** the `tokens-per-minute` cap (set in the file — tune it) trips, and the next call
returns **HTTP 429** with a `Retry-After`. The `x-remaining-tokens` / `x-consumed-tokens`
response headers show the meter draining. This caps the tokens you actually pay for, per
consumer — something request-count limiting can't do.

### 2) Semantic cache

```sh
az apim api policy create -g rg-apim-ai-gw-lab --service-name <apim> \
  --api-id azure-openai --xml-path policies/semantic-cache.xml
```

**Do this:** ask a question, then ask the **same question reworded**.
**Observe:** the second response returns near-instantly and the token meter barely moves — a
cache hit on *semantic* similarity, not an exact string match. At scale that's a real bill
reduction.

> **PREREQ (VERIFY-IN-TEST):** semantic cache needs an **external Redis Enterprise** cache
> (vector index) wired to APIM **and** an embeddings backend
> (`embeddings-backend-id="openai-embeddings"`). The deploy leaves these **OFF** — add them
> first (see the policy file's header) or the lookup safely no-ops and you'll see no hit. This
> is also the one cost add (see the cost table).

### 3) Weighted load-balance

```sh
az apim api policy create -g rg-apim-ai-gw-lab --service-name <apim> \
  --api-id azure-openai --xml-path policies/load-balance.xml
```

**Do this:** send a stream of calls.
**Observe:** every call now goes at the **pool**; APIM weights 50/50 across the two regional
accounts. The `azure-openai-emit-token-metric` dimension `Backend ID` lets you chart the split
moving across both backends in Application Insights.

### 4) Circuit breaker

```sh
az apim api policy create -g rg-apim-ai-gw-lab --service-name <apim> \
  --api-id azure-openai --xml-path policies/circuit-breaker.xml
```

**Do this:** **fail one backend.** The clean way is to drive its deployment past its TPM so it
returns **429** (loop the hammer); the blunt way is to disable or delete its model deployment.
**Observe:** the per-backend circuit breaker (armed in `main.bicep`) trips after a few 429s,
takes that account out of rotation for the `tripDuration`, and the pool serves **100% from the
survivor** — no client-visible failures. Same shape as the AGC reveal: there, AKS pods failed
and AGC reconverged with zero dropped requests; here an OpenAI *region* throttles and APIM
reroutes to the healthy region with zero client errors.

---

## Cleanup

Deleting the resource group removes APIM, both OpenAI accounts, the PEs, the private DNS zone,
and the VNet. The scripts then **purge** the soft-deleted APIM + OpenAI so a redeploy doesn't
collide with `ServiceAlreadyExistsInSoftDeletedState`.

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
./cleanup-apim.sh                 # prompts for confirmation
CONFIRM=1 ./cleanup-apim.sh       # no prompt (scripted)
RG=rg-apim-ai-gw-lab ./cleanup-apim.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./cleanup-apim.ps1                # prompts for confirmation
./cleanup-apim.ps1 -Confirm1 1    # no prompt (scripted)
$env:CONFIRM='1'; ./cleanup-apim.ps1
./cleanup-apim.ps1 -Rg rg-apim-ai-gw-lab
```
</details>

> **APIM Developer SKU is non-deletable for ~30–45 min after create.** If you just deployed,
> the RG delete will block on the APIM resource until that window lifts. Plan the teardown — or
> accept that the delete runs in the background (`--no-wait`) and clears once the lock expires.

---

## How it works under the hood

| File | Purpose |
|---|---|
| `main.bicep` | APIM (Developer SKU) + two Azure OpenAI accounts + two Private Endpoints + `privatelink.openai.azure.com` zone & link + APIM backends (two singles + a load-balanced pool with 429 circuit breakers) + the API shell. |
| `deploy-apim.sh` / `deploy-apim.ps1` | Fires APIM **async first**, builds OpenAI/PE/DNS while it bakes, does the private-DNS check, optional VNet peering, waits for APIM, grants the managed identity, IP-allowlists APIM's outbound IPs on the OpenAI accounts, imports the OpenAI spec, creates a demo subscription key, prints the policy runbook. |
| `cleanup-apim.sh` / `cleanup-apim.ps1` | Deletes the module's resource group, then purges the soft-deleted APIM + OpenAI (with the APIM non-deletable-window caveat). |
| `policies/token-rate-limit.xml` | `azure-openai-token-limit` + `azure-openai-emit-token-metric`. |
| `policies/semantic-cache.xml` | `azure-openai-semantic-cache-lookup` + `-store` (+ a guard rate-limit). |
| `policies/load-balance.xml` | `set-backend-service` at the weighted pool + per-backend retry + token metric by Backend ID. |
| `policies/circuit-breaker.xml` | Pool routing + clean 429/`Retry-After` handling; the breaker itself is armed on the backends in `main.bicep`. |

---

## Troubleshooting / FAQ

**Q: My smoke-test `curl` returns 401.**
**A:** You're missing the subscription key, or sending it on the wrong header. This API expects
`Ocp-Apim-Subscription-Key: <demo-key>`. The deploy prints the key; if it printed
`<create-in-portal>`, create one for the `ai-gw-demo` subscription in the Portal.

**Q: The smoke test returns a 403 / connectivity error from APIM to OpenAI.**
**A:** The OpenAI accounts default-deny public access; the deploy IP-allowlists APIM's outbound
IPs and waits 60s for the ACL to propagate. If you redeployed APIM (new IPs) or the PATCH was
skipped, re-run the deploy or add APIM's `publicIpAddresses` to each account's `networkAcls`.

**Q: I applied `semantic-cache.xml` but never get a cache hit.**
**A:** That's expected without the prereqs — semantic cache needs an external Redis Enterprise
cache **and** an embeddings backend, both **OFF** by default. The lookup safely no-ops until you
wire them up. See the policy file header.

**Q: `nslookup` returns a public IP, not 10.226.0.x.**
**A:** You're resolving from a host that can't see the linked private zone. Run it from the
peered AKS cluster (deploy with peering on) or another host on the linked VNet. If APIM *itself*
resolves to a public IP, switch APIM to VNet integration on `snet-apim`.

**Q: The deploy says it couldn't confirm both OpenAI accounts.**
**A:** Usually capacity/region — confirm your model + version exists in both regions, then check
`az deployment group show -g rg-apim-ai-gw-lab -n <name> --query properties.provisioningState`.

**Q: The RG delete is hanging.**
**A:** APIM Developer SKU is non-deletable for ~30–45 min after create. The delete runs in the
background and clears once the lock lifts.

### VERIFY-IN-TEST checklist (carried from the code comments)

- **APIM outbound DNS** resolves `*.openai.azure.com` to the PE private IP (else switch APIM to
  VNet integration on `snet-apim`).
- **Model + `ModelVersion`** available in BOTH chosen regions.
- **APIM↔AKS VNet peering** ranges don't overlap (APIM VNet is `10.226.0.0/24`, inside the AKS
  `10.224.0.0/12` space but clear of the node + ALB subnets).
- **Pool backend type + per-backend `circuitBreaker`** accepted on the API version in
  `main.bicep`; if ARM rejects them, bump to a `*-preview` version or create the pool/breakers
  via `az apim` in the deploy script.
- **Semantic cache** needs an external Redis Enterprise cache **and** an embeddings backend
  wired up — both OFF by default.
- **OpenAI inference OpenAPI spec** version/URL is current (`OpenAiApiVersion`).

---


## Sources

- Microsoft Learn — [APIM GenAI gateway capabilities](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
- Microsoft Learn — [azure-openai-token-limit policy](https://learn.microsoft.com/azure/api-management/azure-openai-token-limit-policy)
- Microsoft Learn — [azure-openai-semantic-cache-store policy](https://learn.microsoft.com/azure/api-management/azure-openai-semantic-cache-store-policy)
- Microsoft Learn — [azure-openai-emit-token-metric policy](https://learn.microsoft.com/azure/api-management/azure-openai-emit-token-metric-policy)
- Microsoft Learn — [API Management backends (pools + circuit breaker)](https://learn.microsoft.com/azure/api-management/backends)
