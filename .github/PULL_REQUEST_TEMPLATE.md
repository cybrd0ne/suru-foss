## Description
<!-- What does this change do, and why? Link any related issue (#123). -->

## Affected tier(s)
- [ ] Tier 1 — Perimeter
- [ ] Tier 2 — Telemetry / detection content
- [ ] Tier 3 — Core
- [ ] Tier 4 — Operations
- [ ] Cross-tier / repo-wide

## Type of change
- [ ] feat: new feature
- [ ] fix: bug fix
- [ ] security: security improvement
- [ ] docs: documentation
- [ ] refactor: code refactoring
- [ ] BREAKING CHANGE (API, schema, or container interface)

## Checklist
- [ ] Conventional commit messages used
- [ ] Verified locally — `shellcheck` clean for `*.sh`, `docker compose config` passes
- [ ] `terraform validate && terraform fmt -check` passes (if IaC changed)
- [ ] Detection content validated with its native tool (`suricata -T`, `sigma check`, `zeek -s`)
- [ ] Docs updated in the same PR (tier `README.md` / `docs/`, `.env.example` for new vars)
- [ ] No secrets, real hostnames, or private keys committed
- [ ] Container changes preserve the hardening baseline (non-root, `cap_drop`, pinned image, no docker.sock)
