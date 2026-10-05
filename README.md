# TrustTunnel 中文一键安装与管理

简体中文 | [English](README.en.md)

为 Debian / Ubuntu VPS 安装官方 TrustTunnel 服务端，提供中文交互菜单、可修改端口、已有证书扫描，以及手机配置链接和二维码。当前脚本版本：**v1.2.2**。

本项目是独立的安装与管理脚本；服务端程序由 [TrustTunnel 官方仓库](https://github.com/TrustTunnel/TrustTunnel)下载。

## 一键运行

适用：**Debian 12+ / Ubuntu 22.04+、x86_64 / aarch64、systemd、公网 IPv4**。在 VPS 的交互式 SSH 终端执行。先进入 root 会话；非 root 用户可运行 `sudo -i`。

```bash
curl -fL --retry 3 --connect-timeout 15 --max-time 180 https://raw.githubusercontent.com/zhou-3788/trusttunnel-oneclick/main/trusttunnel-oneclick.sh -o trusttunnel-oneclick.sh && bash trusttunnel-oneclick.sh
```

如果系统没有 curl，先执行 `apt-get update && apt-get install -y curl ca-certificates`。

选择菜单 **1** 安装，然后按提示确认公网 IP、端口、证书方式和连接用户名。密码直接回车会生成随机密码。脚本需要先下载到本地文件再运行，以保留交互输入并安装管理快捷命令。

首次安装的默认用户名为 `ttuser`，导出节点名称为 `TrustTunnel`；示例域名使用 `tt.example.com`。真实 IP、域名和连接凭据在 VPS 上输入或从本机证书中读取，不预置在源码中。已有安装继续使用原来的用户名和密码。

安装完成后运行：

```bash
tt-menu
```

## 修改端口

默认端口为 **8443**，HTTP/2 使用 TCP，QUIC 使用相同数字的 UDP 端口。安装时可以直接输入其他端口，支持 **443 或 1024–65535**。

也可以修改初始默认值：

```bash
TT_DEFAULT_PORT=9443 bash trusttunnel-oneclick.sh
```

已安装的节点使用 **菜单 10** 修改端口，或执行：

```bash
bash trusttunnel-oneclick.sh --change-port
```

端口修改成功后生成新链接；启动失败会恢复原配置。需要在云厂商安全组放行新端口的 **TCP 和 UDP**，并在手机重新导入新链接。环境变量只影响首次安装的提示默认值。

## 证书方式

| 选项 | 使用方式 | 续期方式 |
| --- | --- | --- |
| 1 | 输入域名，通过 Certbot 申请证书；域名 A 记录指向 VPS | Certbot 自动续期并通知本服务重新加载 |
| 2 | 只有公网 IP，生成一年有效的自签证书，主机名为 `tt.local` | 菜单 8 续签，手机重新导入新链接 |
| 3（默认） | 扫描已有证书，按编号自动填写域名、证书链及私钥路径 | 沿用原签发工具；证书更新后重启本服务 |

扫描支持 Certbot、acme.sh、Xray、V2Ray、sing-box、Nginx、Apache、Caddy 等常见目录或配置引用。只列出已经生效、剩余有效期超过一天、域名匹配且有对应未加密私钥的证书。

扫描列表中的操作：

- 输入编号：自动选定域名、证书链和私钥。
- 输入 `D`：扫描另一个绝对路径目录。
- 输入 `R`：重新扫描。
- 输入 `M`：手动填写域名和路径。
- 输入 `0`：返回证书方式选择。

通配符证书如 `*.example.com` 会生成受证书覆盖的示例主机名 `tt.example.com`。连接地址仍使用 VPS 公网 IP。

单独扫描可使用 **菜单 11**，或：

```bash
bash trusttunnel-oneclick.sh --scan-certs
bash trusttunnel-oneclick.sh --scan-certs /你的证书目录
```

单独扫描只展示结果。已有节点的证书配置不会因扫描自动切换。

使用 Certbot 申请新证书时，HTTP 验证需要 **TCP 80**。若已有网站占用 80，脚本会要求网站的 webroot 路径。使用 Cloudflare 管理该域名时，将对应记录设为 **DNS only（灰云）**。

## 手机一键导入

安装 [TrustTunnel 安卓客户端](https://play.google.com/store/apps/details?id=com.adguard.trusttunnel)。通过 **菜单 2** 查看完整 `tt://?...` 链接和终端二维码。

**官方导入页直接导入，无需手动填写节点参数。** 安装完成或选择菜单 **2** 时，脚本会在链接下方显示以下步骤：

1. 在手机上复制 `client-link.txt` 中完整的 **`tt://?...` 链接**；也可复制菜单 2 展示的完整链接。
2. 用手机浏览器打开 [TrustTunnel 官方导入页](https://trusttunnel.org/qr.html)。
3. 粘贴链接，点 **Generate QR Code Locally（生成二维码）**。
4. 再点 **Open in TrustTunnel App（在 TrustTunnel 中打开）**，自动带入节点配置。
5. 按提示保存，回到 **Servers** 开启连接，并允许系统 VPN 授权。

首次测试建议使用 **HTTP/2**，再测试 **QUIC**。脚本按 IPv4 出口生成配置。自签证书会包含在导出链接内，客户端保持证书验证开启。证书重新签发后，需要重新导入配置。

`tt://` 链接包含连接口令，请在自己的设备上使用。

## 管理菜单

| 菜单 | 功能 |
| --- | --- |
| 1 | 安装；已有配置时展示连接配置 |
| 2 | 查看手机配置、链接和二维码 |
| 3 | 查看版本、服务状态、监听端口、证书日期及日志 |
| 4 / 5 / 6 | 重启 / 停止 / 启动服务 |
| 7 | 更新官方服务端；失败自动恢复旧程序 |
| 8 | 证书维护或续期检查 |
| 9 | 确认后卸载本脚本管理的服务及专用文件 |
| 10 | 修改端口并生成新链接；失败恢复原配置 |
| 11 | 只读扫描已有证书与域名 |
| 0 | 退出 |

命令参数：

```bash
bash trusttunnel-oneclick.sh --help
bash trusttunnel-oneclick.sh --install
bash trusttunnel-oneclick.sh --show
bash trusttunnel-oneclick.sh --status
bash trusttunnel-oneclick.sh --update
bash trusttunnel-oneclick.sh --check-cert
bash trusttunnel-oneclick.sh --change-port
bash trusttunnel-oneclick.sh --scan-certs
```

菜单 7 更新的是官方服务端程序。管理脚本有新版时，重新下载并运行新版 `.sh` 文件。

## 配置文件位置

| 路径 | 用途 |
| --- | --- |
| `/etc/trusttunnel-oneclick/vpn.toml` | 服务端主配置、监听端口、HTTP/2 与 QUIC 参数 |
| `/etc/trusttunnel-oneclick/hosts.toml` | TLS 主机名、证书链和私钥路径 |
| `/etc/trusttunnel-oneclick/credentials.toml` | 连接用户名和密码 |
| `/etc/trusttunnel-oneclick/state.json` | 管理脚本状态，包含连接口令 |
| `/etc/trusttunnel-oneclick/client-link.txt` | 手机导入链接 |
| `/etc/trusttunnel-oneclick/certs/` | 自签证书及私钥（证书方式 2） |
| `/opt/trusttunnel-oneclick/bin/` | 官方服务端程序 |
| `/etc/systemd/system/trusttunnel-oneclick.service` | systemd 服务文件 |
| `/usr/local/sbin/tt-menu` | 安装时保存的管理快捷命令 |

查看日志：

```bash
journalctl -u trusttunnel-oneclick.service -n 50 --no-pager
```

端口调整建议使用菜单 10，以同步主配置、管理状态和手机链接。配置文件、私钥和导入链接仅 root 可读。

## 网络与证书排查

- **无法连接**：检查服务状态，并在 VPS 安全组放行所选端口的 TCP、UDP。服务本地监听成功后仍需手机测试公网连通性。
- **HTTP/2 可用、QUIC 不可用**：检查 UDP 端口放行及当前网络的 UDP 连通性。
- **扫描不到证书**：使用 `D` 或 `--scan-certs /目录` 补充位置；检查证书有效期、域名及未加密私钥是否匹配。也可以选择 `M` 手动输入。
- **证书续期后无法连接**：外部证书更新后重启服务；自签证书重签后重新导入手机配置。
- **官方程序下载失败**：检查 VPS 到 GitHub API、Raw 和 Releases 下载地址的连通性，再重试。

已启用 UFW 时脚本添加相应放行规则；云厂商安全组需在平台上设置。卸载保留 Certbot 证书和防火墙规则，以便其他服务继续使用。

## 发布校验

`SHA256SUMS` 保存本次发布文件的 SHA-256。克隆或下载完整仓库后，可在仓库目录执行：

```bash
sha256sum -c SHA256SUMS
```

v1.2 已通过 Bash 语法、真实 OpenSSL 证书扫描与校验，以及模拟安装、端口修改和回退检查。下载、systemd 和防火墙使用模拟环境验证；实际 VPS 与手机连通性需部署后测试。

v1.2.1 清理默认值中的个人标识，并通过 Bash 语法、默认输入、导出节点名称及模拟安装和端口回退检查。

官方资料：[服务端配置](https://github.com/TrustTunnel/TrustTunnel/blob/master/CONFIGURATION.md) · [证书续期](https://github.com/TrustTunnel/TrustTunnel/blob/master/CERT_RENEWAL.md)
