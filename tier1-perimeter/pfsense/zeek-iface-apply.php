<?php
/**
 * SURU Tier 1 — Zeek capture interface applier for pfSense
 *
 * Sets the Zeek capture interface in /conf/config.xml via the same PHP API
 * the pfSense GUI uses, then calls zeek_settings_resync() to regenerate
 * /usr/local/etc/node.cfg. If zeek_settings_resync() cannot resolve a
 * physical trunk interface name (e.g. igb1 has no pfSense logical alias),
 * node.cfg is written directly so the correct interface is always set.
 *
 * Why this exists: pfSense Zeek package stores the capture interface as
 * active_interface in installedpackages/zeek/config/0. zeek_settings_resync()
 * calls get_real_interface($iface) which only resolves pfSense logical names
 * (lan, wan, opt1 …). A physical trunk like igb1 is not a logical interface,
 * so get_real_interface() returns empty and node.cfg is never written —
 * leaving whatever was already on disk untouched.
 *
 * No boot-persistence mechanism needed (CONFIRMED by reading zeek.inc on
 * the router, 2026-06-23): zeek_settings_resync() only writes node.cfg
 * inside `if ($iface) { ... }` — when get_real_interface() returns empty
 * for a physical trunk name, the write is skipped entirely. It never
 * overwrites node.cfg with a broken default; it just leaves our last
 * direct write alone. Two earlier fix attempts (system/shellcmd, then a
 * cron/item polling every minute) were built on the wrong assumption that
 * this needed reapplying after every boot/resync — both were removed.
 * node.cfg, once correctly written by this applier, already survives every
 * reboot for free, confirmed by two live reboot tests.
 *
 * Usage (run on router as root):
 *   sudo php /tmp/suru-staging/zeek-iface-apply.php igb1
 */

require_once('config.inc');
require_once('config.lib.inc');
require_once('/usr/local/pkg/zeek.inc');
require_once('services.inc'); // configure_cron() — removing the superseded cron/item entry below

define('ZEEK_NODE_CFG', '/usr/local/etc/node.cfg');

if ($argc < 2 || empty(trim($argv[1]))) {
    fwrite(STDERR, "usage: php zeek-iface-apply.php <interface>\n");
    fwrite(STDERR, "  interface: physical device name (e.g. igb1, em0)\n");
    exit(2);
}

$iface = trim($argv[1]);

if (!preg_match('/^[A-Za-z0-9._-]+$/', $iface)) {
    fwrite(STDERR, "[zeek-iface-apply] ERROR: invalid interface name: '{$iface}'\n");
    fwrite(STDERR, "  Allowed characters: A-Za-z0-9._-\n");
    exit(2);
}

// 1. Write active_interface to config.xml so the GUI reflects the setting.
config_set_path('installedpackages/zeek/config/0/active_interface', $iface);
write_config('SURU: set Zeek active_interface to ' . $iface);
echo "[zeek-iface-apply] Updated config.xml: active_interface={$iface}" . PHP_EOL;

// 2. Call pfSense Zeek package resync — regenerates node.cfg and networks.cfg
//    from config.xml. For logical interface names (lan, opt1…) this is
//    sufficient. For physical names that have no logical alias (igb1 trunk),
//    get_real_interface() returns empty and node.cfg is not written.
zeek_settings_resync();

// 3. Verify node.cfg was written with the correct interface.
//    If not (physical trunk name), write it directly.
$node_cfg = file_exists(ZEEK_NODE_CFG) ? file_get_contents(ZEEK_NODE_CFG) : '';
if (strpos($node_cfg, 'interface=' . $iface) === false) {
    $hostname = config_get_path('installedpackages/zeek/config/0/hostname', 'localhost');
    $content = <<<EOD
# Managed by SURU deploy — do not edit manually.
# Source: tier1-perimeter/pfsense/zeek-iface-apply.php
[zeek]
type=standalone
host={$hostname}
interface={$iface}

EOD;
    if (file_put_contents(ZEEK_NODE_CFG, $content) === false) {
        fwrite(STDERR, "[zeek-iface-apply] ERROR: failed to write " . ZEEK_NODE_CFG . "\n");
        exit(4);
    }
    chmod(ZEEK_NODE_CFG, 0640);
    echo "[zeek-iface-apply] zeek_settings_resync() did not set interface (physical trunk)." . PHP_EOL;
    echo "[zeek-iface-apply] Wrote node.cfg directly: interface={$iface}" . PHP_EOL;
} else {
    echo "[zeek-iface-apply] node.cfg confirmed: interface={$iface}" . PHP_EOL;
}

// --- Cleanup: remove the now-unnecessary cron/item self-heal job and its
// files from a previous version of this applier (2026-06-23). node.cfg is
// already durable without it — see the file header. Safe no-op if absent.
$zeek_dir     = '/usr/local/etc/zeek';
$zeek_marker  = $zeek_dir . '/suru-active-interface';
$zeek_boot_sh = $zeek_dir . '/suru-boot-apply.sh';

$cron_items = config_get_path('cron/item', []);
$cron_items_before = count($cron_items);
$cron_items = array_values(array_filter($cron_items, function ($i) use ($zeek_boot_sh) {
    return strpos((string)($i['command'] ?? ''), $zeek_boot_sh) === false;
}));
if (count($cron_items) !== $cron_items_before) {
    config_set_path('cron/item', $cron_items);
    write_config('SURU: removed superseded Zeek interface self-heal cron job');
    configure_cron();
    echo "[zeek-iface-apply] Removed superseded cron/item entry for {$zeek_boot_sh}." . PHP_EOL;
}
@unlink($zeek_boot_sh);
@unlink($zeek_marker);

echo "[zeek-iface-apply] Done. Caller must run 'zeekctl deploy' to activate." . PHP_EOL;
