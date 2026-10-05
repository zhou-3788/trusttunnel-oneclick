# TrustTunnel installer and manager

[简体中文](README.md) | English

Install the official TrustTunnel server on a Debian or Ubuntu VPS with an English menu, configurable ports, existing certificate discovery, and mobile configuration links and QR codes. Current script version: **v1.2**.

This is an independent installation and management script. Server binaries are downloaded from the [official TrustTunnel repository](https://github.com/TrustTunnel/TrustTunnel).

## Quick start

Supported: **Debian 12+ / Ubuntu 22.04+, x86_64 / aarch64, systemd, and public IPv4**. Run in an interactive SSH terminal on your VPS as root. If necessary, enter a root session with `sudo -i` first.

```bash
curl -fL --retry 3 --connect-timeout 15 --max-time 180 https://raw.githubusercontent.com/zhou-3788/trusttunnel-oneclick/main/trusttunnel-oneclick-en.sh -o trusttunnel-oneclick-en.sh && bash trusttunnel-oneclick-en.sh
```

If curl is missing, install it with `apt-get update && apt-get install -y curl ca-certificates`.

Select **1** to install. Confirm the public IP, port, certificate mode, and connection username. Press Enter at the password prompt to generate a random password. Download the script to a file before running it so interactive input remains available and the management shortcut can be installed.

After a new installation, reopen the saved management menu with:

```bash
tt-menu
```

The English and Chinese scripts manage the **same installation**, service, and configuration files. To open an English menu for a node previously installed with the Chinese script, run `bash trusttunnel-oneclick-en.sh`. The existing `tt-menu` shortcut retains its saved language until that saved script is replaced.

## Change the port

The default port is **8443**. HTTP/2 uses TCP; QUIC uses UDP on the same numeric port. Enter a different port during installation. Supported values are **443 or 1024-65535**.

To change the initial default:

```bash
TT_DEFAULT_PORT=9443 bash trusttunnel-oneclick-en.sh
```

For an existing installation, use **menu 10**, or run:

```bash
bash trusttunnel-oneclick-en.sh --change-port
```

A successful port change generates a new mobile configuration link. If startup fails, the previous configuration is restored. Allow the new **TCP and UDP** port in your cloud security group and reimport the new link on your phone. `TT_DEFAULT_PORT` only affects the first-install prompt; it does not change an existing node.

## Certificate modes

| Mode | Setup | Renewal |
| --- | --- | --- |
| 1 | Enter a domain and obtain a certificate with Certbot; point its A record to the VPS | Certbot renews automatically and notifies this service to reload |
| 2 | Use a public IP and generate a self-signed certificate valid for one year; hostname is `tt.local` | Renew using menu 8, then reimport the new link on your phone |
| 3 (default) | Scan existing certificates; choose a number to fill the domain, certificate chain, and private key paths | Keep the original renewal process; restart this service after the files are updated |

Discovery checks common directories and certificate references in Certbot, acme.sh, Xray, V2Ray, sing-box, Nginx, Apache, and Caddy configurations. Results include certificates that are already valid, remain valid for more than one day, cover a usable domain, and match an unencrypted private key.

At the selection prompt:

- Enter a number to select the domain, certificate chain, and private key automatically.
- Enter `D` to scan an additional directory specified by its absolute path.
- Enter `R` to rescan.
- Enter `M` to enter the domain and paths manually.
- Enter `0` to return to certificate mode selection.

For a wildcard such as `*.example.com`, discovery generates a covered example hostname such as `tt.example.com`. The connection address still uses the public VPS IP.

Use **menu 11** for a separate read-only scan, or run:

```bash
bash trusttunnel-oneclick-en.sh --scan-certs
bash trusttunnel-oneclick-en.sh --scan-certs /your/certificate/directory
```

A separate scan only lists results. It does not switch the certificate configuration of an existing node.

Certbot HTTP validation requires **TCP 80**. If an existing website occupies that port, provide its webroot path. For a domain managed through Cloudflare, set the relevant record to **DNS only (gray cloud)** when requesting a new certificate.

## Import on your phone

Install the [TrustTunnel Android client](https://play.google.com/store/apps/details?id=com.adguard.trusttunnel). Use **menu 2** to display the complete `tt://?...` link and terminal QR code.

On your phone, open the [official TrustTunnel import page](https://trusttunnel.org/qr.html), paste the complete link, select **Generate QR Code Locally**, then **Open in TrustTunnel App**. Save the imported server, connect from the Servers screen, and allow the system VPN permission.

Test with **HTTP/2** first, then try **QUIC**. The script configures an IPv4 exit. Self-signed certificates are embedded in the exported link; keep client certificate verification enabled. Reimport the configuration after issuing a new self-signed certificate.

The `tt://` link contains connection credentials. Use it on your own devices and keep it private.

## Management menu

| Menu | Action |
| --- | --- |
| 1 | Install; display connection settings if an installation already exists |
| 2 | Show mobile settings, link, and QR code |
| 3 | Show version, service status, listening ports, certificate dates, and logs |
| 4 / 5 / 6 | Restart / stop / start the service |
| 7 | Update the official server; restore the previous binaries on failure |
| 8 | Certificate maintenance or renewal check |
| 9 | Remove the managed service and dedicated files after confirmation |
| 10 | Change the port and generate a new link; restore the previous configuration on failure |
| 11 | Scan existing certificates and domains without changing configuration |
| 0 | Exit |

Command options:

```bash
bash trusttunnel-oneclick-en.sh --help
bash trusttunnel-oneclick-en.sh --install
bash trusttunnel-oneclick-en.sh --show
bash trusttunnel-oneclick-en.sh --status
bash trusttunnel-oneclick-en.sh --update
bash trusttunnel-oneclick-en.sh --check-cert
bash trusttunnel-oneclick-en.sh --change-port
bash trusttunnel-oneclick-en.sh --scan-certs
```

Menu 7 updates the official server binaries. To use a newer management script, download and run the newer `.sh` file.

## Configuration paths

| Path | Purpose |
| --- | --- |
| `/etc/trusttunnel-oneclick/vpn.toml` | Main server configuration, listening port, HTTP/2 and QUIC settings |
| `/etc/trusttunnel-oneclick/hosts.toml` | TLS hostname, certificate chain path, and private key path |
| `/etc/trusttunnel-oneclick/credentials.toml` | Connection username and password |
| `/etc/trusttunnel-oneclick/state.json` | Management state, including connection credentials |
| `/etc/trusttunnel-oneclick/client-link.txt` | Mobile import link |
| `/etc/trusttunnel-oneclick/certs/` | Self-signed certificate and private key for mode 2 |
| `/opt/trusttunnel-oneclick/bin/` | Official server executable |
| `/etc/systemd/system/trusttunnel-oneclick.service` | systemd service unit |
| `/usr/local/sbin/tt-menu` | Management shortcut saved during installation |

View recent logs:

```bash
journalctl -u trusttunnel-oneclick.service -n 50 --no-pager
```

Use menu 10 for port changes so the server configuration, management state, and mobile link stay consistent. Configuration files, private keys, and import links are readable only by root.

## Troubleshooting

- **Cannot connect:** Check the service status and allow the chosen TCP and UDP port in your VPS security group. Test public connectivity from your phone after confirming local listeners.
- **HTTP/2 works but QUIC does not:** Check UDP firewall rules and UDP connectivity on your current network.
- **No certificates found:** Add a location with `D` or `--scan-certs /directory`. Check validity, hostname coverage, and the matching unencrypted private key, or choose `M` for manual entry.
- **Connection fails after renewal:** Restart the service after external certificate files change. Reimport the phone configuration after renewing a self-signed certificate.
- **Server download fails:** Check VPS connectivity to GitHub API, Raw, and Releases download endpoints, then retry.

The script adds firewall rules when UFW is already active. Configure cloud security groups through your provider. Uninstalling keeps Certbot certificates and firewall rules available to other services.

## Verify downloaded files

`SHA256SUMS` contains the SHA-256 checksums for the published files. After cloning or downloading the complete repository, run this from its directory:

```bash
sha256sum -c SHA256SUMS
```

v1.2 has passed Bash syntax checks, discovery and validation with real OpenSSL certificates, and simulated installation, port changes, and rollback checks. Downloads, systemd, and firewall operations are mocked in those tests. Test actual VPS and mobile connectivity after deployment.

Official documentation: [Server configuration](https://github.com/TrustTunnel/TrustTunnel/blob/master/CONFIGURATION.md) · [Certificate renewal](https://github.com/TrustTunnel/TrustTunnel/blob/master/CERT_RENEWAL.md)
