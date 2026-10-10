# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Chapter 11: keeping confidential data in one zone (local model vs cloud, separate boards, egress per UID,
  memory and backups in the zone).
- Chapter 5: creating and verifying an agent (define in platform.toml, create, model login, lock, verify).
- Chapter 4: local patches (why they exist, the three kinds, apply by hand or via apply-patches.sh).
- Chapter 10: limits and known issues (patch maintenance across upgrades, the multiplexing tension,
  what user isolation does not give, scale and cost).
- Chapter 9: operations (tag-pinned manual update, post-update checks, logs, monitoring independence, backup/recovery).
- Chapter 8: credential pattern (a dedicated keyless-to-agents service holds the keys, fixed catalog, approval
  with a kernel-verified sender).
- Chapter 7: collaboration through Kanban (board as a trust boundary, task flow, per-user dispatch).
- Chapter 6: hardening the units and user slices (per-agent drop-ins, slice limits, immutable instruction files).
- Design chapter: design decisions and the automation map (which script automates which step).
- Chapter 3: host setup (packages, Hermes core and patches, groups, directories, host hardening).
- Chapter 2: architecture overview (domains and zones, users, groups, fixed IDs, directories, units).
- Isolation toolset: `hermes-agent-create.sh`, `hermes-agent-lock.sh`, `hermes-agent-verify.sh` with
  shared libraries, driven by a single `platform.toml`.
- Example `platform.toml`, gateway hardening drop-in (`units/`), example agent SOUL (`agents/`),
  and `SHA256SUMS` for the toolset.
- Local patches P-03 to P-08 with `apply-patches.sh` and a patch overview (`patches/`).

- Repository skeleton: README, support, security and contributing guidelines, changelog.
- Issue templates (bug report, feature request), issue contact links, pull request template.
- CI: ShellCheck, Markdown lint, link check and secret scan (gitleaks) on every push and pull request.
- Private-data checklist and local pre-push scan (gitleaks and private strings) in CONTRIBUTING.md.
- Chapter 1: threat model.

### Changed

- Tool: generated config.yaml sets security.allow_lazy_installs false, so an agent never attempts a
  runtime pip install into the root-owned read-only venv.
- Example platform.toml: set soul for all agents; note that A2A is open on loopback until tokens are set.
- Chapter 3 (host setup): pinned supported Python in a world-readable venv, a tirith install step,
  profiles/ at 711, vault directories, and version/permission notes from the fresh-VM validation.
- CI: lychee skips the throttled upstream SECURITY.md blob link (still linked in the docs).
- CI: lychee checks github.com links via the API with a token and retries transient failures.
- Chapter 1: an agent's own configuration, instructions and keys are protected by root ownership and the
  immutable attribute, not by the file system boundary alone; profiles must not carry ACLs.
