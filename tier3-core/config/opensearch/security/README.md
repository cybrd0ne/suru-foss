# OpenSearch Security Configuration

> **AI-CONTEXT:** This directory contains the OpenSearch Security plugin
> configuration (RBAC, users, roles). Changes to these files must be applied
> using `securityadmin.sh` — editing files alone has no effect on a running cluster.

---

## File Reference

| File | Purpose |
|------|---------|
| `config.yml` | Authentication backend (internal users DB) |
| `internal_users.yml` | User accounts with bcrypt-hashed passwords |
| `roles.yml` | SURU RBAC role definitions |
| `roles_mapping.yml` | User → role bindings |
| `action_groups.yml` | Named permission groups used in roles.yml |
| `tenants.yml` | OpenSearch Dashboards tenant definitions |
| `nodes_dn.yml` | Allowed node transport certificate DNs |

---

## Applying Changes

```bash
docker exec opensearch-node1 \
  /usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh \
  -cd /usr/share/opensearch/config/opensearch-security/ \
  -icl -nhnv \
  -cacert /usr/share/opensearch/config/certs/root-ca.pem \
  -cert   /usr/share/opensearch/config/certs/admin.pem \
  -key    /usr/share/opensearch/config/certs/admin-key.pem
```

This command must be run every time any file in this directory is changed.

---

## SURU Roles Summary

| Role | Index Access | Cluster Access | Assigned Users |
|------|-------------|----------------|----------------|
| `suru_admin` | `suru-*` all, `.opendistro*` all | Full | `admin` |
| `suru_ingest` | `suru-*` write | `cluster:monitor/main` | `logstash` |
| `suru_analyst` | `suru-*` read | `cluster:monitor/health` | `analyst` |
| `suru_readonly` | `suru-*` read | none | `readonly` |

---

## Password Management

Passwords are **never** stored in plaintext in these files.
All passwords are bcrypt hashed (cost factor 12).

To generate a new bcrypt hash:
```bash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'<password>', bcrypt.gensalt(12)).decode())"
# or:
htpasswd -nbB -C 12 "" "<password>" | cut -d: -f2
```

Update `internal_users.yml` with the new hash, then re-apply with `securityadmin.sh`.

---

## Security Notes

- `admin` user credentials must never be used in application code (Logstash)
- Application service account (`logstash`) uses `suru_ingest` role only
- `admin.pem` client cert is only for `securityadmin.sh` — not mounted in any service container
- All passwords sourced from `.env` at container start — never hardcoded in compose files
