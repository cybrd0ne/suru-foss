# =============================================================================
# SURU Platform — syslog-ng OPNsense Security Log Forwarder
# Version: 0.1.0-stub
# Target OPNsense: 24.x (FreeBSD 14, syslog-ng 4.x)
#
# TEMPLATE: tier1-perimeter/templates/opnsense/syslog-ng.conf.tpl
# Rendered by: tier1-perimeter/scripts/platforms/opnsense.sh _opn_deploy_syslogng
#
# STATUS: Log source paths marked [STUB] have NOT been validated on a live
# OPNsense 24.x instance. Validate each path before production use.
# Destination block (mTLS → Tier 4 frontdoor) is byte-identical to the
# pfSense template and is production-ready.
#
# Template tokens (aligned with pfSense template):
#   @@FRONTDOOR_SYSLOG_SNI@@ — SNI hostname for the frontdoor stream demux (env: FRONTDOOR_SYSLOG_SNI, default: syslog.suru.local)
#   @@FRONTDOOR_PORT@@       — Frontdoor port, literal 443 (env: FRONTDOOR_PORT, default: 443)
#   @@SENSOR_NAME@@          — human label for this sensor    (env: ROUTER_SENSOR_NAME, default: suru-tier1-opn)
#   @@WAN_IFACE@@            — WAN interface name (env: WAN_IFACE, default: igb0)
#   @@LAN_IFACE@@            — LAN interface name (env: LAN_IFACE, default: igb1)
#
# Log sources (OPNsense paths — validate each [STUB] before use):
#   Suricata EVE  /var/log/suricata/eve.json              [STUB: confirm on OPNsense 24.x — no per-iface dirs on default pkg]
#   Zeek          (commented out)                         [STUB: no standard OPNsense Zeek package; enable when available]
#   Resolver      /var/log/resolver/resolver.log           [STUB: confirm unbound log path on OPNsense 24.x]
#   DHCP          /var/log/dhcpd.log                       [STUB: confirm dhcpd/Kea log path on OPNsense 24.x]
#   Firewall/auth /var/run/log, /var/run/logpriv           same as pfSense — confirmed in OPNsense docs
#
# TLS cert paths (written by deploy script):
#   /usr/local/etc/syslog-ng/tls/ca/root-ca.pem  — SURU Root CA (ca-dir + openssl rehash symlinks)
#   /usr/local/etc/syslog-ng/tls/client.pem      — client certificate
#   /usr/local/etc/syslog-ng/tls/client-key.pem  — client private key (0600)
#
# Key OPNsense differences from pfSense:
#   - syslog-ng config dir: /usr/local/etc/syslog-ng.conf.d/  (drop-in, not monolithic)
#   - Service restart: configctl syslog restart  (not pfSsh.php pluginctl)
#   - Suricata: single eve.json, no per-interface UUID subdirs (default pkg layout)
#   - Zeek: not available as a standard OPNsense package
# =============================================================================

@version: 4.6
@include "scl.conf"

options {
    flush_lines(0);
    time_reopen(10);
    log_fifo_size(10000);
    chain_hostnames(off);
    use_dns(no);
    use_fqdn(yes);
    dns_cache(no);
    keep_hostname(yes);
    stats(freq(3600));
    bad_hostname("^gconfd$");
    trim_large_messages(yes);
};

# --- Destination -------------------------------------------------------------
# Byte-identical to the pfSense template — the mTLS frontdoor contract is
# platform-agnostic.

destination d_siem_tls {
    network(
        "@@FRONTDOOR_SYSLOG_SNI@@"
        port(@@FRONTDOOR_PORT@@)
        transport("tls")
        tls(
            ca-dir("/usr/local/etc/syslog-ng/tls/ca")
            cert-file("/usr/local/etc/syslog-ng/tls/client.pem")
            key-file("/usr/local/etc/syslog-ng/tls/client-key.pem")
            peer-verify(required-trusted)
            ssl-options(no-sslv2, no-sslv3, no-tlsv1, no-tlsv11, no-tlsv12)
            sni(yes)
        )
        keep-alive(yes)
        so-keepalive(yes)
        log-fifo-size(10000)
        throttle(0)
        # Inlined JSON template — kept byte-identical to the pfSense template's
        # destination. A named `template t_json_base` object is deliberately
        # NOT used: on pfSense, syslogng_resync() re-emits templates AFTER the
        # destinations that reference them, and syslog-ng does not forward-
        # resolve template() refs, silently degrading the reference to the
        # literal string "t_json_base" (see tier1 SKILL §10c). Inlining keeps
        # both platform templates immune to that class of bug.
        template("$(format-json \
            time=$ISODATE \
            host=$HOST \
            facility=$FACILITY \
            severity=$LEVEL \
            program=$PROGRAM \
            pid=$PID \
            message=$MSG \
            raw_message=$RAWMSG \
            syslog_tag=$SYSLOGTAG \
            source_type=syslog \
            sensor=@@SENSOR_NAME@@ \
        )\n")
    );
};

destination d_local_fallback {
    file("/var/log/suru-syslog-ng-buffer.log"
        create-dirs(yes)
        perm(0640)
        owner("root")
        group("wheel")
    );
};

# --- Sources -----------------------------------------------------------------

source s_opnsense_syslog {
    unix-dgram("/var/run/log" flags(no-parse));
    unix-dgram("/var/run/logpriv" flags(no-parse) perm(0600));
};

# MITRE ATT&CK: TA0009 Collection / T1005 Data from Local System
# [STUB: OPNsense 24.x default Suricata package writes a single eve.json
# at /var/log/suricata/eve.json — no per-interface UUID subdirs.
# Validate path on a live OPNsense before enabling in production.]
source s_suricata_eve {
    file("/var/log/suricata/eve.json"
        follow-freq(1)
        flags(no-parse)
        program-override("suricata")
        optional(yes)
    );
};

# MITRE ATT&CK: TA0009 Collection / T1005 Data from Local System
# [STUB: Zeek is not available as a standard OPNsense package.
# Uncomment and validate paths when a Zeek integration is available.]
# source s_zeek_conn   { file("/var/log/zeek/conn.log"   follow-freq(1) flags(no-parse) program-override("zeek-conn")   optional(yes)); };
# source s_zeek_dns    { file("/var/log/zeek/dns.log"    follow-freq(1) flags(no-parse) program-override("zeek-dns")    optional(yes)); };
# source s_zeek_http   { file("/var/log/zeek/http.log"   follow-freq(1) flags(no-parse) program-override("zeek-http")   optional(yes)); };
# source s_zeek_ssl    { file("/var/log/zeek/ssl.log"    follow-freq(1) flags(no-parse) program-override("zeek-ssl")    optional(yes)); };
# source s_zeek_notice { file("/var/log/zeek/notice.log" follow-freq(1) flags(no-parse) program-override("zeek-notice") optional(yes)); };
# source s_zeek_weird  { file("/var/log/zeek/weird.log"  follow-freq(1) flags(no-parse) program-override("zeek-weird")  optional(yes)); };
# source s_zeek_files  { file("/var/log/zeek/files.log"  follow-freq(1) flags(no-parse) program-override("zeek-files")  optional(yes)); };

source s_openvpn { file("/var/log/openvpn.log" follow-freq(1) flags(no-parse) program-override("openvpn") optional(yes)); };
source s_ipsec   { file("/var/log/ipsec.log"   follow-freq(1) flags(no-parse) program-override("ipsec")   optional(yes)); };

# MITRE ATT&CK: TA0009 Collection / T1005 Data from Local System
# [STUB: OPNsense unbound log path — validate on OPNsense 24.x.
# Common locations: /var/log/resolver/resolver.log or /var/unbound/unbound.log]
source s_resolver { file("/var/log/resolver/resolver.log" follow-freq(1) flags(no-parse) program-override("unbound") optional(yes)); };

# MITRE ATT&CK: TA0009 Collection / T1005 Data from Local System
# [STUB: OPNsense dhcpd/Kea log path — validate on OPNsense 24.x.
# ISC dhcpd: /var/log/dhcpd.log; Kea DHCP: check /var/log/kea-dhcp*.log]
source s_dhcpd { file("/var/log/dhcpd.log" follow-freq(1) flags(no-parse) program-override("dhcpd") optional(yes)); };

# --- Filters -----------------------------------------------------------------

filter f_firewall   { program("filterlog"); };
filter f_dhcp       { program("dhcpd") or program("dhclient") or program("kea-dhcp4") or program("kea-dhcp6"); };
filter f_dns_all    { program("unbound") or program("dnsmasq"); };
filter f_vpn        { program("openvpn") or program("ipsec") or program("charon"); };
filter f_auth       { facility(auth, authpriv); };
filter f_suricata   { program("suricata") or program("suricata-fast"); };
filter f_drop_noise { match("last message repeated" value("MESSAGE")) or program("cron"); };

# --- Rewrites ----------------------------------------------------------------

rewrite r_add_tag_firewall { set("opnsense-firewall", value(".suru.log_type")); };
rewrite r_add_tag_dhcp     { set("opnsense-dhcp",     value(".suru.log_type")); };
rewrite r_add_tag_dns      { set("opnsense-dns",      value(".suru.log_type")); };
rewrite r_add_tag_vpn      { set("opnsense-vpn",      value(".suru.log_type")); };
rewrite r_add_tag_auth     { set("opnsense-auth",     value(".suru.log_type")); };
rewrite r_add_tag_suricata { set("suricata-eve",      value(".suru.log_type")); };
rewrite r_add_hostname     { set("${HOST}",           value(".suru.sensor")); };
rewrite r_add_tier         { set("tier1-perimeter",   value(".suru.tier")); };
rewrite r_add_version      { set("0.1.0-stub",        value(".suru.config_version")); };

# --- Log paths ---------------------------------------------------------------

log { source(s_opnsense_syslog); filter(f_drop_noise); flags(final); };

log { source(s_opnsense_syslog); filter(f_firewall);
      rewrite(r_add_tag_firewall); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); destination(d_local_fallback); };

log { source(s_opnsense_syslog); source(s_dhcpd); filter(f_dhcp);
      rewrite(r_add_tag_dhcp); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_opnsense_syslog); source(s_resolver); filter(f_dns_all);
      rewrite(r_add_tag_dns); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_opnsense_syslog); source(s_openvpn); source(s_ipsec); filter(f_vpn);
      rewrite(r_add_tag_vpn); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_opnsense_syslog); filter(f_auth);
      rewrite(r_add_tag_auth); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_suricata_eve); filter(f_suricata);
      rewrite(r_add_tag_suricata); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

# [STUB: uncomment when Zeek sources are validated on OPNsense]
# log { source(s_zeek_conn); source(s_zeek_dns); source(s_zeek_http); source(s_zeek_ssl);
#       source(s_zeek_notice); source(s_zeek_weird); source(s_zeek_files);
#       rewrite(r_add_tag_zeek); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
#       destination(d_siem_tls); };
