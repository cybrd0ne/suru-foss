# SURU — Tier 3 / ingestion

This group manages the **log and event ingestion layer** for the SURU platform.
Each sub-directory is an independently deployable ingestion engine.

## Structure

```
ingestion/
├── logstash/            ← Active: Logstash OSS with OpenSearch output plugin
│   └── compose.yaml
│
├── filebeat/            ← Placeholder: add compose.yaml to enable
├── packetbeat/          ← Placeholder: add compose.yaml to enable
└── winlogbeat/          ← Placeholder: add compose.yaml to enable
```

## Adding a New Ingestor

1. Create `ingestion/<engine>/compose.yaml`
2. Follow the naming convention: `suru.t3.ingestion.<engine>`
3. Add `"ingestion/<engine>"` to `ALL_GROUPS` in `deploy.sh`
4. Connect to `suru-t3-core-internal` network and point output at `suru-t3-datalake-opensearch:9200`

## Active Engine: logstash

- Listens on UDP 5140 (pfSense syslog), 5141 (Suricata EVE), 5142 (Zeek)
- Beats input on TCP 5044 (TLS)
- Pipelines: pfsense, suricata-eve, zeek-conn, pfblocker
- Normalizes all events to ECS v8 and writes to `suru-*` indices
