# Tier 3 — Deployment Guide

---

## Prerequisites Checklist

```bash
# Verify Docker Compose v2
docker compose version   # must be 2.x+

# Verify OpenSSL for cert generation
openssl version          # 3.x recommended

# Verify available RAM
free -h                  # 8 GB minimum, 16 GB recommended
```

---

## Step-by-Step Deployment

### 1. Generate SURU Root CA and Service Certificates

```bash
bash scripts/generate-certs.sh
```

This creates under `certs/`:
- `root-ca.pem` / `root-ca-key.pem` — SURU Root CA (keep the key secure)
- `logstash-server.pem` / `logstash-server-key.pem` — Logstash TLS server identity
- `opensearch-node.pem` / `opensearch-node-key.pem` — OpenSearch node TLS

The Root CA is required by Tier 1 (`tier1-perimeter/scripts/deploy.sh`) to issue
client certificates for syslog-ng mTLS.

### 2. Configure Environment

```bash
cp .env.example .env
$EDITOR .env
```

Mandatory variables to set:

| Variable | Description |
|----------|-------------|
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | Min 12 chars, 1 upper, 1 digit, 1 special |
| `LOGSTASH_OPENSEARCH_PASSWORD` | Logstash writer account password |
| `SIEM_HOST` | IP/hostname of this machine (used in cert SANs) |

### 3. Start the Datalake (OpenSearch)

```bash
docker compose -f datalake/opensearch/compose.yaml up -d

# Wait for OpenSearch to be healthy
docker compose -f datalake/opensearch/compose.yaml ps
# opensearch-node1   healthy
# opensearch-dashboards   healthy
```

### 4. Apply Security Configuration

```bash
# Push RBAC config to running OpenSearch
docker exec opensearch-node1 \
  /usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh \
  -cd /usr/share/opensearch/config/opensearch-security/ \
  -icl -nhnv \
  -cacert /usr/share/opensearch/config/certs/root-ca.pem \
  -cert  /usr/share/opensearch/config/certs/admin.pem \
  -key   /usr/share/opensearch/config/certs/admin-key.pem
```

### 5. Apply ECS Index Template

```bash
curl -k -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" \
  -X PUT "https://localhost:9200/_index_template/suru-ecs" \
  -H 'Content-Type: application/json' \
  -d @config/opensearch/index-templates/suru-ecs-template.json
```

### 6. Start Logstash

```bash
docker compose -f ingestion/logstash/compose.yaml up -d

# Verify pipeline loaded
docker logs logstash 2>&1 | grep -E 'Pipeline started|error'
```

### 7. Start Monitoring (Tier 4 Operations)

Monitoring has moved to `tier4-operations/monitoring/` as part of the Tier 4
control-plane split. Bring it up after tier3-core's datalake is healthy:

```bash
docker compose -f ../tier4-operations/monitoring/compose.yaml up -d
```

### 8. Import Dashboards

```bash
bash scripts/import-dashboards.sh
# Dashboards available at https://<SIEM_HOST>:5601
```

### 9. Recovery: Admin-Credential Seed/Repair or Empty Dashboards

`scripts/deploy.sh start` automatically detects and repairs two failure modes
on every run against the `datalake/opensearch` group:

- **Admin credential mismatch** — detected via a `/_cluster/health` probe;
  on a definitive `401` it re-runs `security-init` with `--no-deps`, since
  `securityadmin.sh` authenticates via the admin mTLS client cert, not the
  REST password. This covers two distinct triggers that present identically:
  - **Fresh bootstrap** — `DISABLE_INSTALL_DEMO_CONFIG=true` disables the
    image's only password-substitution mechanism, so a brand-new
    `opensearch-data` volume's security index seeds with the image's bundled
    default credential, not `OPENSEARCH_INITIAL_ADMIN_PASSWORD`.
  - **Drift against a surviving volume** — e.g. `.env`'s
    `OPENSEARCH_INITIAL_ADMIN_PASSWORD` was rotated but the existing security
    index still has the old hash.

  The probe/repair is unconditional (not gated on whether the volume
  pre-existed) — disable with `--no-repair-security`.
- **Empty `.kibana`** after the dashboard-importer runs — verified via
  `_find?type=dashboard&per_page=1` `.total > 0` (not just that the API
  answered). One automatic reimport retry; hard-fails if still empty.

For a manual, single-command recovery (e.g. after a failed deploy or a
suspected password mismatch), run:

```bash
bash scripts/deploy.sh repair
```

This re-syncs the security index, re-applies index templates and ISM
policies, waits for Dashboards to be healthy, re-runs the dashboard importer,
and verifies the import actually populated `.kibana`.

---

## Makefile Targets

A `Makefile` is planned for the root of `tier3-core/`. Current operations
use the scripts directly. Planned targets:

| Target | Description |
|--------|-------------|
| `make up` | Bring up full SIEM stack in correct dependency order |
| `make down` | Graceful shutdown all stacks |
| `make certs` | Regenerate all certificates |
| `make validate` | Validate all Logstash pipeline configs |
| `make lint` | shellcheck all scripts |
| `make index-template` | Push ECS index template to OpenSearch |
| `make dashboards` | Import OpenSearch Dashboards saved objects |
| `make health` | Check health of all services |
| `make logs` | Tail logs from all containers |

---

## Deployment Flow (scripts/deploy.sh)

```
deploy.sh
  │
  ├─[1] preflight()          Docker available, .env loaded, certs present
  ├─[2] start_datalake()     docker compose up opensearch → wait for :9200
  ├─[3] apply_security()     securityadmin.sh RBAC bootstrap
  ├─[4] apply_templates()    PUT /_index_template/suru-ecs
  ├─[5] start_ingestion()    docker compose up logstash → wait pipeline ready
  ├─[6] start_monitoring()   docker compose up prometheus grafana
  ├─[7] import_dashboards()  scripts/import-dashboards.sh
  └─[8] verify()             curl /healthz on each service, log result

  ERR trap → rollback():     docker compose down all stacks, preserve cert/data volumes
```

---

## Ongoing Operations

Some capabilities require scheduled maintenance tasks that run on the SIEM
host after the initial deployment. Without these, the relevant features
silently degrade.

### Daily: Security Analytics index alias rotation (00:10 UTC)

Security Analytics detectors query data through stable index aliases
(`suru-zeek-current`, `suru-suricata-current`). Logstash rolls to a new
dated index each midnight UTC. The aliases must be rotated daily or detectors
query stale data and produce no alerts.

**Schedule on the SIEM host:**

```bash
# /etc/cron.d/suru-alias-rotate  (runs as root, 00:10 UTC)
10 0 * * * root \
  OPENSEARCH_INITIAL_ADMIN_PASSWORD="$(cat /etc/suru/opensearch-pass)" \
  /opt/suru/tier3-core/scripts/rotate-sa-aliases.sh \
  >> /var/log/suru-alias-rotate.log 2>&1
```

Or as a user crontab entry (`crontab -e`):
```
OPENSEARCH_INITIAL_ADMIN_PASSWORD=<password>
10 0 * * * /opt/suru/tier3-core/scripts/rotate-sa-aliases.sh >> /var/log/suru-alias-rotate.log 2>&1
```

**Verify aliases are current:**
```bash
docker exec suru.t3.datalake.opensearch \
  curl -sk -u admin:$PASS \
  "https://localhost:9200/_cat/aliases/suru-zeek-current,suru-suricata-current?v"
```

Both aliases must show today's `suru-<type>-YYYY.MM.dd` index. If either is
stale, run `bash tier3-core/scripts/rotate-sa-aliases.sh --verbose` manually.
The script is idempotent — safe to re-run at any time.

See `tier3-core/scripts/rotate-sa-aliases.sh` for full options and
`tier3-core/docs/security-analytics.md` §"Operational Requirements" for
background on why this is necessary.

---

## Environment Variables

See [`.env.example`](../.env.example) for the full annotated list.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | ✅ | — | OpenSearch admin password |
| `LOGSTASH_OPENSEARCH_PASSWORD` | ✅ | — | Logstash → OpenSearch writer password |
| `SIEM_HOST` | ✅ | — | Hostname/IP for cert SANs and Dashboards URL |
| `OPENSEARCH_PORT` | — | `9200` | OpenSearch REST port |
| `DASHBOARDS_PORT` | — | `5601` | Dashboards UI port |
| `LOGSTASH_SYSLOG_PORT` | — | `5140` | mTLS syslog input port |
| `LOGSTASH_BEATS_PORT` | — | `5044` | Beats input port |
| `OPENSEARCH_HEAP` | — | `1g` | JVM heap for OpenSearch |
| `LOGSTASH_HEAP` | — | `512m` | JVM heap for Logstash |
| `GEO_DB_PATH` | — | `/usr/share/GeoIP` | Path to MaxMind GeoLite2 databases |

---

## Upgrade Procedure

1. Pull latest images: `docker compose pull` in each subsystem directory
2. Validate config changes against new version release notes
3. Run `make validate` (Logstash pipeline syntax check)
4. Rolling restart: datalake → ingestion → monitoring
5. Verify index template compatibility: `GET /_index_template/suru-ecs`
6. Check index mappings for breaking field type changes

---

## Backup and Recovery

| Data | Location | Backup Method |
|------|----------|---------------|
| OpenSearch indices | Docker volume `opensearch-data` | OpenSearch snapshot API → S3/MinIO |
| OpenSearch config | `config/opensearch/` | Git (this repo) |
| Logstash pipelines | `config/logstash-*/pipelines/` | Git (this repo) |
| Certificates | `certs/` | Encrypted backup (SOPS/age) — gitignored |
| Dashboards | `config/opensearch/dashboards/` | `scripts/import-dashboards.sh` export |
