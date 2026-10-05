#!/usr/bin/env bash
# TrustTunnel one-click installer and manager v1.2.1 — 2026-10-05
# Compatibility marker for the shared tt-menu ownership checks:
# TrustTunnel 中文一键安装与管理
# Supported: Debian 12+ / Ubuntu 22.04+, x86_64 / aarch64, systemd, public IPv4.
# Upload to your VPS, run bash trusttunnel-oneclick-en.sh as root, and select 1.
# Uses the official installer and configuration format; configuration directories are root-only.
# Official documentation: https://github.com/TrustTunnel/TrustTunnel
# https://github.com/TrustTunnel/TrustTunnel/blob/master/CONFIGURATION.md
# https://github.com/TrustTunnel/TrustTunnel/blob/master/CERT_RENEWAL.md
# Dedicated service: trusttunnel-oneclick; management shortcut: tt-menu.
# Self-signed certificates are embedded in exported links; keep client certificate verification enabled.
# Enables HTTP/2 and QUIC; does not implement split upload/download transports or CDN forwarding.
# Configure cloud firewall rules, domain DNS, and mobile VPN permission on their respective platforms.

set +x
set -Eeuo pipefail
umask 077

MANAGER_VERSION="1.2.1"
# Change the initial default here, or run TT_DEFAULT_PORT=9443 bash trusttunnel-oneclick-en.sh.
DEFAULT_PORT="${TT_DEFAULT_PORT:-8443}"
APP_DIR="/opt/trusttunnel-oneclick"
CONF_DIR="/etc/trusttunnel-oneclick"
STATE="$CONF_DIR/state.json"
SERVICE="trusttunnel-oneclick.service"
UNIT="/etc/systemd/system/$SERVICE"
HOOK="/etc/letsencrypt/renewal-hooks/deploy/trusttunnel-oneclick.sh"
SHORTCUT="/usr/local/sbin/tt-menu"
# Common certificate directories and service configurations; scan read-only without executing configurations.
CERT_SCAN_ROOTS=(
    /etc/letsencrypt/live /root/.acme.sh '/home/*/.acme.sh'
    /etc/xray /usr/local/etc/xray /etc/v2ray /usr/local/etc/v2ray
    /etc/sing-box /etc/nginx /etc/apache2 /etc/haproxy /etc/caddy
    /etc/x-ui /usr/local/x-ui /etc/ssl /usr/local/etc/ssl /etc/pki/tls
    /root/cert /root/certs /root/.cert /root/ssl /opt/cert /opt/certs
    /var/lib/caddy/.local/share/caddy/certificates
    /root/.local/share/caddy/certificates "$CONF_DIR/certs"
)
INSTALL_URL="https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh"
MANAGER_SOURCE="${BASH_SOURCE[0]}"
WORK=""
INITIAL_INSTALL_PENDING=0
UPDATE_PENDING=0
UPDATE_WAS_ACTIVE=0
SHORTCUT_WRITTEN=0
PORT_CHANGE_PENDING=0
PORT_CHANGE_BACKUP=""
PORT_CHANGE_OLD_PORT=""
PORT_CHANGE_WAS_ACTIVE=0

say() { printf '\n%s\n' "$*"; }
warn() { printf '\n[NOTE] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() {
    if (( PORT_CHANGE_PENDING )); then
        warn "The port change did not complete. Restoring the previous configuration..."
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
        cp -p -- "$PORT_CHANGE_BACKUP/vpn.toml" "$CONF_DIR/vpn.toml"
        cp -p -- "$PORT_CHANGE_BACKUP/state.json" "$STATE"
        if [[ -f "$PORT_CHANGE_BACKUP/client-link.txt" ]]; then
            cp -p -- "$PORT_CHANGE_BACKUP/client-link.txt" "$CONF_DIR/client-link.txt"
        fi
        PORT=$PORT_CHANGE_OLD_PORT
        if (( PORT_CHANGE_WAS_ACTIVE )); then
            systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
            if systemctl start "$SERVICE" && wait_ready; then
                warn "Restored the previous port $PORT; the service is running."
            else
                warn "The previous configuration has been restored, but the service is not ready. Check journalctl -u $SERVICE."
            fi
        fi
        PORT_CHANGE_PENDING=0
    fi
    if (( UPDATE_PENDING )); then
        warn "The update did not complete. Restoring the previous binaries..."
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
        if [[ -d "$APP_DIR/bin.previous" ]]; then
            rm -rf -- "$APP_DIR/bin"
            mv -- "$APP_DIR/bin.previous" "$APP_DIR/bin"
        fi
        if (( UPDATE_WAS_ACTIVE )); then
            systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
            if systemctl start "$SERVICE" && wait_ready; then
                warn "The previous version is running again."
            else
                warn "The previous binaries have been restored, but the service is not ready. Check journalctl -u $SERVICE."
            fi
        fi
        UPDATE_PENDING=0
    fi
    if (( INITIAL_INSTALL_PENDING )); then
        warn "Rolling back this incomplete installation. Fix the cause and run the script again."
        if [[ -f "$UNIT" ]] && grep -q '^# Managed by TrustTunnel oneclick$' "$UNIT"; then
            systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
            rm -f -- "$UNIT"
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        if [[ -f "$HOOK" ]] && grep -q '^# Managed by TrustTunnel oneclick$' "$HOOK"; then rm -f -- "$HOOK"; fi
        if (( SHORTCUT_WRITTEN )); then rm -f -- "$SHORTCUT"; fi
        if [[ -f "$APP_DIR/.managed-by-tt-oneclick" ]]; then rm -rf -- "$APP_DIR" "$CONF_DIR"; fi
        INITIAL_INSTALL_PENDING=0
    fi
    [[ -z "${WORK:-}" ]] || rm -rf -- "$WORK"
}
failure() {
    local code=$? line=$1
    printf '\n[ERROR] Operation failed (line %s, status %s). Fix the error and run the script again.\n' "$line" "$code" >&2
    exit "$code"
}

help_text() {
    cat <<'HELP'
TrustTunnel one-click installer and manager
Run: sudo bash trusttunnel-oneclick-en.sh
Select 1 and enter the public IP, port, certificate mode, username, and password (blank generates a password).
Certificate modes: 1=domain with Certbot renewal; 2=self-signed without a domain; 3=scan existing certificates (default).
Mode 3 selects the domain, certificate chain, and private key by number; manual entry is also available.
Scans common Certbot, acme.sh, Xray, and Nginx locations; an additional directory can be specified.
Lists valid certificates that cover a domain, remain valid for over one day, and match an unencrypted private key.
Menu 11 or --scan-certs [additional-directory] lists existing certificates without changing the configuration.
Default: TCP/UDP 8443. Prompts for another port if occupied; other services remain running.
Set the initial default with TT_DEFAULT_PORT=9443 bash trusttunnel-oneclick-en.sh.
After installation, menu 10 changes the port and generates a new link; failure restores the previous port.
For a new domain certificate, point the A record to the VPS, use Cloudflare DNS only, and allow TCP 80.
If port 80 is occupied, use the existing website webroot; the script does not stop the website.
Self-signed certificates last one year; reimport the tt:// configuration after issuing a new certificate.
External certificates continue to use the original issuer and renewal process.
Allow the selected TCP and UDP port in your cloud security group; ACME HTTP validation also requires TCP 80.
Adds rules when UFW is already active; does not enable UFW, clear its rules, or change the SSH port.
After installation, run tt-menu to reopen the saved management menu.
Command options: --install --show --status --update --check-cert --change-port --scan-certs --help
Client: https://play.google.com/store/apps/details?id=com.adguard.trusttunnel
HELP
}

ask() {
    local target=$1 prompt=$2 fallback=${3:-} value
    printf '%s' "$prompt" >&2
    [[ -z "$fallback" ]] || printf ' [%s]' "$fallback" >&2
    printf ': ' >&2
    IFS= read -r value || die "Input ended. Run this script in an interactive SSH terminal."
    printf -v "$target" '%s' "${value:-$fallback}"
}

valid_ip() {
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    a = ipaddress.IPv4Address(sys.argv[1])
    sys.exit(0 if a.is_global and not a.is_multicast else 1)
except ValueError:
    sys.exit(1)
PY
}

valid_domain() {
    python3 - "$1" <<'PY'
import re, sys
s = sys.argv[1]
parts = s.split('.')
ok = len(s) <= 253 and len(parts) >= 2 and all(
    re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', x)
    for x in parts) and re.fullmatch(r'[A-Za-z]{2,63}', parts[-1])
sys.exit(0 if ok else 1)
PY
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$1 == 443 || (10#$1 >= 1024 && 10#$1 <= 65535) ))
}

port_free() {
    local result
    result=$(ss -H -lntu "( sport = :$1 )") || return 1
    [[ -z "$result" ]]
}

require_system() {
    [[ "$EUID" -eq 0 ]] || die "Run as root, or use sudo bash $MANAGER_SOURCE."
    valid_port "$DEFAULT_PORT" || die "Invalid default port. Use 443 or 1024-65535."
    [[ -f /etc/os-release ]] || die "Unable to identify the operating system."
    # Trusted OS identification file; user state is never executed as shell code.
    . /etc/os-release
    case "${ID:-}" in
        debian) (( ${VERSION_ID%%.*} >= 12 )) || die "Debian 12 or newer is required." ;;
        ubuntu) (( ${VERSION_ID%%.*} >= 22 )) || die "Ubuntu 22.04 or newer is required." ;;
        *) die "This script supports Debian 12+ / Ubuntu 22.04+." ;;
    esac
    case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) die "An x86_64 or aarch64 CPU is required." ;; esac
    [[ -d /run/systemd/system ]] || die "systemd is not running. Containers without systemd are unsupported."
    command -v flock >/dev/null || die "flock is missing. Install util-linux first."
    exec 9>/run/lock/trusttunnel-oneclick.lock
    flock -n 9 || die "Another TrustTunnel management process is running."
}

dependencies() {
    say "Installing dependencies..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl ca-certificates openssl python3 iproute2 tar gzip xz-utils \
        dnsutils certbot qrencode util-linux
}

check_owned() {
    [[ -f "$APP_DIR/.managed-by-tt-oneclick" && -f "$STATE" ]] || die "No complete installation managed by this script was found. Select Install first."
    [[ -f "$UNIT" ]] && grep -q '^# Managed by TrustTunnel oneclick$' "$UNIT" \
        || die "The service file is missing or is not managed by this script. Aborting."
}

load_state() {
    check_owned
    local data
    data=$(python3 - "$STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding='utf-8'))
keys = ('ip', 'hostname', 'port', 'username', 'password', 'cert_mode', 'cert', 'key')
for key in keys:
    value = str(s[key])
    if '\n' in value or '\r' in value or '\0' in value:
        raise ValueError('invalid state value')
    print(value)
PY
)
    local -a values
    mapfile -t values <<< "$data"
    [[ "${#values[@]}" -eq 8 ]] || die "The state file is invalid."
    PUBLIC_IP=${values[0]} HOSTNAME=${values[1]} PORT=${values[2]} TT_USER=${values[3]}
    TT_PASSWORD=${values[4]} CERT_MODE=${values[5]} CERT=${values[6]} KEY=${values[7]}
    valid_ip "$PUBLIC_IP" && valid_domain "$HOSTNAME" && valid_port "$PORT" \
        || die "The state file contains an invalid address, domain, or port."
}

allow_ufw() {
    local port=$1 protocol=$2
    if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
        ufw allow "$port/$protocol" comment 'trusttunnel-oneclick'
    fi
}

discover_certificates() {
    local -a roots=("${CERT_SCAN_ROOTS[@]}")
    [[ -z "${1:-}" ]] || roots+=("$1")
    python3 - "${roots[@]}" <<'PY'
import datetime, glob, hashlib, json, os, re, shlex, ssl, subprocess, sys

# Emit a fixed-field TSV. Exclude paths with control characters and never emit private key contents.
MAX_FILES, MAX_DEPTH, MAX_BYTES = 12000, 7, 2 * 1024 * 1024
skipped_dirs = {'archive', 'backup', 'backups', 'cache', 'logs', 'log', '.git', 'node_modules'}
certs, keys, configs, visited_dirs = {}, {}, [], set()
key_names = {'certificatefile', 'keyfile', 'certificate_path', 'key_path',
             'cert_chain_path', 'private_key_path', 'ssl_certificate', 'ssl_certificate_key'}
openssl_env = dict(os.environ, LC_ALL='C')

def clean(value):
    return bool(value) and all(ord(c) >= 32 and ord(c) != 127 for c in value)

def domain(value):
    parts = value.split('.')
    return (len(value) <= 253 and len(parts) >= 2
            and all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', p) for p in parts)
            and bool(re.fullmatch(r'[a-z]{2,63}', parts[-1])))

def run(arguments, data=None):
    try:
        result = subprocess.run(['openssl', *arguments], input=data, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=3, env=openssl_env)
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None

def inspect_file(path, priority):
    path = os.path.abspath(path)
    if not clean(path):
        return
    try:
        if not os.path.isfile(path) or os.path.getsize(path) > MAX_BYTES:
            return
        with open(path, 'rb') as stream:
            head = stream.read(MAX_BYTES + 1)
    except OSError:
        return
    if b'-----BEGIN CERTIFICATE-----' in head:
        certs.setdefault(path, priority)
    if b'PRIVATE KEY-----' in head:
        keys.setdefault(path, priority)

roots = []
for value in sys.argv[1:]:
    matches = [value] if os.path.isdir(value) else glob.glob(value)
    for path in sorted(matches):
        if os.path.isdir(path) and clean(path):
            roots.append(os.path.abspath(path))

count = 0
for priority, root in enumerate(roots):
    for directory, children, files in os.walk(root, followlinks=False):
        canonical = os.path.realpath(directory)
        if canonical in visited_dirs:
            children[:] = []
            continue
        visited_dirs.add(canonical)
        depth = os.path.relpath(directory, root).count(os.sep)
        children[:] = sorted(c for c in children if c not in skipped_dirs
                             and not c.startswith('certs-backup-')) if depth < MAX_DEPTH else []
        for name in sorted(files):
            count += 1
            if count > MAX_FILES:
                break
            path = os.path.join(directory, name)
            suffix = os.path.splitext(name)[1].lower()
            if suffix in {'.pem', '.crt', '.cer', '.cert', '.key'} or not suffix:
                inspect_file(path, priority)
            # Read only certificate paths from application configurations; do not execute shell configurations or scan website data.
            if suffix in {'.conf', '.json', '.toml', '.cfg'} or not suffix or name == 'Caddyfile':
                configs.append((path, priority, root))
        if count > MAX_FILES:
            break
    if count > MAX_FILES:
        print('Certificate scan reached the file limit; specify a more precise additional directory.', file=sys.stderr)
        break

def reference(value, config, priority, root):
    if not isinstance(value, str) or not clean(value):
        return
    paths = [value] if os.path.isabs(value) else [os.path.join(os.path.dirname(config), value),
                                               os.path.join(root, value)]
    for path in paths:
        inspect_file(path, priority)

def json_paths(value, config, priority, root):
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() in key_names:
                reference(child, config, priority, root)
            if isinstance(child, (dict, list)):
                json_paths(child, config, priority, root)
    elif isinstance(value, list):
        for child in value:
            json_paths(child, config, priority, root)

quoted = r'''("[^"\n]*"|'[^'\n]*'|[^\s;#]+)'''
directive = re.compile(r'(?i)^\s*(?:ssl_certificate(?:_key)?|SSLCertificate(?:Key)?File)\s+' + quoted)
assignment = re.compile(r'(?i)^\s*(?:cert_chain_path|private_key_path|certificate_path|key_path|'
                        r'Le_Real(?:FullChain|Cert|Key)Path)\s*=\s*' + quoted)
caddy = re.compile(r'^\s*tls\s+' + quoted + r'\s+' + quoted)
for config, priority, root in configs:
    try:
        if os.path.getsize(config) > MAX_BYTES:
            continue
        text = open(config, encoding='utf-8', errors='replace').read(MAX_BYTES + 1)
    except OSError:
        continue
    if text.lstrip().startswith(('{', '[')):
        try:
            json_paths(json.loads(text), config, priority, root)
        except (ValueError, RecursionError):
            pass
    for line in text.splitlines():
        match = directive.match(line) or assignment.match(line) or caddy.match(line)
        if not match:
            continue
        for raw in match.groups():
            try:
                values = shlex.split(raw, comments=False)
            except ValueError:
                continue
            if len(values) == 1:
                reference(values[0], config, priority, root)

key_index = {}
for path, priority in sorted(keys.items(), key=lambda x: (x[1], x[0])):
    public = run(['pkey', '-in', path, '-passin', 'pass:', '-pubout', '-outform', 'DER'])
    if public:
        key_index.setdefault(hashlib.sha256(public).digest(), []).append(path)
if not key_index:
    sys.exit(0)

def cert_order(item):
    path, priority = item
    name = os.path.basename(path).lower()
    return (priority, 0 if 'fullchain' in name or 'full_chain' in name else 1, path)

seen, now = set(), datetime.datetime.now(datetime.timezone.utc).timestamp()
for cert, priority in sorted(certs.items(), key=cert_order):
    info = run(['x509', '-in', cert, '-noout', '-dates', '-subject', '-nameopt', 'RFC2253',
                '-ext', 'subjectAltName'])
    if not info:
        continue
    text = info.decode('utf-8', errors='replace')
    dates = dict(re.findall(r'(?m)^(notBefore|notAfter)=(.+)$', text))
    try:
        starts = ssl.cert_time_to_seconds(dates['notBefore'])
        ends = ssl.cert_time_to_seconds(dates['notAfter'])
    except (KeyError, ValueError, OverflowError):
        continue
    if starts > now or ends <= now + 86400:
        continue
    names = re.findall(r'DNS:([^,\s]+)', text)
    if not names:
        subject = re.search(r'(?m)^subject=(.+)$', text)
        cn = re.search(r'(?:^|,)CN=([^,]+)', subject[1]) if subject else None
        names = [cn[1]] if cn else []
    hosts = []
    for name in names:
        name = name.lower().rstrip('.')
        # Generate a TLS hostname covered by the wildcard; exported links still use the public VPS IP.
        host = 'tt.' + name[2:] if name.startswith('*.') else name
        if domain(host) and host not in [h[0] for h in hosts]:
            hosts.append((host, 'Wildcard ' + name if name.startswith('*.') else 'Certificate domain'))
    if not hosts:
        continue
    pem_public = run(['x509', '-in', cert, '-pubkey', '-noout'])
    public = run(['pkey', '-pubin', '-outform', 'DER'], pem_public) if pem_public else None
    matches = key_index.get(hashlib.sha256(public).digest(), []) if public else []
    if not matches:
        continue
    key = next((p for p in matches if os.path.dirname(p) == os.path.dirname(cert)), matches[0])
    try:
        data = open(cert, 'r', encoding='ascii').read(MAX_BYTES)
        first = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', data, re.S)[0]
        fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(first)).digest()
    except (OSError, UnicodeError, ValueError, TypeError):
        continue
    expiry = datetime.datetime.fromtimestamp(ends, datetime.timezone.utc).strftime('%Y-%m-%d UTC')
    for host, note in hosts:
        identity = (fingerprint, host)
        if identity in seen:
            continue
        checked = run(['x509', '-in', cert, '-noout', '-checkhost', host])
        # OpenSSL x509 can return 0 for a hostname mismatch; require an explicit positive match.
        if checked is None or checked.decode('utf-8', errors='replace').strip() != f'Hostname {host} does match certificate':
            continue
        seen.add(identity)
        print('\t'.join((host, cert, key, expiry, note)))
PY
}

print_certificate_choices() {
    local index=0 hostname cert key expiry note row
    for row in "$@"; do
        IFS=$'\t' read -r hostname cert key expiry note <<< "$row"
        index=$((index + 1))
        printf '\n  %s. %s  (expires %s; %s)\n     Certificate chain: %s\n     Private key: %s\n' \
            "$index" "$hostname" "$expiry" "$note" "$cert" "$key"
    done
}

select_existing_certificate() {
    local extra="" data selection expiry note fallback
    local -a candidates=()
    while :; do
        say "Scanning existing certificates and domains..."
        data=$(discover_certificates "$extra") || { warn "The scan did not complete. Return and choose another certificate mode."; return 1; }
        candidates=()
        if [[ -n "$data" ]]; then
            mapfile -t candidates <<< "$data"
            print_certificate_choices "${candidates[@]}"
            fallback="1"
        else
            warn "No usable certificate/domain and matching private key were found. Scan another directory or enter paths manually."
            fallback="0"
        fi
        ask selection "Select a number; D scan another directory; R rescan; M enter manually; 0 go back" "$fallback"
        case "${selection^^}" in
            0) return 1 ;;
            R) continue ;;
            D)
                ask extra "Absolute path to an additional certificate or service configuration directory"
                if [[ "$extra" != /* || ! -d "$extra" ]]; then
                    warn "The directory does not exist. Enter an absolute path."
                    extra=""
                fi
                continue ;;
            M) HOSTNAME="" CERT="" KEY=""; return 0 ;;
        esac
        if [[ "$selection" =~ ^[0-9]{1,5}$ ]] && (( 10#$selection >= 1 && 10#$selection <= ${#candidates[@]} )); then
            IFS=$'\t' read -r HOSTNAME CERT KEY expiry note <<< "${candidates[$((10#$selection - 1))]}"
            validate_certificate
            say "Selected domain: $HOSTNAME; certificate chain and private key paths were filled automatically."
            return 0
        fi
        warn "Enter a number from the list."
    done
}

scan_certificates_main() {
    command -v python3 >/dev/null && command -v openssl >/dev/null || die "Scanning requires python3 and openssl."
    local extra=${1:-} data
    local -a candidates=()
    [[ -z "$extra" || ( "$extra" == /* && -d "$extra" ) ]] || die "The additional scan directory must exist and use an absolute path."
    say "Scanning existing certificates and domains (read-only)..."
    data=$(discover_certificates "$extra")
    if [[ -n "$data" ]]; then
        mapfile -t candidates <<< "$data"
        print_certificate_choices "${candidates[@]}"
    else
        warn "No usable certificates were found. Add a directory with --scan-certs /your/certificate/directory."
    fi
}

gather_inputs() {
    local detected=""
    detected=$(curl -4 -fsS --connect-timeout 4 --max-time 6 https://api.ipify.org 2>/dev/null || true)
    if ! valid_ip "$detected"; then detected=""; fi
    while :; do
        ask PUBLIC_IP "VPS public IPv4" "$detected"
        valid_ip "$PUBLIC_IP" && break
        warn "Enter a globally reachable IPv4 address, not a private address."
    done
    while :; do
        ask PORT "TrustTunnel port (same number for HTTP/2 and QUIC)" "$DEFAULT_PORT"
        if valid_port "$PORT"; then
            PORT=$((10#$PORT))
            if port_free "$PORT"; then break; fi
            warn "TCP or UDP port $PORT is occupied. Choose another port."
            ss -lntup "( sport = :$PORT )" || true
        else
            warn "Use port 443 or 1024-65535."
        fi
    done
    HOSTNAME="" CERT="" KEY=""
    say "Certificate modes: 1 domain with automatic renewal; 2 IP-only/self-signed; 3 scan existing certificates and select a domain"
    while :; do
        ask CERT_MODE "Select certificate mode" "3"
        [[ "$CERT_MODE" =~ ^[123]$ ]] || continue
        if [[ "$CERT_MODE" == 3 ]]; then
            select_existing_certificate && break
        else
            break
        fi
    done
    if [[ "$CERT_MODE" == 2 ]]; then
        HOSTNAME="tt.local"
    elif [[ -z "$HOSTNAME" ]]; then
        while :; do
            ask HOSTNAME "Domain covered by the certificate (without https:// or a port)"
            HOSTNAME=${HOSTNAME,,}
            valid_domain "$HOSTNAME" && break
            warn "Enter a complete domain, for example tt.example.com."
        done
    fi
    while :; do
        ask TT_USER "Connection username" "ttuser"
        [[ "$TT_USER" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] && break
        warn "Use letters, digits, underscores, or hyphens for the username; maximum 64 characters."
    done
    printf 'Connection password (hidden input; press Enter to generate): ' >&2
    IFS= read -r -s TT_PASSWORD || die "Unable to read the password."
    printf '\n' >&2
    [[ -n "$TT_PASSWORD" ]] || TT_PASSWORD=$(openssl rand -hex 24)
    if ! printf '%s' "$TT_PASSWORD" | python3 -c 'import sys; s=sys.stdin.read(); sys.exit(0 if 12<=len(s)<=256 and all(ord(c)>=32 and ord(c)!=127 for c in s) else 1)'; then
        die "The password must contain 12-256 characters without control characters. Rerun and press Enter to generate one."
    fi
}

validate_certificate() {
    [[ -r "$CERT" && -r "$KEY" ]] || die "Unable to read the certificate or private key."
    openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null || die "The certificate has expired or will expire within one day."
    local cert_pub key_pub host_check
    host_check=$(LC_ALL=C openssl x509 -in "$CERT" -noout -checkhost "$HOSTNAME") \
        || die "Unable to check the certificate hostname."
    [[ "$host_check" == "Hostname $HOSTNAME does match certificate" ]] \
        || die "Certificate does not cover hostname $HOSTNAME."
    cert_pub=$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
    key_pub=$(openssl pkey -in "$KEY" -passin pass: -pubout -outform DER | openssl dgst -sha256)
    [[ "$cert_pub" == "$key_pub" ]] || die "The certificate and private key do not match."
}

acme_cert_name() {
    # Use a dedicated fixed-length certificate name to avoid changing another service certificate or its SAN list.
    python3 - "$HOSTNAME" <<'PY'
import hashlib, sys
print('tt-oneclick-' + hashlib.sha256(sys.argv[1].encode('ascii')).hexdigest()[:16])
PY
}

prepare_certificate() {
    if [[ "$CERT_MODE" == 2 ]]; then
        CERT="$CONF_DIR/certs/fullchain.pem"
        KEY="$CONF_DIR/certs/privkey.pem"
        install -d -m 700 "$CONF_DIR/certs"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -nodes -days 365 -subj "/CN=$HOSTNAME" \
            -addext "subjectAltName=DNS:$HOSTNAME,IP:$PUBLIC_IP" \
            -keyout "$KEY" -out "$CERT"
        chmod 600 "$KEY" "$CERT"
    elif [[ "$CERT_MODE" == 3 ]]; then
        if [[ -z "${CERT:-}" || -z "${KEY:-}" ]]; then
            ask CERT "Absolute path to the full certificate chain PEM file"
            ask KEY "Absolute path to the unencrypted private key PEM file"
        fi
        [[ "$CERT" == /* && "$KEY" == /* ]] || die "The certificate and private key must use absolute paths."
    else
        say "Checking domain DNS... Cloudflare records must use DNS only (gray cloud)."
        python3 - "$HOSTNAME" "$PUBLIC_IP" <<'PY'
import socket, sys
try:
    addresses = {x[4][0] for x in socket.getaddrinfo(sys.argv[1], 80, socket.AF_INET)}
except OSError as e:
    sys.exit('Domain DNS lookup failed: ' + str(e))
if addresses != {sys.argv[2]}:
    sys.exit('The A record must point only to this VPS IPv4; current results: ' + ', '.join(sorted(addresses)))
PY
        local email webroot cert_name
        cert_name=$(acme_cert_name)
        local -a cert_args=(certonly --non-interactive --agree-tos --cert-name "$cert_name" -d "$HOSTNAME")
        ask email "Certificate contact email (press Enter to skip)"
        if [[ -n "$email" ]]; then
            [[ "$email" == *@*.* && "$email" != *[[:space:]]* ]] || die "Invalid email address."
            cert_args+=(--email "$email")
        else
            cert_args+=(--register-unsafely-without-email)
        fi
        local tcp80
        tcp80=$(ss -H -lnt '( sport = :80 )')
        if [[ -z "$tcp80" ]]; then
            cert_args+=(--standalone)
        else
            warn "TCP 80 is used by a website. Use webroot validation; the directory must serve this domain and its ACME challenge files."
            ask webroot "Absolute website root path (blank cancels installation)"
            [[ "$webroot" == /* && -d "$webroot" ]] || die "No usable webroot was provided. Choose a self-signed or existing certificate."
            cert_args+=(--webroot -w "$webroot")
        fi
        allow_ufw 80 tcp
        warn "Allow TCP 80 in the cloud security group; correct any invalid AAAA records first."
        certbot "${cert_args[@]}"
        CERT="/etc/letsencrypt/live/$cert_name/fullchain.pem"
        KEY="/etc/letsencrypt/live/$cert_name/privkey.pem"
    fi
    validate_certificate
}

download_binaries() {
    WORK=$(mktemp -d "$APP_DIR/.download-XXXXXXXX")
    say "Downloading the official installer and latest server..."
    local release_version
    curl -fLSs --retry 2 --connect-timeout 15 --max-time 60 \
        https://api.github.com/repos/TrustTunnel/TrustTunnel/releases/latest -o "$WORK/release.json"
    release_version=$(python3 - "$WORK/release.json" <<'PY'
import json, re, sys
tag = json.load(open(sys.argv[1], encoding='utf-8')).get('tag_name', '')
match = re.fullmatch(r'v?(\d+\.\d+\.\d+)', tag)
if not match: sys.exit('Invalid latest official version number. Download aborted.')
print(match.group(1))
PY
)
    say "Preparing to install official version v$release_version"
    curl -fLSs --retry 2 --connect-timeout 15 --max-time 90 "$INSTALL_URL" -o "$WORK/install.sh"
    # The installer writes into a new temporary directory; a failed download leaves the running version intact.
    if ! (cd "$WORK" && sh ./install.sh -V "$release_version" -o "$WORK/bin" -a y) >"$WORK/install.log" 2>&1; then
        tail -n 35 "$WORK/install.log" >&2
        die "The official installer failed. Check connectivity from the VPS to GitHub."
    fi
    [[ -x "$WORK/bin/trusttunnel_endpoint" ]] || die "The server executable was not found in the installation package."
    "$WORK/bin/trusttunnel_endpoint" --version
}

write_configs() {
    # Pass the password through a file descriptor, not Python command-line arguments.
    python3 - "$CONF_DIR" "$PUBLIC_IP" "$HOSTNAME" "$PORT" "$TT_USER" "$CERT_MODE" "$CERT" "$KEY" \
        3< <(printf '%s' "$TT_PASSWORD") <<'PY'
import json, os, sys, tempfile
directory, ip, hostname, port, user, mode, cert, key = sys.argv[1:]
password = os.fdopen(3, 'rb').read().decode('utf-8')
quote = lambda s: json.dumps(s, ensure_ascii=False)
def save(name, text):
    fd, temp = tempfile.mkstemp(dir=directory, prefix='.new-')
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text)
        os.replace(temp, os.path.join(directory, name))
    finally:
        if os.path.exists(temp): os.unlink(temp)
# IPv4 deployment: do not advertise unavailable IPv6 egress to clients.
vpn = f'''listen_address = "0.0.0.0:{int(port)}"
ipv6_available = false
allow_private_network_connections = false
tls_handshake_timeout_secs = 10
client_listener_timeout_secs = 600
connection_establishment_timeout_secs = 30
tcp_connections_timeout_secs = 604800
udp_connections_timeout_secs = 300
credentials_file = {quote(os.path.join(directory, 'credentials.toml'))}

[listen_protocols.http2]
initial_connection_window_size = 8388608
initial_stream_window_size = 131072
max_concurrent_streams = 1000
max_frame_size = 16384
header_table_size = 65536

[listen_protocols.quic]
recv_udp_payload_size = 1350
send_udp_payload_size = 1350
initial_max_data = 104857600
initial_max_stream_data_bidi_local = 1048576
initial_max_stream_data_bidi_remote = 1048576
initial_max_stream_data_uni = 1048576
initial_max_streams_bidi = 4096
initial_max_streams_uni = 4096
max_connection_window = 25165824
max_stream_window = 16777216
disable_active_migration = true
enable_early_data = false
message_queue_capacity = 4096

[forward_protocol]
direct = {{}}
'''
save('vpn.toml', vpn)
save('hosts.toml', '[[main_hosts]]\n' + f'hostname = {quote(hostname)}\ncert_chain_path = {quote(cert)}\nprivate_key_path = {quote(key)}\n')
save('credentials.toml', '[[client]]\n' + f'username = {quote(user)}\npassword = {quote(password)}\n')
save('state.json', json.dumps(dict(ip=ip, hostname=hostname, port=int(port), username=user,
     password=password, cert_mode=mode, cert=cert, key=key), ensure_ascii=False, indent=2) + '\n')
PY
}

export_to() {
    local executable=$1 destination=$2
    local temp="$destination.tmp"
    (cd "$CONF_DIR" && "$executable" "$CONF_DIR/vpn.toml" "$CONF_DIR/hosts.toml" \
        -c "$TT_USER" -a "$PUBLIC_IP:$PORT" --format deeplink \
        --name "TrustTunnel" --dns-upstream 1.1.1.1) >"$temp"
    python3 - "$temp" <<'PY'
import sys
path = sys.argv[1]
lines = [x.strip() for x in open(path, encoding='utf-8') if x.strip().startswith('tt://?')]
if len(lines) != 1:
    sys.exit('The server did not export exactly one valid tt:// configuration link.')
with open(path, 'w', encoding='utf-8') as stream:
    stream.write(lines[0] + '\n')
PY
    chmod 600 "$temp"
    mv -f -- "$temp" "$destination"
}

write_unit() {
    cat > "$UNIT" <<EOF
# Managed by TrustTunnel oneclick
[Unit]
Description=TrustTunnel Endpoint (English oneclick)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONF_DIR
ExecStart=$APP_DIR/bin/trusttunnel_endpoint $CONF_DIR/vpn.toml $CONF_DIR/hosts.toml
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
TimeoutStopSec=30
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UNIT"
    systemctl daemon-reload
}

configure_renewal() {
    [[ "$CERT_MODE" == 1 ]] || return 0
    if [[ -e "$HOOK" ]] && ! grep -q '^# Managed by TrustTunnel oneclick$' "$HOOK"; then
        die "The certificate hook path is used by another program: $HOOK."
    fi
    install -d -m 755 "${HOOK%/*}"
    # Reload this service only after its own certificate has been renewed successfully.
    cat > "$HOOK" <<EOF
#!/bin/sh
# Managed by TrustTunnel oneclick
if [ "\${RENEWED_LINEAGE:-}" = "${CERT%/*}" ]; then
    if systemctl is-active --quiet $SERVICE; then
        systemctl kill --kill-who=main --signal=HUP $SERVICE
    fi
fi
EOF
    chmod 755 "$HOOK"
    if systemctl cat certbot.timer >/dev/null 2>&1; then
        systemctl enable --now certbot.timer
    elif [[ -f /etc/cron.d/certbot ]]; then
        warn "Certbot uses the system cron renewal task."
    else
        die "No Certbot automatic renewal task was found. Check the Certbot installation."
    fi
}

wait_ready() {
    local attempt pid
    for attempt in {1..15}; do
        pid=$(systemctl show -p MainPID --value "$SERVICE") || return 1
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && systemctl is-active --quiet "$SERVICE"; then
            if ss -H -lntp "( sport = :$PORT )" | grep -Fq "pid=$pid," \
                && ss -H -lnup "( sport = :$PORT )" | grep -Fq "pid=$pid,"; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

save_manager() {
    [[ -f "$MANAGER_SOURCE" ]] || return 0
    if [[ -e "$SHORTCUT" ]] && ! grep -q '^# TrustTunnel 中文一键安装与管理' "$SHORTCUT"; then
        warn "$SHORTCUT is used by another program. Keeping it unchanged; open the menu with this script."
        return 0
    fi
    if [[ "$(readlink -f "$MANAGER_SOURCE")" != "$(readlink -m "$SHORTCUT")" ]]; then
        install -m 700 "$MANAGER_SOURCE" "$SHORTCUT"
        SHORTCUT_WRITTEN=1
    fi
}

show_config() {
    load_state
    export_to "$APP_DIR/bin/trusttunnel_endpoint" "$CONF_DIR/client-link.txt"
    say "Mobile connection settings (contain a password; keep them private)"
    printf 'Address: %s\nPort: %s\nHostname: %s\nUsername: %s\nPassword: %s\nDNS: 1.1.1.1\n' \
        "$PUBLIC_IP" "$PORT" "$HOSTNAME" "$TT_USER" "$TT_PASSWORD"
    printf '\nProtocol: test with HTTP/2 first, then try QUIC.\n\n'
    cat "$CONF_DIR/client-link.txt"
    if command -v qrencode >/dev/null; then
        printf '\nConfiguration QR code (scan when the terminal is wide enough):\n'
        if ! qrencode -t ANSIUTF8 < "$CONF_DIR/client-link.txt"; then
            warn "QR code generation failed. Copy the link above instead."
        fi
    fi
    if [[ "$CERT_MODE" == 2 ]]; then
        warn "Self-signed certificate: import the tt:// link above to include the certificate. Keep verification enabled and reimport after renewal."
    fi
    printf '\nAndroid client: https://play.google.com/store/apps/details?id=com.adguard.trusttunnel\n'
    printf 'Allow TCP %s and UDP %s in the cloud security group.\n' "$PORT" "$PORT"
    printf 'Configuration directory: %s.\n' "$CONF_DIR"
    if [[ -f "$SHORTCUT" ]] && grep -q '^# TrustTunnel 中文一键安装与管理' "$SHORTCUT"; then
        printf 'Service management command: tt-menu\n'
    else
        printf 'Management menu: bash %q\n' "$MANAGER_SOURCE"
    fi
}

install_main() {
    if [[ -f "$STATE" ]]; then
        say "An installation already exists. Check its status; use the update menu to upgrade the server."
        show_config
        return 0
    fi
    [[ ! -e "$UNIT" ]] || die "$UNIT already exists. Aborting installation to avoid overwriting it."
    if [[ -d "$APP_DIR" ]] && [[ -n "$(ls -A "$APP_DIR")" ]] \
        && [[ ! -f "$APP_DIR/.managed-by-tt-oneclick" ]]; then
        die "$APP_DIR contains unrelated files. Installation aborted."
    fi
    if [[ -d "$CONF_DIR" ]] && [[ -n "$(ls -A "$CONF_DIR")" ]]; then
        die "$CONF_DIR contains an incomplete configuration. Inspect and back it up before cleaning it and retrying."
    fi
    dependencies
    gather_inputs
    install -d -m 700 "$APP_DIR" "$CONF_DIR"
    printf '%s\n' 'TrustTunnel oneclick owned directory' > "$APP_DIR/.managed-by-tt-oneclick"
    INITIAL_INSTALL_PENDING=1
    # Validate the executable before creating certificate configuration.
    download_binaries
    prepare_certificate
    write_configs
    export_to "$WORK/bin/trusttunnel_endpoint" "$CONF_DIR/client-link.txt"
    [[ ! -e "$APP_DIR/bin" ]] || die "The dedicated directory already contains bin. Inspect it before retrying."
    mv -- "$WORK/bin" "$APP_DIR/bin"
    write_unit
    configure_renewal
    allow_ufw "$PORT" tcp
    allow_ufw "$PORT" udp
    save_manager
    systemctl enable --now "$SERVICE"
    if ! wait_ready; then
        journalctl -u "$SERVICE" -n 40 --no-pager >&2 || true
        die "The service is not listening on both TCP and UDP. Rolling back this installation; fix the logged error before retrying."
    fi
    INITIAL_INSTALL_PENDING=0
    cleanup
    WORK=""
    say "Installation complete. The service is running and enabled at boot."
    show_config
}

status_main() {
    load_state
    "$APP_DIR/bin/trusttunnel_endpoint" --version
    systemctl status "$SERVICE" --no-pager -l || true
    ss -lntup "( sport = :$PORT )" || true
    openssl x509 -in "$CERT" -noout -dates || true
    printf '\nRecent logs (configuration passwords are not printed):\n'
    journalctl -u "$SERVICE" -n 30 --no-pager || true
    warn "Local listeners do not prove public connectivity. Test TCP, UDP, and the actual egress IP from your phone."
}

update_main() {
    load_state
    download_binaries
    # Validate the new executable against the current configuration before stopping the service.
    export_to "$WORK/bin/trusttunnel_endpoint" "$WORK/client-link.txt"
    UPDATE_WAS_ACTIVE=0
    if systemctl is-active --quiet "$SERVICE"; then UPDATE_WAS_ACTIVE=1; fi
    rm -rf -- "$APP_DIR/bin.previous"
    UPDATE_PENDING=1
    if (( UPDATE_WAS_ACTIVE )); then systemctl stop "$SERVICE"; fi
    mv -- "$APP_DIR/bin" "$APP_DIR/bin.previous"
    mv -- "$WORK/bin" "$APP_DIR/bin"
    if (( UPDATE_WAS_ACTIVE )); then
        if systemctl start "$SERVICE" && wait_ready; then
            say "The new version is running."
        else
            die "The new version failed to start. Rolling back this update to the previous binaries."
        fi
    fi
    install -m 600 "$WORK/client-link.txt" "$CONF_DIR/client-link.txt"
    UPDATE_PENDING=0
    cleanup
    WORK=""
    say "Server update complete."
    if (( ! UPDATE_WAS_ACTIVE )); then warn "The service was stopped before the update. Use the Start menu to run it."; fi
}

certificate_main() {
    load_state
    openssl x509 -in "$CERT" -noout -dates
    case "$CERT_MODE" in
        1)
            say "Testing certificate renewal and the reload hook..."
            certbot renew --cert-name "$(acme_cert_name)" --dry-run --run-deploy-hooks
            ;;
        2)
            say "Self-signed certificates last one year. Renewal changes the certificate trusted by clients."
            local answer
            ask answer "Type RENEW to renew and export a new configuration (Enter cancels)"
            [[ "$answer" == RENEW ]] || return 0
            local backup
            backup=$(mktemp -d "$CONF_DIR/certs-backup-XXXXXXXX")
            cp -p -- "$CERT" "$KEY" "$backup/"
            prepare_certificate
            if systemctl is-active --quiet "$SERVICE"; then
                systemctl kill --kill-who=main --signal=HUP "$SERVICE"
            fi
            show_config
            warn "Reimport the new link on your phone. Previous certificate backup: $backup."
            ;;
        3) warn "External certificates are renewed by their original issuer. Restart this service after the files are updated." ;;
    esac
}

uninstall_main() {
    load_state
    local answer
    warn "This removes the managed service, dedicated application directory, and configuration (including connection credentials)."
    ask answer "Type UNINSTALL to confirm removal (Enter cancels)"
    [[ "$answer" == UNINSTALL ]] || return 0
    systemctl disable --now "$SERVICE"
    rm -f -- "$UNIT"
    if [[ -f "$HOOK" ]] && grep -q '^# Managed by TrustTunnel oneclick$' "$HOOK"; then rm -f -- "$HOOK"; fi
    if [[ -f "$SHORTCUT" ]] && grep -q '^# TrustTunnel 中文一键安装与管理' "$SHORTCUT"; then rm -f -- "$SHORTCUT"; fi
    rm -rf -- "$APP_DIR" "$CONF_DIR"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    say "The managed service and dedicated files have been removed. Certbot certificates and firewall rules remain available to other services."
}

service_action() {
    load_state
    systemctl "$1" "$SERVICE"
    if [[ "$1" == start || "$1" == restart ]]; then
        if ! wait_ready; then die "The service failed to start. Use the Status menu to inspect its logs."; fi
    fi
    say "Service action complete: $1"
}

change_port_main() {
    load_state
    local new_port
    say "Current port: $PORT (TCP and UDP). Reimport the new link on your phone after a successful change."
    while :; do
        ask new_port "New port (Enter cancels)" "$PORT"
        if ! valid_port "$new_port"; then
            warn "Use port 443 or 1024-65535."
            continue
        fi
        new_port=$((10#$new_port))
        if [[ "$new_port" == "$PORT" ]]; then
            say "Port change cancelled."
            return 0
        fi
        if port_free "$new_port"; then break; fi
        warn "TCP or UDP port $new_port is occupied. Choose another port."
        ss -lntup "( sport = :$new_port )" || true
    done
    PORT_CHANGE_BACKUP=$(mktemp -d "$CONF_DIR/port-backup-XXXXXXXX")
    cp -p -- "$CONF_DIR/vpn.toml" "$STATE" "$PORT_CHANGE_BACKUP/"
    if [[ -f "$CONF_DIR/client-link.txt" ]]; then
        cp -p -- "$CONF_DIR/client-link.txt" "$PORT_CHANGE_BACKUP/"
    fi
    PORT_CHANGE_OLD_PORT=$PORT
    PORT_CHANGE_WAS_ACTIVE=0
    if systemctl is-active --quiet "$SERVICE"; then PORT_CHANGE_WAS_ACTIVE=1; fi
    PORT_CHANGE_PENDING=1
    # Change only the listening port and state port; preserve other settings and credentials.
    python3 - "$CONF_DIR/vpn.toml" "$STATE" "$new_port" <<'PY'
import json, os, re, sys, tempfile
config, state_path, port = sys.argv[1:]
text = open(config, encoding='utf-8').read()
table = re.search(r'(?m)^[ \t]*\[', text)
boundary = table.start() if table else len(text)
head, tail = text[:boundary], text[boundary:]
pattern = re.compile(r'''(?m)^(?P<prefix>[ \t]*listen_address[ \t]*=[ \t]*)(?P<value>"(?:[^"\\\n]|\\.)*"|'[^'\n]*')(?P<suffix>[ \t]*(?:\#[^\n]*)?)$''')
matches = list(pattern.finditer(head))
if len(matches) != 1:
    sys.exit('No unique top-level listen_address was found. Port change aborted.')
match = matches[0]
raw = match['value']
address = json.loads(raw) if raw.startswith('"') else raw[1:-1]
bind, separator, old_port = address.rpartition(':')
if not separator or not bind or not old_port.isdigit():
    sys.exit('listen_address is not in address:port format. Port change aborted.')
state = json.load(open(state_path, encoding='utf-8'))
if int(old_port) != int(state['port']):
    sys.exit('The current configuration and state ports differ. Inspect the configuration first.')
state['port'] = int(port)
replacement = match['prefix'] + json.dumps(bind + ':' + str(int(port))) + match['suffix']
updated = head[:match.start()] + replacement + head[match.end():] + tail
def save(path, content):
    fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.port-new-')
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream: stream.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
save(config, updated)
save(state_path, json.dumps(state, ensure_ascii=False, indent=2) + '\n')
PY
    PORT=$new_port
    export_to "$APP_DIR/bin/trusttunnel_endpoint" "$PORT_CHANGE_BACKUP/client-link-new.txt"
    allow_ufw "$PORT" tcp
    allow_ufw "$PORT" udp
    if (( PORT_CHANGE_WAS_ACTIVE )); then
        if ! systemctl restart "$SERVICE" || ! wait_ready; then
            die "The new port failed to start. Rolling back the port change."
        fi
    fi
    install -m 600 "$PORT_CHANGE_BACKUP/client-link-new.txt" "$CONF_DIR/client-link.txt"
    PORT_CHANGE_PENDING=0
    save_manager
    say "Port updated to $PORT."
    if (( ! PORT_CHANGE_WAS_ACTIVE )); then
        warn "The service is stopped. Use menu 6 to start it."
    fi
    show_config
    warn "Allow TCP $PORT and UDP $PORT in the cloud security group, then reimport the configuration above on your phone."
}

menu() {
    local choice
    while :; do
        cat <<MENU

────────────────────────────────────
  TrustTunnel manager v$MANAGER_VERSION (English)
────────────────────────────────────
  1. Install
  2. Show mobile settings / link / QR code
  3. Show status and logs
  4. Restart service
  5. Stop service
  6. Start service
  7. Update official server (rollback on failure)
  8. Certificate maintenance / renewal check
  9. Uninstall the managed TrustTunnel service
 10. Change port (new link; rollback on failure)
 11. Scan existing certificates and domains (read-only)
  0. Exit
MENU
        ask choice "Select an option" "0"
        case "$choice" in
            1) install_main ;;
            2) show_config ;;
            3) status_main ;;
            4) service_action restart ;;
            5) service_action stop ;;
            6) service_action start ;;
            7) update_main ;;
            8) certificate_main ;;
            9) uninstall_main ;;
            10) change_port_main ;;
            11) scan_certificates_main ;;
            0) return 0 ;;
            *) warn "Enter a number from the menu." ;;
        esac
    done
}

main() {
    if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then help_text; return 0; fi
    trap cleanup EXIT
    trap 'failure "$LINENO"' ERR
    require_system
    case "${1:-}" in
        '') menu ;;
        --install) install_main ;;
        --show) show_config ;;
        --status) status_main ;;
        --update) update_main ;;
        --check-cert) certificate_main ;;
        --change-port) change_port_main ;;
        --scan-certs) scan_certificates_main "${2:-}" ;;
        *) help_text; die "Unknown option: $1" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
