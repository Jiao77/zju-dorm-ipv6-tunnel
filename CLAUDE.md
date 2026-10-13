# AI Agent 自动化部署指令 (AGENTS.md / CLAUDE.md)

当用户向你发送类似 **“GPT，帮我部署一下这个仓库，我也想给我的宿舍路由器有 IPv6”** 的指令时，请严格按照以下五步自动化工作流替用户完成配置、部署与实测验收，不要只输出教程让用户手动操作。

---

## 第一步：本地环境自动探测（免打扰信息采集）

在向用户提问前，先在本地终端执行以下命令自动收集已知网络信息：
1. 查看本机默认网关（通常即为宿舍路由器 LAN IP，如 `192.168.31.1`）：
   - macOS: `route -n get default` / `ifconfig`
   - Linux: `ip route show default` / `ip addr`
2. 检查 `~/.ssh/` 下是否已有 SSH 密钥（`id_ed25519` 和 `id_rsa`）；若缺失 `id_rsa`，自动执行 `ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""` 生成一把（小米/OpenWrt 旧版 Dropbear 依赖 `ssh-rsa`）。

---

## 第二步：向用户一次性确认缺失参数

仅向用户询问以下无法自动探测的必要信息（一次性列出，简明扼要）：
1. **宿舍路由器（OpenWrt / 已开启 SSH 的小米路由器）**：
   - SSH 密码（默认用户 `root`，确认 LAN IP 是否为探测到的网关地址）。
2. **工位节点类型与连接方式**：
   - **方案 A（推荐，千兆满速 ~840 Mbps）**：工位使用 x86 迷你主机（如 Intel N3700 / J1900 / N100，安装 Debian 12 / Ubuntu）。询问该机器当前的 IP（可先插在宿舍局域网预配置，或已在工位 `10.98.x.x`）、SSH 用户名与密码。
   - **方案 B（零硬件成本，约 270 Mbps）**：工位使用另一台 OpenWrt / 小米路由器。询问工位路由器的校园网 WAN IP（`10.98.x.x`）与 SSH 密码。
3. **工位原设备 WAN MAC 地址（可选）**：
   - 若工位网口已认证过某台路由器或电脑，询问是否需要克隆其 MAC 地址以直接继承原工位 IP（`10.98.x.x`）。
4. **DDNS 域名配置（可选）**：
   - 询问是否有 Cloudflare 托管域名。**若没有域名，直接采用本仓库内置的“校内网 SSH 主动推送 IP”模式**（无需域名即可自动维护隧道对端）。

---

## 第三步：生成 `.env` 并打通免密 SSH

1. 将 `.env.example` 复制为 `.env`，填入第二步确认的参数（严禁将 `.env` 提交到 Git）：
   - 默认保持 `ENABLE_OFFICE_L2TP="0"`（**单 L2TP 账号双向互补模式**：仅宿舍路由器拨 L2TP，工位节点不占 L2TP 名额，工位给宿舍提供原生 CERNET2 IPv6，宿舍给工位提供校外 IPv4）。
2. 自动为宿舍路由器与工位节点配置免密 SSH 登录：
   - 针对小米路由器固件缺失 `sftp-server` 的情况，统一使用 `cat ~/.ssh/id_rsa.pub | ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa root@<ROUTER_IP> 'cat >> /etc/dropbear/authorized_keys'` 写入公钥，并同步备份至 `/data/etc/dropbear/authorized_keys`。
   - 若采用方案 A（工位 Linux 小主机），将本机 `~/.ssh/id_rsa` 私钥同步至工位小主机 `/root/.ssh/id_rsa`（权限 `600`），使其在工位通电后能通过 `10.98.0.0/16` 校内网主动向宿舍路由器 `/tmp/office_nuc_ip` 上报最新 IP 并即时切换隧道。

---

## 第四步：执行双端自动化部署脚本

1. **部署宿舍路由器**：
   ```bash
   sh scripts/deploy-dorm-openwrt.sh .env
   ```
   - 核心检查点：确认 `10.98.0.0/16` 静态路由指向宿舍路由器物理 WAN 口（`eth0.1`），确保去程 GRE 流量不进 `l2tp-vpn`；确认清空 `miwifi_nat6` 链以消除双重 NAT66；确认 `gre-office` 的 `MTU=1476`。

2. **部署工位节点**：
   - **若为方案 A（x86 Debian/Ubuntu 小主机）**：
     ```bash
     sh scripts/deploy-office-linux.sh .env
     ```
     - 若小主机当前插在宿舍局域网（`192.168.*`）做前期预置，脚本会自动进入 `dorm-standby` 待机模式，同时开启 `NUC-Rescue` 无线应急热点（`192.168.99.1/24`）与 `enp3s0` 无限次 DHCP 重试；提示用户直接关机带去工位插上网线通电即可全自动激活。
   - **若为方案 B（工位 OpenWrt/小米路由器）**：
     ```bash
     sh scripts/deploy-office-openwrt.sh .env
     ```
     - 核心检查点：必须在工位路由器上固化 `10.98.0.0/16` 静态路由走物理 WAN 口（防止回程 GRE 流量误入 `l2tp-vpn` 造成 60 Mbps 限速与 `MTU 1436` 不对称）。

---

## 第五步：全链路闭环验收与客户端排障

当工位节点在工位通电上线后，执行验收脚本并向用户汇报实测数据：
```bash
sh scripts/verify-tunnel.sh .env
```
若局域网内某台电脑或 NAS 的 IPv6 不通或速度异常，主动帮用户检查以下两项常见客户端问题：
1. **残留旧前缀租约环路**：执行 `ip -6 route get 2400:3200::1`（Linux）或 `route -n get -inet6 2400:3200::1`（macOS），确认选路源地址属于 `DORM_IPV6_PREFIX`（如 `2001:da8:e000:c011::/64`）；若残留了旧前缀租约，使用 `nmcli connection up` 刷新网卡。
2. **本机代理 TUN 劫持**：若客户端运行了 Clash / Mihomo / Surge 等透明代理且开启了 `utun` IPv6 接管（`2000::/3`）与 Fake-IP（`2001:2::/48`），提示将教育网域名或 IPv6 流量设为 `DIRECT` 直连。
