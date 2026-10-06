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

Everything in this repository is public, including the git history. Use neutral examples
(`example.org`, `192.0.2.0/24`, `agent-a`) instead of real values.

### Checklist before every commit

- [ ] No host names, domain names or IP addresses of real systems (including VPN and LAN addresses).
- [ ] No user names, home paths (`/home/<name>`, `/Users/<name>`) or group names of real people.
- [ ] No e-mail addresses or phone numbers, also not in commit metadata: set
      `git config user.email <id>+<user>@users.noreply.github.com` in your clone.
- [ ] No tokens, API keys, passwords, private keys, key fingerprints, chat or channel IDs.
- [ ] Command output and logs: only the lines that matter, with all of the above replaced.
- [ ] Screenshots: no visible host names, addresses, accounts or notifications; metadata removed.
- [ ] Commit messages and pull request texts follow the same rules.

### Local scan before every push

CI runs gitleaks on every push, but by then the data is already public. Scan locally first.

1. Install [gitleaks](https://github.com/gitleaks/gitleaks) (8.x).
2. List your own private strings, one literal string per line, in `.git/info/private-patterns`.
   This file lives inside `.git/` and is never committed. Lines starting with `#` are ignored.
3. Install the hook below as `.git/hooks/pre-push` and make it executable (`chmod +x`).

The hook scans the whole history with gitleaks and checks the pushed commits (content, author,
committer and message) against your private strings. It stops the push on any finding.

```bash
#!/usr/bin/env bash
# pre-push: secret scan and private-string check. Read-only.
set -euo pipefail
command -v gitleaks >/dev/null || { echo "pre-push: gitleaks not found" >&2; exit 1; }
gitleaks git --no-banner --redact .

pat="$(git rev-parse --git-dir)/info/private-patterns"
list=$(grep -v -e '^#' -e '^[[:space:]]*$' "$pat" 2>/dev/null || true)
[ -n "$list" ] || { echo "pre-push: no private strings in $pat" >&2; exit 1; }

while read -r _ local_sha _ remote_sha; do
  [[ $local_sha =~ ^0+$ ]] && continue                      # branch deletion
  if [[ $remote_sha =~ ^0+$ ]]; then range=("$local_sha" --not --remotes)
  else range=("$remote_sha..$local_sha"); fi
  if git log -p --format='%an <%ae>%n%cn <%ce>%n%B' "${range[@]}" \
       | grep -n -i -F -f <(printf '%s\n' "$list"); then
    echo "pre-push: private string found (see lines above)" >&2; exit 1
  fi
done
```
