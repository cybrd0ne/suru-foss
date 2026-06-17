# Tier 3 — Architecture

> **AI-CONTEXT:** This document is the authoritative architectural reference for
> `tier3-core`. An AI agent starting a new thread should read this file first,
> then `deployment.md`, then `pipelines.md`.

---

## Service Topology

```
┌─────────────────────────────────────────────────────────────────────────┐
│  TIER 3 — CORE SIEM HOST  (Linux, Docker Compose v2)                   │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  INGESTION LAYER                                                  │  │
│  │                                                                   │  │
│  │  ┌──────────────────────────────────────────────────────────┐   │  │
│  │  │  Logstash  (ingestion/logstash/compose.yaml)              │   │  │
│  │  │  • Port 5140/tcp  — mTLS syslog-ng input (Tier 1/2)      │   │  │
│  │  │  • Port 5044/tcp  — Beats input (optional)               │   │  │
│  │  │  • Port 9600/tcp  — Logstash monitoring API              │   │  │
│  │  │  • Config: config/logstash-pfsense/  (pfSense mTLS mode)  │   │  │
│  │  │  • Config: config/logstash-opnsense/ (OPNsense UDP mode)  │   │  │
│  │  └──────────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                               │ ECS v8 JSON (HTTP)                      │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  DATALAKE LAYER                                                   │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────┐  ┌───────────────────────────┐ │  │
│  │  │  OpenSearch Node            │  │  OpenSearch Dashboards    │ │  │
│  │  │  (datalake/opensearch/)     │  │  (datalake/opensearch/)   │ │  │
│  │  │  • Port 9200/tcp REST       │  │  • Port 5601/tcp HTTP     │ │  │
│  │  │  • Port 9300/tcp Transport  │  │  • Saved searches         │ │  │
│  │  │  • TLS 1.3 (mTLS nodes)     │  │  • Alert dashboards       │ │  │
│  │  │  • RBAC (security plugin)   │  │  • Drilldown views        │ │  │
│  │  │  • ILM: 30d hot / 90d warm  │  └───────────────────────────┘ │  │
│  │  └─────────────────────────────┘                                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                               │ API                                     │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  DETECTION & RESPONSE LAYER                                       │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────┐  ┌───────────────────────────┐ │  │
│  │  │  OpenSearch Alerting        │  │  Detection Content        │ │  │
│  │  │  (config/opensearch/)       │  │  (tier2-telemetry/)       │ │  │
│  │  │  • Saved monitors           │  │  • Suricata rules         │ │  │
│  │  │  • Threshold + KQL alerts   │  │  • Sigma rules            │ │  │
│  │  │  • MITRE ATT&CK mapping     │  │  • pfBlockerNG feeds      │ │  │
│  │  │  • Dashboard drilldown      │  │  • GeoIP enrichment       │ │  │
│  │  └─────────────────────────────┘  └───────────────────────────┘ │  │
│  │                                                                   │  │
│  │  Note: Monitoring (Prometheus/Grafana) has moved to Tier 4        │  │
│  │  (tier4-operations/monitoring/) per the operations split.         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
          ▲ mTLS syslog (port 5140)          ▲ Beats (port 5044, optional)
          │                                  │
   pfSense / Tier 1              Endpoint agents (optional)
```

---

## Data Flow — Full Pipeline

```
[pfSense syslog-ng]
  │  protocol : TCP/TLS 1.3
  │  auth     : mTLS (client cert signed by SURU Root CA)
  │  format   : RFC 5424 syslog envelope wrapping raw log line
  │  port     : 5140
  ▼
[Logstash — 00-input-beats-tls.conf]
  │  • Terminates TLS, validates client cert against SURU Root CA
  │  • Parses RFC 5424 header → @timestamp, host.name, syslog.facility
  │  • Tags event with suru.source = "pfsense"
  ▼
[Logstash — routing by suru.log_type]
  ├─ "firewall"    → 10-pfsense-firewall.conf
  │     grok: PF BSD log format
  │     ECS: event.{action,category,type}, network.{protocol,transport}
  │           source.{ip,port,geo}, destination.{ip,port,geo}
  │           rule.id, observer.ingress.interface.name
  │     MITRE: TA0001 Initial Access, TA0011 C2
  │
  ├─ "dhcp"        → 11-pfsense-services.conf
  │     ECS: network.type, client.ip, client.mac, dhcp.*
  │
  ├─ "dns"         → 11-pfsense-services.conf
  │     ECS: dns.{question,answers,response_code}, network.protocol
  │
  ├─ "vpn"         → 11-pfsense-services.conf
  │     ECS: event.{action,category}, user.name, network.tunnel
  │
  ├─ "auth"        → 11-pfsense-services.conf
  │     ECS: event.category=["authentication"], user.name, event.outcome
  │
  ├─ "suricata"    → 20-suricata-eve.conf
  │     JSON passthrough + ECS mapping
  │     ECS: rule.{id,name,category}, threat.{indicator,technique}
  │     MITRE: annotated per Suricata rule metadata
  │
  ├─ "zeek"        → 30-zeek.conf
  │     ECS: network.*, tls.*, http.*, dns.*, file.*
  │     log types: conn, dns, http, ssl, notice, weird, files, x509
  │
  ├─ "pfblockerng" → 40-pfblockerng.conf
  │     ECS: threat.indicator.*, dns.question.name
  │     MITRE: TA0043 Reconnaissance
  │
  └─ [unmatched]   → 90-deadletter.conf
        index: suru-deadletter-YYYY.MM.DD
  ▼
[OpenSearch — index: suru-<type>-YYYY.MM.DD]
  │  ILM policy : 30d hot → 90d warm → delete
  │  Template   : suru-ecs-template.json (ECS v8 mappings)
  ▼
[OpenSearch Dashboards — :5601]
  Visualisation, saved searches, alerting rules
```

---

## Network Segments

| Docker Network | Name | Connected Services |
|----------------|------|--------------------|
| Ingest | `suru-t3-ingestion` | Logstash (external-facing) |
| Core internal | `suru-t3-core-internal` | Logstash → OpenSearch |
| Monitoring | `suru-t4-monitoring-internal` | Prometheus, Grafana, exporters — owned by `tier4-operations/monitoring/`, attaches to `suru-t3-core-internal` |

All cross-service traffic inside Docker networks uses TLS 1.3 with mTLS where supported.
No service binds to `0.0.0.0` without a firewall rule allowing only the SURU management host.

---

## Index Naming Convention

```
suru-pfsense-firewall-YYYY.MM.DD      pfSense firewall filter events
suru-pfsense-services-YYYY.MM.DD     pfSense DHCP / DNS / VPN / auth events
suru-suricata-YYYY.MM.DD             Suricata EVE JSON alerts + metadata
suru-zeek-YYYY.MM.DD                 Zeek network telemetry (all log types)
suru-pfblockerng-YYYY.MM.DD         pfBlockerNG DNSBL + IP reputation blocks
suru-audit-YYYY.MM.DD               Privileged action audit trail
suru-deadletter-YYYY.MM.DD          Unmatched / parse-failed events
```

---

## ECS Version Contract

All events stored in OpenSearch **must** conform to **ECS v8**.
The Logstash pipelines are the enforcement point — no raw/un-normalised events
reach the data store. The `suru-ecs-template.json` index template enforces
strict field type mappings and rejects documents with type violations.

Key mandatory fields on every document:

| ECS Field | Type | Source |
|-----------|------|--------|
| `@timestamp` | date | syslog header / EVE timestamp |
| `event.kind` | keyword | pipeline-set (event, alert, metric) |
| `event.category` | keyword[] | pipeline-set |
| `event.type` | keyword[] | pipeline-set |
| `event.module` | keyword | pipeline-set (pfsense, suricata, zeek, …) |
| `host.name` | keyword | syslog source hostname |
| `observer.type` | keyword | firewall / ids / network-sensor |
| `suru.log_type` | keyword | SURU internal routing tag |
| `suru.tier` | keyword | always `tier1` for pfSense events |

---

## Graceful Degradation

Tier 3 is designed so that each subsystem degrades independently:

- **OpenSearch down** → Logstash buffers to disk (persistent queue, 1 GB default)
- **Monitoring down** → SIEM fully functional; only Grafana visibility is lost
- **Logstash pipeline crash** → Dead-letter queue captures failed events
- **Tier 1 / pfSense down** → OpenSearch retains historical data; no new ingestion
