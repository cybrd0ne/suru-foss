# tier2-telemetry/opensearch — Layer 2 + Layer 3 Detection Content

This directory holds the OpenSearch-Security-Analytics-specific portion of the
three-layer rule architecture defined in the SIEM Security Analytics feature plan
(see `docs/detection-coverage-map.md` once T11 lands, and the plan at
`the feature design document` for full design rationale):

```
tier2-telemetry/
  sigma/                  ← LAYER 1: canonical Sigma rules (source of truth)
  opensearch/             ← LAYER 2 + LAYER 3 (this directory)
    field-mappings/<logtype>.yml   LAYER 3: Sigma abstract field <-> concrete ECS field, per log type
    detectors/<slug>.yml           LAYER 2: binds Layer-1 rule(s) -> index pattern + schedule + exclusion predicate
    correlations/<slug>.yml        LAYER 2: cross-log-type correlation rules
    actions/<slug>.yml             LAYER 2: trigger actions (email default, perimeter_block opt-in)
```

`tier3-core` only ever imports already-rendered artifacts produced by
`tier2-telemetry/build/render.sh` (Layer 1-3 + STIX2 threat intel). It has no
knowledge of Sigma or the rule layers directly.

## Stub convention — `*.stub.*`

Files matching the glob `*.stub.*` anywhere under this directory (e.g.
`detectors/execution-persistence.stub.yml`) are **scaffolding for future-agent
extension, not deployable detection content**. They exist to reserve shape/naming
for a capability that has no live data path yet.

**Hard rule:** `tier2-telemetry/build/lib/render-tier3.sh` (T3, a separate task)
MUST glob-exclude `*.stub.*` from every render pass. A `.stub.` file must never be
rendered into `tier3-core/config/opensearch/security-analytics/**` and must never
be imported into a live OpenSearch cluster. This is the only mechanism preventing
a stub skeleton from accidentally going live.

A field-mapping file can also be "stub-status" without the `.stub.` filename
suffix (e.g. `field-mappings/suru_endpoint.yml`) when it documents a real future
log-type schema rather than acting as a Layer-2 binding target. In that case the
file's own header carries an explicit `[STUB: ...]` marker and a `status:
stub-unconfirmed` field, and every individual field mapping is marked
`confirmed: false`. Any detector/correlation that references such a file is
itself required to use the `.stub.` suffix — see
`detectors/execution-persistence.stub.yml` for the paired example.

## Current stub: endpoint execution & persistence (TA0002 / TA0003)

| File | Status |
|------|--------|
| `field-mappings/suru_endpoint.yml` | Stub — every ECS mapping unconfirmed; no live index |
| `detectors/execution-persistence.stub.yml` | Stub — skeleton only, not deployable |

**Why this is stubbed:** the architect's research (read live: only
`tier2-telemetry/edr-agent/ossec.conf.template` exists; no EDR Manager, no
EDR agent-to-OpenSearch output plugin, no `suru-endpoint-*` index in the running
cluster) confirmed there is no endpoint telemetry data source today. EDR agent
Agent's role is currently EDR-agent telemetry collection only, with OpenSearch
Security Analytics as the sole correlation/detection engine once that path is
wired up — per the operator decision recorded in the feature plan.

**Where a future agent resumes this work:**
1. Wire an actual EDR agent -> OpenSearch ingestion path (new work,
   not currently planned in this feature's task list — track as a new plan/task).
2. Confirm the live index name and read a real alert payload — do not guess.
3. Rewrite `field-mappings/suru_endpoint.yml` against the confirmed payload shape,
   flipping `confirmed: true` per mapping as each is verified against
   `tier3-core/config/opensearch/suru-ecs-template.json`.
4. Author real Layer-1 Sigma rules under `tier2-telemetry/sigma/rules/execution/`
   and `tier2-telemetry/sigma/rules/persistence/`.
5. Split `detectors/execution-persistence.stub.yml` into individual non-stub
   detector files, one per confirmed Sigma rule, following the pattern used by
   the buildable categories (reconnaissance, initial-access, c2, exfiltration,
   defense-evasion).
6. Only after a live-detection confirmation (inject a known-matching event,
   confirm a finding — per CONTRIBUTING.md) should
   the `.stub.` suffix be dropped and the detector included in T3's render pass.

## Verification

Non-stub files in this directory follow the standard per-artifact checks in
CONTRIBUTING.md (`sigma check`, ECS field-existence
greps against `suru-ecs-template.json`, JSON/YAML validity). Stub files are
intentionally **not** run through `sigma check` or live-index verification —
see each stub file's own header for rationale.
