# Logstash pfSense Pipelines

> **AI-CONTEXT:** This directory contains the production Logstash pipelines for
> processing pfSense telemetry forwarded via syslog-ng over mTLS.
> All pipelines normalise events to **ECS v8** before writing to OpenSearch.

---

## Pipeline Execution Order

```
00-input-beats-tls.conf      ← TLS input, RFC 5424 parse, routing tag
        │
        ├── suru.log_type = "firewall"    → 10-pfsense-firewall.conf
        ├── suru.log_type = "dhcp"        → 11-pfsense-services.conf
        ├── suru.log_type = "dns"         → 11-pfsense-services.conf
        ├── suru.log_type = "vpn-*"       → 11-pfsense-services.conf
        ├── suru.log_type = "auth"        → 11-pfsense-services.conf
        ├── suru.log_type = "suricata"    → 20-suricata-eve.conf
        ├── suru.log_type = "zeek"        → 30-zeek.conf
        ├── suru.log_type = "pfblockerng" → 40-pfblockerng.conf
        └── [unmatched]                   → 90-deadletter.conf
```

---

## File Reference

| File | ECS Category | OpenSearch Index |
|------|-------------|------------------|
| `00-input-beats-tls.conf` | — | (input only, no output) |
| `10-pfsense-firewall.conf` | `network` | `suru-pfsense-firewall-*` |
| `11-pfsense-services.conf` | `network`, `authentication`, `session`, `configuration` | `suru-pfsense-services-*` |
| `20-suricata-eve.conf` | `intrusion_detection` | `suru-suricata-*` |
| `30-zeek.conf` | `network` | `suru-zeek-*` |
| `40-pfblockerng.conf` | `threat` | `suru-pfblockerng-*` |
| `90-deadletter.conf` | — | `suru-deadletter-*` |

---

## Adding a New Pipeline

See [`../../docs/extending.md`](../../docs/extending.md) — REQ-001 through REQ-009.

Validation command:
```bash
docker exec logstash logstash --config.test_and_exit \
  -f /etc/logstash/pipelines/<filename>.conf
```
