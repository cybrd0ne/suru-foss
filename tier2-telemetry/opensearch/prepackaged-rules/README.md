# Pre-packaged Security Analytics Rule Selections

Single source of truth for which OpenSearch Security Analytics pre-packaged rules
SURU opts into. Mirrors the Suricata `enable.conf`/`disable.conf` pattern as structured
YAML — the operator flips `enabled: true/false` and never edits the raw rule content
(which lives in OpenSearch).

## Files

| File | SA category | SURU index | Active rules |
|---|---|---|---|
| `dns.yml` | `dns` | `suru-zeek-*` | 4 (Wannacry killswitch, B64 DNS, TXT exec, DNS tunneling) |
| `http-web.yml` | `others_web` | `suru-zeek-*` | 1 (path traversal) |
| `http-proxy.yml` | `others_proxy` | `suru-suricata-*` | 9 (malware/APT/CS UAs, WebDAV, BITS, suspicious downloads) |

## Schema

```yaml
category: dns | others_web | others_proxy
index_pattern: <suru-*-current alias>
detector_name: <suru-prepackaged-*>
detector_type: <matching SA category>
field_mapping_aliases:
  <sa-abstract-field>: <ecs-field>   # registered via _plugins/_security_analytics/mappings
rules:
  - rule_id: "<opensearch-prepackaged-rule-uuid>"
    title: "<human label>"
    enabled: true | false          # ← the ONLY field the operator changes
    level: critical | high | medium | low
    field_available: true | false  # false = field-mapping alias required; see field_mapping_note
    field_mapping_note: "..."      # present when field_available: false
    log_source: zeek_dns | zeek_http | suricata_http
    mitre:
      tactics: [{id, name}]
      techniques: [{id, name}]
    tier1_boundary: additive | exclusion-predicates-required
    rationale: "..."
    falsepositives: [...]
```

## Workflow (Workflow D6)

1. **Edit**: flip `enabled: true` or `enabled: false` on the relevant rule entry.
2. **Render**: `cd tier2-telemetry && build/render.sh --scope tier3`
   Produces `tier3-core/config/opensearch/security-analytics/prepackaged-selections/*.json`
3. **Apply**: `bash tier3-core/scripts/apply-security-analytics.sh`
   Re-creates the detector(s) in OpenSearch with the updated rule set.

## Field mapping notes

Rules with `field_available: false` rely on OpenSearch SA alias field mappings
registered via `_plugins/_security_analytics/mappings` against the target index
(e.g. `dns.question.registered_domain → dns.question.name`). These are registered
automatically by `apply-security-analytics.sh` before creating the detectors.

## Q1 confirmed (activation model)

Pre-packaged rules are activated by creating a **detector** that references them in
`pre_packaged_rules: [{id: "..."}]`. There is no per-rule enable toggle endpoint
(GET on a rule ID returns 405 with only DELETE/PUT allowed). Each manifest file maps
to one detector. Changing the `enabled` set within a file re-creates the detector
with the updated rule list (idempotent: old detector is deleted, new one created).
