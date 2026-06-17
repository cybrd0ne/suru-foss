# SURU Platform — DNS entropy-based tunneling detection
# Detects high-entropy DNS queries indicative of DNS tunneling / C2 over DNS.
# MITRE ATT&CK: TA0011 Command and Control / T1071.004 DNS
# Validation: zeek -b suru-dns-entropy.zeek
#
# SOURCE OF TRUTH: tier2-telemetry/zeek/scripts/

# Load the notice framework explicitly (SEC-045). This script defines a
# Notice::Type and calls NOTICE(); it currently works only because suru-base.zeek
# happens to pull in the framework transitively (intel/do_notice) and loads first
# under filesystem-sort order. Loading it here makes the script self-contained and
# robust to load-order changes.
@load base/frameworks/notice

module SURU_DNS;

export {
    redef enum Notice::Type += {
        ## Fired when a DNS query subdomain exceeds the entropy threshold
        DNS_High_Entropy_Query
    };

    ## Minimum query label length to evaluate
    const min_label_len: count = 20 &redef;

    ## Shannon entropy threshold (bits per character) above which alert fires
    const entropy_threshold: double = 3.8 &redef;
}

function shannon_entropy(s: string): double
    {
    local freq: table[string] of count;
    local len = |s|;
    if ( len == 0 ) return 0.0;
    # Zeek 6.x: for-in over a string yields each character as a string
    for ( ch in s )
        {
        if ( ch !in freq ) freq[ch] = 0;
        ++freq[ch];
        }
    local entropy = 0.0;
    for ( ch in freq )
        {
        local p = freq[ch] * 1.0 / len;
        entropy -= p * ln(p) / ln(2.0);
        }
    return entropy;
    }

event dns_request(c: connection, msg: dns_msg, query: string, qtype: count, qclass: count)
    {
    # Only evaluate the leftmost label (subdomain portion)
    local parts = split_string(query, /\./);
    if ( |parts| < 2 ) return;
    local label = parts[0];
    if ( |label| < min_label_len ) return;

    local e = shannon_entropy(label);
    if ( e >= entropy_threshold )
        {
        NOTICE([
            $note        = DNS_High_Entropy_Query,
            $conn        = c,
            $msg         = fmt("High-entropy DNS subdomain: %s (entropy=%.2f) — T1071.004", query, e),
            # Per-(host,query) suppression: each distinct high-entropy query alerts
            # once per 10 min. If a DGA host floods many distinct names and the
            # notice volume becomes noisy, switch to per-host suppression by using
            # `cat(c$id$orig_h)` here (one alert per host per window).
            $identifier  = cat(c$id$orig_h, query),
            $suppress_for = 10min
        ]);
        }
    }
