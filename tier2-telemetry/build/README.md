# tier2-telemetry/build — Render Pipeline

This directory contains the render pipeline that transforms Tier 2 security
policy data files into deployment-ready artefacts. `render.sh` is a thin
master dispatcher over two independent render **scopes**:

| Scope | Produces | Consumed by |
|-------|----------|-------------|
| `tier1` (default) | Perimeter render: Suricata/pfBlockerNG/Zeek config | `tier1-perimeter/rendered/<platform>/` → `tier1-perimeter/deploy.sh` |
| `tier3` | SIEM Security Analytics render: Layer 1-3 Sigma/detector/correlation/action JSON + STIX2 threat-intel bundle skeletons | `tier3-core/config/opensearch/security-analytics/**` → T7's import-only provisioner (separate task, live OpenSearch import) |

**Backward compatibility:** `--scope` defaults to `tier1` — the only scope
that existed before this dispatcher was introduced. Every existing caller
(`tier1-perimeter/Makefile`'s `render`/`deploy`/`deploy-full` targets,
`build/tests/test-render.sh`'s pre-existing assertions) invokes `render.sh`
with no `--scope` flag and gets byte-identical output to the pre-dispatcher
monolithic script. The `--platform pfsense|opnsense|all` flag is unchanged.
Opt into the new tier3 render path explicitly with `--scope tier3` or
`--scope all`.

## Concept

```
tier1 scope:  T2 data files  +  T1 templates  →  tier1-perimeter/rendered/<platform>/
tier3 scope:  T2 sigma/opensearch/threat-intel →  tier3-core/config/opensearch/security-analytics/**
```

The render pipeline is invoked via the Tier 1 Makefile (tier1 scope only —
the Makefile has no tier3 target as of this writing):

```bash
make -C tier1-perimeter render          # render only (tier1 scope, implicit)
make -C tier1-perimeter deploy-full     # render + deploy
```

## Files

```
build/
├── render.sh                    # Master dispatcher: --scope tier1|tier3|all
├── lib/
│   ├── render-tier1.sh              # Orchestrates the (unchanged) perimeter renderers below
│   ├── render-pfblockerng.sh        # Merges pfblockerng tpl + categories.yml → rendered XML
│   ├── render-suricata.sh           # Copies rule-selection files to rendered/
│   ├── render-zeek.sh               # Assembles local.zeek from tpl + script list
│   ├── render-tier3.sh              # Orchestrates the SIEM Security Analytics renderers below
│   ├── render-sigma.sh              # Layer 1: validates/copies Sigma rules, skips *.stub.*, emits manifest.json
│   ├── render-detectors.sh          # Layer 2: opensearch/detectors/*.yml → security-analytics/detectors/*.json
│   ├── render-correlations.sh       # Layer 2: opensearch/correlations/*.yml → security-analytics/correlation-rules/*.json
│   ├── render-actions.sh            # Layer 2: opensearch/actions/*.yml → security-analytics/actions/*.json
│   └── render-stix2.sh              # threat-intel/sources.yml → threat-intel/stix2/*.json bundle skeletons
└── tests/
    ├── test-sigma-lint.sh      # sigma-cli --validate on all Sigma rules
    ├── test-suricata-rules.sh  # suricata --test-rules on custom rules
    └── test-render.sh          # Dry-run render for both scopes; asserts output structure + *.stub.* skip
```

## Usage

```bash
# Tier 1 — perimeter render (default scope; unchanged behavior)
bash render.sh --platform pfsense
bash render.sh --platform opnsense --dry-run
bash render.sh --platform pfsense --verbose
bash render.sh --scope tier1 --platform pfsense   # identical to the above, explicit

# Tier 3 — SIEM Security Analytics render (new)
bash render.sh --scope tier3
bash render.sh --scope tier3 --dry-run --verbose

# Both scopes in one invocation
bash render.sh --scope all --platform pfsense
```

## Tier 3 render — schema-verification caveat

Every JSON document `render-detectors.sh`/`render-correlations.sh`/
`render-actions.sh` emits carries an explicit
`"_render_meta": {"schema_verified": false, "pending": "T0a"}` marker. The
OpenSearch Security Analytics plugin's actual `_plugins/_security_analytics/*`
REST endpoint wire-format has not been live-verified against a running
OpenSearch 3.7.0 instance (plan task T0a, deferred to the Executor stage,
operator-gated). These renderers produce a **best-effort** structure from
the tier2 YAML source of truth — they do not fabricate a confirmed schema,
and they make **no live OpenSearch API calls**. T7 (a separate, later task)
performs the live import and is responsible for reconciling this best-effort
shape against whatever T0a confirms.

`render-stix2.sh` likewise renders STIX2 bundle **envelopes** only (source
metadata, MITRE-derived `kill_chain_phases`, a placeholder `pattern`) — it
does not fetch live feed content from the source URLs in `sources.yml`;
that is a live network call out of scope for local-file rendering, performed
separately by `tier3-core/scripts/apply-threat-intel.sh` at apply time.

## Output (git-ignored)

- Tier 1: `tier1-perimeter/rendered/<platform>/` — git-ignored. Run
  `make render` before every `make deploy`.
- Tier 3: `tier3-core/config/opensearch/security-analytics/**` and
  `tier2-telemetry/threat-intel/stix2/*.json` — both git-ignored build
  artifacts, regenerated on every render run.
