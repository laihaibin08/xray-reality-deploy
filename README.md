# xray-reality-deploy

Xray VLESS + Reality 一键部署脚本。适用于各类 VPS 和独立服务器。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/laihaibin08/xray-reality-deploy/main/deploy-xray.sh)
```

非 root 用户先执行 `sudo -i` 再运行上面的命令。

## 常用命令

```bash
URL=https://raw.githubusercontent.com/laihaibin08/xray-reality-deploy/main/deploy-xray.sh
bash <(curl -fsSL $URL) info       # 显示导入链接、二维码、Egern / mihomo 节点配置
bash <(curl -fsSL $URL) update     # 更新 Xray 内核，保留配置和密钥
bash <(curl -fsSL $URL) restart    # 重启
bash <(curl -fsSL $URL) status     # 运行状态
bash <(curl -fsSL $URL) logs 50    # 最近 50 行日志
bash <(curl -fsSL $URL) uninstall  # 卸载
```

## 参数（放在命令前）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| PORT | 443 | 监听端口 |
| SNI | www.microsoft.com | 伪装站点 |
| NAME | VPS-Reality | 节点名称 |
| MODE | auto | auto / docker / native |
| BLOCK_CN | 0 | 1 = 服务器拒绝转发发往中国大陆的流量 |
| FORCE | 0 | 1 = 重新生成密钥并重装 |
| YES | 0 | 1 = 卸载时不确认 |

示例：

```bash
PORT=8443 NAME=OVH_94_164_Reality bash <(curl -fsSL $URL)
SNI=www.apple.com FORCE=1 bash <(curl -fsSL $URL)
```

## 支持环境

- 系统：Debian、Ubuntu、CentOS、Rocky、Alma、RHEL、Fedora、Alpine、Arch、openSUSE
- 架构：x86_64、arm64
- 网络：IPv4、IPv6、双栈
- 虚拟化：KVM、独立服务器；OpenVZ / LXC 自动使用原生模式
- 防火墙：自动放行 ufw、firewalld、iptables

## 部署模式

- `auto`（默认）：已安装 Docker 就用 Docker；否则用原生 systemd 服务；都不行再尝试安装 Docker。
- `docker`：使用 `teddysun/xray` 镜像，host 网络。
- `native`：使用 XTLS 官方 Xray-install 脚本安装二进制和 systemd 服务。

## 客户端兼容性（重要）

| 客户端 | 注意 |
| --- | --- |
| Egern / Shadowrocket / v2rayN / Xray 内核客户端 | 直接用 `info` 输出的配置或导入链接 |
| Clash Verge Rev / mihomo | 必须用 `chrome` 指纹，并在 `reality-opts` 里加 `support-x25519mlkem768: true`（`info` 输出的 mihomo 节点已包含） |

原因：Xray 26.9.9 起要求客户端握手带 X25519MLKEM768，mihomo 默认不带，会报 `REALITY authentication failed`。服务器端另加了 `minClientVer: 1.8.2`，用于兼容 26.7.11 – 26.9.7 版本对 mihomo 上报版本号的限制。

## 文件位置

| 文件 | 内容 |
| --- | --- |
| /opt/xray/config.json | 服务端配置 |
| /opt/xray/client.env | 客户端参数（UUID、公钥、ShortID 等，仅 root 可读） |
| /opt/xray/client-link.txt | vless 导入链接 |
| /opt/xray/egern-proxy.yaml | Egern 节点配置片段 |
| /opt/xray/mihomo-proxy.yaml | Clash Verge / mihomo 节点配置片段（含 support-x25519mlkem768） |

## 更新记录

| 版本 | 内容 |
| --- | --- |
| 2.0.2 | mihomo 节点模板加 `support-x25519mlkem768: true` |
| 2.0.1 | 服务器 realitySettings 加 `minClientVer: 1.8.2` |
| 2.0.0 | 多系统支持、Docker / 原生双模式、子命令、输出 Egern / mihomo 配置 |
