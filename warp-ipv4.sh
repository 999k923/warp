#!/bin/bash
set -e

# ======== 颜色 ===========
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

# ======== 检测系统 ===========
if [ -f /etc/os-release ]; then
    . /etc/os-release
    SYS=$ID
else
    red "无法识别系统"
    exit 1
fi

yellow "检测到系统：$SYS"

# ======== 安装依赖 ===========

case "$SYS" in
    alpine)
        apk update
        apk add --no-cache bash curl wget iproute2 wireguard-tools openrc
        SYSTEMD=0
    ;;
    ubuntu|debian)
        apt-get update
        apt-get install -y curl wget iproute2 wireguard-tools
        SYSTEMD=1
    ;;
    *)
        red "不支持的系统：$SYS"
        exit 1
    ;;
esac

# ======== 下载 warp-go ===========
ARCH="amd64"
WG_BIN="/usr/local/bin/warp-go"

yellow "下载 warp-go ..."
wget -O "$WG_BIN" https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${ARCH}
chmod +x "$WG_BIN"

# ======== 使用你原脚本的 warpapi 生成配置 ===========
yellow "申请 WARP 普通账户..."

API_BIN="./warpapi"
wget -O "$API_BIN" https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/amd64
chmod +x "$API_BIN"

output=$($API_BIN)
private_key=$(echo "$output" | awk -F': ' '/private_key/{print $2}')
device_id=$(echo "$output" | awk -F': ' '/device_id/{print $2}')
warp_token=$(echo "$output" | awk -F': ' '/token/{print $2}')
rm -f $API_BIN

mkdir -p /etc/warp
CONF="/etc/warp/warp.conf"

# ======== 生成配置（与你原脚本保持一致）===========
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

# ======== 创建服务（systemd + openrc 双支持）===========

if [ "$SYSTEMD" = "1" ]; then
    # systemd
    yellow "创建 systemd warp-go 服务..."

    cat > /etc/systemd/system/warp-go.service <<EOF
[Unit]
Description=warp-go service
After=network.target

[Service]
ExecStart=${WG_BIN} --config=${CONF}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-go
    systemctl restart warp-go

else
    # openrc
    yellow "创建 OpenRC warp-go 服务..."

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
    rc-service warp-go restart
fi

sleep 2

# ======== 输出 IPv4 ===========
ipv4=$(curl -4s https://ip.gs || true)

if [ -n "$ipv4" ]; then
    green "================================="
    green " 🎉 WARP IPv4 获取成功：$ipv4"
    green "================================="
else
    red "❌ WARP IPv4 获取失败"
fi
