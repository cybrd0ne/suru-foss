# SURU Platform — Suricata 7.x engine configuration template
# Mode: AF_PACKET IDS / NFQ inline IPS
# Validation: suricata --test-config -c /etc/suricata/suricata.yaml
# MITRE ATT&CK: TA0001 Initial Access, TA0011 C2, TA0010 Exfiltration
#   T1071 (Application Layer Protocol), T1566 (Phishing), T1595 (Active Scanning)
#
# TEMPLATE: tier1-perimeter/templates/suricata/suricata.yaml.tpl
# Rendered by: tier1-perimeter/scripts/platforms/pfsense.sh _pf_deploy_suricata
# Rule selection policy: tier2-telemetry/suricata/rule-selection/
# Rendered rule files: tier1-perimeter/rendered/<platform>/suricata/

%YAML 1.1
---

##############################################################################
# Global settings
##############################################################################

max-pending-packets: 1024
default-packet-size: 1514

vars:
  address-groups:
    HOME_NET: "[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]"
    EXTERNAL_NET: "!$HOME_NET"
    HTTP_SERVERS: "$HOME_NET"
    SMTP_SERVERS: "$HOME_NET"
    SQL_SERVERS: "$HOME_NET"
    DNS_SERVERS: "$HOME_NET"
    TELNET_SERVERS: "$HOME_NET"
    AIM_SERVERS: "$EXTERNAL_NET"
    DNP3_SERVER: "$HOME_NET"
    DNP3_CLIENT: "$HOME_NET"
    MODBUS_CLIENT: "$HOME_NET"
    MODBUS_SERVER: "$HOME_NET"
    ENIP_CLIENT: "$HOME_NET"
    ENIP_SERVER: "$HOME_NET"
  port-groups:
    HTTP_PORTS: "80"
    SHELLCODE_PORTS: "!80"
    ORACLE_PORTS: 1521
    SSH_PORTS: 22
    DNP3_PORTS: 20000
    MODBUS_PORTS: 502
    FILE_DATA_PORTS: "[$HTTP_PORTS,110,143]"
    FTP_PORTS: 21
    VXLAN_PORTS: 4789
    TEREDO_PORTS: 3544

##############################################################################
# Capture — multi-interface AF_PACKET
# Token __SURICATA_AF_PACKET__ is expanded by render-suricata.sh into one
# af-packet entry per interface from SURICATA_IFACES (comma-separated,
# e.g. "lan,opt1" for pfSense logical names or "eth0,eth1" for standalone).
# Each interface receives a unique cluster-id (99, 98, 97, …).
##############################################################################

af-packet:
__SURICATA_AF_PACKET__

##############################################################################
# Outputs — EVE-JSON (ECS-compatible field names)
##############################################################################

outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: /var/log/suricata/eve.json
      pcap-file: false
      community-id: true
      community-id-seed: 0
      xff:
        enabled: no
      types:
        - alert:
            payload: no
            payload-buffer-size: 4kb
            payload-printable: yes
            packet: yes
            metadata: yes
            http-body: yes
            http-body-printable: yes
            tagged-packets: yes
        - anomaly:
            enabled: yes
            types:
              decode: yes
              stream: yes
              applayer: yes
        - http:
            extended: yes
        - dns:
            version: 2
        - tls:
            extended: yes
        - files:
            force-magic: no
        - smtp: {}
        - dnp3: {}
        - nfs: {}
        - ike: {}
        - krb5: {}
        - dhcp:
            enabled: yes
            extended: yes
        - ssh: {}
        - stats:
            totals: yes
            threads: no
            deltas: no
        - flow: {}

  - fast:
      enabled: no

  - stats:
      enabled: yes
      filename: /var/log/suricata/stats.log
      append: yes
      totals: yes
      threads: yes
      null-values: no

##############################################################################
# Rule management (suricata-update)
# Rule selection policy lives in: tier2-telemetry/suricata/rule-selection/
# Rendered to: tier1-perimeter/rendered/<platform>/suricata/
##############################################################################

default-rule-path: /etc/suricata/rules

rule-files:
  - suricata.rules
  - suru-custom.rules

##############################################################################
# Engine configuration
##############################################################################

detect:
  profile: medium
  custom-values:
    toclient-groups: 3
    toserver-groups: 25
  sgh-mpm-context: auto
  inspection-recursion-limit: 3000
  prefilter:
    default: mpm
  grouping: {}
  profiling:
    grouping:
      dump-to-disk: false
      include-rules: false
      include-mpm-stats: false

app-layer:
  protocols:
    tls:
      enabled: yes
      detection-ports:
        dp: 443
      ja3-fingerprints: auto
    http:
      enabled: yes
      libhtp:
        default-config:
          personality: IDS
          request-body-limit: 100kb
          response-body-limit: 100kb
          request-body-minimal-inspect-size: 32kb
          request-body-inspect-window: 4kb
          response-body-minimal-inspect-size: 40kb
          response-body-inspect-window: 16kb
          response-body-decompress-layer-limit: 2
          http-body-inline: auto
          swf-decompression:
            enabled: yes
            type: both
            compress-depth: 100kb
            decompress-depth: 100kb
          double-decode-path: no
          double-decode-query: no
    dns:
      tcp:
        enabled: yes
        detection-ports:
          dp: 53
      udp:
        enabled: yes
        detection-ports:
          dp: 53
    smtp:
      enabled: yes
      raw-extraction: no
      mime:
        decode-mime: yes
        decode-base64: yes
        decode-quoted-printable: yes
        header-value-depth: 2000
        extract-urls: yes
        body-md5: no
    ssh:
      enabled: yes
      hassh: yes

##############################################################################
# Profiling & limits
##############################################################################

profiling:
  rules:
    enabled: yes
    filename: /var/log/suricata/rule_perf.log
    append: yes
    limit: 10
    json: yes
  keywords:
    enabled: no
  rulegroups:
    enabled: no
  packets:
    enabled: yes
    filename: /var/log/suricata/packet_stats.log
    append: yes
    csv:
      enabled: no
      filename: /var/log/suricata/packet_stats.csv
  locks:
    enabled: no
  pcap-log:
    enabled: no

host-mode: sniffer-only

runmode: autofp

logging:
  default-log-level: notice
  default-output-filter:
  outputs:
    - console:
        enabled: yes
    - file:
        enabled: yes
        level: info
        filename: /var/log/suricata/suricata.log
    - syslog:
        enabled: no
        facility: local5
        format: "[%i] <%d> -- "
