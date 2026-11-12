#!/usr/bin/env bash
# ==============================================================================
#  Xray VLESS + Reality 一键部署脚本
#  仓库：https://github.com/laihaibin08/xray-reality-deploy
#
#  一键安装：
#    bash <(curl -fsSL https://raw.githubusercontent.com/laihaibin08/xray-reality-deploy/main/deploy-xray.sh)
#
#  子命令：install（默认）| info | update | restart | status | logs | uninstall | help
#  环境变量：PORT  SNI  NAME  MODE(auto|docker|native)  BLOCK_CN(0|1)  FORCE(0|1)  YES(0|1)
#
#  支持：Debian / Ubuntu / CentOS / Rocky / Alma / RHEL / Fedora / Alpine / Arch / openSUSE
#        x86_64 / arm64；IPv4、IPv6、双栈；KVM、独立服务器；OpenVZ/LXC（自动用原生模式）
# ==============================================================================
set -u

VERSION="2.0.2"
# 2.0.2：mihomo 节点模板加 support-x25519mlkem768: true。
#        Xray 26.9.9 起要求客户端握手带 X25519MLKEM768，mihomo 默认不带，会报 REALITY authentication failed
# 2.0.1：realitySettings 加 minClientVer=1.8.2。
#        Xray 26.7.x 起未设置时默认要求客户端 ≥26.3.27，而 mihomo（Clash Verge）上报 1.8.2，会报 REALITY authentication failed

# ---------------- 默认参数（可用环境变量覆盖） ----------------
PORT="${PORT:-443}"
SNI="${SNI:-www.microsoft.com}"
NAME="${NAME:-VPS-Reality}"
MODE="${MODE:-auto}"          # auto：已有 docker 用 docker，否则用原生 systemd
BLOCK_CN="${BLOCK_CN:-0}"     # 1 = 服务器拒绝转发发往中国大陆的流量
FORCE="${FORCE:-0}"           # 1 = 重新生成密钥并重装
YES="${YES:-0}"               # 1 = 卸载时不再确认

DIR=/opt/xray
CONF="$DIR/config.json"
ENVF="$DIR/client.env"
IMG=teddysun/xray
NATIVE_BIN=/usr/local/bin/xray
NATIVE_CONF=/usr/local/etc/xray/config.json
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# ---------------- 输出 ----------------
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
info() { echo "${C_G}[+]${C_0} $*"; }
warn() { echo "${C_Y}[!]${C_0} $*"; }
err()  { echo "${C_R}[x]${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { echo "${C_B}------------------------------------------------------------${C_0}"; }

# ---------------- 基础检测 ----------------
need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash $0 ${1:-}"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

has_systemd() { [ -d /run/systemd/system ] && has_cmd systemctl; }

PM=""
detect_pm() {
  if   has_cmd apt-get; then PM=apt
  elif has_cmd dnf;     then PM=dnf
  elif has_cmd yum;     then PM=yum
  elif has_cmd apk;     then PM=apk
  elif has_cmd pacman;  then PM=pacman
  elif has_cmd zypper;  then PM=zypper
  else PM=""
  fi
}

APT_UPDATED=0
pkg_install() {
  # 用法：pkg_install 包名...（失败返回非 0，不退出）
  [ -n "$PM" ] || return 1
  case "$PM" in
    apt)
      if [ "$APT_UPDATED" -eq 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; APT_UPDATED=1
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
    dnf)    dnf install -y -q "$@" >/dev/null 2>&1 ;;
    yum)    yum install -y -q "$@" >/dev/null 2>&1 ;;
    apk)    apk add --no-cache -q "$@" >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    zypper) zypper -q -n install "$@" >/dev/null 2>&1 ;;
  esac
}

ensure_deps() {
  detect_pm
  local need=""
  has_cmd curl    || need="$need curl"
  has_cmd openssl || need="$need openssl"
  [ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ] || need="$need ca-certificates"
  if [ -n "$need" ]; then
    info "安装依赖：$need"
    # shellcheck disable=SC2086
    pkg_install $need || die "依赖安装失败，请手动安装：$need"
  fi
  # 可选：二维码（失败不影响部署）
  if ! has_cmd qrencode; then
    case "$PM" in
      apk) pkg_install libqrencode-tools || true ;;
      *)   pkg_install qrencode || true ;;
    esac
  fi
  # 可选：端口检测工具
  has_cmd ss || has_cmd netstat || pkg_install iproute2 || pkg_install iproute || true
}

# ---------------- 环境 ----------------
port_in_use() {
  if has_cmd ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${1}\$"
  elif has_cmd netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${1}\$"
  else
    return 1
  fi
}

show_port_owner() {
  if has_cmd ss; then ss -ltnp 2>/dev/null | grep -E "[:.]${1}[[:space:]]" || true
  elif has_cmd netstat; then netstat -ltnp 2>/dev/null | grep -E "[:.]${1}[[:space:]]" || true
  fi
}

ipv6_enabled() {
  [ -f /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ]
}

PUBLIC_IP=""
detect_ip() {
  local u ip=""
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me https://ip.sb; do
    ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
    if echo "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then PUBLIC_IP="$ip"; return 0; fi
  done
  for u in https://api6.ipify.org https://ipv6.icanhazip.com https://ifconfig.co; do
    ip=$(curl -6 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
    if echo "$ip" | grep -q ':'; then PUBLIC_IP="$ip"; return 0; fi
  done
  return 1
}

open_firewall() {
  local p="$1"
  if has_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${p}/tcp" >/dev/null 2>&1 && info "ufw 已放行 TCP $p"
  elif has_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && info "firewalld 已放行 TCP $p"
  elif has_cmd iptables && iptables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP'; then
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
    if has_cmd ip6tables && ip6tables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP'; then
      ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT
    fi
    warn "已用 iptables 放行 TCP $p（重启后可能失效，请用你的防火墙持久化工具保存）"
  fi
}

enable_bbr() {
  if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then return 0; fi
  modprobe tcp_bbr >/dev/null 2>&1 || true
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" > /etc/sysctl.d/99-bbr.conf
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 && info "已开启 BBR"
  else
    warn "内核不支持 BBR（OpenVZ/LXC 常见），跳过"
  fi
}

# ---------------- 运行模式：docker / native ----------------
docker_usable() { has_cmd docker && docker info >/dev/null 2>&1; }

COMPOSE=""
detect_compose() {
  if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"
  elif has_cmd docker-compose; then COMPOSE="docker-compose"
  else COMPOSE=""
  fi
}

install_docker() {
  info "安装 Docker（官方脚本 get.docker.com）..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || return 1
  if has_systemd; then systemctl enable --now docker >/dev/null 2>&1 || true
  elif has_cmd rc-update; then rc-update add docker default >/dev/null 2>&1; service docker start >/dev/null 2>&1 || true
  fi
  docker_usable
}

DEPLOY_MODE=""
choose_mode() {
  case "$MODE" in
    docker)
      docker_usable || install_docker || die "Docker 不可用且安装失败，可改用：MODE=native"
      DEPLOY_MODE=docker ;;
    native)
      has_systemd || die "原生模式需要 systemd，本机没有；可改用：MODE=docker"
      DEPLOY_MODE=native ;;
    auto)
      if docker_usable; then DEPLOY_MODE=docker
      elif has_systemd; then DEPLOY_MODE=native
      elif install_docker; then DEPLOY_MODE=docker
      else die "既没有 systemd 也无法安装 Docker，无法部署"
      fi ;;
    *) die "MODE 只能是 auto / docker / native" ;;
  esac
  info "部署模式：$DEPLOY_MODE"
}

# 已安装时识别模式（兼容 1.x 版本生成的 client.env）
load_mode() {
  DEPLOY_MODE=""
  if [ -f "$ENVF" ]; then DEPLOY_MODE=$(grep -E '^DEPLOY_MODE=' "$ENVF" | cut -d= -f2); fi
  if [ -z "$DEPLOY_MODE" ]; then
    if has_cmd docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx xray; then DEPLOY_MODE=docker
    elif [ -x "$NATIVE_BIN" ]; then DEPLOY_MODE=native
    fi
  fi
}

xray_run() {
  # 在当前模式下执行 xray 子命令，例如：xray_run x25519
  if [ "$DEPLOY_MODE" = docker ]; then
    docker run --rm -v "$DIR:/data:ro" --entrypoint sh "$IMG" -c "cd /data && xray $*"
  else
    (cd "$DIR" && "$NATIVE_BIN" "$@")
  fi
}

prepare_runtime() {
  if [ "$DEPLOY_MODE" = docker ]; then
    info "拉取镜像 $IMG ..."
    docker pull -q "$IMG" >/dev/null || die "镜像拉取失败"
  else
    if [ ! -x "$NATIVE_BIN" ]; then
      info "安装 Xray（官方 Xray-install 脚本）..."
      bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ install >/dev/null 2>&1 || die "Xray 安装失败"
    fi
  fi
}

start_service() {
  if [ "$DEPLOY_MODE" = docker ]; then
    detect_compose
    if [ -n "$COMPOSE" ]; then
      cat > "$DIR/docker-compose.yml" <<'EOF'
services:
  xray:
    image: teddysun/xray
    container_name: xray
    restart: unless-stopped
    network_mode: host
    entrypoint: ["sh", "-c"]
    command: ["exec xray run -c /etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
EOF
      (cd "$DIR" && $COMPOSE up -d --force-recreate >/dev/null 2>&1)
    else
      docker rm -f xray >/dev/null 2>&1 || true
      docker run -d --name xray --restart unless-stopped --network host \
        -v "$CONF:/etc/xray/config.json:ro" --entrypoint sh "$IMG" \
        -c 'exec xray run -c /etc/xray/config.json' >/dev/null
    fi
  else
    mkdir -p "$(dirname "$NATIVE_CONF")"
    ln -sf "$CONF" "$NATIVE_CONF"
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray
  fi
}

service_running() {
  if [ "$DEPLOY_MODE" = docker ]; then
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx xray
  else
    systemctl is-active --quiet xray
  fi
}

show_logs() {
  if [ "$DEPLOY_MODE" = docker ]; then docker logs xray --tail "${1:-30}" 2>&1
  else journalctl -u xray -n "${1:-30}" --no-pager 2>/dev/null
  fi
}

# ---------------- 配置 ----------------
gen_keys() {
  local out
  out=$(xray_run x25519 2>/dev/null)
  PRIV=$(echo "$out" | awk -F': *' '/Private/{print $2}' | head -1 | tr -d ' \r')
  PUB=$(echo "$out"  | awk -F': *' '/Public|Password/{print $2}' | head -1 | tr -d ' \r')
  [ -n "$PRIV" ] && [ -n "$PUB" ] || die "Reality 密钥生成失败：$out"
  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || xray_run uuid)
  SID=$(openssl rand -hex 8)
}

write_config() {
  local listen="0.0.0.0" routing=""
  ipv6_enabled && listen="::"
  if [ "$BLOCK_CN" = "1" ]; then
    routing=',
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:cn", "geoip:private"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "block" }
    ]
  }'
  fi
  cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "${listen}",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SNI}:443",
        "xver": 0,
        "serverNames": ["${SNI}"],
        "privateKey": "${PRIV}",
        "shortIds": ["${SID}"],
        "minClientVer": "1.8.2"
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]${routing}
}
EOF
  # 原生模式下 xray 以非 root 用户运行，需要可读
  if [ "$DEPLOY_MODE" = native ]; then chmod 644 "$CONF"; else chmod 600 "$CONF"; fi
}

test_config() {
  if [ "$DEPLOY_MODE" = docker ]; then
    docker run --rm -v "$CONF:/c.json:ro" --entrypoint sh "$IMG" -c 'xray run -test -c /c.json' >/dev/null 2>&1
  else
    "$NATIVE_BIN" run -test -c "$CONF" >/dev/null 2>&1
  fi
}

save_env() {
  cat > "$ENVF" <<EOF
UUID=${UUID}
PUB=${PUB}
SID=${SID}
IP=${PUBLIC_IP}
PORT=${PORT}
SNI=${SNI}
NAME=${NAME}
DEPLOY_MODE=${DEPLOY_MODE}
BLOCK_CN=${BLOCK_CN}
VERSION=${VERSION}
EOF
  chmod 600 "$ENVF"
}

# ---------------- 客户端信息 ----------------
show_info() {
  [ -f "$ENVF" ] || die "未找到 $ENVF，请先安装"
  # shellcheck disable=SC1090
  . "$ENVF"
  local host="$IP"
  case "$IP" in *:*) host="[$IP]" ;; esac
  local link="vless://${UUID}@${host}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp#${NAME}"
  echo "$link" > "$DIR/client-link.txt"

  cat > "$DIR/egern-proxy.yaml" <<EOF
proxies:
  - vless:
      name: ${NAME}
      server: ${IP}
      port: ${PORT}
      user_id: ${UUID}
      flow: xtls-rprx-vision
      udp_relay: true
      transport:
        tls:
          sni: ${SNI}
          reality:
            public_key: "${PUB}"
            short_id: "${SID}"
EOF

  cat > "$DIR/mihomo-proxy.yaml" <<EOF
proxies:
  - name: ${NAME}
    type: vless
    server: ${IP}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUB}
      short-id: "${SID}"
      support-x25519mlkem768: true
EOF
  chmod 600 "$DIR/client-link.txt" "$DIR/egern-proxy.yaml" "$DIR/mihomo-proxy.yaml"

  echo
  hr
  echo " 地址   : $IP"
  echo " 端口   : $PORT"
  echo " UUID   : $UUID"
  echo " 公钥   : $PUB"
  echo " ShortID: $SID"
  echo " SNI    : $SNI      指纹: chrome      Flow: xtls-rprx-vision"
  echo " 模式   : ${DEPLOY_MODE:-?}      拒绝国内流量: ${BLOCK_CN:-0}"
  hr
  echo "${C_G}导入链接（Shadowrocket / v2rayN / sing-box 等）：${C_0}"
  echo "$link"
  if has_cmd qrencode; then echo; qrencode -t ansiutf8 "$link"; fi
  hr
  echo "${C_G}Egern 节点配置（$DIR/egern-proxy.yaml）：${C_0}"
  cat "$DIR/egern-proxy.yaml"
  hr
  echo "${C_G}Clash Verge / mihomo 节点配置（$DIR/mihomo-proxy.yaml）：${C_0}"
  cat "$DIR/mihomo-proxy.yaml"
  hr
  echo "以后再看这些信息：bash <(curl -fsSL https://raw.githubusercontent.com/laihaibin08/xray-reality-deploy/main/deploy-xray.sh) info"
}

# ---------------- 子命令 ----------------
cmd_install() {
  need_root install
  mkdir -p "$DIR"

  if [ -f "$ENVF" ] && [ "$FORCE" != "1" ]; then
    load_mode
    warn "检测到已有部署，直接显示客户端信息（重新生成密钥请加 FORCE=1）"
    service_running || start_service
    show_info
    return 0
  fi

  info "Xray Reality 部署脚本 v$VERSION"
  ensure_deps
  choose_mode

  # 端口检查（重装时允许自己的旧进程占用）
  if port_in_use "$PORT"; then
    if ! { [ -f "$ENVF" ] && service_running 2>/dev/null; }; then
      err "端口 $PORT 已被占用："
      show_port_owner "$PORT"
      die "请换端口重试，例如：PORT=8443 bash $0"
    fi
  fi

  info "检测公网 IP ..."
  detect_ip || die "获取公网 IP 失败"
  info "公网 IP：$PUBLIC_IP"

  info "检测伪装站点 $SNI ..."
  if ! curl -fsSI --tlsv1.3 --max-time 8 "https://$SNI" >/dev/null 2>&1; then
    warn "从本机访问 $SNI 的 TLS1.3 失败，建议换 SNI（如 SNI=www.apple.com）"
  fi

  prepare_runtime
  gen_keys
  write_config
  if ! test_config; then
    if [ "$BLOCK_CN" = "1" ]; then
      warn "配置校验失败，可能缺少地理数据文件，关闭 BLOCK_CN 后重试"
      BLOCK_CN=0; write_config
      test_config || die "配置校验失败"
    else
      die "配置校验失败"
    fi
  fi
  save_env

  enable_bbr
  open_firewall "$PORT"

  info "启动服务 ..."
  start_service
  sleep 3
  if service_running; then
    info "Xray 运行中"
  else
    err "服务未运行，最近日志："
    show_logs 30
    exit 1
  fi

  show_info
  warn "如果 VPS 厂商后台有安全组 / 防火墙面板，请在面板里也放行 TCP $PORT"
}

cmd_info()    { need_root info; load_mode; show_info; }

cmd_update() {
  need_root update; load_mode
  [ -n "$DEPLOY_MODE" ] || die "未检测到已安装的 Xray"
  if [ "$DEPLOY_MODE" = docker ]; then
    docker pull -q "$IMG" >/dev/null && start_service
  else
    bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ install >/dev/null 2>&1 && start_service
  fi
  sleep 2
  service_running && info "已更新并重启" || { err "更新后未运行"; show_logs 30; exit 1; }
}

cmd_restart() {
  need_root restart; load_mode
  [ -n "$DEPLOY_MODE" ] || die "未检测到已安装的 Xray"
  start_service; sleep 2
  service_running && info "已重启" || { err "重启后未运行"; show_logs 30; exit 1; }
}

cmd_status() {
  need_root status; load_mode
  [ -n "$DEPLOY_MODE" ] || die "未检测到已安装的 Xray"
  echo "模式：$DEPLOY_MODE"
  if service_running; then info "运行中"; else err "未运行"; fi
  [ -f "$ENVF" ] && port_in_use "$(grep -E '^PORT=' "$ENVF" | cut -d= -f2)" && info "端口监听正常"
}

cmd_logs() { need_root logs; load_mode; show_logs "${1:-50}"; }

cmd_uninstall() {
  need_root uninstall; load_mode
  if [ "$YES" != "1" ]; then
    read -r -p "确定卸载 Xray 并删除 $DIR？[y/N] " ans
    case "$ans" in y|Y|yes) ;; *) echo "已取消"; return 0 ;; esac
  fi
  if [ "$DEPLOY_MODE" = docker ]; then
    docker rm -f xray >/dev/null 2>&1 || true
  elif [ "$DEPLOY_MODE" = native ]; then
    bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ remove >/dev/null 2>&1 || true
    rm -f "$NATIVE_CONF"
  fi
  rm -rf "$DIR"
  info "已卸载"
}

usage() {
  cat <<EOF
Xray VLESS + Reality 部署脚本 v$VERSION

用法：bash deploy-xray.sh [子命令]
  install     安装（默认）。已安装时只显示客户端信息
  info        显示导入链接、二维码、Egern / mihomo 节点配置
  update      更新 Xray 内核，保留配置和密钥
  restart     重启
  status      查看运行状态
  logs [N]    查看最近 N 行日志
  uninstall   卸载
  help        显示本帮助

环境变量（放在命令前）：
  PORT=443               监听端口
  SNI=www.microsoft.com  伪装站点
  NAME=VPS-Reality       节点名称
  MODE=auto              auto | docker | native
  BLOCK_CN=0             1 = 服务器拒绝转发发往中国大陆的流量
  FORCE=1                重新生成密钥并重装
  YES=1                  卸载时不确认

示例：
  PORT=8443 NAME=OVH_Reality bash deploy-xray.sh
  SNI=www.apple.com FORCE=1 bash deploy-xray.sh
EOF
}

main() {
  local cmd="${1:-install}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    install)   cmd_install ;;
    info)      cmd_info ;;
    update)    cmd_update ;;
    restart)   cmd_restart ;;
    status)    cmd_status ;;
    logs)      cmd_logs "$@" ;;
    uninstall) cmd_uninstall ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
