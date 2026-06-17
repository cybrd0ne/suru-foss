# OpenSearch Dashboards — Auto-Import Library

All `*.ndjson` files in this directory are automatically imported into
OpenSearch Dashboards on first startup (and on `deploy.sh reimport`) via the
`dashboard-importer` service. Files import in **lexical order** with
`?overwrite=true` into the **Global** tenant.

## Dashboard Inventory

| File | Dashboard title | Index pattern | Role |
|------|----------------|---------------|------|
| `00-index-patterns.ndjson` | _(canonical index patterns — imported first)_ | n/a | — |
| `01-pfsense-firewall-overview.ndjson` | SURU — Perimeter Firewall & IP Reputation | `suru-pfsense-*` | drill-down. KPI row: Total Events / Blocked / Allowed. Added: Blocked Source IPs over Time (heat map) + Top Blocked Source IPs (tag cloud). |
| `02-suricata-alerts.ndjson` | SURU — Intrusion Detection & Prevention | `suru-suricata-*` | drill-down. Added: Alerts KPI, Top Dest Ports, MITRE Techniques table, Alert Log (Discover), Alert Signatures over Time + Events by Source IP (heat maps), Top DNS Queries (tag cloud). |
| `03-zeek-network-telemetry.ndjson` | SURU — DNS, DHCP & Network Services | `suru-zeek-*` | drill-down. Added: DHCP Lease Event Log (Discover). |
| `04-pfblockerng-dnsbl.ndjson` | pfBlockerNG DNSBL / IP Reputation | `suru-pfblockerng-*` | drill-down |
| `05-siem-overview.ndjson` | **SURU — SIEM Overview** | `suru-*` | **Main landing page**. Added: Active Alerts KPI, Recent Alerts (Discover). |
| `06-suricata-per-interface.ndjson` | SURU — Suricata Per-Interface | `suru-suricata-*` | Per-interface breakdown: Events/Alerts KPIs, histogram, top source IPs, alert categories, top signatures per interface (igb1.10, igb2). |
| `07-dns-visibility.ndjson` | SURU — DNS Visibility (Zeek) | `suru-zeek-*` (`event.dataset:dns`) | drill-down. Top queries/clients (tag clouds), query-type + response-code donuts, queries-by-client heat map, NXDOMAIN triage, DNS query log. |
| `08-dhcp-visibility.ndjson` | SURU — DHCP Visibility (Zeek) | `suru-zeek-*` (`event.dataset:dhcp`) | drill-down. Operations donut + over-time, IP/MAC/hostname inventory, assigned addresses, hostname tag cloud, activity heat map, lease log. |
| `09-geoip-threat-origins.ndjson` | SURU — GeoIP Threat Origins | `suru-*` (`source.geo.country_name:*`) | drill-down, cross-source. Top source countries/ASNs, source-country heat map + tag cloud, destination countries, source cities, threat-origin log. Requires Logstash geoip enrichment (`source.geo.*`/`source.as.*`). |

**`05-siem-overview.ndjson` is the default operator entry point.** All other
dashboards are drill-down destinations reached by narrowing scope in the SIEM
Overview (filter on `event.module`, then switch dashboard).

## Canonical Index Pattern IDs

Index patterns are defined **only** in `00-index-patterns.ndjson`. No other file
embeds a `type:index-pattern` object. All visualizations reference patterns via
`references[]` using these IDs:

| ID | Pattern | Covers |
|----|---------|--------|
| `suru-pfsense-index-pattern` | `suru-pfsense-*` | pfSense firewall + services |
| `suru-ids-index-pattern` | `suru-suricata-*` | Suricata IDS/IPS + protocol telemetry |
| `suru-netservices-index-pattern` | `suru-zeek-*` | Zeek NSM |
| `suru-pfblockerng-index-pattern` | `suru-pfblockerng-*` | pfBlockerNG blocks |
| `suru-all-index-pattern` | `suru-*` | SIEM Overview (all sources) |

## Adding a New Dashboard

> **Follow the authoring rules below and in [`CONTRIBUTING.md`](../../../../CONTRIBUTING.md).**
> They are the authoring standard covering ECS field canon, MITRE annotations,
> ndjson format rules, and the pre-commit checklist. `04-pfblockerng-dnsbl.ndjson`
> is the confirmed-working reference implementation — model new dashboards on it.

Short process:
1. Assign the next sequential prefix (`06-`, `07-`, …)
2. Author ndjson modelled on `04-pfblockerng-dnsbl.ndjson` (confirmed working reference)
3. Reference only canonical index-pattern IDs from the table above
4. Never embed `type:index-pattern` objects — `00-` is the sole producer
5. Never use `input_control_vis` — broken in this OSD version
6. Add MITRE ATT&CK annotations to every security panel description
7. Update the inventory table above
8. Import: `bash tier3-core/scripts/deploy.sh reimport` — verify HTTP 200 for all files
9. Request review from a detection-content maintainer (see `CONTRIBUTING.md`)

## Re-Importing

```bash
# From tier3-core/ or repo root:
bash tier3-core/scripts/deploy.sh reimport
```

Safe to run repeatedly — `?overwrite=true` updates existing objects without
deleting data.

## Tenant

All saved objects are in the **Global** tenant. Confirm the tenant selector
(top-right user menu → "Switch tenants") is set to **Global** before opening
dashboards. Objects in the Private tenant are not managed by the importer.

## Reference Implementation

`04-pfblockerng-dnsbl.ndjson` is the canonical reference: hand-authored vislib,
no PFELK artefacts, no embedded index patterns, no `input_control_vis`, MITRE
annotations on every security panel. Confirmed working in this OSD deployment.
