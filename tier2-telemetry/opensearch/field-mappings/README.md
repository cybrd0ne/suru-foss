# Field Mappings — Layer 3 ECS Bridge

## Purpose

This directory is **Layer 3** of the tier2-telemetry three-layer rule
architecture (canonical Sigma → OpenSearch detector binding → ECS
field-mapping bridge):

```
Layer 1  tier2-telemetry/sigma/rules/**            canonical Sigma rules, abstract field names
Layer 2  tier2-telemetry/opensearch/detectors/**   binds Layer-1 rule(s) → index pattern + schedule
Layer 3  tier2-telemetry/opensearch/field-mappings/**  <- this directory
Layer 2  tier2-telemetry/opensearch/correlations/**  cross-log-type correlation rules
Layer 2  tier2-telemetry/opensearch/actions/**       trigger actions (email default, perimeter_block opt-in)
```

Each file in this directory maps the Sigma-abstract field names used by
Layer 1 rules to the concrete ECS v8 field path emitted by this
deployment's tier3-core Logstash pipelines for one log type. This is the
file that makes Layer 1's abstract field names resolvable against real
data — without it, a Sigma rule referencing e.g. `dns.question.name`
has no defined mapping to OpenSearch Security Analytics' custom-log-type
field model, and silently produces zero detections (see plan risk R2).

OpenSearch Security Analytics' custom-log-type field-mapping is consumed
as a JSON wire-format payload. The YAML here is **not** that wire format —
it is a flat, hand-authorable `{raw_field, ecs_field}` list. Converting
this YAML into the OpenSearch JSON payload is tier2's `build/render.sh`
render step (T3), not a concern of this directory.

## One mapping file per log type

| File | Log type | Index pattern | Source |
|------|----------|----------------|--------|
| `suru_suricata.yml` | Suricata EVE (alert/dns/http/tls sub-events) | `suru-suricata-*` | Suricata IDS/IPS |
| `suru_zeek_dns.yml` | Zeek `dns.log` | `suru-zeek-*` (`event.dataset:"dns"`) | Zeek NSM |
| `suru_zeek_conn.yml` | Zeek `conn.log` | `suru-zeek-*` (`event.dataset:"conn"`) | Zeek NSM |
| `suru_zeek_ssl.yml` | Zeek `ssl.log` + TLS-relevant `notice.log`/`weird.log` | `suru-zeek-*` (`event.dataset:"ssl"/"notice"/"weird"`) | Zeek NSM |
| `suru_pfsense_fw.yml` | pfSense `filterlog` firewall events | `suru-pfsense-firewall-*` | pfSense/OPNsense |
| `suru_pfblockerng.yml` | pfBlockerNG DNSBL / IP-reputation blocks | `suru-pfblockerng-*` | pfBlockerNG |

`suru_endpoint.yml` (T1c) is the future-agent endpoint stub — it
intentionally references ECS fields (`process.*`, `file.*`, `registry.*`,
`user.name`) not yet present in `suru-ecs-template.json`, because no
endpoint telemetry is ingested today (coverage category 6, stub-only).
It is not validated against the live template for that reason and is
owned by a separate task; do not edit it from this convention without
coordinating with that owner.

**Convention:** one file per log type, named `<log_type>.yml` matching
the `log_type` value inside the file and the eventual OpenSearch
custom-log-type name. Splitting a single Zeek index (`suru-zeek-*`) into
per-`event.dataset` files (`suru_zeek_dns.yml`, `suru_zeek_conn.yml`,
`suru_zeek_ssl.yml`) mirrors how `event.dataset` discriminates sub-types
within that one physical index, and how Security Analytics custom log
types are scoped — each detector binds to one log type's field set, not
an entire shared index's superset of fields.

## File schema

```yaml
log_type: <name>            # matches the eventual OpenSearch custom-log-type
index_pattern: <pattern>    # the suru-* index pattern this log type lives in
description: >
  Human-readable description of the source pipeline and event.dataset scoping.

mappings:
  - raw_field: <sigma-abstract-or-source-field-name>
    ecs_field: <dotted ECS v8 path>
  - ...
```

`raw_field` is the Sigma-abstract / source-field name a Layer 1 rule or
Layer 2 detector references. `ecs_field` is the concrete dotted ECS path
that field resolves to in the live `suru-*` index, per
`tier3-core/config/opensearch/index-templates/suru-ecs-template.json`
and `tier2-telemetry/opensearch/field-mappings/README.md` (the ECS field canon).

## Validation

Every `ecs_field` value in every file (except the explicitly stubbed
`suru_endpoint.yml`) MUST exist in `suru-ecs-template.json` or in the
documented field tables of `tier2-telemetry/opensearch/field-mappings/README.md`.
Run before commit:

```bash
python3 - <<'PYEOF'
import yaml, json, re, glob

template_path = "tier3-core/config/opensearch/index-templates/suru-ecs-template.json"
dash_path = "`tier2-telemetry/opensearch/field-mappings/README.md`"

with open(template_path) as fh:
    lines = fh.readlines()
start = next(i for i, l in enumerate(lines) if l.strip().startswith("{"))
tmpl = json.loads("".join(lines[start:]))

def walk(props, prefix, out):
    for k, v in props.items():
        path = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict) and "properties" in v:
            walk(v["properties"], path, out)
        else:
            out.add(path)
    return out

known = walk(tmpl["template"]["mappings"]["properties"], "", set())
known |= {"@timestamp", "tags", "in_iface"}

with open(dash_path) as fh:
    dash_fields = set(re.findall(r"`([a-zA-Z_][a-zA-Z0-9_.]*)`", fh.read()))

for path in sorted(glob.glob("tier2-telemetry/opensearch/field-mappings/*.yml")):
    if path.endswith("suru_endpoint.yml"):
        continue
    with open(path) as fh:
        data = yaml.safe_load(fh)
    missing = [m["ecs_field"] for m in data["mappings"]
               if m["ecs_field"] not in known and m["ecs_field"] not in dash_fields]
    status = "OK" if not missing else f"MISSING {missing}"
    print(f"{path}: {len(data['mappings'])} mappings - {status}")
PYEOF
```

## Adding a new log type

1. Identify the `event.dataset` (or dedicated index pattern) the new
   source uses, per `tier2-telemetry/opensearch/field-mappings/README.md`.
2. Create `<log_type>.yml` following the schema above.
3. Run the validation script and confirm zero `MISSING` entries.
4. Reference the new `log_type` from the relevant Layer 2 detector(s)
   in `tier2-telemetry/opensearch/detectors/`.
5. Update the table in this README in the same PR.
