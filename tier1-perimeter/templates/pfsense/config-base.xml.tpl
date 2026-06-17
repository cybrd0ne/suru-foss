<?xml version="1.0"?>
<!-- SURU Platform — pfSense baseline config template — managed by SURU -->
<!-- Replace <PLACEHOLDER> values before applying -->
<!-- Rendered by: tier1-perimeter/scripts/platforms/pfsense.sh -->
<pfsense>
  <version>21.7</version>
  <system>
    <hostname>fw01</hostname>
    <domain>internal.suru.local</domain>
    <!-- CIS Benchmark: disable unneeded services -->
    <ssh><enabled>enabled</enabled><port>22</port></ssh>
  </system>
  <!-- [STUB: pfBlockerNG XML export block — injected from rendered/pfsense/pfblockerng.xml] -->
  <!-- [STUB: Suricata interface config block] -->
</pfsense>
