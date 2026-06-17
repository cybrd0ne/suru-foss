# tier2-telemetry/suricata — Suricata Security Policy

This directory is the **authoritative source** for all Suricata security-policy decisions.
It is consumed by the Tier 1 render pipeline (`tier2-telemetry/build/render.sh`) to produce
deployment-ready artefacts in `tier1-perimeter/rendered/`.

## Directory Layout

```
suricata/
├── rule-selection/      # Which SIDs to force-enable or suppress (suricata-update modifiers)
│   ├── enable.conf      # Force-enable specific SIDs
│   └── disable.conf     # Suppress SIDs / rule groups with high FP rate
├── update-policy/       # suricata-update source and feed configuration
│   └── update.yaml
├── custom-rules/        # SURU-authored detection rules (not from upstream feeds)
│   └── *.rules          # Each file named by tactic/technique area
└── thresholds/          # Rate-limit and suppression thresholds
    └── threshold.conf
```

## Invariant

> **T2 is the sole authority for security policy.**
> Rule selection, feed sources, custom rules, and thresholds MUST live here.
> `tier1-perimeter/` MUST NOT contain security-policy decisions.

## Custom Rule SID Block

SURU project-local SIDs are allocated from **9990000–9999999**.  
This range does not overlap with ET Open (1000000–2999999) or Talos/registered ranges.  
Never use SIDs outside this block in `custom-rules/`.

## MITRE ATT&CK Coverage

All custom rules MUST include a comment with `TA####` and `T####` identifiers.
See `custom-rules/` for examples.

## Validation

```bash
# Validate custom rules syntax
suricata --test-rules -c /etc/suricata/suricata.yaml -S custom-rules/*.rules

# Preview suricata-update with this policy (no write)
suricata-update --config update-policy/update.yaml --no-merge --no-test
```
