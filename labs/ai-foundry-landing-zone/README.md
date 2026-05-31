# Lab 2B: A private AI Foundry agent landing zone

In this lab you'll stand up a fully private hub/spoke landing zone for a Microsoft
Foundry agent and prove it runs with **no public egress** — agent compute injected
into a delegated subnet, bring-your-own Storage/Search/Cosmos reached only over
private endpoints, and every outbound byte forced through an Azure Firewall you
control. You'll deploy it, get inside the VNet over Bastion, prove private DNS,
watch the missing-private-endpoint failure then fix it, run an agent end to end,
and inspect what actually leaves through the firewall — all yourself.

> **Source note:** This lab is sourced from **Microsoft Learn (verified Apr 2026)** —
> *Set up private networking for Foundry Agent Service*. The Foundry
> account/project/capability-host/network-injection resources are version-sensitive;
> the Bicep marks every such spot with `// VERIFY-IN-TEST:`.
>
> Primary source:
> <https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks>

---

## What you'll learn

A Standard private Foundry agent isn't "a model behind a private endpoint." It's a
**distributed system** — agent compute, a vector store, a thread store, a blob
store, and a model endpoint — that an enterprise must contain inside its own
network with **no public egress** and **all data in-tenant**. Getting that right is
a *networking* problem first:

1. **The agent compute is injected into a delegated subnet**
   (`Microsoft.App/environments`). That subnet is yours; one Foundry resource owns
   it exclusively. This is the single most surprising fact for people who think
   Foundry is "just an API."
2. **You bring your own data** — Storage, AI Search, Cosmos DB — and you must wire
   **exactly one connection of each** into the capability host, or it won't create.
3. **Private endpoints to your data are NOT auto-created.** Deploy Foundry and you
   get an account; you still have to create the PEs to Search/Storage/Cosmos
   yourself. Forget one and DNS may resolve while the data plane silently fails.
4. **Egress is a firewall problem, and TLS inspection breaks it.** The agent's only
   way out is the hub Azure Firewall, allow-listed to Entra ID / Container Apps
   FQDNs — and you must **not** TLS-inspect, or you break auth.

The lesson: "make it private" is not a toggle. It's five services, a delegated
subnet, a capability host, and a firewall hop — wired together so there's no public
path in or out.

---

## Architecture / topology

```
  HUB vnet (platform / connectivity)  10.10.0.0/16        SPOKE vnet (workload)  192.168.0.0/16
  ┌────────────────────────────────────────────┐         ┌────────────────────────────────────────────┐
  │ AzureFirewallSubnet 10.10.0.0/26             │         │ snet-agent  192.168.0.0/24                   │
  │   └─ Azure Firewall + Policy                 │         │   delegated → Microsoft.App/environments     │
  │        egress allowlist (AAD + ACA FQDNs)    │◄══════► │   (Standard Agent compute injected here)     │
  │        *** NO TLS INSPECTION ***             │ peering │                                              │
  │ AzureBastionSubnet 10.10.1.0/26              │         │ snet-pe    192.168.1.0/24                     │
  │   └─ Bastion                                 │         │   ├─ pe-foundry        (account)             │
  │ snet-jump 10.10.2.0/24                       │         │   ├─ pe-search         (searchService)       │
  │   └─ vm-jump (Ubuntu, no public IP)          │         │   ├─ pe-storage-blob   (blob)                │
  │        nslookup / az / agents SDK            │         │   └─ pe-cosmos-sql     (Sql)                 │
  └────────────────────────────────────────────┘         │                                              │
            │                                              │ rt-spoke-egress: 0.0.0.0/0 → AzFW private IP │
            │  all egress forced to AzFW (UDR)             └────────────────────────────────────────────┘
            ▼                                                            │
   (only allowlisted FQDNs leave; no public egress for the agent)        ▼  BYO data (public access Disabled)
                                                          Storage (blob) · AI Search · Cosmos DB (Sql)

  Private DNS (linked to BOTH vnets): privatelink.cognitiveservices.azure.com · privatelink.openai.azure.com
    · privatelink.services.ai.azure.com · privatelink.search.windows.net
    · privatelink.documents.azure.com · privatelink.blob.core.windows.net
```

See `ai-foundry-landing-zone-diagram.svg` for the slide-ready version.

---

## Verified technical facts (Microsoft Learn, Apr 2026)

These are baked into the Bicep and are the heart of the lab. All from the
*virtual-networks* how-to unless noted.

- **No public egress.** A Standard private agent has no public egress by design;
  the platform handles auth/security without trusted-service bypass.
- **Subnet delegation + size.** The agent compute is injected into a subnet
  **delegated to `Microsoft.App/environments`**. Recommended **/24** (256
  addresses), **/27 minimum** — the delegation to Azure Container Apps consumes
  addresses. **One agent subnet per Foundry resource** — it can't be shared.
- **RFC1918 only.** Both subnets must be in `10.0.0.0/8`, `172.16-31.0.0/12`, or
  `192.168.0.0/16`. CGNAT `100.64.0.0/10` is **not** supported. (This lab uses the
  documented `192.168.0.0/16` reference plan.)
- **BYO data is mandatory.** Storage **+** AI Search **+** Cosmos DB, all three,
  all in-tenant. The capability host needs **exactly one connection each** — fewer
  than three fails with *"CapabilityHost supports a single, non empty value for
  &lt;storage|vectorStore|threadStorage&gt;Connections."*
- **Six private DNS zones.** Foundry alone needs **three** (its three data-plane
  hostnames): `privatelink.cognitiveservices.azure.com`,
  `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com`. Plus
  `privatelink.search.windows.net`, `privatelink.documents.azure.com`,
  `privatelink.blob.core.windows.net`. Custom DNS? Conditional-forward each public
  zone to the Azure DNS virtual server **168.63.129.16**.
- **PEs are NOT auto-created.** Private endpoints to **AI Search, Storage, and
  Cosmos DB are not created** when you deploy Foundry — you create them yourself
  (this lab does, in `modules/privateendpoints.bicep`). This is the gotcha the demo
  makes you feel.
- **No TLS inspection on egress.** Allow-list the Container Apps managed-identity
  FQDNs **or** the `AzureActiveDirectory` service tag. **Verify no TLS inspection**
  adds a self-signed cert — it breaks auth (cert pinning).
- **Region colocation.** The **Foundry account must be in the same region as the
  VNet.** Storage/Search/Cosmos may live elsewhere (cross-region adds
  data-transfer cost; this lab colocates them).
- **Teardown order.** Delete the VNet **last**. Before deleting it, **delete AND
  purge** the Foundry resource — otherwise the `Microsoft.App/environments`
  service-association-link on the agent subnet blocks VNet deletion. `cleanup.sh` /
  `cleanup.ps1` do this in order.

---

## WAF pillar mapping

| Pillar | How this landing zone earns it |
|---|---|
| **Security** | Public access **Disabled** on Foundry + all three data resources; identity-only (`disableLocalAuth`); no public egress; single audited egress chokepoint (Azure Firewall) with an allowlist and **no TLS inspection**; private endpoints + private DNS so names resolve only inside the VNet. |
| **Reliability** | Hub/spoke isolates the platform blast radius from the workload; forced-tunnel UDR means a misconfigured spoke can't silently bypass egress control; BYO data stores are first-class resources you can back up and SLA independently. |
| **Cost** | Data resources colocated with Foundry to avoid cross-region data-transfer charges; `Standard_B2s` jump box; firewall is the cost driver (see the cost table). Cross-region BYO data is *possible* but billed — the lab calls out the trade-off. |
| **Operational excellence** | Everything is declarative Bicep modules (hub/spoke/data/foundry/dns/PE) so the environment is reproducible and reviewable; Bastion + jump box give a clean, auditable "inside the VNet" operations path; firewall logs make egress observable. |
| **Performance efficiency** | Private endpoints keep the agent's data-plane traffic on Microsoft's backbone, no public hairpin; agent compute sits in the same VNet as its data; recall from Lab 1 that **PE region ≠ latency** — colocation here is for cost/compliance, the backbone handles the path. |

---

## CAF landing-zone mapping

| CAF construct | In this lab |
|---|---|
| **Platform / connectivity hub** | `vnet-hub` — Azure Firewall (egress), Bastion (operator access). In a real tenant this is a shared, centrally-owned subscription; here it's one RG for the lab. |
| **Workload spoke** | `vnet-spoke` — the application team's network: delegated agent subnet + PE subnet, peered to the hub, default route forced to the platform firewall. |
| **Azure Policy: deny public access** | Modelled in-template by setting `publicNetworkAccess: 'Disabled'` and `networkAcls.defaultAction: 'Deny'` on Foundry, Storage, Search, and Cosmos. In a real LZ this is enforced by an **`Audit`/`Deny` policy** (e.g. *Cognitive Services accounts should disable public network access*) so drift is caught. |
| **Naming & tagging** | Consistent `vnet-hub`/`vnet-spoke`/`pe-*`/`snet-*` names + a per-deployment `suffix` for globally-unique resources. Add your org's tagging policy on top. |
| **RBAC** | Builder needs **Azure AI Account Owner** (subscription scope) + **Role Based Access Administrator** (or Owner) to assign roles on the BYO data. Each agent author needs **Azure AI User** on the project (`agents/*/read`, `agents/*/action`, `agents/*/delete`). |

---

## Prerequisites

- **Azure CLI (`az`)** logged in (`az login`) to a subscription you can deploy into,
  with **Azure AI Account Owner** at subscription scope **and** rights to assign
  roles on the BYO data resources (**Role Based Access Administrator** or **Owner**;
  key permission `Microsoft.Authorization/roleAssignments/write`).
- An **SSH key pair** for the jump VM. If `~/.ssh/id_rsa.pub` is absent the deploy
  script generates one (on Windows you need the OpenSSH Client optional feature for
  `ssh-keygen`).
- A region that offers your chosen model (`gpt-4o`) **and** the Standard private
  agent — see the [region pre-flight](#region-pre-flight). Default `swedencentral`.
- **Patience — this is the slow lab.** Azure Firewall, Bastion, and the Foundry
  capability host make deploy take **~15–25 min**. Kick it off in a coffee break.

---

## Cost — read this first

Approximate pay-as-you-go while the lab is up:

| Resource | Qty | Rough cost |
|---|---|---|
| **Azure Firewall (Standard)** | 1 | **~$1.25 / hr + data processing — cost driver** |
| **Azure AI Search (Standard)** | 1 | **~$0.34 / hr — cost driver** |
| Azure Bastion (Basic) | 1 | ~$0.19 / hr |
| Jump VM (Standard_B2s) | 1 | ~$0.04 / hr |
| Cosmos DB (serverless/provisioned, idle) | 1 | low — RU-based |
| Storage (Standard_LRS, idle) | 1 | negligible |
| Foundry account + gpt-4o | 1 | per-token; idle ≈ $0 |
| Private endpoints (4) + DNS zones (6) | — | ~$0.01/hr each PE; zones negligible |

A demo session is **a few dollars**, dominated by **Azure Firewall** and **AI
Search**. Tear it down promptly with the [cleanup](#cleanup) step — and remember the
purge-before-VNet order so it actually tears down.

---

## Deploy

This lab ships **both** a Bash variant (`deploy.sh`, macOS/Linux) and a
**PowerShell 7** variant (`deploy.ps1`, Windows). They do the same thing and take
the same settings.

First-time prep (Bash only):

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
chmod +x deploy.sh cleanup.sh scripts/*.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
# No chmod needed; the scripts declare #Requires -Version 7.0.
$PSVersionTable.PSVersion
```
</details>

Then deploy:

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
./deploy.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./deploy.ps1
```
</details>

The script checks prereqs, registers the required resource providers, runs the
region pre-flight, generates an SSH key if absent, deploys the landing zone, then
prints the exact next commands (the Bastion SSH line, the five FQDNs to look up, and
the agent run). Deploy is the slow part — Firewall, Bastion, and the capability host
take ~15–25 min.

### Region pre-flight

`deploy.sh` / `deploy.ps1` run a capacity pre-flight **before** submitting the
Bicep. Azure regional capacity for `gpt-4o` Standard SKU and AI Search "standard"
varies day-to-day; without this probe you can waste 20 minutes on a doomed deploy.
The probe walks an ordered fallback list and uses the **first region that passes**:

```
<your LOCATION>  →  westus3  →  canadacentral  →  northcentralus  →  eastus2  →  swedencentral
```

Customize the order:

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
FOUNDRY_REGIONS="eastus westus3 swedencentral" ./deploy.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./deploy.ps1 -FoundryRegions "eastus westus3 swedencentral"
# env-var form also works:
$env:FOUNDRY_REGIONS='eastus westus3 swedencentral'; ./deploy.ps1
```
</details>

Skip the pre-flight (force the chosen region, no fallback):

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
SKIP_REGION_PROBE=1 LOCATION=eastus2 ./deploy.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./deploy.ps1 -SkipRegionProbe 1 -Location eastus2
```
</details>

**What the probe doesn't catch:** Cosmos DB regional capacity (no Azure API to query
— surfaced only when account creation actually tries) and the Foundry agent
capability host's regional rollout state. Those still surface **during** the deploy.
If they hit, re-run with a different region (see [Troubleshooting](#troubleshooting--faq)).

### Configuration

Every setting has a sensible default. In **Bash** set environment variables; in
**PowerShell** use the same env vars *or* the named `-Parameter`.

| Env var (Bash) | PowerShell param | Default | Purpose |
|---|---|---|---|
| `RG` | `-Rg` | `rg-ai-foundry-lz-lab` | Resource group name. |
| `LOCATION` | `-Location` | `swedencentral` | Foundry account **and** spoke VNet region (colocated). Also the probe's first candidate. |
| `FOUNDRY_REGIONS` | `-FoundryRegions` | `<LOCATION> westus3 canadacentral northcentralus eastus2 swedencentral` | Space-separated probe/fallback list. |
| `SKIP_REGION_PROBE` | `-SkipRegionProbe` | `0` | `1` skips the probe and forces `LOCATION` (no fallback). |
| `ADMIN_USER` | `-AdminUser` | `azureuser` | Jump VM admin user. |
| `SSH_KEY` | `-SshKey` | `~/.ssh/id_rsa.pub` | Path to the SSH **public** key (generated if absent). |
| `VM_SIZE` | `-VmSize` | `Standard_B2s` | Jump VM size. |
| `MODEL_NAME` | `-ModelName` | `gpt-4o` | Model to deploy. |
| `MODEL_VERSION` | `-ModelVersion` | `2024-11-20` | Model version — `// VERIFY-IN-TEST:` pin to one your region offers. |
| `MODEL_CAPACITY` | `-ModelCapacity` | `20` | Model deployment capacity (TPM in thousands). |

---

## What you'll see — run it yourself

The deploy output prints a ready-to-paste block. Work through these beats —
**run this → observe this → here's the result.**

### 1. Get inside the VNet via Bastion

The jump box has **no public IP** — the only way in is Azure Bastion. The deploy
output prints the exact line (run it from your laptop):

```bash
az network bastion ssh \
  --name <bastion> --resource-group <rg> \
  --target-resource-id $(az vm show -g <rg> -n <jump-vm> --query id -o tsv) \
  --auth-type ssh-key --username azureuser --ssh-key ~/.ssh/id_rsa
```

**Observe:** you land a shell *inside* the hub VNet (peered to the spoke). No public
IP was ever exposed. Everything from here on runs on the jump box, inside the VNet.

### 2. Prove private DNS — inside vs. outside

`scripts/check-private-dns.sh` is a **bash script that runs on the jump box** (cloud-init
also drops a copy onto the VM). Pass it the five FQDNs from the deploy output:

```bash
# on the jump box, inside the VNet
check-private-dns.sh \
  <cognitive-fqdn> <openai-fqdn> <search-fqdn> <blob-fqdn> <cosmos-fqdn>
```

**Observe:** inside the VNet every name resolves to a **private `192.168.1.x`**
address — the private endpoints in `snet-pe`, wired by the private DNS zones. Run the
**same** lookups from your laptop (outside) and they **NXDOMAIN** or return a public
name that goes nowhere reachable (public access is Disabled, and the private
A-records only live in zones linked to the hub/spoke). That gap — private inside,
nothing outside — *is* the landing zone.

### 3. The missing-PE failure, then the fix

This is the heart of the lesson: **private endpoints are not auto-created for BYO
resources.** Manufacture the gotcha by deleting one PE (the Cosmos one is the most
instructive):

```bash
az network private-endpoint delete -g <rg> -n pe-cosmos-sql
```

Now load the **Agents** page in the Foundry project, or run an agent. It **hangs /
times out** — the docs' *"Timeout of 60000ms exceeded"* symptom — because the project
can't reach Cosmos DB to manage threads. DNS for `*.documents.azure.com` may still
resolve (the zone is there) but there's no PE behind it, and because `0.0.0.0/0` is
routed to the firewall with no public route out, the call is blackholed rather than
failing fast.

**The fix:** re-deploy (idempotent) or recreate just that PE + its DNS zone group:

```bash
./deploy.sh    # idempotent — recreates pe-cosmos-sql and its A-record
```

The dependency now resolves to a `192.168.1.x` address (step 2) and the call
completes.

### 4. Run an agent end to end, from inside the VNet

`scripts/run-agent.py` is a **Python script that runs on the jump box**, in the venv
cloud-init created at `/opt/agentvenv`. It takes the project endpoint as its one
argument; auth uses `DefaultAzureCredential`:

```bash
# on the jump box, inside the VNet
/opt/agentvenv/bin/python run-agent.py \
  "https://<foundry-account>.services.ai.azure.com/api/projects/<project>"
```

(`deploy.sh` prints the account/project names; confirm the exact project endpoint in
the Foundry portal — Project > Overview — since the path format moves with the SDK.)

**Observe:** the script prints `created agent: ...`, a `run status: ...`, the
assistant's reply, then `done — and every byte of this ran inside your VNet.` The
Foundry data-plane call resolved over a **private endpoint**, threads were stored in
your **BYO Cosmos DB**, and the model's outbound traffic exited via the **firewall
allow-list**. Run the same script from your laptop and it fails — no public path, no
private DNS.

### 5. Inspect egress on the firewall

Open the Azure Firewall logs (or its Policy analytics). The only traffic leaving is
the **allow-listed** Entra ID / Container Apps FQDNs on 443.

**Observe:** the firewall sees the **hostname (SNI/FQDN) but not the payload** — the
application rule matches on FQDN only, **with no TLS inspection** (no self-signed
cert injected). That's the exfiltration story for AI: the agent can only talk to what
you allow, you can audit every FQDN it asked for, and you never had to decrypt a
thing to enforce it.

---

## Cleanup

> **CRITICAL teardown order.** The Standard Agent leaves a
> **service-association-link (SAL)** on the delegated agent subnet
> (`Microsoft.App/environments`). While the Foundry resource exists — *including in
> its soft-deleted state* — that SAL blocks deletion of the subnet and therefore the
> spoke VNet (*"Subnet requires ... delegation(s) [Microsoft.App/environments] to
> reference service association link .../legionservicelink."*). A plain
> `az group delete` will **hang on the VNet**. The cleanup scripts do the right thing
> in three steps: **(1) delete the Foundry account** (soft delete), **(2) purge the
> soft-deleted account** (releases the SAL), then **(3) delete the resource group**.

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
RG=rg-ai-foundry-lz-lab ./cleanup.sh      # prompts for confirmation
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

The purge retries up to 6× at 15s intervals (the soft-deleted record takes a moment
to become purgeable), then the RG delete runs in the background (`--no-wait`). If a
manual RG delete ever hangs on the spoke VNet, re-run the cleanup script — step 2
(purge) is the fix.

---

## How it works under the hood

`main.bicep` orchestrates six modules + the hub↔spoke peering, then exposes the
outputs `deploy.sh` reads.

| File | What it builds |
|---|---|
| `main.bicep` | Orchestrator — wires the six modules + bidirectional hub/spoke peering + outputs (account, project, jump VM, firewall private IP, the five FQDNs). |
| `modules/hub.bicep` | Hub VNet, Azure Firewall + Policy (egress allowlist, **no TLS inspection** — SNI/FQDN match only), Bastion, jump VM. |
| `modules/spoke.bicep` | Spoke VNet: agent subnet **delegated to `Microsoft.App/environments`** + PE subnet; route table forcing `0.0.0.0/0` to the hub firewall. |
| `modules/data.bicep` | BYO Storage + AI Search + Cosmos DB, all **public access Disabled**, identity-only. |
| `modules/foundry.bicep` | Foundry account (AIServices) + project + gpt-4o + connections + capability host + **network injection**. **Version-sensitive — `VERIFY-IN-TEST`.** |
| `modules/privatedns.bicep` | The six `privatelink.*` zones, linked to **both** hub and spoke. |
| `modules/privateendpoints.bicep` | Explicit PEs for Foundry/Search/Storage/Cosmos (**not auto-created**) + DNS zone groups. |
| `cloud-init.yaml` | Bootstraps the jump VM: dnsutils, Azure CLI, a Python venv at `/opt/agentvenv` with the agents SDK; drops `check-private-dns.sh` / `run-agent.py`. |
| `deploy.sh` / `deploy.ps1` | az-CLI wrapper: prereqs, provider registration, region pre-flight, SSH key, Bicep deploy, next-step output. |
| `cleanup.sh` / `cleanup.ps1` | **Correct teardown order** — delete + purge Foundry, *then* delete the RG. `CONFIRM=1` / `-Confirm1 1` supported. |
| `scripts/check-private-dns.sh` | On-jump-box DNS reveal (private `192.168.1.x` inside vs. public/NXDOMAIN outside). |
| `scripts/run-agent.py` | On-jump-box end-to-end agent run via `DefaultAzureCredential`. |

> The Foundry account/project/capability-host and network injection have steps ARM
> can't fully express, so the wrapper scripts carry weight and deliberately mirror
> Microsoft's official quickstart happy path. Every version-sensitive spot carries a
> `// VERIFY-IN-TEST:` marker — confirm against the live MS Learn Bicep tab and an
> `az resource show` after deploy before trusting it.

---

## Troubleshooting / FAQ

**Q: Why a whole /24 for the agents?**
A: The subnet is delegated to `Microsoft.App/environments` (Azure Container Apps
under the hood). ACA consumes addresses for its infrastructure; Microsoft recommends
/24, /27 is the floor. And it's **exclusive** — one Foundry resource per agent
subnet.

**Q: Can't I just put a PE on Foundry and call it private?**
A: No — that covers the model/account control plane. The agent still needs to reach
**Search, Storage, and Cosmos privately**, each with its own PE. That's the whole
point of step 3, and PEs to those three are **not** auto-created with Foundry.

**Q: Why not just use a service endpoint instead of all these private endpoints?**
A: Service endpoints keep traffic on the backbone but still resolve to public IPs and
apply at the subnet level. Private endpoints give the dependency a **private IP inside
your VNet** with private DNS — which is what lets you prove there's no public path,
and what lets the UDR-to-firewall design blackhole anything that isn't private.

**Q: Why no TLS inspection — isn't that less secure?**
A: TLS inspection presents a self-signed cert; the agent/Entra auth pins certs and
breaks. MS Learn says explicitly: verify no TLS inspection. You still get FQDN-level
egress control (SNI match) without decrypting the payload.

**Q: My agent run just hangs / times out — what's wrong?**
A: Almost always a **missing private endpoint or DNS zone link** for a BYO dependency
(step 3). Because `0.0.0.0/0` is routed to the firewall with no public route out, a
call with no private path is blackholed rather than failing fast. Confirm with
`check-private-dns.sh` that every dependency FQDN resolves to a `192.168.1.x` address
from the jump box.

**Q: The deploy failed during the capability-host / model / Cosmos step.**
A: This is the transient class the region probe **can't** catch — regional
capacity-host provisioning, `ServiceUnavailable` on Cosmos (AZ),
`InsufficientResourcesAvailable` on Search, and model quota that clears the
availability check but fails at deploy time. Retry, lower `MODEL_CAPACITY`, or pick
another region via `FOUNDRY_REGIONS` (or `SKIP_REGION_PROBE=1 LOCATION=...`).

**Q: Why is the latency to the model not affected by the PE region?**
A: Callback to Lab 1 — a PE is a control-plane shim; the data plane rides Microsoft's
backbone to the real service. Colocation here is for **cost/compliance**, not latency.

**Q: Cleanup is hanging on the spoke VNet delete.**
A: That's the service-association-link on the delegated subnet. Use the provided
`cleanup.sh` / `cleanup.ps1`, which delete → purge the Foundry account → then delete
the RG. A plain `az group delete` will not release the SAL.

---

## Sources

This lab is built on **Microsoft Learn (verified Apr 2026)**:

- Microsoft Learn — [Set up private networking for Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks) — subnet delegation, BYO requirement, the DNS-zone table, PE-not-auto-created note, no-TLS-inspection caveat, region colocation, purge-before-VNet teardown.
- Microsoft Learn — [Baseline Microsoft Foundry landing-zone reference architecture](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-landing-zone) — the WAF/CAF framing.
- Microsoft Learn — [Integrate Azure Container Apps with Azure Firewall (Application rules)](https://learn.microsoft.com/en-us/azure/container-apps/use-azure-firewall) — the egress FQDN allowlist.
- Microsoft Learn — [Foundry RBAC](https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry) — Azure AI Account Owner / Azure AI User roles.
- Microsoft Learn — [Foundry hosted-agent quickstart](https://learn.microsoft.com/en-us/azure/foundry/agents/quickstarts/quickstart-hosted-agent) — the end-to-end agent run.
- See also the sibling [Private Endpoint latency lab](../private-endpoint-latency/README.md) — the PE illusion reveal and how AzFW app rules act as a proxy.

_Technical claims verified against Microsoft Learn, **Apr 2026**._
