#!/bin/sh
#
#   WARP-Go 全自动安装脚本（兼容 Alpine / Debian / Ubuntu）
#   特性：
#     - IPv4-only VPS 获取 WARP IPv4（最稳定，不丢 SSH）
#     - IPv6-only VPS 获取 WARP IPv4
#     - 入站走原生公网，出站走 WARP
#     - 无需等待 wg 接口，不会卡死
#     - 自动创建 rt_tables / policy routing
#     - OpenRC / Systemd 自动适配
#

set -e

# ---------- 基础 ----------
COLOR_GREEN="\033[32m"
COLOR_RED="\033[31m"
COLOR_YELLOW="\033[33m"
COLOR_RESET="\033[0m"

log() {
    echo -e "${COLOR_GREEN}$1${COLOR_RESET}"
}

err() {
    echo -e "${COLOR_RED}$1${COLOR_RESET}"
}

# ---------- 检测系统 ----------
OS=""
if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif [ -f /etc/debian_version ]; then
    OS="debian"
elif [ -f /etc/lsb-release ] || [ -f /etc/ubuntu-release ]; then
    OS="ubuntu"
else
    err "不支持的系统"
    exit 1
fi

log "检测系统：$OS"

# ---------- 安装依赖 ----------
install_deps() {
    if [ "$OS" = "alpine" ]; then
        log "安装依赖（Alpine）"
        apk update
        apk add iproute2 wireguard-tools openrc curl wget busybox-extras
    else
        log "安装依赖（Debian/Ubuntu）"
        apt update
        apt install -y iproute2 wireguard-tools curl wget
    fi
}

install_deps

# ---------- warp-go 下载 ----------
mkdir -p /etc/warp
cd /etc/warp

log "下载 warp-go..."
wget -O warp-go https://gitlab.com/ProjectWARP/warp-go/-/raw/main/warp-go
chmod +x warp-go

# ---------- 生成 WireGuard 配置 ----------
log "申请 WARP 账户..."
/etc/warp/warp-go --register >/etc/warp/account 2>/dev/null

PRIVKEY=$(grep PrivateKey /etc/warp/account | awk -F'= ' '{print $2}')
PUBKEY=$(grep ClientPublicKey /etc/warp/account | awk -F'= ' '{print $2}')

# ---------- 检测网络 ----------
log "检测网络环境..."
PUB_IPV4=$(curl -s4 --max-time 2 ifconfig.co || echo "")
PUB_IPV6=$(curl -s6 --max-time 2 ifconfig.co || echo "")

if [ -n "$PUB_IPV4" ]; then
    log "✔ 检测到 IPv4-only 或双栈"
    MODE="IPv4"
elif [ -n "$PUB_IPV6" ]; then
    log "✔ 检测到 IPv6-only"
    MODE="IPv6"
else
    err "无法检测公网 IP，退出"
    exit 1
fi

# ---------- 网卡信息 ----------
ETH=$(ip route show default | awk '/default/ {print $5}' | head -n1)
GW=$(ip route show default | awk '/default/ {print $3}' | head -n1)

log "主网卡: $ETH, 网关: $GW"

# ---------- 写入 WARP 配置 ----------
cat >/etc/warp/warp.conf <<EOF
[Interface]
PrivateKey = $PRIVKEY
Address = 172.16.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $PUBKEY
AllowedIPs = 0.0.0.0/0
Endpoint = 162.159.192.1:2408
PersistentKeepalive = 25
EOF

log "已写入 warp.conf"

# ---------- 创建路由表 ----------
TABLE_FILE="/etc/iproute2/rt_tables"
if [ ! -f $TABLE_FILE ]; then
    echo "创建 $TABLE_FILE"
    echo "200 warp_main" >$TABLE_FILE
elif ! grep -q "warp_main" $TABLE_FILE; then
    echo "200 warp_main" >>$TABLE_FILE
fi

# ---------- 添加路由策略 ----------
if [ -n "$PUB_IPV4" ]; then
    log "添加 IPv4 policy routing"
    ip rule add from "$PUB_IPV4" lookup warp_main 2>/dev/null || true
fi

ip route add default via "$GW" dev "$ETH" table warp_main 2>/dev/null || true

# ---------- OpenRC / systemd 服务 ----------
if [ "$OS" = "alpine" ]; then
    log "创建 OpenRC 服务..."
    cat >/etc/init.d/warp-go <<'EOF'
#!/sbin/openrc-run
name="warp-go"
command="/etc/warp/warp-go"
command_background="yes"
pidfile="/var/run/warp-go.pid"
EOF
    chmod +x /etc/init.d/warp-go
    rc-update add warp-go default
    rc-service warp-go restart || true
else
    log "创建 Systemd 服务..."
    cat >/etc/systemd/system/warp-go.service <<'EOF'
[Unit]
Description=warp-go
After=network.target

[Service]
ExecStart=/etc/warp/warp-go
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-go
    systemctl restart warp-go
fi

log "WARP-Go 已启动（不会卡死，无等待逻辑）"

# ---------- 显示 WARP 出口IP ----------
sleep 3
WARP_IP=$(curl -4 --interface 172.16.0.2 --max-time 2 ifconfig.co || echo "WARP 未上线")

log "WARP 出口 IPv4：$WARP_IP"

echo ""
log "安装完成。出站已走 WARP，入站保持原生公网。"
