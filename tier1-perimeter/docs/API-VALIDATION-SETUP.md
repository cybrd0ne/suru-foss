# Tier 1 — REST API Setup for Post-Deploy Validation

This guide covers the **authentication (authN)**, **authorization (authZ)**,
and **validation surface** that the SURU Tier 1 deploy pipeline uses against
the router's REST API after every `make deploy`.

The API is also the channel Tier 3 (SIEM/SOAR) uses for **live blocking
calls** during incident response — same credentials, same audit log.

---

## 1. Why API for validation (not SSH)

| Concern | API channel | SSH channel |
|---|---|---|
| Audited per call | ✓ (pfREST log) | ✗ (sshd log only) |
| RBAC-restrictable | ✓ (per-endpoint privilege) | weak (sudoers granularity) |
| Structured response | ✓ JSON | ✗ stdout parsing |
| Same channel as Tier 3 active response | ✓ | n/a |
| Works without privileged shell | ✓ | needs sudoers |

The deploy writes themselves stay on SSH (sudo cp, package install). The
**post-deploy validation suite uses the API exclusively**, with SSH only as
a break-glass fallback when `api_health` fails.

---

## 2. Authentication modes

`API_AUTH_MODE` selects how credentials are sent. Both modes are supported
by `lib/api.sh`.

### `api_key` (default — best for CI/automation)

- pfSense: `X-API-Key: <key>` header
- OPNsense: HTTP Basic with `key:secret`
- Long-lived. Rotate on a schedule (recommended: 90 days).
- Key is in `.env` — store the `.env` with SOPS + age encryption.

```env
API_AUTH_MODE=api_key
PFSENSE_API_KEY=<paste from pfSense UI>
```

Generate in pfSense UI: **System → REST API → Authentication → Issue Key**.

### `jwt` (recommended for interactive operator sessions)

- Short-lived bearer token from `POST /api/v2/auth/jwt`
- pfSense only (OPNsense native API does not support JWT)
- Cached in-process by `lib/api.sh`; auto-refreshed before expiry
- Smaller blast radius if leaked

```env
API_AUTH_MODE=jwt
PFSENSE_API_USERNAME=<validator-user>
PFSENSE_API_PASSWORD=<password>   # SOPS-encrypt the .env
```

---

## 3. Authorization — minimum-privilege validator user

Do **not** use the pfSense `admin` user for deploy validation. The
`api-bootstrap` Make target creates a dedicated `suru-validator` user
with only the privileges the validation suite needs, issues a sha512
API key, and prints it for you to paste into `.env`.

### Automated setup (recommended)

```bash
cd tier1-perimeter

# Step 1: install pfRest (if not already installed)
make api-install-pfrest

# Step 2: create suru-validator and issue an API key
# Prompts for the pfSense admin password — never stored or logged.
make api-bootstrap                     # uses admin as default admin user
make api-bootstrap ADMIN_USER=myuser   # if your admin account has a different name

# Step 3: paste the printed PFSENSE_API_KEY into .env, then encrypt
sops --encrypt --in-place .env
```

`api-bootstrap` is idempotent: re-running resets the ephemeral password
and issues a fresh key. Use it for key rotation too.

### Required pfSense privileges

These are set automatically by `api-bootstrap`. Listed here for reference
and for manual setup if needed (see `_SURU_VALIDATOR_PRIVS` in `lib/api.sh`):

| pfSense privilege ID | UI label | API endpoints covered |
|---|---|---|
| `page-system-restapi` | System: REST API package | All pfREST endpoints — required |
| `page-diagnostics-command` | Diagnostics: Command | `POST /diagnostics/command_prompt` (engine tests) |
| `page-status-system-logs` | Status: System Logs | `GET /status/logs/system` |
| `page-status-services` | Status: Services | `GET /status/service?id=` |
| `page-system-packages` | System: Package Manager | `GET /system/packages` |
| `page-firewall-aliases-edit` | Firewall: Aliases (Edit) | `GET /firewall/aliases` |
| `WebCfg - Diagnostics: Command` | `_api_pfsense_exec` (all engine config tests) | `POST /api/v2/diagnostics/command_prompt` |

### Setup steps

1. **System → User Manager → Users → Add**
   - Username: `suru-validator`
   - Password: strong, store in SOPS-encrypted `.env`
2. **Effective Privileges** — add the 6 privileges above.
3. **System → REST API → Authentication**
   - For `api_key`: issue a key as `suru-validator` and paste it into `PFSENSE_API_KEY`.
   - For `jwt`: just set `PFSENSE_API_USERNAME=suru-validator` and the password.

### Caveat — `Diagnostics: Command` is broad

This privilege lets the API exec arbitrary shell commands as root. It is
required because pfREST has **no native endpoints for Suricata, Zeek, or
syslog-ng** — `_api_pfsense_exec` bridges that gap. If you cannot grant it,
the engine config tests (`suricata -T`, `zeekctl status`, `syslog-ng -s`)
will be skipped and validation degrades to service-running checks only.

Audit: every command is logged in `/status/logs/packages/restapi`. The
recommended posture is: grant the privilege, ship the audit log to Tier 3,
alert on commands that don't match the SURU validator's expected pattern.

---

## 4. TLS verification

`API_TLS_VERIFY=yes` is the default and must stay on in production.

Disabling it (`no`) prints a `WARN` on every API call. The only acceptable
use case is lab environments with a self-signed router cert that you have
not yet trusted on the operator workstation. Production routers must have a
cert signed by a CA trusted by the operator host (the Tier 3 internal CA is
the right answer).

---

## 5. Validation suite coverage

`api_validate_deployment` runs a 4-step **lightweight** suite using only
native pfREST read endpoints. Engine config tests (`suricata -T`,
`syslog-ng -s`, `zeekctl status`) are intentionally excluded from this
suite — see the note below.

| # | Check | Function | API path | Pass criterion |
|---|---|---|---|---|
| Auth gate | Reachability + auth | `api_health` | `GET /status/system` | Abort immediately on 401/503 |
| 1 | Packages installed | `api_validate_packages` | `GET /system/packages` | All 4 SURU packages present |
| 2 | Services running | `api_service_running` × 3 | `GET /status/service?id=<svc>` | `status: true` for syslog-ng, suricata, zeek |
| 3 | pfBlockerNG aliases | `api_validate_pfblockerng_aliases` | `GET /firewall/aliases` | `pfB_SURU_*` aliases present (soft) |
| 4 | Recent log errors | `api_validate_recent_errors` | `GET /status/logs/system` | Error count reported (informational) |

### Why engine config tests are excluded from api-validate

`suricata -T`, `syslog-ng -s`, and `zeekctl status` run via
`POST /diagnostics/command_prompt`, which executes them synchronously
inside PHP-FPM on the router. On SOHO hardware (4–8 GB RAM), loading
45,000+ Suricata rules in a web server process can exhaust memory and
crash the pfSense web GUI and SSH access for several minutes.

These tests already run **during `make deploy`** via SSH, where resource
usage is isolated from the web stack. Running them again post-deploy via
API is redundant and unsafe on constrained hardware.

The engine-test functions (`api_validate_suricata_config`,
`api_validate_zeek_status`, `api_validate_syslogng_config`) remain in
`lib/api.sh` and are callable individually — use them on routers with
sufficient resources and only outside active traffic windows.

---

## 6. Tier 3 → Tier 1 active-response considerations

The same API user can be granted additional privileges for live blocking
driven from Tier 3 (e.g. an OpenSearch alerting webhook or operator action):

| Action | Endpoint | Extra privilege |
|---|---|---|
| Add IP to block table | `POST /diagnostics/table` | `WebCfg - Diagnostics: Tables` |
| Remove IP (unblock) | `DELETE /diagnostics/table` | same |
| Kill active sessions for IP | `DELETE /firewall/states` | `WebCfg - Diagnostics: States` |
| Add persistent block alias entry | `PATCH /firewall/alias` + `POST /firewall/apply` | `WebCfg - Firewall: Aliases: Edit`, `WebCfg - Firewall: Rules` |

**Recommended split**: two separate API users.

- `suru-validator` — read-only + `Diagnostics: Command`. Used by deploy CI.
- `suru-responder` — write privileges for tables/states/aliases. Used only
  by Tier 3 SOAR. Keys rotated more aggressively (30d) because the blast
  radius is larger.

This keeps the deploy pipeline credential out of the active-response path.

---

## 7. Verifying the setup

After populating `.env`:

```bash
cd tier1-perimeter
# Health probe — confirms auth + connectivity
source scripts/lib/api.sh && api_init && api_health && echo "OK"

# Full validation suite — same call the deploy makes post-install
source scripts/lib/api.sh && api_validate_deployment
```

A successful end-to-end output looks like:

```
Validation suite (pfSense via pfREST):
[1/6] Packages installed:
  package: pfSense-pkg-RESTAPI ✓
  package: pfSense-pkg-suricata ✓
  package: pfSense-pkg-zeek ✓
  package: pfSense-pkg-pfBlockerNG-devel ✓
[2/6] Service status:
  syslog-ng: ✓ (running)
  suricata: ✓ (running)
  zeek: ✓ (running)
[3/6] Suricata engine config test:
  suricata -T: ✓ (config valid)
[4/6] Zeek node status:
  zeekctl status: ✓ (nodes running)
[5/6] syslog-ng config syntax:
  syslog-ng -s: ✓ (config valid)
[6/6] pfBlockerNG aliases + recent errors:
  pfBlockerNG aliases: ✓ (5 pfB_SURU_* aliases present)
  recent log scan: ✓ (0 errors in last 100 lines)
Validation suite: PASS
```
