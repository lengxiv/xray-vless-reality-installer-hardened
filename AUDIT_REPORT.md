# xray-vless-reality-installer 全量审计报告

- **审计对象**:`ndatg/xray-vless-reality-installer`(main 分支快照,2026-09-26)
- **审计文件**:`xray-install.sh`(786 行)、`xray-install-docker.sh`(892 行)、`README.md`、`.gitignore`、`LICENSE`
- **审计方式**:逐行人工审读(安全性、正确性、健壮性、可移植性),修改后以 bash 5.3 语法校验 + 29 项函数级测试验证

## 一、总体结论

代码整体质量**较高**,未发现后门、恶意代码或数据外传:脚本仅访问 `api.ipify.org` / `ifconfig.me` 探测公网 IP、GitHub API 获取版本号并从 GitHub Releases 下载 Xray 二进制,均为常规操作。已有不少良好实践:写入配置前 `xray run -test` 校验、临时文件 + `mv` 原子替换、专用低权限服务账户、私网地址黑洞(`blackhole`)、`set -euo pipefail`。

本次审计发现 **1 处主要安全缺口(systemd 服务无沙箱)、3 处安全加固点、约 15 处健壮性/可移植性缺陷**,全部已直接修复。遗留风险见第四节。

## 二、已修复问题

### A. 安全类

**A1. systemd 服务缺少沙箱(最重要)** — `xray-install.sh` 的 `xray.service` 只有 `User=xray` + `CAP_NET_BIND_SERVICE`。Xray 直接解析不可信客户端流量,一旦 RCE 可读写全盘。已加入完整加固集:`NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`PrivateDevices`、`ProtectProc=invisible`、内核/控制组/时钟/主机名保护、`RestrictSUIDSGID/Realtime/Namespaces`、`LockPersonality`、`RestrictAddressFamilies`、`MemoryDenyWriteExecute`、`SystemCallArchitectures=native`、`UMask=0077`、`RestartSec=3`。

**A2. 交互输入未校验即内嵌 JSON/URI** — 服务器地址和 SNI 域名原样写入 `config.json`(如 `"target": "$sni:443"`)与客户端 URI。带引号的输入可破坏 JSON、注入额外配置键;含空格/斜杠则生成废 URI。新增 `is_valid_host()`(IPv4 / 域名白名单正则),两个脚本的安装流程均改为循环重试直到合法。附带效果:明确拒绝 IPv6 字面量(原来会生成无方括号的非法 URI)。

**A3. 凭据回退路径可预测** — UUID 回退用 `date +%s%N | sha256sum`(时间戳可猜测),ShortID 回退用 `RANDOM*RANDOM`(bash PRNG 可预测)。UUID 是认证凭据,不可预测性必须保证。改为:uuidgen → `/proc/sys/kernel/random/uuid` → `/dev/urandom`;ShortID 回退用 `od -An -N4 -tx1 /dev/urandom`(同时替换了最小镜像常缺失的 `xxd`)。

**A4. QR 码 PNG 含完整客户端凭据但按 umask 落盘** — 现生成后 `chmod 600`。

**A5. 私网黑洞缺少组播/保留段** — `PRIVATE_IPS_JSON` 补充 `224.0.0.0/4`、`240.0.0.0/4`、`ff00::/8`。

**A6. 防火墙不处理** — 系统启用 ufw/firewalld 时安装后 443 不通且无提示。新增 `open_firewall()`(检测活动防火墙、幂等放行 443/tcp、失败仅告警不中断),仅 host 版安装时调用;容器内防火墙一般由宿主负责,未加。

### B. 正确性 / 健壮性类

**B1. BBR 失败会中止整个安装** — `set -e` 下 `sysctl -p` 在内核不支持 BBR 时返回非零,安装中途退出留下半装状态。改为先 `modprobe tcp_bbr`,失败仅警告继续(BBR 只是加速项,不是必需项)。

**B2. busybox sed 不兼容** — docker 版 rc.local 插入用 GNU 扩展地址 `0,/^exit 0/`,Alpine 的 busybox sed 不支持,会直接报错。改为 `awk` 实现(插入到第一个 `exit 0` 之前),并保留原 inode 权限。

**B3. Alpine 依赖包名风险** — `apk add procps-ng` 在多数 Alpine 版本无此包名(且 busybox 自带 pgrep/pkill)。改为先不装,检测缺失时依次尝试 `procps` / `procps-ng`。

**B4. 输入 "08" 会让 remove_client 崩溃** — `(( choice < 1 ))` 把 `08` 当八进制解析报错,`set -e` 直接退出脚本。校验后先 `choice=$((10#$choice))` 剥离前导零。

**B5. clients 与 shortIds 失配时按索引删除会错位** — Short ID 与客户端是按位置配对的,数量不等时删 `shortIds[idx]` 会删错。现在仅在两者数量相等时同步删除,失配时只删客户端条目并给出警告。

**B6. public.key 丢失时生成空公钥的废 URI** — `add_client` 现在从配置中的私钥用 `xray x25519 -i` 自动恢复公钥并回写 `public.key`;仍失败则明确报错退出,而不是打印坏链接。

**B7. NAT VPS 检测到内网 IP** — `hostname -I` 回退可能取到 RFC1918/CGNAT/链路本地地址并写进客户端 URI。现在逐个过滤私网段(10/8、127/8、169.254/16、192.168/16、172.16/12、100.64/10、0/8),全是私网则交回交互输入。

**B8. nologin 路径写死** — `/usr/sbin/nologin` 在部分发行版(如 Arch)路径不同。改为探测:`/usr/sbin/nologin` → `command -v nologin` → `/bin/false`。

**B9. host 版 install_deps 缺 openssl** — 脚本用 `openssl rand` 生成 ShortID/spiderX 但未声明依赖。已加入 apt/dnf/yum/pacman 列表(docker 版原本就有)。

**B10. qrencode 兼容性** — `-t ANSIUTF8` 需要 qrencode ≥ 4.0,老版本报错会在安装收尾阶段被 `set -e` 中断;PNG 写失败同理。改为 PNG 失败仅告警,终端二维码按 ANSIUTF8 → UTF8 → ANSI 降级且永不中断。

**B11. 私网拦截提示反复骚扰** — 每次重跑菜单都会再问一次。拒绝后写入 `/etc/xray/.no-private-block` 记忆,之后不再询问;接受安装后自动清除该标记。

**B12. restart_xray 固定 sleep 2** — 改为 5×1s 轮询 `is-active`,启动慢的服务不再误报失败。

**B13. 卸载残留 xray 系统用户** — `remove_xray` 现在会 `userdel xray`(失败仅提示)。

**B14. 文档同步** — README 补充:防火墙放行、systemd 加固说明、组播/保留段、拒绝记忆说明、域名/IPv4 要求。

## 三、验证

| 项目 | 结果 |
|---|---|
| `bash -n` 语法校验(两个脚本,bash 5.3.15) | 通过 |
| 函数级测试 29 项(`run-tests.sh`) | 全部通过 |
| `PRIVATE_IPS_JSON` JSON 合法性(PowerShell `ConvertFrom-Json`) | 合法,13 个 CIDR |

`run-tests.sh` 为一次性测试脚手架(从脚本中剥离入口点后加载函数测试),可复跑:`bash run-tests.sh`,不需要时可删除。

## 四、遗留风险(审阅后有意不改,建议知悉)

1. **Xray 二进制未做签名/校验和验证** — 下载仅依赖 HTTPS 与 GitHub Releases。官方发布页提供 `.dgst` 与 XTLS 签名,自动验证需内置公钥并引入 gpg 依赖;如需供应链级保证可作为后续增强。
2. **docker 模式 Xray 以 root 运行** — 容器内无统一用户体系(useradd/adduser 差异),靠容器隔离兜底;README 已注明与 host 版差异。
3. **`curl | bash` 执行方式本身的风险** — README 现有 `wget` 后再 `bash` 的用法更稳妥。
4. **无流量统计/审计/速率限制** — 属产品定位,非缺陷。

## 五、修改文件清单

| 文件 | 变更 |
|---|---|
| `xray-install.sh` | A1–A6、B1、B4–B13 |
| `xray-install-docker.sh` | A2–A5、B2–B7、B10–B11(容器版无 systemd/BBR/防火墙对应项) |
| `README.md` | B14 |
| `AUDIT_REPORT.md` | 本报告(新增) |
| `run-tests.sh` | 测试脚手架(新增,可删) |
