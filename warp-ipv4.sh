#!/bin/bash
set -e

# ======== 彩色输出 ===========
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

WG_BIN="/usr/local/bin/warp-go"
CONF="/etc/warp/warp.conf"

SERVICE_NAME="warp-go"

# =====================================================
# =============== 状态 / 控制 =========================
# =====================================================

warp_status() {
    echo "========================"
    echo "🌍 WARP IP 信息"
    echo "========================"
    echo "🔸 IPv4:"
    curl -4s https://ip.gs || echo "未获取 IPv4"
    echo ""
    echo "🔸 IPv6:"
    curl -6s https://ip.gs || echo "未获取 IPv6"
    echo ""
    echo "🔸 Cloudflare trace:"
    curl -s https://www.cloudflare.com/cdn-cgi/trace || echo "trace 获取失败"
    echo ""
}

warp_stop() {
    if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl stop $SERVICE_NAME
    elif [ -f /etc/init.d/$SERVICE_NAME ]; then
        rc-service $SERVICE_NAME stop
    fi
    pkill -f warp-go 2>/dev/null || true
}

warp_start() {
    if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl start $SERVICE_NAME
    elif [ -f /etc/init.d/$SERVICE_NAME ]; then
        rc-service $SERVICE_NAME start
    fi
}

warp_restart() {
    if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl restart $SERVICE_NAME
    elif [ -f /etc/init.d/$SERVICE_NAME ]; then
        rc-service $SERVICE_NAME restart
    fi
}

# =====================================================
# =============== IPv4 Watchdog（★ 修改重点） =========
# =====================================================
warp_ipv4_watchdog() {
    LOG="/var/log/warp-ipv4-watch.log"
    SERVICE="warp-go"

    ipv4=$(curl -4s --max-time 6 https://ip.gs)

    # ★ 修改 1：获取不到 IPv4
    if [ -z "$ipv4" ]; then
        echo "$(date '+%F %T') IPv4 获取失败，重启 warp-go" >> "$LOG"
        warp_restart
        return
    fi

    # ★ 修改 2：不是 WARP IPv4（104.28.*）
    if [[ "$ipv4" =~ ^104\.28\. ]]; then
        echo "$(date '+%F %T') WARP IPv4 正常：$ipv4" >> "$LOG"
    else
        echo "$(date '+%F %T') 非 WARP IPv4：$ipv4，重启 warp-go" >> "$LOG"
        warp_restart
    fi
}

# =====================================================
# =============== 参数处理 =============================
# =====================================================
case "$1" in
    status) warp_status; exit 0 ;;
    check-ipv4) warp_ipv4_watchdog; exit 0 ;;
    stop) warp_stop; exit 0 ;;
    start) warp_start; exit 0 ;;
    restart) warp_restart; exit 0 ;;
    uninstall) ;;
    ""|install) yellow "开始安装 WARP..." ;;
    *) red "未知命令：$1"; exit 1 ;;
esac

# =====================================================
# =============== 清理旧进程 ==========================
# =====================================================
pkill -f warp-go 2>/dev/null || true
rm -f "$WG_BIN" 2>/dev/null || true

# =====================================================
# =============== 系统检测 ===========================
# =====================================================
. /etc/os-release
SYS=$ID

case "$SYS" in
    alpine)
        apk add --no-cache bash curl wget iproute2 wireguard-tools openrc
        SYSTEMD=0
    ;;
    ubuntu|debian)
        apt-get update
        apt-get install -y curl wget iproute2 wireguard-tools
        SYSTEMD=1
    ;;
    *) red "不支持的系统"; exit 1 ;;
esac

# =====================================================
# =============== 下载 warp-go ========================
# =====================================================
wget -O "$WG_BIN" https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_amd64
chmod +x "$WG_BIN"

# =====================================================
# =============== 申请账户 ============================
# =====================================================
wget -O warpapi https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/amd64
chmod +x warpapi
output=$(./warpapi)
rm -f warpapi

private_key=$(echo "$output" | awk -F': ' '/private_key/{print $2}')
device_id=$(echo "$output" | awk -F': ' '/device_id/{print $2}')
warp_token=$(echo "$output" | awk -F': ' '/token/{print $2}')

mkdir -p /etc/warp

# =====================================================
# =============== 生成 warp.conf ======================
# =====================================================
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
Table = off        # ★ 修改 3：不抢系统默认路由
KeepAlive = 25
EOF

# =====================================================
# =============== 创建服务 ============================
# =====================================================
if [ "$SYSTEMD" = "1" ]; then
cat > /etc/systemd/system/warp-go.service <<EOF
[Unit]
Description=warp-go
After=network.target

[Service]
ExecStart=$WG_BIN --config=$CONF
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-go
    systemctl restart warp-go
else
cat > /etc/init.d/warp-go <<EOF
#!/sbin/openrc-run
command="$WG_BIN"
command_args="--config=$CONF"
command_background="yes"
EOF
    chmod +x /etc/init.d/warp-go
    rc-update add warp-go default
    rc-service warp-go restart
fi

# =====================================================
# =============== 安装 cron ===========================
# =====================================================
SCRIPT_PATH=$(realpath "$0")
CRON_CMD="*/2 * * * * bash $SCRIPT_PATH check-ipv4"

(crontab -l 2>/dev/null | grep -q check-ipv4) || \
(crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -

green "✅ WARP 安装完成（TUN 出站 + 正确 IPv4 检测）"
