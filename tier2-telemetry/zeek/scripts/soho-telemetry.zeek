# SURU Platform — Zeek SOHO telemetry suppression script
# Reduces log volume by suppressing RFC1918 → RFC1918 benign flows.
# All external (WAN-side) connections are always logged.
# MITRE ATT&CK: TA0010 Exfiltration detection via anomalous external conn volume.
#
# SOURCE OF TRUTH: tier2-telemetry/zeek/scripts/

# Explicit load: soho-telemetry is registered before suru-base alphabetically,
# so Conn::Info and Conn::log_policy may not yet be in scope when this file is
# compiled. Declaring the dependency here makes this script self-contained.
@load base/protocols/conn

module SOHO;

export {
    ## RFC1918 subnets — internal traffic suppressed if bidirectional and short-lived
    const private_nets: set[subnet] = {
        10.0.0.0/8,
        172.16.0.0/12,
        192.168.0.0/16
    } &redef;

    ## Minimum bytes transferred to log a local-to-local connection
    const local_conn_min_bytes: count = 10000 &redef;
}

# Drop RFC1918-only sub-threshold connections from conn.log before write.
# Log::PolicyHook fires before the record is committed; break drops it entirely.
# MITRE ATT&CK: TA0010 Exfiltration — retain only anomalous or external flows.
hook Conn::log_policy(rec: Conn::Info, id: Log::ID, filter: Log::Filter)
    {
    if ( rec$id$orig_h !in private_nets ) return;
    if ( rec$id$resp_h !in private_nets ) return;
    local ob: count = 0;
    if ( rec?$orig_bytes ) ob = rec$orig_bytes;
    local rb: count = 0;
    if ( rec?$resp_bytes ) rb = rec$resp_bytes;
    if ( ob + rb < local_conn_min_bytes )
        break;
    }
