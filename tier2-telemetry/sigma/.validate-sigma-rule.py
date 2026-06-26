#!/usr/bin/env python3
"""SURU Platform — single Sigma rule required-field / MITRE-tag / falsepositives check.

Mirrors tier2-telemetry/sigma/README.md "Validation" section's python3 snippet.
Exit 0 = valid, exit 1 = invalid (message printed to stdout describing the failure).
"""
import sys

import yaml

import re

REQUIRED = ["title", "id", "status", "description", "author", "date", "modified",
            "tags", "logsource", "detection", "falsepositives", "level"]

# OpenSearch Security Analytics only accepts these status values — "production" causes a 400.
VALID_STATUSES = {"experimental", "test", "stable", "deprecated"}

# OpenSearch SA's SigmaRule parser requires YYYY/MM/DD (slashes), not YYYY-MM-DD.
DATE_RE = re.compile(r"^\d{4}/\d{2}/\d{2}$")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate-sigma-rule.py <rule.yml>")
        return 1
    path = sys.argv[1]
    with open(path) as fh:
        doc = yaml.safe_load(fh)

    missing = [k for k in REQUIRED if k not in doc]
    if missing:
        print(f"{path}: missing required field(s): {missing}")
        return 1

    status = str(doc.get("status", ""))
    if status not in VALID_STATUSES:
        print(f"{path}: invalid status '{status}' — must be one of {sorted(VALID_STATUSES)}"
              " (OpenSearch SA rejects 'production' with HTTP 400)")
        return 1

    for date_field in ("date", "modified"):
        val = str(doc.get(date_field, ""))
        if not DATE_RE.match(val):
            print(f"{path}: {date_field} '{val}' must be YYYY/MM/DD format"
                  " (OpenSearch SA's SigmaRule parser NPEs on YYYY-MM-DD)")
            return 1

    tags = doc.get("tags", [])
    if not any(t.startswith("attack.ta") for t in tags):
        print(f"{path}: missing MITRE Tactic tag (attack.ta####)")
        return 1
    if not any(t.startswith("attack.t") and not t.startswith("attack.ta") for t in tags):
        print(f"{path}: missing MITRE Technique tag (attack.t####)")
        return 1

    if not doc.get("falsepositives"):
        print(f"{path}: falsepositives is empty/missing")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
