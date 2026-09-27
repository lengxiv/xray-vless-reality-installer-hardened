# Xray VLESS + REALITY Installer(Hardened / 审计加固版)

**这是什么**:一个在 **Linux VPS / Docker 容器**上一键安装并管理 **Xray VLESS + REALITY** 代理服务的脚本。首次运行自动完成全部安装——下载 Xray 内核、生成 REALITY 密钥与客户端凭据、配置服务与开机自启、输出连接链接和二维码;之后再次运行进入管理菜单——添加/删除客户端、重启服务、彻底卸载。无需域名、无需证书,支持 **TCP + XTLS Vision** 与 **XHTTP** 两种传输,并默认拦截客户端对服务器私网/云元数据地址的访问。

本项目基于 [ndatg/xray-vless-reality-installer](https://github.com/ndatg/xray-vless-reality-installer) 完成了**全量安全审计与加固**,修复 20+ 项安全与健壮性问题:systemd 服务沙箱隔离、交互输入校验(防配置注入)、凭据随机性(全部改用 /dev/urandom)、BBR 失败不再中断安装、Alpine/busybox 兼容、REALITY 公钥自动恢复等,逐项说明见 **[AUDIT_REPORT.md](AUDIT_REPORT.md)**。上游采用 MIT 许可,本项目同样以 MIT 发布。

## Quick Start

One script to install and manage a VLESS + REALITY VPN server on any Linux VPS, with a choice of TCP + XTLS Vision or XHTTP transport. No domain, no certificates — works out of the box in under 2 minutes. A separate script is available for Docker containers without systemd.

VPS(root 执行):

```bash
wget https://raw.githubusercontent.com/lengxiv/xray-vless-reality-installer-hardened/main/xray-install.sh && sudo bash xray-install.sh
```

To manage clients later, just re-run `sudo bash xray-install.sh`.

### Running in Docker (no systemd)

Use `xray-install-docker.sh` inside a Docker container (Debian/Ubuntu, Fedora, Alpine, Arch images). Run it as root; bash is required:

```bash
wget https://raw.githubusercontent.com/lengxiv/xray-vless-reality-installer-hardened/main/xray-install-docker.sh && bash xray-install-docker.sh
```

Differences from the host script:
- Xray runs as a background process; log in `/var/log/xray.log`
- No systemd unit, no dedicated user, no BBR
- Publish port 443 of the container (e.g. `docker run -p 443:443 ...`)
- Autostart without systemd, detected automatically:
  - **cron** (if a cron daemon runs in the container): checks every minute, so Xray comes back after a container restart *and* after a crash
  - otherwise **OpenRC** (`/etc/local.d`) or **`/etc/rc.local`**: starts Xray at container boot
  - if none is available, set your provider's startup command to `/usr/local/bin/xray-autostart`, or start Xray from the menu (**Start / restart Xray**)

## What It Does

**First run** — interactive installation:
- Installs Xray-core (latest version, auto-detects architecture)
- Detects the server's public IP — you can keep it or enter a domain instead
- Generates REALITY keys, UUID, Short ID
- Lets you choose the transport: **TCP + XTLS Vision** (default, supported by all clients) or **XHTTP** (see below)
- Checks the SNI site against REALITY target requirements (TLS 1.3, HTTP/2, no redirect to another domain) and warns before continuing
- Lets you choose DNS (Google, Cloudflare, Quad9, AdGuard, OpenDNS)
- Configures a hardened systemd service on port 443 with autostart at boot
  (dedicated user, minimal capabilities, filesystem/syscall sandboxing)
- Opens port 443 in UFW or firewalld if one is active
- Validates the config and checks that Xray actually started (shows logs if not)
- Blocks clients from reaching the server's local and private addresses (see below)
- Enables TCP BBR for better speed (persistent across reboots)
- Prints connection URI + QR code

**Every next run** — service status and management menu:

```
Xray VLESS+REALITY is already installed.

   Service  : active (since Thu 2026-09-25 21:00:00 MSK)
   Autostart: enabled
   Version  : 26.3.27
   Address  : 203.0.113.10
   SNI      : www.cloudflare.com
   Transport: TCP + XTLS Vision
   Clients  : 3
   Log      : journalctl -u xray

Select an option:
   1) Add a new client
   2) Remove an existing client
   3) Start / restart Xray
   4) Remove Xray
   5) Exit
```

If autostart at boot was turned off, the script re-enables it. Config changes
(adding/removing clients) are validated before they replace the running config.
If the config was created by an older version without the private-address block,
the script offers to add it.

**Remove Xray** deletes the binary, configuration, service and BBR settings.

## Requirements

- Linux VPS (Debian, Ubuntu, CentOS, Fedora, Arch)
- Root access
- Port 443 open
- Server address for client links: a domain or IPv4 (IPv6 literals are not supported)

The script installs all dependencies automatically.

## How It Works

REALITY is a next-gen security layer by the Xray team. It makes your VPN traffic indistinguishable from a regular HTTPS connection to a real website (the SNI site, e.g. `www.cloudflare.com`). Unlike traditional TLS proxies, REALITY requires no certificates and no domain — just a VPS with a public IP. On top of REALITY the traffic is carried either over TCP with XTLS Vision or over XHTTP (see below).

### Choosing the SNI site

The SNI site should be a foreign site that supports TLS 1.3 and HTTP/2 (required for XHTTP) and does not redirect to another domain — the script checks this during installation. Prefer a site hosted in the same network as your VPS over popular domains (Google, Microsoft, Apple): a VPS IP claiming to be one of them is easy to spot. Some sites pass the check but still fail with REALITY (e.g. `www.microsoft.com` with its very large certificate chain), so test a connection after installing.

## Transport: TCP + Vision or XHTTP

| | TCP + XTLS Vision | XHTTP |
|---|---|---|
| Client support | All apps | Apps with a recent Xray-core; see [Client Apps](#client-apps) |
| How it looks | One long TLS connection | HTTP requests (harder to fingerprint by connection pattern) |
| Flow | `xtls-rprx-vision` | none (Vision works only over TCP) |

XHTTP follows the [official Project X example](https://github.com/XTLS/Xray-examples/tree/main/VLESS-XHTTP-Reality):
only a random `path` is set, `mode` is `auto` (the client picks `stream-one` with REALITY),
everything else uses Xray defaults. Requires Xray-core v25.3.6 or newer. Do **not** enable
Mux (mux.cool) in the client app when using XHTTP.

The transport is chosen at install time; to switch, reinstall (clients get new links).

## Private Address Blocking

Clients can use the server only to reach the internet. Connections to the
server's own and internal addresses are dropped:

- `127.0.0.0/8`, `::1` — services on the server itself (databases, admin panels, APIs listening on localhost)
- `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `fc00::/7` — provider/LAN networks, Docker host
- `169.254.0.0/16`, `fe80::/10` — link-local, including the cloud metadata service `169.254.169.254`
- `224.0.0.0/4`, `240.0.0.0/4`, `ff00::/8` — multicast and reserved ranges

This also covers hostnames that resolve to these addresses (`localhost`, entries
from `/etc/hosts`, public domains pointing to `127.0.0.1`). Xray's own DNS queries
are routed directly, so a local system resolver keeps working. To allow access,
remove the `"outboundTag": "block"` rule from `routing.rules` in `/etc/xray/config.json`
and restart Xray. Declining the one-time prompt is remembered (a marker file in
`/etc/xray`), so it is not asked again on every run.

## Client Apps

Import the generated URI or scan the QR code. All apps below support **TCP + XTLS Vision**.
**XHTTP** is an Xray-core feature: apps built on a recent Xray-core (v25.3.6+) support it,
apps built on sing-box usually do not.

| Platform | App | XHTTP |
|----------|-----|-------|
| iOS | [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118), [V2BOX](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) | check the app version |
| macOS | [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118), [V2BOX](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) | check the app version |
| Android | [v2rayNG](https://github.com/2dust/v2rayNG) | yes (Xray-core) |
| Android | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid) | no (sing-box core) |
| Windows | [v2rayN](https://github.com/2dust/v2rayN) | yes (Xray-core) |
| Linux | [v2rayA](https://github.com/v2rayA/v2rayA) | yes, with Xray-core |
| Linux | [Nekoray](https://github.com/Mahdi-zarei/nekoray), [Hiddify](https://github.com/hiddify/hiddify-app) | usually no (sing-box core) |

With XHTTP, keep **Mux** disabled in the app.

## File Locations

| Path | Description |
|------|-------------|
| `/usr/local/bin/xray` | Xray-core binary |
| `/etc/xray/config.json` | Server configuration |
| `/etc/xray/public.key` | REALITY public key |
| `/etc/xray/server.addr` | Server address (IP or domain) used in client links |
| `/etc/xray/vless-*.png` | QR code images |
| `/etc/systemd/system/xray.service` | Systemd service unit |
| `/etc/sysctl.d/99-xray-bbr.conf` | TCP BBR settings |

## License

MIT
