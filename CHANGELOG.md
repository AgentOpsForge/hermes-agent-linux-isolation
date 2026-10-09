# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
