# SURU — Tier 3 / datalake

This group manages the **data persistence layer** for the SURU platform.
Each sub-directory is an independently deployable storage engine.

## Structure

```
datalake/
├── opensearch/          ← Active: OpenSearch + Dashboards
│   ├── compose.yaml
│   └── Dockerfile.opensearch
│
└── elasticsearch/       ← Placeholder: add compose.yaml to enable
```

## Adding a New Engine

1. Create `datalake/<engine>/compose.yaml`
2. Follow the naming convention: `suru.t3.datalake.<engine>.*`
3. Add `"datalake/<engine>"` to `ALL_GROUPS` in `deploy.sh`
4. Ensure the engine joins the `suru-t3-core-internal` external network

## Active Engine: opensearch

- OpenSearch node (`suru.t3.datalake.opensearch`) — primary index store
- OpenSearch Dashboards (`suru.t3.datalake.dashboards`) — visualization layer
- Dashboard importer (`suru.t3.datalake.dashboard-importer`) — one-shot NDJSON loader
- Security init (`suru.t3.datalake.security-init`) — seeds `.opendistro_security` index
