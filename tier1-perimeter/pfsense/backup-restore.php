<?php
/**
 * SURU Tier 1 — decrypt + restore /conf/config.xml from an encrypted backup
 *
 * Called by the platform driver's revert hook (auto-triggered on deploy
 * failure) and available for manual operator recovery.
 *
 * Reads an encrypted backup produced by backup-encrypt.php (or by the
 * pfSense / OPNsense GUI's "Encrypt this configuration file" feature),
 * decrypts using the password supplied via a 0600 file, validates the
 * decrypted payload is a sane pfSense config (starts with the right
 * root element), then atomically replaces /conf/config.xml, flushes
 * the config cache, and re-parses.
 *
 * Service restarts are intentionally left to the caller — the driver
 * knows which services touched config and can decide whether to bounce
 * them. This script only fixes the on-disk state.
 *
 * Security note: pfSense's native AES-256-CBC backup format (the --decrypt path)
 * is unauthenticated — there is no MAC/HMAC. A crafted ciphertext could decrypt
 * to a valid config.xml under an attacker-supplied passphrase. Treat backup files
 * from untrusted sources as hostile regardless of this script's validation gate.
 *
 * Usage (run on router as root):
 *   sudo php /tmp/suru-staging/backup-restore.php \
 *     /tmp/suru-staging/.suru-bkpass    # 0600 file containing the password \
 *     /root/suru-backups/config.xml.suru-<TS>.bak   # encrypted backup path
 *
 * Exit codes:
 *   0 success
 *   2 missing/invalid args
 *   3 crypt.inc unavailable
 *   4 decrypt failed (wrong password / corrupt envelope)
 *   5 decrypted payload doesn't look like a pfSense/OPNsense config
 *   6 write failed
 */

if ($argc < 3) {
  fwrite(STDERR, "usage: php backup-restore.php <password-file> <encrypted-backup-path>\n");
  exit(2);
}

$pass_file = $argv[1];
$enc_path  = $argv[2];

if (!is_readable($pass_file)) {
  fwrite(STDERR, "[backup-restore] password file not readable: {$pass_file}\n");
  exit(2);
}
$pass = trim((string)@file_get_contents($pass_file));
if ($pass === '') {
  fwrite(STDERR, "[backup-restore] empty password\n");
  exit(2);
}

if (!is_readable($enc_path)) {
  fwrite(STDERR, "[backup-restore] backup not readable: {$enc_path}\n");
  exit(2);
}

// crypt.inc depends transitively on globals.inc::g_get() and util.inc.
// log_error inside decrypt_data's fallback paths will fatal without these.
if (!file_exists('/etc/inc/crypt.inc')) {
  fwrite(STDERR, "[backup-restore] /etc/inc/crypt.inc absent — unsupported platform variant\n");
  exit(3);
}
require_once('/etc/inc/globals.inc');
require_once('/etc/inc/functions.inc');
require_once('/etc/inc/util.inc');
require_once('/etc/inc/crypt.inc');

$wrapped = file_get_contents($enc_path);
if ($wrapped === false || $wrapped === '') {
  fwrite(STDERR, "[backup-restore] backup empty/unreadable\n");
  exit(2);
}

$body = '';
if (!tagfile_deformat($wrapped, $body, 'config.xml')) {
  fwrite(STDERR, "[backup-restore] envelope not recognised — not a SURU/pfSense encrypted backup?\n");
  exit(4);
}

$plain = decrypt_data($body, $pass);
if ($plain === '' || $plain === false) {
  fwrite(STDERR, "[backup-restore] decrypt_data returned empty (wrong password? corrupt backup?)\n");
  exit(4);
}

// Parse and validate: a real pfSense/OPNsense config must be well-formed XML
// with <pfsense> or <opnsense> as the root element.
// Note: the pfSense AES-256-CBC backup format is unauthenticated (no MAC/HMAC);
// a crafted ciphertext can decrypt to valid XML that passes this check.
// This gate catches accidents (wrong file), not adversarial tampering.
libxml_use_internal_errors(true);
$xml_obj = simplexml_load_string($plain);
if ($xml_obj === false || !in_array($xml_obj->getName(), ['pfsense', 'opnsense'], true)) {
    fwrite(STDERR, "[backup-restore] decrypted payload is not a valid pfSense/OPNsense config — refusing to restore\n");
    if ($xml_obj === false) {
        foreach (libxml_get_errors() as $err) {
            fwrite(STDERR, "  XML parse error: " . trim($err->message) . "\n");
        }
    } else {
        fwrite(STDERR, "  Unexpected root element: <" . $xml_obj->getName() . ">\n");
    }
    libxml_clear_errors();
    exit(5);
}
libxml_clear_errors();

// Atomic replace via tempfile + rename.
$cfg = '/conf/config.xml';
$tmp = $cfg . '.suru-restore.' . posix_getpid();
if (file_put_contents($tmp, $plain) === false) {
  fwrite(STDERR, "[backup-restore] write to {$tmp} failed\n");
  exit(6);
}
@chmod($tmp, 0644);
@chown($tmp, 'root');
@chgrp($tmp, 'wheel');
if (!@rename($tmp, $cfg)) {
  fwrite(STDERR, "[backup-restore] rename {$tmp} -> {$cfg} failed\n");
  @unlink($tmp);
  exit(6);
}

// Flush in-memory cache and re-parse so subsequent PHP calls see restored state.
@unlink('/tmp/config.cache');
if (file_exists('/etc/inc/config.inc')) {
  require_once('/etc/inc/config.inc');
  if (function_exists('parse_config')) {
    parse_config(true);
  }
}

echo "[backup-restore] Restored {$cfg} from " . basename($enc_path) . PHP_EOL;
echo "[backup-restore] Decrypted size: " . strlen($plain) . " bytes." . PHP_EOL;
echo "[backup-restore] config.cache flushed; parse_config(true) reloaded." . PHP_EOL;
echo "[backup-restore] Caller is responsible for restarting affected services." . PHP_EOL;
