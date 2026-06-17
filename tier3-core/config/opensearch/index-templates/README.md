# OpenSearch Index Templates

---

## suru-ecs-template.json

**Applies to:** all indices matching `suru-*`

**Purpose:** Enforces ECS v8 field mappings and ILM policy on every SURU index.

### Key Mappings

| Field | Type | Notes |
|-------|------|-------|
| `@timestamp` | `date` | ISO 8601 with milliseconds |
| `event.kind` | `keyword` | `event`, `alert`, `metric`, `state`, `signal` |
| `event.category` | `keyword` | Array — ECS taxonomy |
| `event.type` | `keyword` | Array — ECS taxonomy |
| `event.module` | `keyword` | Source module name |
| `host.name` | `keyword` | Originating host |
| `source.ip` | `ip` | Native IP type for CIDR queries |
| `destination.ip` | `ip` | Native IP type |
| `source.geo.*` | `geo_point` / `keyword` | GeoIP enrichment fields |
| `rule.id` | `keyword` | Firewall rule number / Suricata SID |
| `threat.technique.id` | `keyword` | MITRE technique ID (e.g. T1071) |
| `threat.tactic.id` | `keyword` | MITRE tactic ID (e.g. TA0011) |
| `suru.log_type` | `keyword` | SURU routing tag — not in ECS spec |
| `suru.tier` | `keyword` | Source tier — not in ECS spec |

### Applying the Template

```bash
export PASS="$(grep OPENSEARCH_INITIAL_ADMIN_PASSWORD ../../.env | cut -d= -f2)"

curl -k -u "admin:${PASS}" \
  -X PUT "https://localhost:9200/_index_template/suru-ecs" \
  -H 'Content-Type: application/json' \
  -d @suru-ecs-template.json
```

### Adding a New Index Pattern

If a new log source requires field types that conflict with this template,
create a separate file `suru-<source>-template.json` with a higher `priority`
value (default template priority is `100`).

See [`../../docs/extending.md`](../../docs/extending.md) REQ-015.
