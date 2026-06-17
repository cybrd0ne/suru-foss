# pfREST v2 API Reference — SURU Platform

Live API: `https://{ROUTER_HOST}/api/v2`  
OpenAPI schema: `https://{ROUTER_HOST}/api/v2/schema/openapi`  
Swagger UI: `https://{ROUTER_HOST}/api/v2/documentation`  
Version tested: **pfREST v2.7.7** (pfSense 2.7.x)

## Authentication

All requests require one of:

| Method | Header | Value |
|--------|--------|-------|
| API Key (recommended for automation) | `X-API-Key` | 64-char hex key |
| JWT Bearer | `Authorization` | `Bearer <token>` |
| HTTP Basic | `Authorization` | `Basic <base64(user:pass)>` |

API keys are issued per user in pfSense → System → REST API. The `suru-validator` user + key are bootstrapped by `tier1-perimeter/scripts/lib/api.sh` (`api_pfsense_bootstrap_validator`).

## Endpoint Conventions

pfREST v2 uses two endpoint types per resource:

| Type | Path pattern | Purpose |
|------|-------------|-------|
| **Singular** | `/resource_name` (singular) | Single-object CRUD |
| **Plural** | `/resource_names` (plural) | Collection list / bulk ops |

### ID handling (IMPORTANT — differs from OpenAPI spec)

The OpenAPI spec at `/schema/openapi` incorrectly documents `id` as `in=query` for DELETE. **Confirmed correct behaviour:**

| Method | Where `id` goes | Notes |
|--------|----------------|-------|
| GET (singular) | `?id=N` query param | |
| PATCH | JSON request body `{"id": N, ...}` | |
| DELETE | JSON request body `{"id": N, ...}` | spec says query, body is correct |

Sending `?id=N` on DELETE returns `400 MODEL_REQUIRES_ID`. The id **must** be in the body.

### `apply` parameter

DELETE and PATCH accept `"apply": true` in the JSON body. When set, pfREST immediately reloads the affected service (e.g. Unbound for DNS changes) after writing the config. POST (create) does **not** support `apply`; use `POST /services/dns_resolver/apply` afterwards.

### Response envelope

```json
{
  "code": 200,
  "status": "ok",
  "response_id": "SUCCESS",
  "message": "",
  "data": { ... }
}
```

Error example:
```json
{
  "code": 400,
  "status": "bad request",
  "response_id": "MODEL_REQUIRES_ID",
  "message": "Field `id` is required.",
  "data": []
}
```

---

## DNS Resolver (Unbound) — Host Overrides

Used by `tier4-operations/scripts/register-dns.sh` to publish `FRONTDOOR_FQDN → FRONTDOOR_IP` on the LAN router so Windows clients (no mDNS) can resolve it.

### List all

```
GET /api/v2/services/dns_resolver/host_overrides
```

Query params (all optional): `limit`, `offset`, `sort_by`, `sort_order`, `query`

Response `data[]` fields: `id` (int), `host`, `domain`, `ip` (array), `descr`, `aliases`

### Read one

```
GET /api/v2/services/dns_resolver/host_override?id=N
```

### Create

```
POST /api/v2/services/dns_resolver/host_override
Content-Type: application/json

{
  "host": "suru",
  "domain": "local",
  "ip": ["192.168.100.199"],
  "descr": "..."
}
```

No `apply` parameter. Call `POST /apply` afterwards (see below).

### Update

```
PATCH /api/v2/services/dns_resolver/host_override
Content-Type: application/json

{
  "id": 11,
  "host": "suru",
  "domain": "local",
  "ip": ["192.168.100.199"],
  "descr": "...",
  "apply": true
}
```

### Delete

```
DELETE /api/v2/services/dns_resolver/host_override
Content-Type: application/json

{"id": 11, "apply": true}
```

`apply: true` reloads Unbound immediately. Without it, the record is deleted from config but Unbound keeps serving the old answer until reloaded.

> **Gotcha:** The OpenAPI spec says `id in=query`. This is wrong. Use the JSON body.

---

## DNS Resolver — Apply Pending Changes

Marks pending config changes as applied and restarts Unbound. Required after POST (create) since POST has no built-in `apply` parameter.

```
POST /api/v2/services/dns_resolver/apply
```

No body required. Response `data.pending` bool indicates whether there were pending changes.

> **Note:** This REST endpoint does not always trigger a full Unbound service restart on its own. `register-dns.sh` follows up with `service unbound restart` via `/api/v2/diagnostics/command_prompt` to guarantee the change takes effect.

---

## Diagnostics — Command Prompt

Runs an arbitrary shell command as root on the pfSense box. Used by SURU to restart services that the REST API doesn't expose a clean endpoint for.

```
POST /api/v2/diagnostics/command_prompt
Content-Type: application/json

{"command": "service unbound restart"}
```

Response:
```json
{
  "data": {
    "command": "service unbound restart",
    "output": "",
    "result_code": 0
  }
}
```

Command length limit: **1024 characters**. Commands appear in the pfREST audit log at `/status/logs/packages/restapi`.

Used by `tier1-perimeter/scripts/lib/api.sh` → `_api_pfsense_exec()`.

---

## System — REST API Version

Lightweight reachability probe. Requires minimal privilege.

```
GET /api/v2/system/restapi/version
```

Used by `api_health()` in `lib/api.sh`.

---

## Services — Status

```
GET /api/v2/status/service?id=<service-name>
```

Returns `{name, description, enabled, status}`. `status: true` = actively running.

Service ids used by SURU: `suricata`, `zeek`, `syslog-ng`.

---

## System — Packages

```
GET /api/v2/system/packages
```

Returns all installed pfSense packages. SURU validates presence of `pfSense-pkg-RESTAPI`, `pfSense-pkg-suricata`, `pfSense-pkg-zeek`, `pfSense-pkg-pfBlockerNG`.

---

## Firewall — Aliases

```
GET /api/v2/firewall/aliases
```

Used to verify pfBlockerNG populated `pfB_SURU_*` aliases after a feed import.

---

## Common Response Codes

| Code | Meaning |
|------|---------|
| 200 | Success |
| 400 | Bad request (check `response_id` for detail) |
| 401 | Unauthenticated |
| 403 | Forbidden (insufficient privilege) |
| 404 | Resource not found |
| 409 | Conflict |
| 415 | Unsupported media type |
| 422 | Validation error |
| 424 | Failed dependency |
| 500 | Internal server error |
| 503 | Service unavailable |

---

## Known OpenAPI Spec Inaccuracies (pfREST v2.7.7)

| Endpoint | Field | Spec says | Actual |
|----------|-------|-----------|--------|
| `DELETE /services/dns_resolver/host_override` | `id` | `in=query` | Must be in JSON body |
| `DELETE /services/dns_forwarder/host_override` | `id` | `in=query` | Likely same (untested) |

When a DELETE returns `400 MODEL_REQUIRES_ID` despite `?id=N` being present, move the id into the request body.
