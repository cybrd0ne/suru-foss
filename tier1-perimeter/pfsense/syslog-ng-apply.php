<?php
/**
 * SURU Tier 1 — syslog-ng XML applier for pfSense
 *
 * Reads a rendered syslog-ng.conf (path on $argv[1]) on the router, parses
 * it into discrete syslog-ng objects, then writes each into the pfSense
 * config XML at installedpackages/syslogngadvanced/config so the pfSense
 * GUI sees them. Finally calls syslogng_resync() — the same function the
 * GUI calls after a Save — which rebuilds /usr/local/etc/syslog-ng.conf
 * from XML and restarts the service.
 *
 * Why: pfSense's syslog-ng package regenerates the on-disk syslog-ng.conf
 * from XML on every GUI save. Direct SCP into /usr/local/etc/syslog-ng.conf
 * is silently overwritten the first time an operator clicks Save in
 * Status > syslog-ng. Writing through XML survives.
 *
 * Idempotent: SURU-managed objects are identified by name. The applier
 * removes every object whose objectname is in the rendered file's
 * declared name set, then re-adds the fresh definitions. Any user-managed
 * objects (e.g. _DEFAULT) are preserved.
 *
 * Usage (run on router as root):
 *   sudo php /tmp/suru-staging/syslog-ng-apply.php /tmp/suru-staging/syslog-ng.conf-source
 */

require_once('config.inc');
require_once('config.lib.inc');
require_once('/usr/local/pkg/syslog-ng.inc');

if ($argc < 2 || !is_readable($argv[1])) {
  fwrite(STDERR, "usage: php syslog-ng-apply.php <rendered-syslog-ng.conf>\n");
  exit(2);
}
$src = file_get_contents($argv[1]);
if ($src === false) {
  fwrite(STDERR, "[syslog-ng-apply] cannot read source file\n");
  exit(2);
}

/**
 * Parse a syslog-ng.conf source string into a list of objects.
 *
 * syslog-ng grammar accepted here:
 *   options { ... };
 *   <type> <name> { ... };
 *   where <type> ∈ {source, destination, filter, parser, rewrite, template, log}
 *
 * No nested braces in bodies — that's true of the SURU template; if it
 * ever isn't, this parser must be replaced with a proper lexer.
 *
 * Top-level @version: and @include "..." directives are stripped here:
 *   @version is emitted by syslogng_build_conf based on the installed
 *   package version. @include "scl.conf" is controlled by the
 *   include_scl global setting (set below).
 */
function suru_parse_syslogng_conf(string $src): array {
  $objects = [];
  $re = '/^[ \t]*(options|source|destination|filter|parser|rewrite|template|log)(?:[ \t]+([A-Za-z0-9_]+))?[ \t]*\{(.*?)\};/sm';
  if (!preg_match_all($re, $src, $m, PREG_SET_ORDER)) {
    return $objects;
  }
  foreach ($m as $match) {
    $type = $match[1];
    $name = isset($match[2]) ? trim($match[2]) : '';
    $body = '{' . $match[3] . '}';
    // options/log blocks are nameless in syslog-ng grammar. The pfSense
    // build function ignores objectname for these. Use a synthetic stable
    // name so the merge-by-name logic still deduplicates across reapplies.
    if ($name === '' && ($type === 'log' || $type === 'options')) {
      // hash the body to get a stable identifier across deploys with same content
      $name = $type . '_suru_' . substr(sha1($body), 0, 8);
    }
    $objects[] = [
      'objecttype'       => $type,
      'objectname'       => $name,
      'objectparameters' => base64_encode($body . ';'),
    ];
  }
  return $objects;
}

$parsed = suru_parse_syslogng_conf($src);
if (count($parsed) === 0) {
  fwrite(STDERR, "[syslog-ng-apply] parser produced 0 objects — refusing to wipe config\n");
  exit(3);
}
echo "[syslog-ng-apply] Parsed " . count($parsed) . " syslog-ng objects from " . basename($argv[1]) . PHP_EOL;

// Build a name-set of objects we will own. Anything currently in XML with
// a name in this set gets replaced; everything else stays.
$suru_names = [];
foreach ($parsed as $o) { $suru_names[$o['objectname']] = true; }

$existing = config_get_path('installedpackages/syslogngadvanced/config', []);
$kept = [];
foreach ($existing as $o) {
  $name = isset($o['objectname']) ? $o['objectname'] : '';
  if (!isset($suru_names[$name])) { $kept[] = $o; }
}
$merged = array_merge($kept, $parsed);
config_set_path('installedpackages/syslogngadvanced/config', $merged);

// Global settings — turn the service on, set include_scl on so @include "scl.conf"
// is emitted by syslogng_build_conf (the SURU template uses scl.conf macros).
$settings = config_get_path('installedpackages/syslogng/config/0', []);
$settings['enable'] = 'on';
$settings['include_scl'] = 'on';
// Keep operator-set values for archive_*, default_logdir etc. — never overwrite
// what isn't explicitly SURU territory.
config_set_path('installedpackages/syslogng/config/0', $settings);

write_config('SURU: applied syslog-ng objects from rendered template');

echo "[syslog-ng-apply] Wrote " . count($parsed) . " SURU objects to installedpackages/syslogngadvanced/config" . PHP_EOL;
echo "[syslog-ng-apply] Preserved " . count($kept) . " pre-existing non-SURU objects" . PHP_EOL;
// syslogng_resync() regenerates /usr/local/etc/syslog-ng.conf from pfSense's
// own XML field schema, which does not support syslog-ng 4.x features
// (wildcard-file, ca-dir, etc.) and also starts syslog-ng with that broken
// config. We call it only for its side-effects: creating required directories
// and marking the service enabled. Then we:
//   1. overwrite the generated conf with our full rendered template
//   2. kill the syslog-ng instance that resync started (wrong config)
//   3. start the syslog-ng binary directly — bypassing pfSense service hooks
//      so syslogng_resync() is NOT triggered a second time
echo "[syslog-ng-apply] Calling syslogng_resync() to update pfSense XML state and create dirs..." . PHP_EOL;
syslogng_resync();
sleep(2); // let resync finish starting the service before we kill it

$sng_conf = '/usr/local/etc/syslog-ng.conf';
$sng_bin  = '/usr/local/sbin/syslog-ng';

// Write to a temp file first so the on-disk conf is never overwritten until
// syntax validation passes. Mirrors the atomic-replace pattern in backup-restore.php.
if (!is_executable($sng_bin)) {
    fwrite(STDERR, "[syslog-ng-apply] ERROR: syslog-ng binary not found at {$sng_bin}\n");
    exit(4);
}
$sng_conf_tmp = $sng_conf . '.suru-staging.' . posix_getpid();
echo "[syslog-ng-apply] Writing SURU config to staging file {$sng_conf_tmp}..." . PHP_EOL;
if (file_put_contents($sng_conf_tmp, $src) === false) {
    fwrite(STDERR, "[syslog-ng-apply] ERROR: failed to write staging file {$sng_conf_tmp}\n");
    exit(4);
}

// Validate from the temp file before touching the live conf or killing the daemon.
$validate_cmd = escapeshellcmd($sng_bin) . ' --syntax-only -f ' . escapeshellarg($sng_conf_tmp) . ' 2>&1';
$validate_out = [];
$validate_rc  = 0;
exec($validate_cmd, $validate_out, $validate_rc);
if ($validate_rc !== 0) {
    @unlink($sng_conf_tmp);
    fwrite(STDERR, "[syslog-ng-apply] ERROR: syslog-ng --syntax-only failed (rc={$validate_rc}):\n");
    fwrite(STDERR, implode("\n", $validate_out) . "\n");
    fwrite(STDERR, "[syslog-ng-apply] NOT restarting — old daemon is still running, on-disk conf unchanged.\n");
    exit(5);
}
echo "[syslog-ng-apply] Syntax OK." . PHP_EOL;

// Atomically replace the live conf now that validation has passed.
echo "[syslog-ng-apply] Replacing {$sng_conf} with validated SURU config..." . PHP_EOL;
if (!@rename($sng_conf_tmp, $sng_conf)) {
    @unlink($sng_conf_tmp);
    fwrite(STDERR, "[syslog-ng-apply] ERROR: rename {$sng_conf_tmp} -> {$sng_conf} failed\n");
    exit(4);
}

// Kill the instance resync started (it has the pfSense schema config).
mwexec('/bin/pkill -TERM syslog-ng 2>/dev/null');
sleep(1);

// Start syslog-ng directly. It daemonizes, reads our conf, and does NOT
// trigger syslogng_resync(). pfSense GUI state shows the service as running.
echo "[syslog-ng-apply] Starting syslog-ng with SURU config..." . PHP_EOL;
mwexec($sng_bin);

sleep(2); // allow daemon to daemonize
$pgrep_rc = 0;
@exec('pgrep -x syslog-ng', $pgrep_out, $pgrep_rc);
if ($pgrep_rc !== 0) {
    fwrite(STDERR, "[syslog-ng-apply] ERROR: syslog-ng failed to start — check /var/log/system.log\n");
    exit(6);
}
echo "[syslog-ng-apply] syslog-ng is running (pid(s): " . implode(', ', $pgrep_out) . ")" . PHP_EOL;

echo "[syslog-ng-apply] Done." . PHP_EOL;
