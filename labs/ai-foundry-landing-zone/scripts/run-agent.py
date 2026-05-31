#!/usr/bin/env python3
# ============================================================================
#  run-agent.py — run a Foundry agent end-to-end, FROM INSIDE the VNet.
#
#  Execute this on the jump VM (Bastion -> jump box), inside the venv that
#  cloud-init created:
#
#      /opt/agentvenv/bin/python run-agent.py "<PROJECT_ENDPOINT>"
#
#  PROJECT_ENDPOINT looks like:
#      https://<foundry-account>.services.ai.azure.com/api/projects/<project>
#  deploy.sh prints the account name; confirm the exact project endpoint in the
#  Foundry portal (Project > overview) — the path format moves with the SDK.
#
#  The point: this only works from inside the VNet. The project's public access
#  is Disabled; the call resolves the *.services.ai.azure.com name through the
#  private DNS zone to the Foundry private endpoint at 192.168.1.x. Run it from
#  your laptop and it fails — no public path, no private DNS.
#
#  VERIFY-IN-TEST: the Foundry/agents SDK surface (package + class names) is
#  renamed frequently. This uses the azure-ai-projects / azure-ai-agents shape
#  current in early 2026. If imports fail, check the live quickstart:
#    https://learn.microsoft.com/en-us/azure/foundry/agents/quickstarts/quickstart-hosted-agent
# ============================================================================
import sys

try:
    from azure.identity import DefaultAzureCredential
    from azure.ai.projects import AIProjectClient
except ImportError as e:  # pragma: no cover
    sys.exit(
        "Foundry SDK not importable: %s\n"
        "Install it:  /opt/agentvenv/bin/pip install azure-identity azure-ai-projects azure-ai-agents"
        % e
    )

MODEL = "gpt-4o"  # must match the deployment name in modules/foundry.bicep


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("Usage: run-agent.py <PROJECT_ENDPOINT>")
    endpoint = sys.argv[1]

    cred = DefaultAzureCredential()
    project = AIProjectClient(endpoint=endpoint, credential=cred)

    # VERIFY-IN-TEST: the agents accessor / create-and-run flow changes with the
    # SDK. The shape below matches the early-2026 azure-ai-agents surface.
    agent = project.agents.create_agent(
        model=MODEL,
        name="lz-lab-agent",
        instructions="You are a terse assistant for a networking lab. Answer in one sentence.",
    )
    print(f"created agent: {agent.id}")

    thread = project.agents.threads.create()
    project.agents.messages.create(
        thread_id=thread.id,
        role="user",
        content="In one sentence: why does a Standard private Foundry agent need a delegated subnet?",
    )
    run = project.agents.runs.create_and_process(thread_id=thread.id, agent_id=agent.id)
    print(f"run status: {run.status}")

    for msg in project.agents.messages.list(thread_id=thread.id):
        print(f"[{msg.role}] {msg.content}")

    # Clean up the agent (threads are stored in your BYO Cosmos DB).
    project.agents.delete_agent(agent.id)
    print("done — and every byte of this ran inside your VNet.")


if __name__ == "__main__":
    main()
