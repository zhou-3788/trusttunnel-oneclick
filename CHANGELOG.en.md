# Changelog

[简体中文](CHANGELOG.md) | English

## v1.2.1 — 2026-10-05

- Remove personal identifiers from the default username and exported server name; use `ttuser` and `TrustTunnel`.
- Use `tt.example.com` for domain examples; deployment environments supply real domains, IP addresses, and credentials.
- Preserve credentials in existing installations and refresh published checksums.

## v1.2 — 2026-10-05

- Add an English script, README, and changelog. Both languages manage the same service and configuration.
- Default to existing certificate discovery during installation; select a number to fill the domain, certificate chain, and private key paths.
- Scan Certbot, acme.sh, and certificate references in common service configurations; support additional directories and manual entry.
- Add menu 11 and `--scan-certs [directory]` to list existing certificates and domains without changing configuration.
- Validate certificate dates, hostname coverage, and matching private keys; require an explicit positive OpenSSL hostname match.

## v1.1 — 2026-10-05

- Support `TT_DEFAULT_PORT` and selecting a port during initial installation.
- Add menu 10 and `--change-port`, preserving credentials and other configuration settings.
- Generate a new mobile link after a successful change; restore the previous port and configuration if startup fails.

## v1.0 — 2026-10-05

- Provide an installation and management menu using the official installer and configuration format.
- Enable HTTP/2 and QUIC; support Certbot, self-signed, and existing certificates.
- Export `tt://` mobile configuration links and terminal QR codes.
- Use a dedicated systemd service and configuration directory, with update rollback, certificate maintenance, and uninstall actions.
