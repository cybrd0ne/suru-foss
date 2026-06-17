# =============================================================================
# SURU — Tier 4 Frontdoor: git-sync sidecar (suru-frontdoor-content)
# =============================================================================
# Periodically pulls the suru-frontdoor-content repository into the shared
# `frontdoor-content` Docker volume. nginx (the proxy container next to this
# one) serves the synced files at the frontdoor's `/` route.
#
# Auth: GitHub fine-grained PAT (Contents: read-only) passed via
#       CONTENT_REPO_TOKEN. The token is handed to git through GIT_ASKPASS
#       so it never lives in git config on disk.
#
# Image is built in-tree (alpine + git) — no third-party dependency.
# Validate: docker build -t suru-t4-frontdoor-content-sync .
# =============================================================================
FROM alpine:3.20.10@sha256:c64c687cbea9300178b30c95835354e34c4e4febc4badfe27102879de0483b5e

RUN apk add --no-cache git openssh-client ca-certificates \
 && rm -rf /var/cache/apk/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN  chmod +x /usr/local/bin/entrypoint.sh

# Static GIT_ASKPASS helper baked onto the (exec-allowed) rootfs so the sidecar
# can run non-root with a noexec /tmp. Contains no secret — reads the token from
# CONTENT_REPO_TOKEN at runtime.
COPY git-askpass /usr/local/bin/git-askpass
RUN  chmod 0755 /usr/local/bin/git-askpass

# git defaults sized for sidecar use — no detached-HEAD warnings, no
# safe.directory complaints. Use --system (/etc/gitconfig) so the settings apply
# to the non-root runtime user (uid 1001) too — --global would only write
# /root/.gitconfig and be invisible once we drop privileges.
RUN git config --system advice.detachedHead false \
 && git config --system safe.directory '*'

# Run as a non-root sidecar user (SEC-038). The shared /content volume is chowned
# to 1001 by the content-volume-init container before this starts. git-askpass is
# baked into /usr/local/bin/git-askpass (above) so no runtime root-FS write is
# needed — it executes from the image layer, not the noexec /tmp tmpfs.
RUN adduser -D -u 1001 content-sync
USER content-sync

WORKDIR /content
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
