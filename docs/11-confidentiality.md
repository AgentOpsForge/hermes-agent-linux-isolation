# Keeping confidential data in one zone

Some data must not leave a zone — personal records, anything a cloud model's provider must never see.
User isolation already separates agents; this chapter points that separation at a confidentiality goal:
a zone whose agent runs a **local (on-premises) model** keeps its data on the host, and no agent on a
**cloud model** ever receives it. The examples use a confidential zone `records` (its agent on a local
model) and a `research` zone (its agent on a cloud model).

## The model is the first control

The provider sees whatever the agent sends it. So the confidential agent runs a local model — the data
never leaves the host to any provider — and the cloud agent simply never gets the data. The model is
chosen per agent at creation ([Creating and verifying an agent](05-create-verify.md)); a cloud model for
a confidential zone defeats everything below.

## Separate zones, separate boards

A zone is its own agent and Linux user ([Architecture](02-architecture.md)). The confidential and cloud
zones are different zones — different agents — and because a board's workspaces are shared by all its
members ([Collaboration through Kanban](07-kanban.md)), different Kanban boards. Never put a confidential
agent and a cloud agent on the same board.

## Data crosses only as a result, never as raw records

Between agents, data moves only over agent-to-agent calls (information) or Kanban (a task), never shared
files ([Architecture](02-architecture.md)). The raw records stay inside the confidential zone. What may
cross to the cloud zone is a **derived, non-sensitive result the owner approved** — handled like the
credential pattern's approval flow ([Credential pattern](08-credentials.md)), not an open pipe. If a
cloud-zone request would need the raw data, the answer is no, not a copy.

## Egress per Linux user

Outbound is allowed in general, but the confidential agent's user should be blocked in the host firewall
from reaching any external model or provider endpoint, so even a misconfiguration cannot send the data
out — allow only the local model's address. The rule is written on the socket owner: nftables
`meta skuid`, iptables `-m owner --uid-owner`. The firewall belongs to the operator
([Host setup](03-host-setup.md)); the guide fixes the requirement, not the ruleset.

## Memory and logs stay in the zone

Each agent has its own memory workspace and no key to another's, so the cloud agent cannot read the
confidential agent's memory; keep that agent's memory backend local. Logs are per agent home, not shared,
with secrets redacted ([Operations](09-operations.md)) — but redaction is not a licence to log records.
Keep confidential content out of the logs in the first place.

## Backups stay on-premises

The confidential zone's state and its backups stay on the host or an on-premises target — never a
destination a cloud zone or an external provider can reach. Back it up like any agent state
([Operations](09-operations.md)), to storage that stays inside the boundary.

## What this does not do

This keeps confidential data away from a cloud model and from other zones; it is **not** a kernel sandbox
([Limits and known issues](10-limits.md)). All agents share one kernel, and the local model still runs
with whatever access its host allows. The control is the user and zone boundary, the model choice, and
egress — not a guarantee against a host compromise.

## What is automated

| Step | By hand | Script |
| --- | --- | --- |
| Model choice per agent | set in `platform.toml`, interactive login ([ch. 5](05-create-verify.md)) | `hermes-agent-create.sh` |
| Separate boards and groups | from the zones in `platform.toml` | host setup ([ch. 3](03-host-setup.md)) |
| Egress per UID | the operator's firewall rule on the socket owner | — |
| No key to a foreign memory workspace | — | `hermes-agent-verify.sh` |
