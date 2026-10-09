# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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

- Chapter 1: an agent's own configuration, instructions and keys are protected by root ownership and the
  immutable attribute, not by the file system boundary alone; profiles must not carry ACLs.
