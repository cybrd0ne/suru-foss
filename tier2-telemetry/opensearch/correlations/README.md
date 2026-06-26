# Correlation Rules — Layer 2 Cross-Log-Type Detection

## Purpose

This directory holds **Layer 2 correlation rules** — cross-log-type detection
configs that join two or more findings/events from different log sources
into a single incident, per the plan's "Tier 1 <-> SIEM boundary" design
(`the feature design document`, "Architecture" section).

A correlation rule is distinct from a Layer 2 detector
(`tier2-telemetry/opensearch/detectors/`): a detector raises a finding from
ONE log type/index against ONE Sigma rule binding. A correlation rule joins
findings/events across MULTIPLE log types/indices (e.g. pfBlockerNG +
Suricata + Zeek) on a shared join key within a time window, producing ONE
incident instead of N separate alerts for what is really one attack chain.

## File schema

```yaml
name: <slug>
status: buildable | stub
buildable: true | false
owner_tier: tier2-telemetry

join:
  key: <ECS field shared across all legs, e.g. source.ip>
  window_minutes: <int>      # correlation time window
  window_rationale: >
    Why this window length was chosen.

legs:
  - id: <leg-slug>
    description: >
      What this leg detects and which log source/detector it reads from.
    index_pattern: <suru-*-pattern>
    query: <KQL/DSL fragment>
    mitre:
      tactics: [{id: TA####, name: ...}]
      techniques: [{id: T####, name: ...}]

mitre:                        # chained MITRE across the whole correlation
  tactics: [...]
  techniques: [...]

actions:
  default: email
  perimeter_block: false

falsepositives: [...]

verification:
  static: passed|not_run
  live_detection_confirmed: false
  rationale: >
```

## Inventory

| File | Slug | Legs | Status |
|------|------|------|--------|
| `pfblockerng-suricata-zeek-c2-chain.yml` | UC1 headline correlation | pfBlockerNG block + Suricata C2 beacon + Zeek high-volume DNS query rate (same `source.ip`, 15 min) | Buildable now |
| `endpoint-execution-c2.stub.yml` | UC2 endpoint correlation | process-creation + outbound-to-known-bad-IOC -> execution+C2 | Stub only — no endpoint telemetry; `.stub.yml` per T1c naming convention, excluded from T3's render step |

## Validation

Every `index_pattern` and `query` field referenced must resolve against a
field confirmed in the corresponding `tier2-telemetry/opensearch/field-mappings/*.yml`
file or directly in `tier3-core/config/opensearch/index-templates/suru-ecs-template.json` /
`tier2-telemetry/opensearch/field-mappings/README.md`, per the field-mappings README's
own validation discipline. Grep-confirm before commit; do not assume a field
exists from memory of the ECS spec in the abstract
(CONTRIBUTING.md-3).

## Avoiding double-counted legs

A correlation rule's legs MUST each draw from an independent underlying
signal. If two legs would resolve to the same Layer-2 detector's finding
(same `rule.name` / same Sigma rule binding), that is not two legs of
evidence — it is one finding being matched twice by query phrasing.
`pfblockerng-suricata-zeek-c2-chain.yml`'s header documents the specific
case this was checked against in this build (DNS-entropy notice already
backing `c2-dns-tunneling-entropy.yml`).
