#!/bin/sh

set -e

# ======== 颜色函数 ===========
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

# ======== 系统检测 ===========
if ! grep -qi "alpine" /etc/os-release; then
    red "❌ 此脚本仅支持 Alpine Linux"
    exit 1
fi

# ======== 安装依赖 ===========
yellow "📦 安装依赖..."
apk update
apk add --no-cache bash curl wget iproute2 wireguard-tools openrc

# ======== 安装 warp-go ==========

ARCH="amd64"
WG_BIN="/usr/local/bin/warp-go"

yellow "⬇️ 下载 warp-go ..."
wget -O "$WG_BIN" https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${ARCH}
chmod +x "$WG_BIN"

# ======== 申请 warp 配置（核心逻辑取自你的脚本） ===========
yellow "🔑 正在申请 WARP 普通账户..."

API_BIN="./warpapi"
wget -O $API_BIN --no-check-certificate https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/amd64
chmod +x $API_BIN

output=$($API_BIN)
private_key=$(echo "$output" | awk -F': ' '/private_key/{print $2}')
device_id=$(echo "$output" | awk -F': ' '/device_id/{print $2}')
warp_token=$(echo "$output" | awk -F': ' '/token/{print $2}')
rm -f $API_BIN

mkdir -p /etc/warp
CONF="/etc/warp/warp.conf"

cat > $CONF <<EOF
[Account]
Device = $device_id
PrivateKey = $private_key
Token = $warp_token
Type = free
Name = WARP
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = 162.159.192.1:2408
AllowedIPs = 0.0.0.0/0
KeepAlive = 30
EOF

# ======== MTU 优化（简化为固定 1280，更适合 Alpine）===========
yellow "📐 设置 MTU = 1280 (适配 Alpine，避免 ping -Mdo 问题)"

# ======== 注册 openrc 服务 ===========
SERVICE_FILE="/etc/init.d/warp-go"

cat > $SERVICE_FILE <<EOF
#!/sbin/openrc-run

command="${WG_BIN}"
command_args="--config=${CONF}"
command_background="yes"
pidfile="/var/run/warp-go.pid"
EOF

chmod +x $SERVICE_FILE
rc-update add warp-go default

# ======== 启动服务 ===========
yellow "🚀 启动 warp-go ..."
rc-service warp-go restart

sleep 2

# ======== 获取 IPv4 ===========
ipv4=$(curl -4s https://ip.gs || true)

if [ -n "$ipv4" ]; then
    green "🎉 WARP IPv4 获取成功：$ipv4"
else
    red "❌ 未能从 WARP 获取 IPv4"
fi
