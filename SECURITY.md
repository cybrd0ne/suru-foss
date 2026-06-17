# Security Policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions, or pull requests.**

Instead, use GitHub's **private vulnerability reporting**:
*Security → Report a vulnerability* on this repository. If that is unavailable,
contact the maintainers privately via the address listed on the repository's
profile.

When reporting, please include:

- A description of the issue and the affected tier/component.
- Steps to reproduce or a proof of concept.
- The impact you foresee (e.g. ingestion bypass, TLS downgrade, RCE).
- Any suggested remediation.

We aim to acknowledge reports within a few days and will keep you updated as we
investigate. Please give us reasonable time to release a fix before public
disclosure (coordinated disclosure).

## Scope

This project is **defensive security tooling** for self-hosted SOHO networks. In
scope: the deployment scripts, Docker Compose definitions, TLS/PKI handling,
Logstash pipelines, detection content, and dashboards in this repository.

Out of scope: vulnerabilities in upstream projects (OpenSearch, Suricata, Zeek,
nginx, pfSense/OPNsense, etc.) — report those to the respective projects. If a
SURU default configuration makes an upstream issue materially worse, that *is* in
scope and we want to hear about it.

## Hardening baseline

Contributions are expected to preserve the platform's security defaults:

- TLS everywhere (min 1.2, prefer 1.3); mTLS for service-to-service log shipping.
- Containers run non-root with `cap_drop: [ALL]`, `no-new-privileges`, pinned
  images, and never mount the Docker socket.
- No secrets in the repository; runtime secrets come from `.env` / Docker secrets.
- Firewall default deny-all; local-first data handling with opt-in cloud export.

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the full standards.
