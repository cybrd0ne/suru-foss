<?php
/**
 * SURU Tier 1 — encrypted /conf/config.xml backup
 *
 * Reads /conf/config.xml on the router, encrypts it with the password
 * supplied via a 0600 file (NOT argv — keeps the secret out of `ps` and
 * /proc/<pid>/cmdline), wraps the ciphertext in the pfSense / OPNsense
 * native "---- BEGIN config.xml ----" envelope so the result is
 * directly restorable via:
 *   pfSense:  Diagnostics > Backup & Restore > Restore Configuration
 *             (check "Configuration file is encrypted", supply password)
 *   OPNsense: System > Configuration > Backups > Restore (encrypted)
 *
 * Uses the platform's own crypt.inc helpers — AES-256-CBC, PBKDF2 with
 * SHA-256, 500_000 iterations. The same code path the GUI's "Encrypt this
 * configuration file" checkbox runs.
 *
 * Usage (run on router as root):
 *   sudo php /tmp/suru-staging/backup-encrypt.php \
 *     /tmp/suru-staging/.suru-bkpass    # 0600 file containing the password \
 *     /root/suru-backups/config.xml.suru-20260517T161200Z.bak   # output path
 *
 * Exit codes:
 *   0 success
 *   2 missing/invalid args
 *   3 crypt.inc unavailable (e.g. unfamiliar OPNsense variant)
 *   4 encryption failed (openssl returned empty)
 *   5 write failed
 */

if ($argc < 3) {
  fwrite(STDERR, "usage: php backup-encrypt.php <password-file> <output-path>\n");
  exit(2);
}

$pass_file = $argv[1];
$out_path  = $argv[2];

if (!is_readable($pass_file)) {
  fwrite(STDERR, "[backup-encrypt] password file not readable: {$pass_file}\n");
  exit(2);
}
$pass = trim((string)@file_get_contents($pass_file));
if ($pass === '') {
  fwrite(STDERR, "[backup-encrypt] empty password\n");
  exit(2);
}

// Both pfSense and OPNsense ship the same crypt.inc API (OPNsense inherited
// it at fork time; the functions are stable across both code lines).
// Dependency chain: crypt.inc → util.inc::log_error → globals.inc::g_get.
// Load the standard pfSense bootstrap so the fallback paths inside
// decrypt_data (which call log_error on failure) don't blow up the script.
if (!file_exists('/etc/inc/crypt.inc')) {
  fwrite(STDERR, "[backup-encrypt] /etc/inc/crypt.inc absent — unsupported platform variant\n");
  exit(3);
}
require_once('/etc/inc/globals.inc');
require_once('/etc/inc/functions.inc');
require_once('/etc/inc/util.inc');
require_once('/etc/inc/crypt.inc');

$cfg = '/conf/config.xml';
if (!is_readable($cfg)) {
  fwrite(STDERR, "[backup-encrypt] cannot read {$cfg}\n");
  exit(2);
}
$plain = file_get_contents($cfg);
if ($plain === false || $plain === '') {
  fwrite(STDERR, "[backup-encrypt] {$cfg} empty/unreadable\n");
  exit(2);
}

// encrypt_data takes its first argument by reference (PHP requires lvalue).
$enc = encrypt_data($plain, $pass);
if ($enc === '' || $enc === false) {
  fwrite(STDERR, "[backup-encrypt] encrypt_data returned empty (openssl failure?)\n");
  exit(4);
}

// tagfile_reformat wraps in `---- BEGIN config.xml ----` / `---- END ... ----`.
// Output is the second-arg ref.
$wrapped = '';
if (!tagfile_reformat($enc, $wrapped, 'config.xml')) {
  fwrite(STDERR, "[backup-encrypt] tagfile_reformat failed\n");
  exit(4);
}

// Ensure parent dir exists; create restrictive.
$dir = dirname($out_path);
if (!is_dir($dir)) {
  if (!@mkdir($dir, 0700, true)) {
    fwrite(STDERR, "[backup-encrypt] could not create {$dir}\n");
    exit(5);
  }
}

if (file_put_contents($out_path, $wrapped) === false) {
  fwrite(STDERR, "[backup-encrypt] write failed: {$out_path}\n");
  exit(5);
}
@chmod($out_path, 0600);

echo "[backup-encrypt] Wrote " . strlen($wrapped) . " bytes of encrypted backup to:" . PHP_EOL;
echo "  {$out_path}" . PHP_EOL;
echo "[backup-encrypt] Restore: GUI 'Restore Configuration' with 'Encrypted' checked, same password." . PHP_EOL;
