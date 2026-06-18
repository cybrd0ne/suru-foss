# OpenSearch Index Templates

---

## suru-ecs-template.json

**Applies to:** all indices matching `suru-*`

**Purpose:** Enforces ECS v8 field mappings and index settings on every SURU index.

### Mapping structure

All multi-segment ECS fields are declared as **nested `object` + `properties`** — never
as dotted-leaf keys. Dotted keys in `properties` are a common anti-pattern that causes
OpenSearch to store nested objects but fail to index sub-fields, producing empty dashboard
fields while the parent shows a serialized JSON blob. The template avoids this by
declaring every parent (`source`, `destination`, `event`, etc.) as an explicit object:

```json
"source": {
  "properties": {
    "ip":   { "type": "ip" },
    "port": { "type": "integer" },
    ...
  }
}
```

### Key field groups

| Group | Notable fields | Notes |
|-------|---------------|-------|
| `source` | `ip` (ip), `port` (integer), `bytes` (long), `mac` (keyword) | GeoIP: `geo.location` (geo_point), `as.number` (long) |
| `destination` | `ip` (ip), `port` (integer), `bytes` (long) | Same geo/AS structure as `source` |
| `event` | `module`, `dataset`, `kind`, `action`, `category`, `type`, `severity` (long), `ingested`/`created` (date), `original` (text) | All keyword unless noted |
| `network` | `transport`, `direction`, `protocol`, `application`, `type` | All keyword |
| `observer` | `hostname`, `type`, `vendor`, `product` + `ingress.interface.name` | All keyword |
| `rule` | `name`, `category`, `id`, `ruleset`, `index` | All keyword |
| `dns` | `rrname`, `rrtype`, `response_code`, `resolved`, `question.{name,type,class}` | All keyword |
| `dhcp` | `host_name`, `assigned_addr`, `requested_addr`, `message_types`, `domain`, `lease_time` (float) | All keyword except `lease_time` |
| `http` | `hostname`, `url`, `http_method` (keyword), `status` (long) | |
| `tls` | `sni`, `version` | All keyword |
| `threat` | `indicator.{name,type,confidence}`, `feed.name` | All keyword |
| `zeek` | `uid`, `file_source` | All keyword |
| `_suru` | `log_type`, `tier` | Custom SURU namespace |
| `service` | `type` | All keyword |
| `process` | `pid` | integer |
| `host` | `name`, `hostname` | All keyword |
| `in_iface` | (top-level) | Pure keyword, `ignore_above:1024`; **no `.keyword` sub-field** |

### Applying the Template

Applied automatically by the `template-init` one-shot container on every deployment.
To apply or update manually:

```bash
PASS=$(grep OPENSEARCH_INITIAL_ADMIN_PASSWORD ../../.env | cut -d= -f2)
BODY=$(sed -n '/^{/,$p' suru-ecs-template.json)
docker exec suru.t3.datalake.opensearch curl -sk -u "admin:${PASS}" \
  -X PUT "https://localhost:9200/_index_template/suru-ecs-template" \
  -H 'Content-Type: application/json' \
  -d "${BODY}"
```

> **Note:** template changes only affect **newly created** indices. Existing indices retain
> their current mapping. To apply the fix to existing data, reindex or wait for UTC midnight
> rollover to a new daily index.

### Adding a New Index Pattern

If a new log source requires field types that conflict with this template,
create a separate file `suru-<source>-template.json` with a higher `priority`
value (default template priority is `100`).

See [`../../docs/extending.md`](../../docs/extending.md) REQ-015.
