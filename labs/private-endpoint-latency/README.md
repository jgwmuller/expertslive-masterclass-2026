# Lab 1: The Private Endpoint latency illusion

In this lab you'll deploy two Azure Private Endpoints into the **same local subnet**,
point them at storage accounts in **two different regions**, measure the latency to
each, and watch one answer in single-digit milliseconds while the other takes
~200+ ms — and you'll understand why a Private Endpoint can never be responsible for
that difference.

The lab has three parts you can run in order:

- **Part A — the latency reveal** (cheap, default). Two local PEs, two regions, one
  measurement. Pennies per hour.
- **Part B — "your routes might be lying"** (opt-in firewall). A hub + Azure Firewall,
  a UDR you try to use to redirect PE traffic, and what the effective route table
  actually does.
- **Part C — "the firewall is a proxy"** (opt-in firewall). An Azure Firewall
  application rule terminates TLS, reads SNI, and does its own DNS — with consequences.

---

## What you'll learn

A Private Endpoint is **control plane only**. When you create one, Azure does exactly
two things:

1. Injects a `/32` route (next-hop = `InterfaceEndpoint`) into the NICs of every VM in
   the PE's VNet and any **directly-peered** VNets.
2. Registers an A-record in the linked `privatelink.*` Private DNS zone.

That's it. There is **no appliance, no proxy, no hop**. The data plane is sourced
straight from the client NIC onto Microsoft's backbone toward the *real* PaaS instance —
wherever on Earth that instance actually lives. So **latency tracks the backing
service's real region, not the PE's**. This lab proves it by putting both PEs in the
same local subnet while their target storage accounts sit in two different regions: if
the PE were carrying data, both would be equally fast; they aren't.

By the end you'll be able to answer the three troubleshooting questions that matter for
any Private Link path:

- **What `/32` was injected, and what next-hop did it get?** (Part A, Part B)
- **Is `RouteTableEnabled` set on the PE subnet?** (Part B — the only durable way to
  force PE traffic through a hub firewall)
- **Who's proxying?** (Part C — an Azure Firewall application rule is a TLS-terminating
  proxy that does its own DNS, so the `privatelink.*` zone must be linked to its VNet)

---

## Architecture / topology

### Part A — the latency reveal (default, VPN-free)

```
                          Region A (e.g. Australia East)
   ┌──────────────────────────────────────────────────────────┐
   │  vnet-pelab 10.20.0.0/16                                   │
   │                                                            │
   │   snet-client 10.20.1.0/24      snet-pe 10.20.2.0/24       │
   │   ┌──────────────┐              ┌──────────────────────┐   │
   │   │  vm-client   │              │ pe-near-blob 10.20.2.x│──┼──► NEAR storage (Region A)
   │   │ (Ubuntu+mtr) │  ──route──►  │ pe-far-blob  10.20.2.y│──┼──► FAR  storage (Region B)
   │   └──────────────┘              └──────────────────────┘   │       e.g. Germany West Central
   │                                                            │
   │   privatelink.blob.core.windows.net  (linked)              │
   └──────────────────────────────────────────────────────────┘

   Both PEs are LOCAL NICs in snet-pe. Their data planes go to different regions.
```

See [`private-endpoint-latency-diagram.svg`](./private-endpoint-latency-diagram.svg)
for the slide-ready version (control plane vs data plane paths).

### Parts B/C — hub + Azure Firewall (opt-in, `DEPLOY_FIREWALL=1`)

```
   HUB  vnet-hub 10.30.0.0/16                 SPOKE  vnet-pelab 10.20.0.0/16
   ┌──────────────────────────────┐  peering  ┌──────────────────────────────┐
   │  AzureFirewallSubnet          │◄─────────►│  snet-client  10.20.1.0/24    │
   │  10.30.0.0/24                 │           │    vm-client (+ rt-client-to-fw)
   │    azfw-pelab  10.30.0.x/.y   │           │  snet-pe      10.20.2.0/24    │
   │  + firewall policy            │           │    pe-near-blob / pe-far-blob │
   └──────────────────────────────┘           └──────────────────────────────┘
   privatelink.blob...  linked to BOTH VNets (the AzFW-app-rule DNS dependency).
```

See [`private-endpoint-firewall-diagram.svg`](./private-endpoint-firewall-diagram.svg)
for the firewall-path version (the route lie and the proxy).

### Two topologies for Part A

The default **simple topology** (`main.bicep`) keeps both PEs local to the client to
keep deploy time short and cost low. An alternative **cross-region topology**
(`main-cross-region.bicep`) puts both PE NICs in the *remote* region, which produces a
more dramatic angle. Both prove the same thing.

| Topology | Setup | What you see |
|---|---|---|
| **Simple** (default) | Local AU VM → both PEs local → AU storage (short) and German storage (long) | Long latency despite a *local* PE — the PE NIC is local but the data plane still travels to Germany. |
| **Cross-region** (`TOPOLOGY=cross-region`) | Client in Region A (AU) → both PE NICs in Region B (DE) → AU storage (short) and DE storage (long) | Short latency (~3–5 ms) to AU storage despite a *remote* PE in Germany — the long-distance "wow". |

Cross-region is **Part A only** — Parts B/C are tied to the simple topology and the
deploy script refuses `TOPOLOGY=cross-region` together with `DEPLOY_FIREWALL=1`.

---

## Prerequisites

- **Azure CLI (`az`)** logged in to a subscription you can deploy into (`az login`).
- Permission to create a VNet, VM, public IP, 2 storage accounts, 2 private endpoints,
  and a private DNS zone (plus a hub VNet + Azure Firewall for Parts B/C).
- An **SSH key pair**. If you don't have one at `~/.ssh/id_rsa.pub`, the deploy script
  generates one for you.
- **Outbound internet** from your machine — the deploy script auto-detects your public
  IP and locks inbound SSH on the VM's NSG to just that `/32`.
- For Parts B/C you also drive the demo from your machine via SSH to the VM, so a
  working `ssh` client is needed.

There is **no VPN gateway** and no on-prem simulation — the single-client design gets
the same reveal with a fraction of the resources and deploy time.

**macOS / bash note:** the deploy/cleanup and on-VM scripts are written for stock-macOS
bash 3.2, so they run as-is on a Mac. On **Windows**, use the PowerShell 7 variants
(`deploy.ps1` / `cleanup.ps1`); the Part B/C demo drivers are bash-only — run them via
WSL or Git Bash (see [What you'll see](#what-youll-see--run-it-yourself)).

---

## Cost — read this first

Part A is **pennies per hour**. The only meaningful cost in the whole lab is **Azure
Firewall (~$1.25/hr)**, and it is **opt-in** via `DEPLOY_FIREWALL=1` — Part-A-only
attendees never pay it. Approximate pay-as-you-go rates while the lab is up:

| Resource | Qty | Rough cost |
|---|---|---|
| Client VM (Standard_B1s) | 1 | ~$0.012 / hr |
| Standard public IP (client) | 1 | ~$0.005 / hr |
| Private endpoints | 2 | ~$0.01 / hr each + data processing |
| Storage accounts (idle) | 2 | negligible |
| Private DNS zone | 1 | negligible |
| **Azure Firewall (Standard)** *(Parts B/C only)* | 1 | **~$1.25 / hr + ~$0.016/GB processed** |
| Standard public IP (firewall) *(Parts B/C only)* | 1 | ~$0.005 / hr |

So **Part A alone is a few cents to a couple of dollars**. With the firewall on for
Parts B/C, budget **~$1.25/hr**. Run [cleanup](#cleanup) promptly afterward so the
firewall, PEs, and public IPs stop billing.

> The firewall tier defaults to `Standard`. `Premium` (`FIREWALL_TIER=Premium`) costs
> more — stick with `Standard` unless you specifically want the Premium features.

---

## Deploy

From this lab directory. The deploy script checks prereqs, generates an SSH key if
needed, detects your public IP for the SSH NSG rule, creates the resource group, runs
the Bicep deployment, and **prints the exact next commands** (the client VM IP, both
storage FQDNs, and the ready-to-paste reveal command).

### Default (simple topology, Part A only)

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
chmod +x deploy.sh cleanup.sh
./deploy.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./deploy.ps1
```
</details>

Defaults: `near = australiaeast`, `far = germanywestcentral`. Give cloud-init ~2 minutes
after the deploy finishes to install `mtr` on the VM before you run Part A.

### Change the regions for a bigger gap

Pick a "near" region close to where you are and a "far" region on the other side of the
planet — the bigger the physical distance, the bigger the latency gap.

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
LOCATION=westeurope FAR_LOCATION=australiaeast ./deploy.sh
# or
LOCATION=eastus FAR_LOCATION=southeastasia ./deploy.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./deploy.ps1 -Location westeurope -FarLocation australiaeast
# or
./deploy.ps1 -Location eastus -FarLocation southeastasia
```
</details>

### Cross-region topology (Part A only)

Client in Region A, **both PE NICs in Region B**, one storage account in each region,
cross-region VNet peering, DNS zone linked to both VNets. With default regions the AU
storage FQDN answers in ~3–5 ms even though its PE NIC lives in Germany, while the
German storage FQDN answers in ~250+ ms.

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
TOPOLOGY=cross-region ./deploy.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./deploy.ps1 -Topology cross-region
```
</details>

### Add the firewall for Parts B/C

This stands up `vnet-hub` (`10.30.0.0/16`) with an `AzureFirewallSubnet`, Azure Firewall
(`azfw-pelab`) + firewall policy, bidirectional peering to `vnet-pelab`, an empty route
table `rt-client-to-fw`, and the hub DNS zone link. Adds ~5–10 min and ~$1.25/hr.

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
DEPLOY_FIREWALL=1 ./deploy.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./deploy.ps1 -DeployFirewall 1
```
</details>

### Environment-variable / parameter overrides

Everything is configurable. Bash uses environment variables; PowerShell uses named
parameters (or the same env vars).

| Env var (bash) | PowerShell param | Default | Purpose |
|---|---|---|---|
| `TOPOLOGY` | `-Topology` | `simple` | `simple` or `cross-region`. Cross-region is Part A only. |
| `RG` | `-Rg` | `rg-pe-latency-lab` | Resource group name. |
| `LOCATION` | `-Location` | `australiaeast` | "Near" region: client + both PEs (simple) / just the client (cross-region). |
| `FAR_LOCATION` | `-FarLocation` | `germanywestcentral` | "Far" storage region (simple) / both PE NICs + far storage (cross-region). |
| `VM_SIZE` | `-VmSize` | `Standard_B1s` | Client VM size. |
| `ADMIN_USER` | `-AdminUser` | `azureuser` | VM admin username. |
| `SSH_KEY` | `-SshKey` | `~/.ssh/id_rsa.pub` | Public key path; generated if missing. |
| `DEPLOY_FIREWALL` | `-DeployFirewall` | `0` | `1` adds the hub + Azure Firewall for Parts B/C (simple topology only). |
| `FIREWALL_TIER` | `-FirewallTier` | `Standard` | `Standard` or `Premium`. |
| `ALLOWED_CIDR` | `-AllowedCidr` | *(auto-detected)* | Source CIDR allowed inbound SSH. Auto-detected from your public IP; set it if detection fails. |

---

## What you'll see — run it yourself

The deploy output gives you the `CLIENT_IP`, `NEAR_FQDN`, and `FAR_FQDN` you'll plug in
below. `lab-on-vm.sh` runs **on the Linux client VM** (always bash); the from-laptop
Part B/C scripts are **bash** — on Windows run them via WSL or Git Bash.

### Part A — the latency reveal

Run the bundled on-VM script over SSH (deploy.ps1/deploy.sh print this exact line with
your values filled in):

```bash
ssh azureuser@<CLIENT_IP> 'sudo lab-on-vm.sh <NEAR_FQDN> <FAR_FQDN>'
```

**Step 1 — watch DNS.** The script runs `dig` against both blob FQDNs. **Both** resolve
to private IPs in the *same local subnet* (`10.20.2.x`). From DNS alone the two services
look identical and equally "local."

**Step 2 — watch latency.** The script runs `mtr -T -P 443 -c 20 --report` against each
FQDN — a TCP SYN to port 443, exactly what a real TLS data-plane connection opens with.
Expected shape:

```
-> NEAR storage (Region A)        last hop  ~2–6 ms
-> FAR  storage (Region B)        last hop  ~230–260 ms
```

**The result.** Two PEs, same subnet, same DNS zone, both "local" — yet one is ~50–100×
slower. The only difference is the storage account's real region, so the PE is **not**
on the data path. It only injected a route and a DNS record; the TCP handshake
round-trips all the way to the storage account's true region over Microsoft's backbone.

> **Why are middle hops blank / `???` in the far trace?** Microsoft's backbone doesn't
> return TTL-exceeded for those hops — you literally cannot see them. That's part of the
> point: the PE is invisible as a hop, and so is the backbone. Only the final handshake
> RTT is meaningful.

### Part B — "your routes might be lying" (firewall, opt-in)

Requires the firewall deploy (`DEPLOY_FIREWALL=1`). Run from **your machine** (the
script drives `az` locally and SSHes to the VM for traceroute):

```bash
RG=rg-pe-latency-lab CLIENT_IP=<CLIENT_IP> ADMIN_USER=azureuser \
  ./scripts/part-b-routes.sh
```

> On Windows: set the same values as `$env:` variables and run
> `bash ./scripts/part-b-routes.sh` from WSL or Git Bash.

**Step 1 — read the truth.** `az network nic show-effective-route-table -n nic-client`
shows the injected `/32` `InterfaceEndpoint` routes, one per PE. These are
SDN-programmed per-NIC; they never appear on a gateway/vHub route table.

**Step 2 — try to redirect with a legacy `/32` UDR.** The script associates the empty
`rt-client-to-fw` route table to the client subnet, adds a `/32` UDR per PE IP with
next-hop = the firewall (`VirtualAppliance`), then re-reads effective routes and
traceroutes to a PE over TCP/443. You'll see both routes present:

```
AddressPrefix    NextHopIpAddress    NextHopType
10.20.2.4/32     10.30.0.x           VirtualAppliance     # your UDR
10.20.2.4/32     -                   InterfaceEndpoint    # the PE's injected route
```

> **Honest caveat (environment-dependent).** Whether your legacy `/32` UDR wins or the
> injected PE `/32` silently bypasses the firewall depends on the topology. The
> documented "PE `/32` silently wins over a `/32` UDR" failure mode reliably reproduces
> only **inside the GatewaySubnet of an active/active VPN gateway** — and *this lab has
> no VPN gateway*, so on a live run the UDR is usually honored here. **Judge by latency,
> not hop count:** Azure Firewall does not decrement TTL, so traceroute always shows the
> PE as the single visible hop either way. If the FAR-PE latency collapses from Part A's
> ~250 ms to a few ms, the firewall is in path. (See the `// VERIFY-IN-TEST:` notes in
> `scripts/part-b-routes.sh`.)

**Step 3 — the durable fix.** The script enables Private Endpoint network policies on
the PE subnet and swaps the per-PE `/32` UDRs for one summary `/24` UDR:

```bash
az network vnet subnet update -n snet-pe --vnet-name vnet-pelab -g $RG \
  --ple-network-policies RouteTableEnabled
# then a single summary UDR for the whole PE subnet:
#   10.20.2.0/24  ->  VirtualAppliance  10.30.0.x
```

Re-read effective routes and traceroute again — the FAR-PE latency drops to single-digit
ms (the firewall is now terminating the TCP locally). `RouteTableEnabled` + a summary
UDR is the GA-supported, durable pattern any time you need PE traffic inspected by a hub
firewall.

> **Why does the wrong UDR prefix break it?** A `/8` UDR like `10.0.0.0/8 -> firewall`
> is *less* specific than the VNet `/24` peering route, so the `/32` PE routes get
> re-plumbed and bypass the firewall anyway. The UDR must be the **most specific** match
> for the PE prefix.
>
> **Why are there two firewall IPs in the traceroute?** Azure Firewall is multi-instance
> under the covers; `10.30.0.x` / `.y` are the actual AzFW data-plane VMs (≥2, scales).

### Part C — "the firewall is a proxy" (stretch, opt-in)

Reuses the Part B firewall. Run from **your machine** (needs both FQDNs):

```bash
RG=rg-pe-latency-lab CLIENT_IP=<CLIENT_IP> ADMIN_USER=azureuser \
  FAR_FQDN=<FAR_FQDN> NEAR_FQDN=<NEAR_FQDN> \
  ./scripts/part-c-firewall.sh
```

> On Windows: set the same values as `$env:` variables and run
> `bash ./scripts/part-c-firewall.sh` from WSL or Git Bash.

An Azure Firewall **application rule is a TLS-terminating proxy**, not an L4 filter. AzFW
terminates the client TCP/TLS, **reads the SNI**, does its **own DNS lookup**, then opens
a fresh connection onward. Two consequences fall out of that.

**Step 1 — add the app rule.** The script adds an application rule allowing the blob
FQDN(s) to the (shipped-empty) rule-collection group `pelab-app-rules` on
`azfwpolicy-pelab`.

**Step 2 — the DNS-zone-link dependency (watch this).** The script **deletes** the
`privatelink.blob.core.windows.net` link to the hub VNet and `curl`s the NEAR blob — it
**fails**, because AzFW resolved the *public* storage IP and the accounts have
`publicNetworkAccess=Disabled`. Then it **re-creates** the link and `curl`s the FAR blob,
which returns a storage-level `4xx` (auth, not network) — proof the TLS handshake
completed *through* the firewall to the PE. (The script uses a different FQDN for each
state so AzFW's per-FQDN DNS cache works with it, no 5-minute cache-expiry wait.)

> A `4xx` here is the storage account rejecting an anonymous request — the *application*
> talking, which means the *network path* succeeded. A network failure looks like a
> timeout / connection-refused, not an HTTP status.

**Step 3 — the impossible latency.** `mtr -T -P 443` to the **far-region** blob FQDN
through the app rule:

```
mtr -T -P 443 stXXXXfar.blob.core.windows.net
1.  10.20.2.x   ~1–5 ms     <- the PE IP, but ANSWERED by AzFW (~5 ms RTT)
```

In Part A this exact FQDN measured ~250+ ms (real region distance). Through the AzFW
application rule it measures single-digit ms — physically impossible to the far region
unless something *local* is answering the TCP. The firewall is: it terminated the
connection, so it's the real TCP endpoint (and it doesn't decrement TTL, so it isn't a
visible hop). The destination IP in the client packet is irrelevant; the SNI is
everything.

> **Could you point the client at a bogus IP and it still works?** Yes — AzFW proxies on
> SNI, so `curl --resolve store.blob...:443:<any-routable-IP-that-reaches-AzFW>` works.
> (IDPS on Premium treats SNI/IP mismatch as a violation, so this trick is
> Standard-SKU-without-IDPS only; for production proxying use the AzFW Explicit Proxy
> feature.)
>
> **Do you need SNAT?** For Storage from a same-VNet client, generally no; Azure SQL is
> the canonical service that *does* need AzFW SNAT for same-VNet flows. Out of scope
> here, but worth flagging.

---

## Cleanup

`cleanup.sh` / `cleanup.ps1` deletes the **entire resource group**, so the hub VNet and
Azure Firewall go with it — no separate teardown for Parts B/C. Do this promptly so the
firewall, PEs, and public IPs stop billing.

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
RG=rg-pe-latency-lab ./cleanup.sh      # prompts; type the RG name to confirm
# or, scripted (skip the prompt):
CONFIRM=1 ./cleanup.sh
```
</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./cleanup.ps1 -Rg rg-pe-latency-lab    # prompts; type the RG name to confirm
# or, scripted (skip the prompt):
./cleanup.ps1 -Confirm1 1
# env-var equivalent:
$env:CONFIRM='1'; ./cleanup.ps1
```
</details>

Deletion runs in the background (`--no-wait`). Verify later with
`az group show -n rg-pe-latency-lab`. If the deploy script generated a fresh SSH key for
you, it printed the `rm` commands to delete it after cleanup if you don't want to keep
it.

---

## How it works under the hood

**The control-plane / data-plane split.** A Private Endpoint is two control-plane
artifacts: a `/32` `InterfaceEndpoint` route the SDN programs into every NIC in the
PE's VNet and any directly-peered VNet, plus an A-record in the linked `privatelink.*`
zone. Neither is a network hop. Once the client has the private IP (DNS) and a route to
it (the `/32`), its packets ride Microsoft's backbone directly to the PaaS service's
real region. The PE region only affects where the *NIC* lives, not where the *data* goes
— which is why a local PE in front of far storage is slow, and a remote PE in front of
near storage is fast (the cross-region topology).

**Why a `/32` UDR can't be trusted to redirect PE traffic (Part B).** The injected PE
route is SDN-programmed, not a UDR and not BGP. A per-subnet `/32` UDR you'd expect to
override it doesn't reliably win in every topology — the documented silent-bypass case
lives in the GatewaySubnet of an active/active VPN gateway. The supported, durable fix
is Private Endpoint network policies (`--ple-network-policies RouteTableEnabled`) on the
PE subnet plus a single summary UDR for the PE prefix.

**Why an AzFW application rule is a proxy (Part C).** Application rules make AzFW
terminate TCP/TLS, read the SNI, and do its **own** DNS lookup before opening a fresh
connection onward. So the `privatelink.*` zone must be linked to the firewall's VNet —
forget it and AzFW resolves the public IP and walks past your private endpoint. And
because AzFW is the real TCP endpoint, latency to a far region collapses to ~local.

### Files in this lab

| File | Purpose |
|---|---|
| `main.bicep` | Part A infrastructure — simple topology (VNet, VM, 2 storage, 2 PEs, DNS) + opt-in wiring of `firewall.bicep`. |
| `main-cross-region.bicep` | Part A cross-region topology — client in Region A, both PE NICs in Region B. Part A only (no firewall). |
| `firewall.bicep` | Parts B/C infrastructure (hub VNet, `AzureFirewallSubnet`, Azure Firewall + policy, peering, route table, hub DNS link). Deployed only when `deployFirewall=true`. |
| `cloud-init.yaml` | Bootstraps the VM: installs `mtr` / `dig` / `traceroute` / `curl`, drops the reveal script at `/usr/local/bin/lab-on-vm.sh`. |
| `deploy.sh` / `deploy.ps1` | az-CLI wrapper: prereqs, IP detection, SSH key, deploy (honors `DEPLOY_FIREWALL=1`), prints next steps for Parts A/B/C. |
| `cleanup.sh` / `cleanup.ps1` | Deletes the whole resource group (firewall included). |
| `scripts/lab-on-vm.sh` | Part A: readable copy of the on-VM latency reveal script (runs on the client VM). |
| `scripts/part-b-routes.sh` | Part B: "your routes might be lying" — effective routes, legacy `/32` UDR, then `RouteTableEnabled` + summary UDR. Runs from your machine. |
| `scripts/part-c-firewall.sh` | Part C: "the firewall is a proxy" — AzFW app rule, DNS-zone-link dependency, impossible-latency `mtr`. Runs from your machine. |
| `private-endpoint-latency-diagram.svg` | Part A slide diagram (control-vs-data-plane). |
| `private-endpoint-firewall-diagram.svg` | Parts B/C slide diagram (hub + firewall path, the route lie, the proxy). |

---

## Troubleshooting / FAQ

**Q: I ran Part A but `mtr` isn't found / the command fails.**
**A:** cloud-init needs ~2 minutes after the deploy finishes to install `mtr`. Wait and
retry the SSH command.

**Q: The deploy failed with "Could not detect your public IP."**
**A:** IP auto-detection couldn't reach the detection endpoints. Pass your CIDR
explicitly: `ALLOWED_CIDR=x.x.x.x/32 ./deploy.sh` (bash) or
`./deploy.ps1 -AllowedCidr x.x.x.x/32` (PowerShell).

**Q: SSH to the VM times out.**
**A:** The NSG only allows inbound SSH from the IP detected at deploy time. If your
public IP changed (e.g. you moved networks), re-deploy or update the NSG rule /
`ALLOWED_CIDR`.

**Q: Doesn't the docs say to co-locate the PE with the origin for latency?**
**A:** That Azure Front Door guidance is about **control-plane resiliency**, not
data-plane latency — PE region has zero effect on data-plane RTT. This lab demonstrates
exactly that.

**Q: What if I add a UDR to force PE traffic through a firewall?**
**A:** That's Part B. A legacy `/32` UDR doesn't reliably beat the injected PE `/32` in
every topology; the durable fix is `RouteTableEnabled` on the PE subnet + a summary UDR.
See the honest caveat in [Part B](#part-b--your-routes-might-be-lying-firewall-opt-in).

**Q: Part C `curl` returns HTTP 400/403/409 — is that a failure?**
**A:** No — that's a storage-level (auth) response, which means the network path through
the firewall to the PE succeeded. A real network failure is a timeout /
connection-refused, not an HTTP status.

**Q: Parts B/C say the firewall wasn't found.**
**A:** You deployed Part A only. Re-deploy with `DEPLOY_FIREWALL=1` (bash) /
`-DeployFirewall 1` (PowerShell) to add the hub + Azure Firewall.

**Q: I tried `TOPOLOGY=cross-region DEPLOY_FIREWALL=1` and the deploy refused.**
**A:** That combination is intentionally blocked — Parts B/C are tied to the simple
topology. Run the simple topology for the routes/firewall demos.

---

## Further reading

- Azure Private Link / Private Endpoint DNS and routing behavior (Microsoft Learn).
- Private Endpoint network policies (`RouteTableEnabled`, GA Aug 2022) for forcing PE
  traffic through a hub firewall.
- Azure Firewall application rules, SNI-based proxying, and the Explicit Proxy feature.
