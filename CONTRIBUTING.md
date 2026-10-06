# Contributing

Corrections and improvements are welcome. Please keep in mind that this project offers no
support (see [SUPPORT.md](SUPPORT.md)).

## Before you start

- Problems in Hermes Agent itself belong in the
  [Hermes Agent issue tracker](https://github.com/NousResearch/hermes-agent/issues), not here.
- For larger changes, open an issue or a discussion first.

## Pull requests

- Changes reach `main` only through pull requests. Only the maintainer merges.
- Describe what changes and **how it affects isolation between agents**: new access, new shared
  paths, sockets, groups or credentials.
- Name the distribution and Hermes Agent version you tested with.
- Shell scripts must pass `shellcheck`. Scripts that only read must say so in their header;
  scripts that change the system must back up first and print how to roll back.
- Scripts must not print secrets.

## No private data

Do not include host names, IP addresses, user names other than the example agents, phone numbers,
e-mail addresses, tokens, keys or log excerpts that contain any of these. Use neutral examples.
