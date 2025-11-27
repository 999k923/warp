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
# =============== 通用功能：start/stop/status =========
# =====================================================

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

# =====================================================
# ========== 处理命令行参数（install / status / start / stop / restart / uninstall） ==========
# =====================================================

case "$1" in
    status) warp_status; exit 0 ;;
    stop) warp_stop; exit 0 ;;
    start) warp_start; exit 0 ;;
    restart) warp_restart; exit 0 ;;
    uninstall) ;; # 卸载逻辑下方执行
    ""|install) yellow "开始安装 WARP..." ;;
    *) red "未知命令：$1"; echo "可用命令：install / uninstall / status / start / stop / restart"; exit 1 ;;
esac

# =====================================================
# =============== 卸载功能 ===========================
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
# ============ 安全卸载旧版本 ========================
# =====================================================
yellow "🧹 清理旧 warp-go 进程..."
if systemctl list-unit-files | grep -q warp-go; then systemctl stop warp-go 2>/dev/null || true; fi
if [ -f /etc/init.d/warp-go ]; then rc-service warp-go stop 2>/dev/null || true; fi
pkill -f warp-go 2>/dev/null || true
rm -f "$WG_BIN" 2>/dev/null || true

# =====================================================
# =============== 系统检测 ===========================
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
# ========== 检测网络环境 / 选择端点 =================
# =====================================================
yellow "🌐 检测网络环境..."
if ping6 -c1 2606:4700:4700::1111 >/dev/null 2>&1; then
    IPv6=1
    yellow "✔ IPv6 可用"
else
    IPv6=0
    yellow "⚠ 未检测到 IPv6"
fi

# IPv4 检测
if ping -c1 1.1.1.1 >/dev/null 2>&1; then
    IPv4=1
    yellow "✔ IPv4 可用"
else
    IPv4=0
    yellow "⚠ 未检测到 IPv4"
fi

# 选择端点
if [ "$IPv6" = "1" ]; then
    ENDPOINT="[2606:4700:d0::a29f:c005]:2408"
elif [ "$IPv4" = "1" ]; then
    ENDPOINT="162.159.192.1:2408"
else
    red "❌ 未检测到可用网络"
    exit 1
fi
yellow "使用端点：$ENDPOINT"

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
Endpoint = $ENDPOINT
AllowedIPs = 0.0.0.0/0, ::/0
KeepAlive = 30
EOF

# =====================================================
# =============== 创建并启动服务 =====================
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
pidfile="/var/run/warp-go.pid"
EOF
    chmod +x $SERVICE_FILE
    rc-update add warp-go default
    rc-service warp-go restart
fi

# =====================================================
# =============== 等待 IPv4/IPv6 获取 =================
# =====================================================
yellow "⏳ 等待 WARP IP..."
for i in {1..15}; do
    ipv4=$(curl -4s https://ip.gs || true)
    ipv6=$(curl -6s https://ip.gs || true)
    if [ -n "$ipv4" ] || [ -n "$ipv6" ]; then break; fi
    sleep 1
done

# 输出结果
if [ -n "$ipv4" ]; then green "✅ WARP IPv4：$ipv4"; fi
if [ -n "$ipv6" ]; then green "✅ WARP IPv6：$ipv6"; fi
if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
    red "❌ 未获取到 WARP IP，请查看日志"
fi
# =====================================================
# =============== 简易管理菜单 =======================
# =====================================================
show_menu() {
    echo ""
    echo "=============================="
    echo "    WARP 管理菜单"
    echo "=============================="
    echo "1) 查看 WARP IP"
    echo "2) 启动 WARP"
    echo "3) 停止 WARP"
    echo "4) 重启 WARP"
    echo "5) 卸载 WARP"
    echo "0) 退出"
    echo "=============================="
    read -rp "请选择操作 [0-5]: " choice
    case "$choice" in
        1) warp_status ;;
        2) warp_start ;;
        3) warp_stop ;;
        4) warp_restart ;;
        5) bash "$0" uninstall ;;
        0) exit 0 ;;
        *) red "无效选项"; show_menu ;;
    esac
}

# 如果未带参数就显示菜单
if [ -z "$1" ]; then
    while true; do
        show_menu
    done
fi
