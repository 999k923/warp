#!/bin/sh
# WARP IPv4 获取脚本（兼容 Alpine / Debian / Ubuntu）
# 出站走 WARP，入站保留原生 IP。不等待 wg，不卡死。

set -e

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

log(){ echo -e "${GREEN}$1${RESET}"; }
err(){ echo -e "${RED}$1${RESET}"; }

OS=""
if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif [ -f /etc/debian_version ]; then
    OS="debian"
else
    OS="ubuntu"
fi

log "系统：$OS"

install_deps(){
    if [ "$OS" = "alpine" ]; then
        log "安装依赖 (Alpine)"
        apk update
        apk add iproute2 wireguard-tools curl wget openrc
    else
        log "安装依赖 (Debian/Ubuntu)"
        apt update
        apt install -y iproute2 wireguard-tools curl wget
    fi
}

install_deps

mkdir -p /etc/warp
cd /etc/warp

log "下载 warp-go..."
wget -O warp-go https://gitlab.com/ProjectWARP/warp-go/-/raw/main/warp-go
chmod +x warp-go

log "申请 WARP 账户..."
/etc/warp/warp-go --register >/etc/warp/account 2>/dev/null

PRIVKEY=$(grep PrivateKey /etc/warp/account | awk -F'= ' '{print $2}')
PUBKEY=$(grep ClientPublicKey /etc/warp/account | awk -F'= ' '{print $2}')

IP4=$(curl -4 -s --max-time 2 ifconfig.co || echo "")
IP6=$(curl -6 -s --max-time 2 ifconfig.co || echo "")

if [ -n "$IP4" ]; then
    log "检测到 IPv4-only 或双栈"
else
    log "检测到 IPv6-only (将强制走 WARP IPv4)"
fi

ETH=$(ip route show default | awk '/default/ {print $5}' | head -n1)
GW=$(ip route show default | awk '/default/ {print $3}' | head -n1)

log "网卡: $ETH  网关: $GW"

# 写入 warp.conf
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

TABLE_FILE="/etc/iproute2/rt_tables"
if [ ! -f $TABLE_FILE ]; then
    echo "200 warp_main" >$TABLE_FILE
else
    grep -q "warp_main" $TABLE_FILE || echo "200 warp_main" >>$TABLE_FILE
fi

if [ -n "$IP4" ]; then
    log "添加 policy routing"
    ip rule add from "$IP4" lookup warp_main 2>/dev/null || true
fi

ip route add default via "$GW" dev "$ETH" table warp_main 2>/dev/null || true

if [ "$OS" = "alpine" ]; then
    log "创建 OpenRC 服务..."
    cat >/etc/init.d/warp-go <<EOF
#!/sbin/openrc-run
command="/etc/warp/warp-go"
command_background="yes"
pidfile="/var/run/warp-go.pid"
EOF
    chmod +x /etc/init.d/warp-go
    rc-update add warp-go default
    rc-service warp-go restart || true
else
    log "创建 systemd 服务..."
    cat >/etc/systemd/system/warp-go.service <<EOF
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

sleep 2

WARP_IP=$(curl -4 --interface 172.16.0.2 --max-time 2 ifconfig.co || echo "WARP 未上线")
log "WARP IPv4：$WARP_IP"

log "完成！"
