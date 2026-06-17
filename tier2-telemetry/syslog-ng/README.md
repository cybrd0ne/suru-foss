# SURU Platform — syslog-ng pfSense Configuration (Tier 2)

> **WARNING — DO NOT DEPLOY THE CONFIGS IN THIS DIRECTORY (SEC-016)**
>
> `syslog-ng-pfsense.conf` and `syslog-ng-forwarder.conf` are retired
> references with known bugs that make them non-functional. See the header
> comment in each file for the full bug list.
>
> The authoritative syslog-ng configuration for pfSense is:
> `tier1-perimeter/templates/pfsense/syslog-ng.conf.tpl`
> Deploy it with `make deploy` (in `tier1-perimeter/`).

## Overview

This directory holds retired reference configs for a tier2 standalone mini-PC
sensor (distinct from the pfSense router at tier1). A correct tier2 syslog-ng
config is a planned deliverable; these files are kept only as a record of the
original design intent.

## Files

| File | Status |
|---|---|
| `syslog-ng-pfsense.conf` | **RETIRED** — known bugs, do not deploy (SEC-016) |
| `syslog-ng-forwarder.conf` | **RETIRED** — known bugs, do not deploy (SEC-016) |

## Correct deployment path (tier1 — pfSense router)

```bash
# From repo root — renders the template and deploys to the router:
cd tier1-perimeter && make deploy
```

The template at `tier1-perimeter/templates/pfsense/syslog-ng.conf.tpl` is the
single source of truth. It uses:

- `sni(yes)` on the destination so the Tier 4 frontdoor SNI demux routes the
  connection to `suru-t3-ingestion-logstash-pfsense:5140` (mTLS).
- A reliable disk-buffer (5 GB) so events survive SIEM outages.
- `file()` sources with `program-override()` and `flags(syslog-protocol)` to
  avoid the syslogd socket-competition bug.
- `flags(final)` on every log path to prevent double-shipping.
- Template `t_json_base` on the destination for ECS-compatible JSON output.
