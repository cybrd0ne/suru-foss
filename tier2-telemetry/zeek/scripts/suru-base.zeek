# SURU Platform — Zeek engine bootstrap (GUI-save resilient)
# SOURCE OF TRUTH: tier2-telemetry/zeek/scripts/
#
# WHY THIS IS A REGISTERED SCRIPT (not local.zeek):
#   pfSense's zeek_script_resync() rebuilds local.zeek from XML on every GUI
#   "Save" in Services > Zeek > Scripts, emitting only `@load <basename>` for
#   registered scripts. By living here, `@load suru-base` is always emitted by
#   resync, so base protocol analysis, engine tuning, the log directory, and the
#   intel framework SURVIVE any GUI save. Do not move these loads back into
#   local.zeek — they would be silently stripped on the next GUI save.
#
# MITRE ATT&CK: TA0007 Discovery / T1046 (network service / protocol visibility)
#               TA0011 Command and Control / T1071, T1071.004 (DNS/SSL/HTTP + intel)

# --- Base protocol stack (engine bootstrap — do not remove) ---
@load base/protocols/conn
@load base/protocols/dns
@load base/protocols/ssl
@load base/protocols/http
@load base/protocols/ftp
@load base/protocols/smtp
@load base/protocols/ssh
@load base/files/hash
# base/files/extract intentionally NOT loaded: no SURU script attaches the
# EXTRACT analyzer, so loading the framework only risks unbounded file carving
# to the /tmp RAM disk if a future/3rd-party policy enables extraction. Removed
# with the FileExtract::prefix redef below (SEC-044). Re-add both together —
# plus `redef FileExtract::default_limit` — if deliberate extraction is needed.
@load policy/protocols/ssl/validate-certs
@load policy/protocols/ssl/log-hostcerts-only
@load policy/tuning/json-logs

# --- Engine settings (GUI-proof) ---
redef Pcap::bufsize = 128;
redef Log::default_rotation_interval = 1hr;
# Live-log dir: must match pfsense.sh _PF_REMOTE_ZEEK_INTEL_DIR and zeekctl LogDir.
# Without this redef, Zeek writes live logs to SpoolDir, not /var/log/zeek.
redef Log::default_logdir = "/var/log/zeek";
# (FileExtract::prefix redef removed with the base/files/extract load — SEC-044.)
redef DNS::max_pending_msgs = 50000;

# --- Intel framework ---
@load base/frameworks/intel
@load policy/frameworks/intel/seen
@load policy/frameworks/intel/do_notice
# Path must match _PF_REMOTE_ZEEK_INTEL_DIR in pfsense.sh (/usr/local/share/zeek/intel).
# Corrected from the prior /usr/local/zeek/intel path which did not exist on disk.
redef Intel::read_files += { "/usr/local/share/zeek/intel/suru-ioc.dat" };
