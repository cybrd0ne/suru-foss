# SURU Platform — Tier 1: Perimeter

Tier 1 contains **deployment scaffolding** for perimeter devices (pfSense, OPNsense).
It does **not** contain security policy. All security intelligence (rules, feeds, scripts)
lives in [`../tier2-telemetry/`](../tier2-telemetry/).

## Directory Structure

```
tier1-perimeter/
├── templates/                        # Structural config templates (schema only)
│   ├── pfsense/
│   │   ├── config-base.xml.tpl       # pfSense base config schema
│   │   └── syslog-ng.conf.tpl        # syslog-ng forwarder (token substitution)
│   ├── suricata/
│   │   └── suricata.yaml.tpl         # Suricata 7.x engine config (no rule selection)
│   ├── zeek/
│   │   └── local.zeek.tpl            # Zeek engine bootstrap (__ZEEK_SCRIPTS__ placeholder)
│   └── opnsense/
│       ├── config-base.xml.tpl
│       └── syslog-ng.conf.tpl
├── rendered/                         # BUILD OUTPUT — git-ignored, do not edit
│   ├── pfsense/                      # Populated by `make render PLATFORM=pfsense`
│   └── opnsense/                     # Populated by `make render PLATFORM=opnsense`
├── scripts/
│   ├── deploy.sh                     # Deployment orchestrator
│   └── platforms/
│       ├── pfsense.sh                # pfSense platform driver
│       └── opnsense.sh               # OPNsense platform driver
└── Makefile                          # render / deploy / deploy-full / clean / test
```

## Operator Workflow

```bash
# 1. Edit security policy in tier2-telemetry/ (rules, feeds, Zeek scripts)

# 2. Render: merge T2 intelligence into T1 templates
make render PLATFORM=pfsense

# 3. Deploy: push rendered artefacts to the router
make deploy PLATFORM=pfsense

# Or: render + deploy in one step
make deploy-full PLATFORM=pfsense

# Dry run (no changes to device)
make deploy-full PLATFORM=pfsense DRY_RUN=true
```

## Required Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ROUTER_HOST` | — | Router SSH/API host |
| `ROUTER_SSH_KEY` | `~/.ssh/suru_deploy` | SSH private key path |
| `FRONTDOOR_SYSLOG_SNI` | `syslog.suru.local` | SNI hostname for Tier 4 frontdoor stream demux |
| `FRONTDOOR_PORT` | `443` | Port for Tier 1 → frontdoor connections |
| `WAN_IFACE` | `igb0` | WAN interface name |
| `LAN_IFACE` | `igb1` | LAN interface name |
| `ROUTER_SENSOR_NAME` | `suru-tier1` | Sensor label in logs |

## Invariant 11

> **T2 is the sole authority for security policy.**
> Any PR adding Suricata SID selection, DNSBL categories, or Zeek detection
> scripts directly inside `tier1-perimeter/` **must be rejected** at review.
> Templates contain structure. Intelligence lives in `tier2-telemetry/`.
