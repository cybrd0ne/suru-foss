# =============================================================================
# SURU Platform — syslog-ng pfSense Comprehensive Security Log Forwarder
# Version: 2.1.0
# Target pfSense: 2.7.x / 2.8.x / 24.x (FreeBSD 14, syslog-ng 4.6)
# Install path: /usr/local/etc/syslog-ng.conf
#
# Template tokens (substituted by pfsense.sh _pf_deploy_syslogng):
#   @@FRONTDOOR_SYSLOG_SNI@@ — SNI hostname for the frontdoor stream demux (env: FRONTDOOR_SYSLOG_SNI, default: syslog.suru.local)
#   @@FRONTDOOR_PORT@@       — Frontdoor port, literal 443 (env: FRONTDOOR_PORT, default: 443)
#   @@SENSOR_NAME@@          — human label for this sensor (env: ROUTER_SENSOR_NAME, default: pfsense-tier1)
#   @@WAN_IFACE@@      — WAN interface name             (env: WAN_IFACE, default: igb0)
#   @@LAN_IFACE@@      — LAN interface name             (env: LAN_IFACE, default: igb1)
#
# TLS cert paths (written by deploy script under _PF_SYSLOGNG_TLS):
#   /usr/local/etc/syslog-ng/tls/root-ca.pem     — SURU Root CA
#   /usr/local/etc/syslog-ng/tls/client.pem      — client certificate
#   /usr/local/etc/syslog-ng/tls/client-key.pem  — client private key (0600)
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

destination d_siem_tls {
    network(
        "@@FRONTDOOR_SYSLOG_SNI@@"
        port(@@FRONTDOOR_PORT@@)
        transport("tls")
        tls(
            ca-file("/usr/local/etc/syslog-ng/tls/root-ca.pem")
            cert-file("/usr/local/etc/syslog-ng/tls/client.pem")
            key-file("/usr/local/etc/syslog-ng/tls/client-key.pem")
            peer-verify(required-trusted)
            ssl-options(no-sslv2, no-sslv3, no-tlsv1, no-tlsv11, no-tlsv12)
            sni(yes)
            cipher-suite("TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256")
        )
        keep-alive(yes)
        so-keepalive(yes)
        log-fifo-size(10000)
        throttle(0)
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

template t_json_base {
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
    )\n");
};

source s_pfsense_syslog {
    unix-dgram("/var/run/log" flags(no-parse));
    unix-dgram("/var/run/logpriv" flags(no-parse) perm(0600));
    internal();
};

source s_syslog_udp {
    udp(ip("127.0.0.1") port(514) flags(no-parse));
};

source s_suricata_eve_wan {
    file("/var/log/suricata/suricata_@@WAN_IFACE@@/eve.json"
        follow-freq(1) flags(no-parse) program-override("suricata"));
};

source s_suricata_eve_lan {
    file("/var/log/suricata/suricata_@@LAN_IFACE@@/eve.json"
        follow-freq(1) flags(no-parse) program-override("suricata"));
};

source s_zeek_conn     { file("/usr/local/logs/zeek/current/conn.log"     follow-freq(1) flags(no-parse) program-override("zeek-conn"));     };
source s_zeek_dns      { file("/usr/local/logs/zeek/current/dns.log"      follow-freq(1) flags(no-parse) program-override("zeek-dns"));      };
source s_zeek_http     { file("/usr/local/logs/zeek/current/http.log"     follow-freq(1) flags(no-parse) program-override("zeek-http"));     };
source s_zeek_ssl      { file("/usr/local/logs/zeek/current/ssl.log"      follow-freq(1) flags(no-parse) program-override("zeek-ssl"));      };
source s_zeek_notice   { file("/usr/local/logs/zeek/current/notice.log"   follow-freq(1) flags(no-parse) program-override("zeek-notice"));   };
source s_zeek_weird    { file("/usr/local/logs/zeek/current/weird.log"    follow-freq(1) flags(no-parse) program-override("zeek-weird"));    };
source s_zeek_files    { file("/usr/local/logs/zeek/current/files.log"    follow-freq(1) flags(no-parse) program-override("zeek-files"));    };
source s_pfblocker_dnsbl  { file("/var/log/pfblockerng/dnsbl.log"         follow-freq(1) flags(no-parse) program-override("pfblockerng-dnsbl")); };
source s_pfblocker_ip     { file("/var/log/pfblockerng/pfblockerng.log"   follow-freq(1) flags(no-parse) program-override("pfblockerng-ip"));   };
source s_openvpn   { file("/var/log/openvpn.log"    follow-freq(1) flags(no-parse) program-override("openvpn")); };
source s_ipsec     { file("/var/log/ipsec.log"      follow-freq(1) flags(no-parse) program-override("ipsec"));   };
source s_unbound   { file("/var/unbound/unbound.log" follow-freq(1) flags(no-parse) program-override("unbound")); };

filter f_firewall     { program("filterlog"); };
filter f_dhcp         { program("dhcpd") or program("dhclient"); };
filter f_dns_all      { program("unbound") or program("dnsmasq"); };
filter f_vpn          { program("openvpn") or program("ipsec") or program("charon"); };
filter f_auth         { facility(auth, authpriv); };
filter f_suricata     { program("suricata") or program("suricata-fast"); };
filter f_zeek         { program("zeek-conn") or program("zeek-dns") or program("zeek-http") or program("zeek-ssl") or program("zeek-notice") or program("zeek-weird") or program("zeek-files"); };
filter f_pfblocker    { program("pfblockerng-dnsbl") or program("pfblockerng-ip"); };
filter f_drop_noise   { match("last message repeated" value("MESSAGE")) or program("cron"); };

rewrite r_add_tag_firewall  { set("pfsense-firewall",   value(".suru.log_type")); };
rewrite r_add_tag_dhcp      { set("pfsense-dhcp",       value(".suru.log_type")); };
rewrite r_add_tag_dns       { set("pfsense-dns",        value(".suru.log_type")); };
rewrite r_add_tag_vpn       { set("pfsense-vpn",        value(".suru.log_type")); };
rewrite r_add_tag_auth      { set("pfsense-auth",       value(".suru.log_type")); };
rewrite r_add_tag_suricata  { set("suricata-eve",       value(".suru.log_type")); };
rewrite r_add_tag_zeek      { set("zeek",               value(".suru.log_type")); };
rewrite r_add_tag_pfblocker { set("pfblockerng",        value(".suru.log_type")); };
rewrite r_add_hostname      { set("${HOST}",            value(".suru.sensor")); };
rewrite r_add_tier          { set("tier1-perimeter",    value(".suru.tier")); };
rewrite r_add_version       { set("2.1.0",              value(".suru.config_version")); };

log { source(s_pfsense_syslog); source(s_syslog_udp); filter(f_drop_noise); flags(final); };

log { source(s_pfsense_syslog); source(s_syslog_udp); filter(f_firewall);
      rewrite(r_add_tag_firewall); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); destination(d_local_fallback); };

log { source(s_pfsense_syslog); source(s_syslog_udp); filter(f_dhcp);
      rewrite(r_add_tag_dhcp); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_pfsense_syslog); source(s_syslog_udp); source(s_unbound); filter(f_dns_all);
      rewrite(r_add_tag_dns); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_pfsense_syslog); source(s_syslog_udp); source(s_openvpn); source(s_ipsec); filter(f_vpn);
      rewrite(r_add_tag_vpn); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_pfsense_syslog); source(s_syslog_udp); filter(f_auth);
      rewrite(r_add_tag_auth); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_suricata_eve_wan); source(s_suricata_eve_lan); filter(f_suricata);
      rewrite(r_add_tag_suricata); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_zeek_conn); source(s_zeek_dns); source(s_zeek_http); source(s_zeek_ssl);
      source(s_zeek_notice); source(s_zeek_weird); source(s_zeek_files);
      rewrite(r_add_tag_zeek); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };

log { source(s_pfblocker_dnsbl); source(s_pfblocker_ip);
      rewrite(r_add_tag_pfblocker); rewrite(r_add_hostname); rewrite(r_add_tier); rewrite(r_add_version);
      destination(d_siem_tls); };
