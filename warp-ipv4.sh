#!/bin/bash
set -e

# ======== 彩色输出 ===========
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

WG_BIN="/usr/local/bin/warp-go"
CONF="/etc/warp/warp.conf"
# =====================================================
# =============== 通用功能：start/stop/status =========
# =====================================================

SERVICE_NAME="warp-go"

warp_status() {
    echo "========================"
    echo "🌍 WARP IP 信息"
    echo "========================"
    echo ""
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
    echo "🛑 停止 WARP 服务..."
    if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl stop $SERVICE_NAME
    elif [ -f /etc/init.d/$SERVICE_NAME ]; then
        rc-service $SERVICE_NAME stop
    fi
    pkill -f warp-go 2>/dev/null || true
    echo "✔ 已停止"
}

warp_start() {
    echo "🚀 启动 WARP 服务..."
    if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl start $SERVICE_NAME
    elif [ -f /etc/init.d/$SERVICE_NAME ]; then
        rc-service $SERVICE_NAME start
    fi
    echo "✔ 已启动"
}

warp_restart() {
    echo "🔄 重启 WARP 服务..."
    if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl restart $SERVICE_NAME
    elif [ -f /etc/init.d/$SERVICE_NAME ]; then
        rc-service $SERVICE_NAME restart
    fi
    echo "✔ 已重启"
}

# ========== 处理命令行参数（install / status / start / stop / restart / uninstall） ==========

case "$1" in
    status)
        warp_status
        exit 0
    ;;
    stop)
        warp_stop
        exit 0
    ;;
    start)
        warp_start
        exit 0
    ;;
    restart)
        warp_restart
        exit 0
    ;;
    uninstall)
        # 卸载逻辑保留，原来部分继续向下执行
    ;;
    ""|install)
        yellow "开始安装 WARP..."
    ;;
    *)
        red "未知命令：$1"
        echo "可用命令：install / uninstall / status / start / stop / restart"
        exit 1
    ;;
esac
# =====================================================
# ===============  卸载功能（可选）  ==================
# =====================================================
if [ "$1" = "uninstall" ]; then
    yellow "🛑 正在卸载 warp-go..."

    if systemctl list-unit-files | grep -q warp-go; then
        systemctl stop warp-go 2>/dev/null || true
        systemctl disable warp-go 2>/dev/null || true
        rm -f /etc/systemd/system/warp-go.service
        systemctl daemon-reload
    fi

    if [ -f /etc/init.d/warp-go ]; then
        rc-service warp-go stop || true
        rc-update del warp-go default || true
        rm -f /etc/init.d/warp-go
    fi

    pkill -f warp-go 2>/dev/null || true

    rm -rf /etc/warp
    rm -f "$WG_BIN"

    green "✅ warp-go 已完全卸载"
    exit 0
fi


# =====================================================
# ============ 脚本开头加入安全卸载逻辑 ==============
# =====================================================

yellow "🧹 清理旧 warp-go 进程（防 Text file busy）..."

# 停止旧 systemd 服务
if systemctl list-unit-files | grep -q warp-go; then
    systemctl stop warp-go 2>/dev/null || true
fi

# 停止旧 openrc 服务
if [ -f /etc/init.d/warp-go ]; then
    rc-service warp-go stop 2>/dev/null || true
fi

# 杀死所有 warp-go 进程
pkill -f warp-go 2>/dev/null || true
sleep 1

# 删除旧二进制
rm -f "$WG_BIN" 2>/dev/null || true


# =====================================================
# ===============  系统检测 ===========================
# =====================================================

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

# =====================================================
# =============== 下载 warp-go ========================
# =====================================================

ARCH="amd64"

yellow "⬇️ 下载 warp-go ..."
wget -O "$WG_BIN" https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${ARCH}
chmod +x "$WG_BIN"

# =====================================================
# =============== warpapi 申请账户 ====================
# =====================================================

yellow "🔑 正在申请 WARP 普通账户..."

API_BIN="./warpapi"
wget -O "$API_BIN" https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/amd64
chmod +x "$API_BIN"

output=$($API_BIN)
private_key=$(echo "$output" | awk -F': ' '/private_key/{print $2}')
device_id=$(echo "$output" | awk -F': ' '/device_id/{print $2}')
warp_token=$(echo "$output" | awk -F': ' '/token/{print $2}')
rm -f $API_BIN

mkdir -p /etc/warp

# =====================================================
# ========== 检测 IPv6-only，自动选择端点 ============
# =====================================================

yellow "🌐 检测网络环境..."

if ping6 -c1 2606:4700:4700::1111 >/dev/null 2>&1; then
    IPv6=1
    yellow "✔ 检测到 IPv6 可用"
else
    IPv6=0
    yellow "⚠ 未检测到 IPv6"
fi

if [ "$IPv6" = "1" ]; then
    ENDPOINT="[2606:4700:d0::a29f:c005]:2408"
else
    ENDPOINT="162.159.192.1:2408"
fi

yellow "使用端点：$ENDPOINT"

# =====================================================
# =============== 生成 warp.conf ======================
# =====================================================

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
Endpoint = $ENDPOINT
AllowedIPs = 0.0.0.0/0
KeepAlive = 30
EOF


# =====================================================
# ===============  创建并启动服务  ====================
# =====================================================

if [ "$SYSTEMD" = "1" ]; then
    yellow "🛠 创建 systemd 服务..."

    cat > /etc/systemd/system/warp-go.service <<EOF
[Unit]
Description=warp-go service
After=network.target

[Service]
ExecStart=${WG_BIN} --config=${CONF}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-go
    systemctl restart warp-go

else
    yellow "🛠 创建 OpenRC 服务..."

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

# =====================================================
# =============== 输出结果 ============================
# =====================================================

ipv4=$(curl -4s https://ip.gs || true)

if [ -n "$ipv4" ]; then
    green "================================="
    green " 🎉 WARP IPv4 获取成功：$ipv4"
    green "================================="
else
    red "❌ 未能获取 WARP IPv4，请查看日志："
    red "journalctl -u warp-go -n 50"
fi
