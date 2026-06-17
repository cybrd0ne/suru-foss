# tier2-telemetry/build — Render Pipeline

This directory contains the render pipeline that transforms Tier 2 security policy
data files into deployment-ready artefacts consumed by `tier1-perimeter/deploy.sh`.

## Concept

```
T2 data files  +  T1 templates  →  tier1-perimeter/rendered/<platform>/
```

The render pipeline is invoked via the Tier 1 Makefile:

```bash
make -C tier1-perimeter render          # render only
make -C tier1-perimeter deploy-full     # render + deploy
```

## Files

```
build/
├── render.sh              # Master render orchestrator
├── lib/
│   ├── render-pfblockerng.sh   # Merges pfblockerng tpl + categories.yml → rendered XML
│   ├── render-suricata.sh      # Copies rule-selection files to rendered/
│   └── render-zeek.sh          # Assembles local.zeek from tpl + script list
└── tests/
    ├── test-sigma-lint.sh      # sigma-cli --validate on all Sigma rules
    ├── test-suricata-rules.sh  # suricata --test-rules on custom rules
    └── test-render.sh          # Dry-run render, assert output files exist
```

## Usage

```bash
bash render.sh --platform pfsense
bash render.sh --platform opnsense --dry-run
bash render.sh --platform pfsense --verbose
```

## Output (git-ignored)

All output lands in `tier1-perimeter/rendered/`. This directory is git-ignored.
Run `make render` before every `make deploy`.
