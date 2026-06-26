# Threat-Intel STIX2 Bundles — Build/Runtime Artifacts (Not Committed)

## Source-vs-rendered separation

This directory mirrors the same source-vs-rendered split already established
by the pfBlockerNG render path
(`tier2-telemetry/build/lib/render-pfblockerng.sh`): the YAML category files
under `tier2-telemetry/pfblockerng/categories/*.yml` are the committed
**source of truth**, while the PHP importer
(`<rendered>/pfblockerng/pfblockerng-import.php`) is a **build output** that
is generated fresh on every render run and never committed.

The same pattern applies here:

| Committed source of truth | Generated artifact (NOT committed) |
|---|---|
| `tier2-telemetry/threat-intel/sources.yml` | `tier2-telemetry/threat-intel/stix2/*.json` (downloaded/normalized STIX2 bundles) |

- `sources.yml` lists feed origins (name, URL, IOC types, update cadence,
  MITRE mapping, live/not-live status). This file is hand-authored and
  version-controlled.
- The `.json` STIX2 bundle files that will appear in this directory at build
  or deploy time are **downloaded from the source URL and/or normalized into
  STIX2 Bundle objects** by the future tier2 renderer
  (`tier2-telemetry/build/lib/render-stix2.sh`, planned under task T3 —
  not yet built as of this task). They are regenerated on every render run,
  may be large, and are environment/time-dependent (feed content changes
  daily per `update_cadence` in `sources.yml`) — exactly the same reasons
  `pfblockerng-import.php` is a build artifact rather than a committed file.

## What ends up here

- One (or more) `*.json` STIX2 Bundle file(s) per live source in
  `sources.yml`, OR a single merged bundle — left to the T3 renderer's
  design once it is built.
- Each bundle's `indicator` objects carry `pattern` (STIX2 patterning
  language), `valid_from`, and a `labels`/`kill_chain_phases` mapping back to
  the MITRE ATT&CK Tactic/Technique recorded in `sources.yml`.

## Consumption

`tier3-core/scripts/apply-threat-intel.sh` reads bundle file(s) from this
directory (or fetches by URL, per OpenSearch Security Analytics' native
STIX2 threat-intel-source ingestion support) and pushes them into
OpenSearch. See that script's header comment for the exact (currently
unverified — pending T0a) API call.

## Why nothing is committed here

1. **Freshness** — IOC feeds update daily (see `update_cadence` in
   `sources.yml`); a committed bundle would be stale within hours and
   misleading in `git log`/`git blame`.
2. **Size** — full threat-intel bundles (especially externally-sourced ones) can
   be large; committing them bloats the repo for no benefit, identical to
   why `tier1-perimeter/rendered/` is gitignored build output.
3. **Single source of truth** — `sources.yml` is the only thing a reviewer
   needs to read or diff to understand what intel SURU consumes; the bundle
   content is a deterministic function of that file plus the live feed
   state at render time.

This directory is `.gitignore`-covered for its generated content (see the
root `.gitignore` `tier2-telemetry/threat-intel/stix2/*.json` entry); this
`README.md` itself remains committed as the directory's documentation.
