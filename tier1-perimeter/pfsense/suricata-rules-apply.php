<?php
/**
 * SURU Tier 1 — Suricata rule-selection + interface registration XML applier
 *
 * Reads two staged files (paths on $argv[1], $argv[2]):
 *   enable.conf  — suricata-update style. `group:<name>` lines mark
 *                  ET Open category files to enable on every interface.
 *   disable.conf — same syntax; `group:<name>` marks categories to disable.
 *
 * Optional arguments (positional, after enable/disable paths):
 *   --ifaces=lan,opt1   Comma-separated list of pfSense logical interface names
 *                       to ensure are registered in installedpackages/suricata/rule.
 *                       Missing entries are created with safe SOHO defaults and
 *                       enabled. Existing entries are left unchanged (idempotent).
 *                       Use pfSense logical names (lan, wan, opt1, opt2, …), not
 *                       physical names (igb0, igb1.10). Found in pfSense:
 *                       Interfaces > Assignments.
 *   --restart           Restart all Suricata interfaces after applying changes.
 *
 * For each interface under installedpackages/suricata/rule[]:
 *   1. Parse the current rulesets list (||-joined category filenames).
 *   2. Union in <name>.rules for each enabled group.
 *   3. Remove <name>.rules for each disabled group.
 *   4. Re-assemble.
 * write_config(), then call sync_suricata_package_config() — the same
 * function the pfSense GUI calls on Save in Services > Suricata. That
 * regenerates each per-interface /usr/local/etc/suricata/suricata_<UUID>_<iface>/
 * suricata.yaml from XML (which the running suricata daemons actually read).
 *
 * Why: the pfSense Suricata package does NOT consume the top-level
 * /usr/local/etc/suricata/suricata.yaml — that is an input to the unrelated
 * `suricata-update` tool. The package maintains per-interface config under
 * installedpackages/suricata/rule and regenerates each suricata_<UUID>_<iface>/
 * suricata.yaml from XML. Files SCP'd to top-level paths sit unused.
 *
 * sid: and re: lines in enable.conf/disable.conf are NOT yet honoured —
 * SID-level toggling is a follow-up item.
 *
 * Usage (run on router as root):
 *   sudo php /tmp/suru-staging/suricata-rules-apply.php \
 *     /tmp/suru-staging/suricata-enable.conf \
 *     /tmp/suru-staging/suricata-disable.conf \
 *     [--ifaces=lan,opt1] [--restart]
 */

require_once('config.inc');
require_once('config.lib.inc');
require_once('/usr/local/pkg/suricata/suricata.inc');

if ($argc < 3) {
  fwrite(STDERR, "usage: php suricata-rules-apply.php <enable.conf> <disable.conf> [--ifaces=...] [--restart]\n");
  exit(2);
}

$enable_path  = $argv[1];
$disable_path = $argv[2];
$do_restart   = false;
$desired_ifaces = [];

foreach (array_slice($argv, 3) as $arg) {
  if ($arg === '--restart') {
    $do_restart = true;
  } elseif (preg_match('/^--ifaces=(.+)$/', $arg, $m)) {
    $desired_ifaces = array_values(array_filter(array_map('trim', explode(',', $m[1]))));
  }
}

foreach ($desired_ifaces as $iface_val) {
  if (!preg_match('/^[A-Za-z0-9._-]+$/', $iface_val)) {
    fwrite(STDERR, "[suricata-rules-apply] ERROR: invalid interface name in --ifaces: '{$iface_val}'\n");
    fwrite(STDERR, "  Allowed characters: A-Za-z0-9._-\n");
    exit(2);
  }
}

if (!is_readable($enable_path))  { fwrite(STDERR, "[suricata-rules-apply] cannot read {$enable_path}\n");  exit(2); }
if (!is_readable($disable_path)) { fwrite(STDERR, "[suricata-rules-apply] cannot read {$disable_path}\n"); exit(2); }

/**
 * Extract `group:NAME` entries from a suricata-update style selection file.
 * Returns a set keyed by the `.rules` filename.
 */
function suru_parse_groups(string $path): array {
  $out = [];
  $f = fopen($path, 'r');
  if ($f === false) return $out;
  while (($line = fgets($f)) !== false) {
    $line = trim($line);
    if ($line === '' || $line[0] === '#') continue;
    if (preg_match('/^group:\s*([A-Za-z0-9._-]+)\s*$/', $line, $m)) {
      $name = $m[1];
      if (substr($name, -strlen('.rules')) !== '.rules') {
        $name .= '.rules';
      }
      $out[$name] = true;
    }
    // sid: and re: are deferred — see header comment.
  }
  fclose($f);
  return $out;
}

/**
 * Generate a unique short UUID for a new Suricata interface entry.
 * Stays in the same 5-digit decimal space used by the pfSense package.
 */
function suru_gen_uuid(array $existing_uuids): string {
  $attempts = 0;
  do {
    $uuid = (string) mt_rand(10000, 99999);
    $attempts++;
    if ($attempts > 1000) {
      // Fall back to longer hex to guarantee uniqueness
      $uuid = bin2hex(random_bytes(4));
      break;
    }
  } while (in_array($uuid, $existing_uuids, true));
  return $uuid;
}

/**
 * Build a default interface entry for a newly registered pfSense Suricata iface.
 * Defaults match the SOHO profile used by existing manually-configured entries.
 * rulesets is intentionally empty — the rule-selection step populates it.
 */
function suru_make_default_iface(string $iface_name, string $uuid): array {
  // 'descr' => 'SURU managed' is the ownership sentinel used by the
  // rule-selection phase to distinguish SURU-registered interfaces from
  // manually-configured ones. Do not change this value.
  return [
    'interface'               => $iface_name,
    'enable'                  => 'on',
    'uuid'                    => $uuid,
    'descr'                   => 'SURU managed',
    'enable_verbose_logging'  => 'off',
    'max_pcap_log_size'       => '32',
    'max_pcap_log_files'      => '100',
    'pcap_log_conditional'    => 'alerts',
    'enable_stats_collection' => 'on',
    'enable_stats_log'        => 'off',
    'append_stats_log'        => 'off',
    'stats_upd_interval'      => '10',
    'enable_telegraf_stats'   => 'off',
    'enable_http_log'         => 'on',
    'append_http_log'         => 'on',
    'enable_tls_log'          => 'off',
    'append_tls_log'          => 'on',
    'enable_tls_store'        => 'off',
    'http_log_extended'       => 'on',
    'tls_log_extended'        => 'on',
    'tls_session_resumption'  => 'off',
    'enable_pcap_log'         => 'off',
    'pcap_use_stream_depth'   => 'off',
    'pcap_honor_pass_rules'   => 'off',
    'enable_file_store'       => 'off',
    'tls_log_filetype'        => 'regular',
    'http_log_filetype'       => 'regular',
    'runmode'                 => 'autofp',
    'autofp_scheduler'        => 'hash',
    'max_pending_packets'     => '2048',
    'inspect_recursion_limit' => '3000',
    'intf_snaplen'            => '1518',
    'detect_eng_profile'      => 'high',
    'mpm_algo'                => 'auto',
    'spm_algo'                => 'auto',
    'sgh_mpm_context'         => 'auto',
    'blockoffenders'          => 'on',
    'ips_mode'                => 'ips_mode_legacy',
    'blockoffenderskill'      => 'on',
    'block_drops_only'        => 'off',
    'passlist_debug_log'      => 'off',
    'blockoffendersip'        => 'both',
    'homelistname'            => 'default',
    'externallistname'        => 'default',
    'enable_eve_log'          => 'on',
    'eve_output_type'         => 'regular',
    'eve_log_alerts'          => 'on',
    'eve_log_alerts_payload'  => 'on',
    'eve_log_alerts_packet'   => 'on',
    'eve_log_alerts_metadata' => 'on',
    'eve_log_alerts_http'     => 'on',
    'eve_log_drops'           => 'on',
    'eve_log_http'            => 'on',
    'eve_log_dns'             => 'on',
    'eve_log_tls'             => 'on',
    'rulesets'                => '',  // populated by rule-selection step below
  ];
}

$enable_set  = suru_parse_groups($enable_path);
$disable_set = suru_parse_groups($disable_path);

if (count($enable_set) === 0 && count($disable_set) === 0) {
  fwrite(STDERR, "[suricata-rules-apply] both enable and disable sets empty — refusing to no-op\n");
  exit(3);
}

echo "[suricata-rules-apply] Parsed " . count($enable_set) . " enabled groups, "
   . count($disable_set) . " disabled groups." . PHP_EOL;

$interfaces = config_get_path('installedpackages/suricata/rule', []);

// ------------------------------------------------------------------
// Phase 1: Interface registration
// Ensure every interface in --ifaces exists in XML. Create if missing.
// ------------------------------------------------------------------
if (count($desired_ifaces) > 0) {
  echo "[suricata-rules-apply] Checking registration for interface(s): "
     . implode(', ', $desired_ifaces) . PHP_EOL;

  $existing_uuids    = array_column($interfaces, 'uuid');
  $existing_names    = array_column($interfaces, 'interface');
  $reg_dirty         = false;

  foreach ($desired_ifaces as $iface_name) {
    if (in_array($iface_name, $existing_names, true)) {
      echo "[suricata-rules-apply] iface={$iface_name} already registered — skipping\n";
      continue;
    }
    $new_uuid         = suru_gen_uuid($existing_uuids);
    $existing_uuids[] = $new_uuid;
    $existing_names[] = $iface_name;
    $interfaces[]     = suru_make_default_iface($iface_name, $new_uuid);
    $reg_dirty        = true;
    echo "[suricata-rules-apply] Registered new interface: {$iface_name} (uuid={$new_uuid})\n";
  }

  if ($reg_dirty) {
    config_set_path('installedpackages/suricata/rule', $interfaces);
    write_config('SURU: registered Suricata interface(s) from SURICATA_IFACES');
    // Reload from config so the rule-selection step sees the updated array.
    $interfaces = config_get_path('installedpackages/suricata/rule', []);
    echo "[suricata-rules-apply] Interface registration written to config.xml.\n";
  } else {
    echo "[suricata-rules-apply] All requested interfaces already registered.\n";
  }
}

if (count($interfaces) === 0) {
  fwrite(STDERR, "[suricata-rules-apply] no Suricata interfaces configured in XML — nothing to do\n");
  exit(0);
}

// ------------------------------------------------------------------
// Phase 2: Rule-selection — apply enable/disable to SURU-managed interfaces
// ------------------------------------------------------------------
$total_added   = 0;
$total_removed = 0;
$dirty         = false;

// Scope rule-selection to SURU-managed interfaces only:
// those in --ifaces OR those previously registered by SURU (descr = "SURU managed").
// This prevents clobbering manually-configured non-SURU interfaces.
$suru_names = array_fill_keys($desired_ifaces, true);
foreach ($interfaces as $iface) {
  if (isset($iface['descr']) && $iface['descr'] === 'SURU managed') {
    $suru_names[$iface['interface']] = true;
  }
}

foreach ($interfaces as $idx => $iface) {
  $name    = isset($iface['interface']) ? $iface['interface'] : "iface_{$idx}";
  // When $suru_names is empty (no --ifaces given AND no 'SURU managed' interfaces in
  // XML yet), all interfaces are processed — intentional first-run behaviour before
  // any interface has been registered by SURU. Once any interface carries
  // 'SURU managed', only those are touched and non-SURU interfaces are skipped.
  if (!empty($suru_names) && !isset($suru_names[$name])) {
      echo "[suricata-rules-apply] iface={$name} — not SURU-managed, skipping rule-selection\n";
      continue;
  }
  $uuid    = isset($iface['uuid'])      ? $iface['uuid']      : '?';
  $current = isset($iface['rulesets'])  ? trim($iface['rulesets']) : '';
  $cur_list = ($current === '') ? [] : explode('||', $current);
  $cur_set  = array_fill_keys($cur_list, true);

  $added = []; $removed = [];

  foreach ($enable_set as $f => $_) {
    if (!isset($cur_set[$f])) { $cur_set[$f] = true; $added[] = $f; }
  }
  foreach ($disable_set as $f => $_) {
    if (isset($cur_set[$f])) { unset($cur_set[$f]); $removed[] = $f; }
  }

  if (count($added) === 0 && count($removed) === 0) {
    echo "[suricata-rules-apply] iface={$name} uuid={$uuid} — no change\n";
    continue;
  }

  $new_list = array_keys($cur_set);
  sort($new_list);
  $new_value = implode('||', $new_list);

  $interfaces[$idx]['rulesets'] = $new_value;
  $total_added   += count($added);
  $total_removed += count($removed);
  $dirty = true;

  echo "[suricata-rules-apply] iface={$name} uuid={$uuid}:\n";
  if (count($added))   echo "    + " . implode("\n    + ", $added)   . "\n";
  if (count($removed)) echo "    - " . implode("\n    - ", $removed) . "\n";
}

if (!$dirty) {
  echo "[suricata-rules-apply] No interfaces required rule-selection changes." . PHP_EOL;
  exit(0);
}

config_set_path('installedpackages/suricata/rule', $interfaces);
write_config('SURU: applied Suricata category enable/disable baseline');

echo "[suricata-rules-apply] Wrote XML changes: +{$total_added} category enables, -{$total_removed} category disables across " . count($interfaces) . " interface(s)." . PHP_EOL;

// sync_suricata_package_config() walks installedpackages/suricata/rule and
// regenerates each per-interface suricata_<UUID>_<iface>/suricata.yaml.
echo "[suricata-rules-apply] Calling sync_suricata_package_config() to regenerate per-interface yamls..." . PHP_EOL;
sync_suricata_package_config();

if ($do_restart) {
  echo "[suricata-rules-apply] --restart given: restarting all Suricata interfaces..." . PHP_EOL;
  suricata_restart_all_interfaces();
  echo "[suricata-rules-apply] Restart issued." . PHP_EOL;
} else {
  echo "[suricata-rules-apply] No --restart flag; existing engines keep running with loaded rules." . PHP_EOL;
  echo "[suricata-rules-apply] Operator must restart Suricata interfaces to load new ruleset." . PHP_EOL;
}

echo "[suricata-rules-apply] Done." . PHP_EOL;
