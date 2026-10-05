#!/usr/bin/env bash
# TrustTunnel 中文一键安装与管理 v1.2.2 — 2026-10-05
# 适用：Debian 12+ / Ubuntu 22.04+，x86_64 / aarch64，systemd，公网 IPv4。
# 上传到 VPS 后运行：bash trusttunnel-oneclick.sh（root 用户），选择 1。
# 使用官方安装器和官方配置格式；配置/证书/链接目录仅 root 可读。
# 官方资料：https://github.com/TrustTunnel/TrustTunnel
# https://github.com/TrustTunnel/TrustTunnel/blob/master/CONFIGURATION.md
# https://github.com/TrustTunnel/TrustTunnel/blob/master/CERT_RENEWAL.md
# 独立服务名：trusttunnel-oneclick；管理快捷命令：tt-menu。
# 自签证书通过导出链接嵌入客户端；客户端应保持证书验证开启。
# 本脚本启用 H2 与 QUIC 两种连接方式，不实现上下行异构传输或 CDN 转发。
# 安全组、域名 DNS 和手机 VPN 授权需要在对应平台完成。

set +x
set -Eeuo pipefail
umask 077

MANAGER_VERSION="1.2.2"
# 可在此修改初始默认端口，也可运行 TT_DEFAULT_PORT=9443 bash 本脚本。
DEFAULT_PORT="${TT_DEFAULT_PORT:-8443}"
APP_DIR="/opt/trusttunnel-oneclick"
CONF_DIR="/etc/trusttunnel-oneclick"
STATE="$CONF_DIR/state.json"
SERVICE="trusttunnel-oneclick.service"
UNIT="/etc/systemd/system/$SERVICE"
HOOK="/etc/letsencrypt/renewal-hooks/deploy/trusttunnel-oneclick.sh"
SHORTCUT="/usr/local/sbin/tt-menu"
# 常见证书目录及使用证书的服务配置；只读扫描，不执行配置文件。
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
warn() { printf '\n[提示] %s\n' "$*" >&2; }
die() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }
cleanup() {
    if (( PORT_CHANGE_PENDING )); then
        warn "端口修改尚未完成，正在恢复原配置……"
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
                warn "已恢复原端口 $PORT，服务正在运行。"
            else
                warn "原配置已恢复；服务未就绪，请查看 journalctl -u $SERVICE。"
            fi
        fi
        PORT_CHANGE_PENDING=0
    fi
    if (( UPDATE_PENDING )); then
        warn "更新尚未完成，正在恢复旧程序……"
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
        if [[ -d "$APP_DIR/bin.previous" ]]; then
            rm -rf -- "$APP_DIR/bin"
            mv -- "$APP_DIR/bin.previous" "$APP_DIR/bin"
        fi
        if (( UPDATE_WAS_ACTIVE )); then
            systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
            if systemctl start "$SERVICE" && wait_ready; then
                warn "旧版本已恢复运行。"
            else
                warn "旧程序已恢复，但服务仍未就绪，请查看 journalctl -u $SERVICE。"
            fi
        fi
        UPDATE_PENDING=0
    fi
    if (( INITIAL_INSTALL_PENDING )); then
        warn "撤回本次未完成的安装，可修复原因后重新运行。"
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
    printf '\n[失败] 操作未完成（第 %s 行，状态 %s）。修复报错后可重新运行脚本。\n' "$line" "$code" >&2
    exit "$code"
}

help_text() {
    cat <<'HELP'
TrustTunnel 中文一键脚本
运行：sudo bash trusttunnel-oneclick.sh
选择 1，填写公网 IP、端口、证书方式、用户名和密码（空密码自动生成）。
证书方式：1=域名＋Certbot 自动续期；2=无域名自签；3=扫描已有证书（默认）。
方式 3 按编号选域名和证书，自动填写证书链及私钥路径；也可手动输入。
扫描 Certbot、acme.sh、Xray、Nginx 等常见位置；额外目录可在扫描时指定。
只列出域名可用、有效期超过一天、与未加密私钥匹配的证书。
菜单 11 或 --scan-certs [额外目录] 可单独查看已有证书，不更改配置。
默认 TCP/UDP 8443；端口占用时提示更换；不停止其他服务。
默认端口可通过 TT_DEFAULT_PORT=9443 bash trusttunnel-oneclick.sh 指定。
安装后选择菜单 10 修改端口，自动更新配置并生成新链接；失败恢复原端口。
有域名：A 记录指向 VPS，Cloudflare 设为 DNS only；证书申请需 TCP 80。
80 被占用时可使用已有网站的 webroot 路径，不会自动停止网站。
自签证书有效期一年；重新签发后必须重新导入含证书的 tt:// 配置。
外部证书沿用原证书工具的续期方式。
云厂商安全组需自行放行所选端口的 TCP、UDP；ACME HTTP 验证还需 TCP 80。
已开启 UFW 时脚本添加放行规则；不会启用 UFW、清空规则或更改 SSH 端口。
安装后运行 tt-menu 可再次打开菜单。
命令参数：--install --show --status --update --check-cert --change-port --scan-certs --help
客户端：https://play.google.com/store/apps/details?id=com.adguard.trusttunnel
HELP
}

ask() {
    local target=$1 prompt=$2 fallback=${3:-} value
    printf '%s' "$prompt" >&2
    [[ -z "$fallback" ]] || printf ' [%s]' "$fallback" >&2
    printf ': ' >&2
    IFS= read -r value || die "输入结束。请在交互式 SSH 终端中运行。"
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
    [[ "$EUID" -eq 0 ]] || die "请以 root 执行，或使用 sudo bash $MANAGER_SOURCE。"
    valid_port "$DEFAULT_PORT" || die "默认端口无效。请使用 443，或 1024–65535。"
    [[ -f /etc/os-release ]] || die "无法识别系统。"
    # 系统自带的可信标识文件；用户状态文件不作为 shell 执行。
    . /etc/os-release
    case "${ID:-}" in
        debian) (( ${VERSION_ID%%.*} >= 12 )) || die "需要 Debian 12 或更新版本。" ;;
        ubuntu) (( ${VERSION_ID%%.*} >= 22 )) || die "需要 Ubuntu 22.04 或更新版本。" ;;
        *) die "本脚本适用于 Debian 12+ / Ubuntu 22.04+。" ;;
    esac
    case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) die "需要 x86_64 或 aarch64 架构。" ;; esac
    [[ -d /run/systemd/system ]] || die "系统未运行 systemd；不支持容器内无 systemd 的安装。"
    command -v flock >/dev/null || die "缺少 flock，请先安装 util-linux。"
    exec 9>/run/lock/trusttunnel-oneclick.lock
    flock -n 9 || die "另一个 TrustTunnel 管理进程正在运行。"
}

dependencies() {
    say "正在安装依赖……"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl ca-certificates openssl python3 iproute2 tar gzip xz-utils \
        dnsutils certbot qrencode util-linux
}

check_owned() {
    [[ -f "$APP_DIR/.managed-by-tt-oneclick" && -f "$STATE" ]] || die "没有找到本脚本管理的完整配置，请先选择安装。"
    [[ -f "$UNIT" ]] && grep -q '^# Managed by TrustTunnel oneclick$' "$UNIT" \
        || die "服务文件缺失或不属于本脚本，停止操作。"
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
    [[ "${#values[@]}" -eq 8 ]] || die "状态文件损坏。"
    PUBLIC_IP=${values[0]} HOSTNAME=${values[1]} PORT=${values[2]} TT_USER=${values[3]}
    TT_PASSWORD=${values[4]} CERT_MODE=${values[5]} CERT=${values[6]} KEY=${values[7]}
    valid_ip "$PUBLIC_IP" && valid_domain "$HOSTNAME" && valid_port "$PORT" \
        || die "状态文件的地址、域名或端口无效。"
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

# 输出固定字段 TSV。控制字符路径被排除，私钥内容不会进入输出。
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
            # 仅读取应用配置中的路径；不读取 shell 配置为命令，不扫描网站数据目录。
            if suffix in {'.conf', '.json', '.toml', '.cfg'} or not suffix or name == 'Caddyfile':
                configs.append((path, priority, root))
        if count > MAX_FILES:
            break
    if count > MAX_FILES:
        print('证书扫描已达到文件数量上限；可指定更精确的额外目录。', file=sys.stderr)
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
        # 通配符生成一个真实覆盖的 TLS 主机名；导出链接仍使用 VPS 公网 IP。
        host = 'tt.' + name[2:] if name.startswith('*.') else name
        if domain(host) and host not in [h[0] for h in hosts]:
            hosts.append((host, '通配符 ' + name if name.startswith('*.') else '证书域名'))
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
        # OpenSSL x509 在域名不匹配时也可能返回 0，必须核对明确的匹配结果。
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
        printf '\n  %s. %s  （有效至 %s；%s）\n     证书链：%s\n     私钥：%s\n' \
            "$index" "$hostname" "$expiry" "$note" "$cert" "$key"
    done
}

select_existing_certificate() {
    local extra="" data selection expiry note fallback
    local -a candidates=()
    while :; do
        say "正在扫描已有证书与域名……"
        data=$(discover_certificates "$extra") || { warn "扫描未完成，可返回选择其他证书方式。"; return 1; }
        candidates=()
        if [[ -n "$data" ]]; then
            mapfile -t candidates <<< "$data"
            print_certificate_choices "${candidates[@]}"
            fallback="1"
        else
            warn "未找到可直接使用的证书／域名和匹配私钥，可扫描其他目录或手动输入。"
            fallback="0"
        fi
        ask selection "选择编号；D 扫描其他目录；R 重扫；M 手动输入；0 返回" "$fallback"
        case "${selection^^}" in
            0) return 1 ;;
            R) continue ;;
            D)
                ask extra "额外证书或服务配置目录的绝对路径"
                if [[ "$extra" != /* || ! -d "$extra" ]]; then
                    warn "目录不存在，请填写绝对路径。"
                    extra=""
                fi
                continue ;;
            M) HOSTNAME="" CERT="" KEY=""; return 0 ;;
        esac
        if [[ "$selection" =~ ^[0-9]{1,5}$ ]] && (( 10#$selection >= 1 && 10#$selection <= ${#candidates[@]} )); then
            IFS=$'\t' read -r HOSTNAME CERT KEY expiry note <<< "${candidates[$((10#$selection - 1))]}"
            validate_certificate
            say "已选域名：$HOSTNAME；证书链和私钥路径已自动填写。"
            return 0
        fi
        warn "请输入列表中的编号。"
    done
}

scan_certificates_main() {
    command -v python3 >/dev/null && command -v openssl >/dev/null || die "扫描需要 python3 和 openssl。"
    local extra=${1:-} data
    local -a candidates=()
    [[ -z "$extra" || ( "$extra" == /* && -d "$extra" ) ]] || die "额外扫描目录必须是存在的绝对路径。"
    say "扫描已有证书与域名（只查看）……"
    data=$(discover_certificates "$extra")
    if [[ -n "$data" ]]; then
        mapfile -t candidates <<< "$data"
        print_certificate_choices "${candidates[@]}"
    else
        warn "没有发现可用证书，可通过 --scan-certs /你的证书目录 补充扫描。"
    fi
}

gather_inputs() {
    local detected=""
    detected=$(curl -4 -fsS --connect-timeout 4 --max-time 6 https://api.ipify.org 2>/dev/null || true)
    if ! valid_ip "$detected"; then detected=""; fi
    while :; do
        ask PUBLIC_IP "VPS 公网 IPv4" "$detected"
        valid_ip "$PUBLIC_IP" && break
        warn "请填写可从公网连接的 IPv4，不能填内网 IP。"
    done
    while :; do
        ask PORT "TrustTunnel 端口（HTTP/2 与 QUIC 使用同一数字）" "$DEFAULT_PORT"
        if valid_port "$PORT"; then
            PORT=$((10#$PORT))
            if port_free "$PORT"; then break; fi
            warn "端口 $PORT 的 TCP 或 UDP 已被占用，请换一个端口。"
            ss -lntup "( sport = :$PORT )" || true
        else
            warn "端口可用 443，或 1024–65535。"
        fi
    done
    HOSTNAME="" CERT="" KEY=""
    say "证书方式：1 域名＋自动续期；2 只有 IP／自签证书；3 扫描已有证书并选择域名"
    while :; do
        ask CERT_MODE "选择证书方式" "3"
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
            ask HOSTNAME "证书对应的域名（不要带 https:// 或端口）"
            HOSTNAME=${HOSTNAME,,}
            valid_domain "$HOSTNAME" && break
            warn "请填写完整域名，例如 tt.example.com。"
        done
    fi
    while :; do
        ask TT_USER "连接用户名" "ttuser"
        [[ "$TT_USER" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] && break
        warn "用户名使用字母、数字、下划线或短横线，最长 64 字符。"
    done
    printf '连接密码（输入不显示，直接回车自动生成）: ' >&2
    IFS= read -r -s TT_PASSWORD || die "读取密码失败。"
    printf '\n' >&2
    [[ -n "$TT_PASSWORD" ]] || TT_PASSWORD=$(openssl rand -hex 24)
    if ! printf '%s' "$TT_PASSWORD" | python3 -c 'import sys; s=sys.stdin.read(); sys.exit(0 if 12<=len(s)<=256 and all(ord(c)>=32 and ord(c)!=127 for c in s) else 1)'; then
        die "密码需 12–256 个字符，不能包含控制字符；可重新运行并回车使用随机密码。"
    fi
}

validate_certificate() {
    [[ -r "$CERT" && -r "$KEY" ]] || die "证书或私钥无法读取。"
    openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null || die "证书已过期或将在一天内过期。"
    local cert_pub key_pub host_check
    host_check=$(LC_ALL=C openssl x509 -in "$CERT" -noout -checkhost "$HOSTNAME") \
        || die "无法检查证书主机名。"
    [[ "$host_check" == "Hostname $HOSTNAME does match certificate" ]] \
        || die "证书不覆盖主机名 $HOSTNAME。"
    cert_pub=$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
    key_pub=$(openssl pkey -in "$KEY" -passin pass: -pubout -outform DER | openssl dgst -sha256)
    [[ "$cert_pub" == "$key_pub" ]] || die "证书与私钥不匹配。"
}

acme_cert_name() {
    # 专用、定长证书名，避免复用或缩减其他服务证书的 SAN 列表。
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
            ask CERT "完整证书链 PEM 文件的绝对路径"
            ask KEY "未加密私钥 PEM 文件的绝对路径"
        fi
        [[ "$CERT" == /* && "$KEY" == /* ]] || die "证书和私钥必须使用绝对路径。"
    else
        say "检查域名解析……Cloudflare 记录应为 DNS only（灰云）。"
        python3 - "$HOSTNAME" "$PUBLIC_IP" <<'PY'
import socket, sys
try:
    addresses = {x[4][0] for x in socket.getaddrinfo(sys.argv[1], 80, socket.AF_INET)}
except OSError as e:
    sys.exit('域名解析失败：' + str(e))
if addresses != {sys.argv[2]}:
    sys.exit('A 记录应只指向本 VPS IPv4；当前结果：' + ', '.join(sorted(addresses)))
PY
        local email webroot cert_name
        cert_name=$(acme_cert_name)
        local -a cert_args=(certonly --non-interactive --agree-tos --cert-name "$cert_name" -d "$HOSTNAME")
        ask email "证书联系邮箱（可直接回车跳过）"
        if [[ -n "$email" ]]; then
            [[ "$email" == *@*.* && "$email" != *[[:space:]]* ]] || die "邮箱格式不正确。"
            cert_args+=(--email "$email")
        else
            cert_args+=(--register-unsafely-without-email)
        fi
        local tcp80
        tcp80=$(ss -H -lnt '( sport = :80 )')
        if [[ -z "$tcp80" ]]; then
            cert_args+=(--standalone)
        else
            warn "TCP 80 已有网站服务，改用 webroot 验证。路径必须对应此域名，并能提供 ACME 验证文件。"
            ask webroot "网站 root 绝对路径（空值取消此次安装）"
            [[ "$webroot" == /* && -d "$webroot" ]] || die "没有可用 webroot。可改用自签证书，或使用已有证书。"
            cert_args+=(--webroot -w "$webroot")
        fi
        allow_ufw 80 tcp
        warn "云厂商安全组还需放行 TCP 80；如有错误 AAAA 记录，请先修正。"
        certbot "${cert_args[@]}"
        CERT="/etc/letsencrypt/live/$cert_name/fullchain.pem"
        KEY="/etc/letsencrypt/live/$cert_name/privkey.pem"
    fi
    validate_certificate
}

download_binaries() {
    WORK=$(mktemp -d "$APP_DIR/.download-XXXXXXXX")
    say "下载官方安装器与最新服务端……"
    local release_version
    curl -fLSs --retry 2 --connect-timeout 15 --max-time 60 \
        https://api.github.com/repos/TrustTunnel/TrustTunnel/releases/latest -o "$WORK/release.json"
    release_version=$(python3 - "$WORK/release.json" <<'PY'
import json, re, sys
tag = json.load(open(sys.argv[1], encoding='utf-8')).get('tag_name', '')
match = re.fullmatch(r'v?(\d+\.\d+\.\d+)', tag)
if not match: sys.exit('官方最新版本号无效，停止下载。')
print(match.group(1))
PY
)
    say "准备安装官方版本 v$release_version"
    curl -fLSs --retry 2 --connect-timeout 15 --max-time 90 "$INSTALL_URL" -o "$WORK/install.sh"
    # 安装器仅写入新建的临时目录，下载失败不会替换正在运行的版本。
    if ! (cd "$WORK" && sh ./install.sh -V "$release_version" -o "$WORK/bin" -a y) >"$WORK/install.log" 2>&1; then
        tail -n 35 "$WORK/install.log" >&2
        die "官方安装器运行失败。请检查 VPS 到 GitHub 的连接。"
    fi
    [[ -x "$WORK/bin/trusttunnel_endpoint" ]] || die "安装包中没有找到服务端程序。"
    "$WORK/bin/trusttunnel_endpoint" --version
}

write_configs() {
    # 密码通过文件描述符传递，不出现在 Python 命令行参数中。
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
# IPv4 部署：客户端 IPv6 目的地能力关闭，避免宣告不可用的 IPv6 出口。
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
    sys.exit('服务端未生成唯一有效的 tt:// 配置链接。')
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
Description=TrustTunnel Endpoint (Chinese oneclick)
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
        die "证书钩子路径已被其他程序使用：$HOOK。"
    fi
    install -d -m 755 "${HOOK%/*}"
    # 仅在本域名证书成功续期后通知本服务加载证书。
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
        warn "Certbot 使用系统自带 cron 续期任务。"
    else
        die "未发现 Certbot 自动续期任务；请检查 certbot 安装。"
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
        warn "$SHORTCUT 已存在其他程序，本次不覆盖；可继续使用原脚本打开菜单。"
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
    say "手机连接参数（这些信息包含密码，请妥善保管）"
    printf '地址：%s\n端口：%s\nHostname：%s\n用户名：%s\n密码：%s\nDNS：1.1.1.1\n' \
        "$PUBLIC_IP" "$PORT" "$HOSTNAME" "$TT_USER" "$TT_PASSWORD"
    printf '\n协议：先用 HTTP/2 测试，再改为 QUIC。\n\n'
    cat "$CONF_DIR/client-link.txt"
    cat <<'IMPORT'

手机一键导入（先安装 TrustTunnel 客户端）：
1. 在手机上复制上面完整的 tt://?... 链接，即 client-link.txt 中的完整内容。
2. 用手机浏览器打开官方导入页：https://trusttunnel.org/qr.html
3. 粘贴链接，点 Generate QR Code Locally（生成二维码）。
4. 点 Open in TrustTunnel App（在 TrustTunnel 中打开），自动带入节点配置。
5. 按提示保存，回到 Servers 开启连接，并允许系统 VPN 授权。
IMPORT
    if command -v qrencode >/dev/null; then
        printf '\n配置二维码（终端窗口足够宽时可扫描）：\n'
        if ! qrencode -t ANSIUTF8 < "$CONF_DIR/client-link.txt"; then
            warn "二维码生成失败，可直接复制上面的链接。"
        fi
    fi
    if [[ "$CERT_MODE" == 2 ]]; then
        warn "自签证书：导入上面的 tt:// 链接以带入证书；证书验证保持开启。续签后需重新导入。"
    fi
    printf '\n安卓客户端：https://play.google.com/store/apps/details?id=com.adguard.trusttunnel\n'
    printf '请在云厂商后台放行 TCP %s 与 UDP %s。\n' "$PORT" "$PORT"
    printf '配置保存在 %s。\n' "$CONF_DIR"
    if [[ -f "$SHORTCUT" ]] && grep -q '^# TrustTunnel 中文一键安装与管理' "$SHORTCUT"; then
        printf '服务管理命令：tt-menu\n'
    else
        printf '管理菜单：bash %q\n' "$MANAGER_SOURCE"
    fi
}

install_main() {
    if [[ -f "$STATE" ]]; then
        say "已存在配置。先检查状态；版本升级使用菜单中的更新功能。"
        show_config
        return 0
    fi
    [[ ! -e "$UNIT" ]] || die "$UNIT 已存在，停止安装以避免覆盖。"
    if [[ -d "$APP_DIR" ]] && [[ -n "$(ls -A "$APP_DIR")" ]] \
        && [[ ! -f "$APP_DIR/.managed-by-tt-oneclick" ]]; then
        die "$APP_DIR 已有其他内容，停止安装。"
    fi
    if [[ -d "$CONF_DIR" ]] && [[ -n "$(ls -A "$CONF_DIR")" ]]; then
        die "$CONF_DIR 存在未完成的配置。请先检查并备份该目录，再清理后重试。"
    fi
    dependencies
    gather_inputs
    install -d -m 700 "$APP_DIR" "$CONF_DIR"
    printf '%s\n' 'TrustTunnel oneclick owned directory' > "$APP_DIR/.managed-by-tt-oneclick"
    INITIAL_INSTALL_PENDING=1
    # 优先验证可执行程序，避免下载失败后留下证书配置。
    download_binaries
    prepare_certificate
    write_configs
    export_to "$WORK/bin/trusttunnel_endpoint" "$CONF_DIR/client-link.txt"
    [[ ! -e "$APP_DIR/bin" ]] || die "专用目录中已存在 bin，请检查后重试。"
    mv -- "$WORK/bin" "$APP_DIR/bin"
    write_unit
    configure_renewal
    allow_ufw "$PORT" tcp
    allow_ufw "$PORT" udp
    save_manager
    systemctl enable --now "$SERVICE"
    if ! wait_ready; then
        journalctl -u "$SERVICE" -n 40 --no-pager >&2 || true
        die "服务未同时监听 TCP/UDP。本次安装将撤回；修复日志中的原因后可重新安装。"
    fi
    INITIAL_INSTALL_PENDING=0
    cleanup
    WORK=""
    say "安装完成，服务已启动并设置开机自启。"
    show_config
}

status_main() {
    load_state
    "$APP_DIR/bin/trusttunnel_endpoint" --version
    systemctl status "$SERVICE" --no-pager -l || true
    ss -lntup "( sport = :$PORT )" || true
    openssl x509 -in "$CERT" -noout -dates || true
    printf '\n最近日志（不输出配置密码）：\n'
    journalctl -u "$SERVICE" -n 30 --no-pager || true
    warn "本地监听正常不等于公网连通；手机仍需测试 TCP、UDP 和实际出口 IP。"
}

update_main() {
    load_state
    download_binaries
    # 新程序先读取现有配置并生成链接，验证后才停服务。
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
            say "新版本已启动。"
        else
            die "新版本启动失败，本次更新将撤回并恢复旧程序。"
        fi
    fi
    install -m 600 "$WORK/client-link.txt" "$CONF_DIR/client-link.txt"
    UPDATE_PENDING=0
    cleanup
    WORK=""
    say "版本更新完成。"
    if (( ! UPDATE_WAS_ACTIVE )); then warn "更新前服务已停止；需要使用菜单中的启动功能运行。"; fi
}

certificate_main() {
    load_state
    openssl x509 -in "$CERT" -noout -dates
    case "$CERT_MODE" in
        1)
            say "测试证书续期和加载钩子……"
            certbot renew --cert-name "$(acme_cert_name)" --dry-run --run-deploy-hooks
            ;;
        2)
            say "自签证书有效期一年，续签会改变客户端信任的证书。"
            local answer
            ask answer "输入 RENEW 续签并重新导出配置（回车取消）"
            [[ "$answer" == RENEW ]] || return 0
            local backup
            backup=$(mktemp -d "$CONF_DIR/certs-backup-XXXXXXXX")
            cp -p -- "$CERT" "$KEY" "$backup/"
            prepare_certificate
            if systemctl is-active --quiet "$SERVICE"; then
                systemctl kill --kill-who=main --signal=HUP "$SERVICE"
            fi
            show_config
            warn "请在手机重新导入新链接。旧证书备份位于 $backup。"
            ;;
        3) warn "外部证书由原签发工具续期；更新文件后可通过菜单重启服务。" ;;
    esac
}

uninstall_main() {
    load_state
    local answer
    warn "将删除本脚本的服务、专用程序目录和配置（包括连接口令）。"
    ask answer "输入 UNINSTALL 确认卸载（回车取消）"
    [[ "$answer" == UNINSTALL ]] || return 0
    systemctl disable --now "$SERVICE"
    rm -f -- "$UNIT"
    if [[ -f "$HOOK" ]] && grep -q '^# Managed by TrustTunnel oneclick$' "$HOOK"; then rm -f -- "$HOOK"; fi
    if [[ -f "$SHORTCUT" ]] && grep -q '^# TrustTunnel 中文一键安装与管理' "$SHORTCUT"; then rm -f -- "$SHORTCUT"; fi
    rm -rf -- "$APP_DIR" "$CONF_DIR"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    say "本脚本的服务与专用文件已卸载。Certbot 证书及防火墙规则保留，便于其他服务继续使用。"
}

service_action() {
    load_state
    systemctl "$1" "$SERVICE"
    if [[ "$1" == start || "$1" == restart ]]; then
        if ! wait_ready; then die "服务启动失败，请使用状态菜单查看日志。"; fi
    fi
    say "服务操作完成：$1"
}

change_port_main() {
    load_state
    local new_port
    say "当前端口：$PORT（TCP 与 UDP）。修改成功后，手机需重新导入新链接。"
    while :; do
        ask new_port "新端口（回车取消）" "$PORT"
        if ! valid_port "$new_port"; then
            warn "端口可用 443，或 1024–65535。"
            continue
        fi
        new_port=$((10#$new_port))
        if [[ "$new_port" == "$PORT" ]]; then
            say "已取消端口修改。"
            return 0
        fi
        if port_free "$new_port"; then break; fi
        warn "新端口 $new_port 的 TCP 或 UDP 已被占用，请更换。"
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
    # 只修改主配置的监听端口和状态端口，保留其他配置与连接口令。
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
    sys.exit('没有找到唯一的顶层 listen_address；停止修改。')
match = matches[0]
raw = match['value']
address = json.loads(raw) if raw.startswith('"') else raw[1:-1]
bind, separator, old_port = address.rpartition(':')
if not separator or not bind or not old_port.isdigit():
    sys.exit('listen_address 不是地址:端口格式；停止修改。')
state = json.load(open(state_path, encoding='utf-8'))
if int(old_port) != int(state['port']):
    sys.exit('配置与状态文件的原端口不一致，请先检查配置。')
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
            die "新端口启动失败，本次修改将撤回。"
        fi
    fi
    install -m 600 "$PORT_CHANGE_BACKUP/client-link-new.txt" "$CONF_DIR/client-link.txt"
    PORT_CHANGE_PENDING=0
    save_manager
    say "端口已更新为 $PORT。"
    if (( ! PORT_CHANGE_WAS_ACTIVE )); then
        warn "服务当前已停止，可使用菜单 6 启动。"
    fi
    show_config
    warn "云厂商安全组需放行 TCP $PORT 与 UDP $PORT；请在手机重新导入上面的配置。"
}

menu() {
    local choice
    while :; do
        cat <<MENU

────────────────────────────────────
  TrustTunnel 中文管理 v$MANAGER_VERSION
────────────────────────────────────
  1. 一键安装
  2. 查看手机配置／链接／二维码
  3. 查看状态与日志
  4. 重启服务
  5. 停止服务
  6. 启动服务
  7. 更新官方服务端（失败自动回退）
  8. 证书维护／续期检查
  9. 卸载本脚本的 TrustTunnel
 10. 修改端口（生成新链接，失败恢复原端口）
 11. 扫描已有证书与域名（只查看）
  0. 退出
MENU
        ask choice "请选择" "0"
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
            *) warn "请输入菜单中的数字。" ;;
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
        *) help_text; die "未知参数：$1" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
