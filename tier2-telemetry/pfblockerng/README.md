# tier2-telemetry/pfblockerng — pfBlockerNG Block-list Policy

This directory is the **authoritative source** for all pfBlockerNG DNSBL and IP-reputation
feed categories. The render pipeline reads these YAML data files and emits the
PHP applier `tier1-perimeter/rendered/pfsense/pfblockerng/pfblockerng-import.php`,
which mutates pfSense's `installedpackages/pfblockerngdnsbl/config` directly via
`config_set_path` + `write_config`. No intermediate XML side file is produced;
the previous `pfblockerng.xml` output was never consumed and has been removed.

## Directory Layout

```
pfblockerng/
├── categories/
│   ├── dnsbl-categories.yml   # DNSBL feed URLs (DNS-level domain blocklists)
│   └── ip-categories.yml      # IPv4 reputation aliases (firewall-level IP blocklists)
└── allowlists/
    └── local-allowlist.txt    # Site-specific DNS/IP exceptions
```

## Invariant

Block-list categories MUST NOT be hardcoded into `tier1-perimeter/` templates or scripts.
All feed policy lives here. Platform drivers in T1 read from `rendered/` only.

## MITRE ATT&CK Coverage

Each feed entry in `dnsbl-categories.yml` SHOULD include a `mitre:` list mapping
to the ATT&CK techniques the feed helps detect or prevent.

## Validation

```bash
# Lint the YAML files
yq eval '.' categories/dnsbl-categories.yml > /dev/null && echo 'OK'
```
