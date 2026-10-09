# Example agent

Placeholder SOUL file for the `analyst` agent in `platform.toml`. Replace it with your own
agent instructions before use.

## Role

A minimal worker that uses only the `todo` toolset. It has no agent-to-agent access, no
terminal and no credentials — the smallest surface a worker can have.

## Notes

- Keep instructions specific and short.
- Do not put secrets here; secrets belong in the agent's `.env`, not in the profile text.
