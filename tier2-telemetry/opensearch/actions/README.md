# Trigger Actions — Layer 2 (OpenSearch Security Analytics)

## Purpose

This directory is part of **Layer 2** of the tier2-telemetry three-layer
rule architecture (canonical Sigma -> OpenSearch detector binding -> ECS
field-mapping bridge):

```
Layer 1  tier2-telemetry/sigma/rules/**              canonical Sigma rules, abstract field names
Layer 2  tier2-telemetry/opensearch/detectors/**     binds Layer-1 rule(s) -> index pattern + schedule
Layer 3  tier2-telemetry/opensearch/field-mappings/** Sigma-abstract <-> ECS field bridge
Layer 2  tier2-telemetry/opensearch/correlations/**  cross-log-type correlation rules
Layer 2  tier2-telemetry/opensearch/actions/**       <- this directory: trigger actions
```

Each file here defines one **trigger-action type's** schema/config: what
happens when a Security Analytics detector or correlation rule produces a
finding. A detector binds to an action type via its own
`actions.default` / `actions.perimeter_block` flags (see "Detector
binding contract" below) — it does not reference an action file by name
today; that name-based binding is a render-step concern for T3.

## Files in this directory

| File | `action_type` | Status | Default on any shipped detector? |
|------|---------------|--------|-----------------------------------|
| `email-default.yml` | `email` | schema-defined | **Yes** — every buildable detector sets `actions.default: email` |
| `perimeter-block.yml` | `perimeter_block` | schema-defined, **opt-in only** | **No** — every shipped detector sets `actions.perimeter_block: false` |
| `slack-unconfigured.yml` | `slack` | unconfigured | No — not referenced by any detector |
| `webhook-unconfigured.yml` | `webhook` | unconfigured | No — not referenced by any detector |

## Detector binding contract

Every Layer 2 detector (`tier2-telemetry/opensearch/detectors/*.yml`) carries
an `actions:` block with exactly two flags today (see e.g.
`c2-dns-tunneling-entropy.yml:59-61`):

```yaml
actions:
  default: email            # email | null (null only on the execution-persistence stub)
  perimeter_block: false    # true | false — opt-in only, per-detector
```

These are boolean/enum flags, not action-file references — the detector
config does not say `actions.default: tier2-telemetry/opensearch/actions/
email-default.yml`. The mapping from `default: email` to the concrete
`email-default.yml` config (recipients, SMTP transport, template) is
resolved by T3's render step (`build/lib/render-actions.sh`, not yet
built), which reads this directory and produces the OpenSearch
Notifications-plugin config + Security Analytics `trigger.actions[]`
binding that T7 provisions live.

## The opt-in-not-default rule for `perimeter_block`

**`perimeter_block` is never a detector default.** Per the feature plan's
R4 guardrail and the operator's explicit instruction:

> Every detector ships with email as the default action. Perimeter-block
> is a second action type the operator can opt into per detector, in
> tier2 config, once a rule's false-positive rate is proven out via email
> alerts first — not a global default.

In practice: every detector ships with `actions.perimeter_block: false`.
To opt a specific detector in, an operator edits **that detector's own
config file** (e.g. `c2-dns-tunneling-entropy.yml`) and flips the flag to
`true` — never by editing this directory's `perimeter-block.yml`, and
never as a platform-wide default. `perimeter-block.yml` only defines
*what happens* when a detector is opted in; it does not opt anything in
itself.

Before flipping any detector's flag to `true`, confirm:
1. The detector has been live for long enough on `email`-only to
   characterize its false-positive rate (no fixed time floor mandated
   here — operator judgment, informed by the detector's own
   `falsepositives:` list).
2. The finding's severity meets `perimeter-block.yml`'s
   `confidence_threshold.min_severity` (`high` or `critical` only).
3. `tier1-perimeter/.env`'s `PERIMETER_BLOCK_ALLOWLIST` covers every
   legitimate non-RFC1918 management/monitoring host that could otherwise
   trigger a self-DoS block (the hardcoded RFC1918/loopback/ROUTER_HOST
   floor in `api.sh` does NOT cover a public-IP management endpoint).

## `perimeter_block`'s call target (T0b)

`perimeter-block.yml` calls into `tier1-perimeter/scripts/lib/api.sh`'s
`api_block_ip IP [TTL_SECONDS]` (api.sh:1305) — the function T0b built.
It does not invent a new blocking mechanism. See `perimeter-block.yml`'s
own header comment for the full guardrail chain (platform check -> IP
syntax -> TTL bound -> allowlist -> rate limit -> alias mutation +
reload -> TTL state + audit) read directly from `api.sh`, with line
numbers. The alias-mutation and reload steps are marked
`[STUB: ... needs live pfSense test]` in `api.sh` itself (api.sh:1037-1042,
1240-1279, 1282-1294) — this action config wires to the function
interface regardless of that STUB status, per the operator's instruction;
the STUB is T0b's open item to resolve, not a blocker for this directory.

## Why `slack`/`webhook` exist but are unconfigured

Per the plan: "slack/webhook schema-present, unconfigured." These two
files exist purely so a future task does not have to invent the
OpenSearch Notifications channel schema shape from scratch. They are:
- Not referenced by any detector's `actions:` block.
- Not consumed by any render step (`render-actions.sh` has no slack/webhook
  branch yet).
- Not provisioned by T7.

Do not flip `enabled: true` in either file without first building the
corresponding render-step and provisioner support — neither exists today.

## Adding a new action type

1. Create `<action-type>.yml` in this directory following the existing
   files' shape (`name`, `status`, `action_type`, `default_for`,
   `description`, type-specific config, `mitre_annotation_note`).
2. If the action type should ever be a detector default, that decision
   is made by editing the **detector's** `actions:` block, not this
   directory — actions files are config, not opt-in switches.
3. Build the corresponding `render-actions.sh` support (T3-equivalent
   follow-on work) before considering the action "wired," not just
   "schema-present."
4. Update the table above in the same PR.
5. If the action introduces a new credential/endpoint, add the env var
   to the owning tier's `.env.example` (see "Email/SMTP ownership"
   below for the precedent) and document it there with a comment.

## Email/SMTP ownership

No SMTP relay or outbound-mail capability exists anywhere in this
codebase prior to this change (confirmed by grep across
`tier1-perimeter/.env.example`, `tier3-core/.env.example`, and
`tier2-telemetry/` — the only pre-existing email-adjacent variable is
credential, and tier1's zeekctl `mail_to` is a router-local sendmail
target for log-rotation/host-up-down alerts, unrelated to OpenSearch).

The new `SECURITY_ANALYTICS_SMTP_*` / `SECURITY_ANALYTICS_ALERT_EMAIL_*`
variables this action introduces are added to **`tier3-core/.env.example`**,
because OpenSearch (and its Notifications plugin, which owns the SMTP
account config) is a tier3-core service — tier2-telemetry only authors the
rendered config that tier3's provisioner (T7, future work) applies.

## Validation

These files are hand-authored YAML, not yet consumed by any tooling — no
JSON-schema validator exists for this directory today (T10, future CI
parity work, is the natural home for one). Until then, validate with:

```bash
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('tier2-telemetry/opensearch/actions/*.yml')]"
```

This confirms valid YAML only — it does not confirm wire-format
correctness against a live OpenSearch instance (that is T0a's job, not
yet run).
