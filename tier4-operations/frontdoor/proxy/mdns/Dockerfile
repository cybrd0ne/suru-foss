# =============================================================================
# SURU — Tier 4 Frontdoor: mDNS responder (avahi-daemon)
# =============================================================================
# Advertises the frontdoor's reachable names (FRONTDOOR_MDNS_ALIASES, default
# `suru.local` and `soc.local`) on the local LAN via mDNS, so macOS / Linux
# clients can resolve them without router DNS. Runs as a sidecar to
# suru.t4.frontdoor.proxy with `network_mode: host` — mDNS multicast cannot
# traverse Docker bridge networks.
#
# No D-Bus: avahi-daemon is configured with enable-dbus=no. Aliases are
# published via /etc/avahi/hosts written at container start, which avahi reads
# natively. This eliminates the dbus-daemon PID-file restart problem and the
# avahi-publish name-collision crash loop.
#
# Validate: docker build -t suru-t4-frontdoor-mdns .
# =============================================================================
FROM alpine:3.20.10@sha256:c64c687cbea9300178b30c95835354e34c4e4febc4badfe27102879de0483b5e

RUN apk add --no-cache \
      avahi \
      bash \
 && rm -rf /var/cache/apk/*

# Configure avahi-daemon:
#   enable-dbus=no      — no dbus dependency; avahi reads /etc/avahi/hosts instead
#   host-name=…        — neutral name so avahi does not auto-claim suru.local /
#                          soc.local or whatever aliases the operator configures
RUN sed -i \
      -e 's/^\s*#\?\s*enable-dbus\s*=.*/enable-dbus=no/' \
      -e 's/^\s*#\?\s*host-name\s*=.*/host-name=suru-t4-mdns-sidecar/' \
      /etc/avahi/avahi-daemon.conf \
 && grep -q '^enable-dbus=no' /etc/avahi/avahi-daemon.conf || \
      sed -i '/^\[server\]/a enable-dbus=no' /etc/avahi/avahi-daemon.conf \
 && grep -q '^host-name=' /etc/avahi/avahi-daemon.conf || \
      sed -i '/^\[server\]/a host-name=suru-t4-mdns-sidecar' /etc/avahi/avahi-daemon.conf

# /etc/avahi is already present from the avahi package; chown -R so the
# entrypoint (running as avahi) can write /etc/avahi/hosts at startup. The
# recursive chown is required because the avahi package ships /etc/avahi/hosts
# as a root:root file — chowning only the directory leaves that file unwritable,
# and the entrypoint truncates it in place (`: >`), which needs write permission
# on the file itself, not just the parent dir (→ "Permission denied" otherwise).
# /run/avahi-daemon is created by avahi-daemon itself on the tmpfs /run mount
# (mode=1777 in compose.yaml so the avahi user can mkdir it at runtime).
RUN chown -R avahi:avahi /etc/avahi

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN  chmod +x /usr/local/bin/entrypoint.sh

USER avahi
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
