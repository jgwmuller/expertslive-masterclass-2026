# Azure Networking & AI — Hands-On Labs

Three self-contained, deployable labs for a Level 400 deep dive into Azure
networking and AI connectivity. Each lab stands up real infrastructure with a
single command, drives one memorable result, and tears itself down cleanly.

Built for the **Azure Networking & AI Masterclass** (Experts Live NL 2026).

## The labs

### Lab 1 — The Private Endpoint latency illusion

[`labs/private-endpoint-latency/`](labs/private-endpoint-latency/)

A Private Endpoint's location does **not** determine latency — round-trip time
tracks the *backing service's* region, not where you placed the endpoint. Deploy
a client and two endpoints, then prove it from inside the VNet. The optional
`TOPOLOGY=cross-region` variant makes the point dramatic (client in one region,
both endpoints in another), and Parts B/C add a hub + Azure Firewall to show how
user-defined routes and application rules actually behave.

### Lab 2A — Sub-second blue/green with Application Gateway for Containers

[`labs/agc-blue-green-convergence/`](labs/agc-blue-green-convergence/)

Stand up AKS + the ALB controller + a weighted blue/green app, then kill the
active backend live: traffic swings to the standby in **under a second, with
zero dropped requests**. The `apim/` sub-module continues into an **APIM AI
gateway** in front of Azure OpenAI — token-rate-limiting, semantic caching,
weighted load-balancing across backends, and a circuit breaker.

### Lab 2B — A private AI Foundry agent landing zone

[`labs/ai-foundry-landing-zone/`](labs/ai-foundry-landing-zone/)

A hub/spoke landing zone for a Microsoft Foundry agent with **no public egress
at all** — an Azure Firewall egress allowlist (no TLS inspection), private
endpoints, and the six private DNS zones. Prove from inside the VNet that the
agent runs end-to-end while the same name lookups fail from outside. That gap
*is* the private landing zone.

## Prerequisites

- An Azure subscription with Contributor access
- Azure CLI (`az`) logged in (`az login`) with Bicep (`az bicep`)
- `bash` (macOS / Linux) or PowerShell 7 (Windows), plus the per-lab tools noted in each lab's README (e.g. `kubectl`, `helm`)

## Running a lab

Each lab is self-documenting and ships both a Bash and a PowerShell 7 variant.
From a lab directory:

<details open>
<summary><b>Bash (macOS / Linux)</b></summary>

```bash
chmod +x deploy.sh cleanup.sh
./deploy.sh                 # sensible env defaults; override via env vars
CONFIRM=1 ./cleanup.sh      # tear everything down (skips the prompt)
```

</details>

<details>
<summary><b>PowerShell 7 (Windows)</b></summary>

```powershell
./deploy.ps1                 # sensible defaults; override via -Params or $env:VARS
./cleanup.ps1 -Confirm1 1    # tear everything down (skips the prompt)
```

</details>

Each lab's own `README.md` documents the exact parameters/env-vars (with per-shell
instructions in collapsible sections), alongside the topology diagram, the demo
script, and cost notes.

## Credits

Inspired by the work of Jose Moreno (Cloudtrooper — <https://blog.cloudtrooper.net>),
Microsoft FastTrack for Azure.
