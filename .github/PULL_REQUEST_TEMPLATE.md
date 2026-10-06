## What changes

<!-- Short description. Link the issue if there is one. -->

## Effect on isolation between agents

<!-- New access, shared paths, sockets, groups or credentials? "None" is a valid answer. -->

## Tested with

<!-- Distribution, systemd version, Hermes Agent version, local patches. -->

## Checklist

- [ ] No private data (host names, addresses, user names, tokens, keys, log excerpts with any of these)
- [ ] Local scan passed (pre-push hook from CONTRIBUTING.md)
- [ ] Scripts pass `shellcheck`; read-only scripts say so in their header
- [ ] Changing scripts back up first and print how to roll back
- [ ] Scripts do not print secrets
- [ ] Documentation and CHANGELOG.md updated
