<?php
/**
 * SURU Tier 1 — pfBlockerNG global settings applier for pfSense
 *
 * Writes a SURU-curated baseline into:
 *   installedpackages/pfblockerng/config/0           (master + update cadence)
 *   installedpackages/pfblockerngdnsblsettings/config (DNSBL feature config)
 *
 * Conservative semantics: only the keys listed below are touched. Operator
 * site-specific fields (interface bindings, listener ports, custom TLDs,
 * pfBlockerNG's IP-feed interface choices) are NEVER written so they
 * survive across deploys.
 *
 * Why this PR exists: pfBlockerNG ships with the master switch `off` by
 * default. SURU's DNSBL + IPv4 feeds (managed by pfblockerng-import.php)
 * are useless until pfb_dnsbl=on and the package is enabled. This applier
 * makes the deploy authoritative for those activation switches without
 * trampling site-local interface choices.
 *
 * Usage (run on router as root):
 *   sudo php /tmp/suru-staging/pfblockerng-globals-apply.php [ip-config-secrets-file]
 *
 * Optional second-stage IP Configuration (GeoIP + ASN). If a secrets file path
 * is passed as argv[1], its KEY=VALUE lines drive pfBlockerNG's IP-config tab
 * (installedpackages/pfblockerngipsettings/config/0):
 *   MAXMIND_ACCOUNT_ID=<MaxMind account id> ┐ both required together to enable
 *   MAXMIND_KEY=<MaxMind license key>       ┘ GeoIP (maxmind_account/maxmind_key
 *                                              + autogeoipupdate). GeoLite2 v3.1.1+
 *                                              registration needs account ID + key.
 *   ASN_TOKEN=<IPinfo token>                -> enables ASN reporting (asn_token)
 * Each feature is only enabled when its token(s) are non-empty, so the deploy is
 * a no-op for operators who have not configured the corresponding .env token.
 *
 * Idempotent: re-running with identical baseline produces no diff in
 * /conf/config.xml. Re-run after an operator GUI save merges back the
 * SURU-claimed keys and leaves the rest alone.
 */

require_once('config.inc');
require_once('config.lib.inc');

// Sanity: pfBlockerNG package must be installed for any of this to take.
if (!file_exists('/usr/local/pkg/pfblockerng/pfblockerng.inc')) {
  fwrite(STDERR, "[pfblockerng-globals-apply] pfBlockerNG package not installed; aborting.\n");
  exit(2);
}

// -- SURU baseline -------------------------------------------------------
// installedpackages/pfblockerng/config/0
// Top-level package switch + cron cadence.
$baseline_master = [
  'enable_cb'    => 'on',       // master pfBlockerNG enable
  'pfb_keep'     => 'on',       // preserve settings on package reinstall
  'pfb_interval' => '24',       // hours between automatic cron updates
];

// installedpackages/pfblockerngdnsblsettings/config
// DNSBL feature activation + sane high-performance defaults.
// NOT touched: dnsbl_interface, pfb_dnsvip, pfb_dnsport, pfb_dnsport_ssl,
// pfb_pytlds_* — these are site-local networking choices.
$baseline_dnsbl = [
  'pfb_dnsbl'    => 'on',                // DNSBL feature enabled
  'dnsbl_mode'   => 'dnsbl_unbound',     // integrated unbound responder
  'pfb_py_block' => 'on',                // Python mode (SOHO-recommended)
  'pfb_cache'    => 'on',                // DNS cache
  'action'       => 'Deny_Outbound',     // block outbound DNS to blocked domains
  'aliaslog'     => 'enabled',           // per-alias logging for SIEM ingest
  'pfb_hsts'     => 'on',                // HSTS bypass for the block page
];

// installedpackages/pfblockerngipsettings/config/0  (IP Configuration tab)
// GeoIP (MaxMind) + ASN (IPinfo) — only enabled when the matching token is
// present in the optional secrets file (argv[1]). NOT touched: maxmind_locale,
// per-feed interface bindings, and any other site-local IP-config field.
$baseline_ip = [];
if ($argc >= 2 && is_readable($argv[1])) {
  $secrets = [];
  foreach (file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $line = trim($line);
    if ($line === '' || $line[0] === '#' || strpos($line, '=') === false) {
      continue;
    }
    [$k, $v] = explode('=', $line, 2);
    $secrets[trim($k)] = trim($v);
  }
  // GeoIP: modern MaxMind GeoLite2 (GeoIP Update 3.1.1+) requires BOTH the
  // account ID and the license key. Only enable when both are present; turning
  // on autogeoipupdate keeps the country DB current via pfBlockerNG's daily cron.
  if (!empty($secrets['MAXMIND_ACCOUNT_ID']) && !empty($secrets['MAXMIND_KEY'])) {
    $baseline_ip['maxmind_account'] = $secrets['MAXMIND_ACCOUNT_ID'];
    $baseline_ip['maxmind_key']     = $secrets['MAXMIND_KEY'];
    $baseline_ip['autogeoipupdate'] = 'on';
  }
  // ASN: a non-empty IPinfo token enables ASN reporting (24h cache is the
  // SOHO-sane default — long enough to avoid hammering IPinfo, short enough
  // to reflect reassignments).
  if (!empty($secrets['ASN_TOKEN'])) {
    $baseline_ip['asn_reporting'] = '24hour';
    $baseline_ip['asn_token']     = $secrets['ASN_TOKEN'];
  }
}

// -- Apply with merge-preserve semantics ---------------------------------
function suru_merge_apply(string $path, array $baseline): array {
  $existing = config_get_path($path, []);
  // Normalise: pfSense sometimes stores leaf config wrapped in /config/0/.
  // Caller passes the path the package actually consumes; we just merge.
  $changes = [];
  foreach ($baseline as $k => $v) {
    $prev = $existing[$k] ?? null;
    if ((string)$prev !== (string)$v) {
      $changes[$k] = ['from' => $prev, 'to' => $v];
      $existing[$k] = $v;
    }
  }
  config_set_path($path, $existing);
  return $changes;
}

echo "[pfblockerng-globals-apply] Applying SURU baseline..." . PHP_EOL;

// Both paths terminate at /0 because pfSense stores these as singleton-wrapped
// arrays: config_get_path('installedpackages/<key>/config') returns
// [0 => <actual_settings_dict>]. The /0 selects the inner dict so our merge
// operates on the right level.
$ch_master = suru_merge_apply('installedpackages/pfblockerng/config/0', $baseline_master);
$ch_dnsbl  = suru_merge_apply('installedpackages/pfblockerngdnsblsettings/config/0', $baseline_dnsbl);
$ch_ip     = empty($baseline_ip) ? []
           : suru_merge_apply('installedpackages/pfblockerngipsettings/config/0', $baseline_ip);

$total_changes = count($ch_master) + count($ch_dnsbl) + count($ch_ip);
if ($total_changes === 0) {
  echo "[pfblockerng-globals-apply] No changes — baseline already matches /conf/config.xml." . PHP_EOL;
  exit(0);
}

write_config('SURU: applied pfBlockerNG global baseline');

// Read-back assertion: verify the values actually landed in config.xml at the
// paths pfBlockerNG reads. Mismatch indicates a config_set_path path error.
$verify_master = config_get_path('installedpackages/pfblockerng/config/0', []);
$verify_dnsbl  = config_get_path('installedpackages/pfblockerngdnsblsettings/config/0', []);
$verify_ok     = true;
foreach ($baseline_master as $k => $v) {
    if (!isset($verify_master[$k]) || (string)$verify_master[$k] !== (string)$v) {
        fwrite(STDERR, "[pfblockerng-globals-apply] WARN: key '{$k}' readback mismatch (master)\n");
        $verify_ok = false;
    }
}
foreach ($baseline_dnsbl as $k => $v) {
    if (!isset($verify_dnsbl[$k]) || (string)$verify_dnsbl[$k] !== (string)$v) {
        fwrite(STDERR, "[pfblockerng-globals-apply] WARN: key '{$k}' readback mismatch (dnsbl)\n");
        $verify_ok = false;
    }
}
if (!empty($baseline_ip)) {
    $verify_ip = config_get_path('installedpackages/pfblockerngipsettings/config/0', []);
    foreach ($baseline_ip as $k => $v) {
        if (!isset($verify_ip[$k]) || (string)$verify_ip[$k] !== (string)$v) {
            fwrite(STDERR, "[pfblockerng-globals-apply] WARN: key '{$k}' readback mismatch (ipsettings)\n");
            $verify_ok = false;
        }
    }
}
if (!$verify_ok) {
    fwrite(STDERR, "[pfblockerng-globals-apply] ERROR: read-back assertion failed — config may not have been applied\n");
    exit(7);
}
echo "[pfblockerng-globals-apply] Read-back assertion passed." . PHP_EOL;

echo "[pfblockerng-globals-apply] installedpackages/pfblockerng/config/0:" . PHP_EOL;
if (count($ch_master) === 0) {
  echo "  (no change)" . PHP_EOL;
} else {
  foreach ($ch_master as $k => $d) {
    $from = is_null($d['from']) ? '(unset)' : "'{$d['from']}'";
    echo "  {$k}: {$from} -> '{$d['to']}'" . PHP_EOL;
  }
}

echo "[pfblockerng-globals-apply] installedpackages/pfblockerngdnsblsettings/config/0:" . PHP_EOL;
if (count($ch_dnsbl) === 0) {
  echo "  (no change)" . PHP_EOL;
} else {
  foreach ($ch_dnsbl as $k => $d) {
    $from = is_null($d['from']) ? '(unset)' : "'{$d['from']}'";
    echo "  {$k}: {$from} -> '{$d['to']}'" . PHP_EOL;
  }
}

if (!empty($baseline_ip)) {
  echo "[pfblockerng-globals-apply] installedpackages/pfblockerngipsettings/config/0:" . PHP_EOL;
  if (count($ch_ip) === 0) {
    echo "  (no change)" . PHP_EOL;
  } else {
    // Mask secret values (maxmind_key, asn_token) — never log credentials.
    $secret_keys = ['maxmind_account' => true, 'maxmind_key' => true, 'asn_token' => true];
    foreach ($ch_ip as $k => $d) {
      if (isset($secret_keys[$k])) {
        echo "  {$k}: (set, value masked)" . PHP_EOL;
      } else {
        $from = is_null($d['from']) ? '(unset)' : "'{$d['from']}'";
        echo "  {$k}: {$from} -> '{$d['to']}'" . PHP_EOL;
      }
    }
  }
}

echo "[pfblockerng-globals-apply] {$total_changes} setting(s) updated." . PHP_EOL;
echo "[pfblockerng-globals-apply] Note: pfBlockerNG applies these on its next cron run, or via GUI 'Force Update'." . PHP_EOL;
echo "[pfblockerng-globals-apply] Done." . PHP_EOL;
