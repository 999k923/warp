#!/bin/bash
set -euo pipefail

# warp-cf-compat-final.sh
# 说明：
# - 优先使用 IPv4 endpoint（保证 IPv4-only 能拿到 WARP IPv4）
# - 若无法使用 IPv4 endpoint（主机无 IPv4 出口），会尝试 IPv6 endpoint
# - 出站走 WARP（AllowedIPs = 0.0.0.0/0, ::/0）
# - 使用策略路由（ip rule + custom table）保证来自 VPS 公网 IP 的流量走原生主路由（SSH 不会断）
# - 兼容 Alpine (OpenRC) 与 Debian/Ubuntu (systemd)
# - 提供 start/stop/restart/status/uninstall 与交互菜单

# ======= 配置 =======
WG_BIN="/usr/local/bin/warp-go"
CONF_DIR="/etc/warp"
CONF="$CONF_DIR/warp.conf"
SERVICE_NAME="warp-go"
ARCH="amd64"
# 优先 IPv4 endpoint（保证 IPv4-only 拿到 WARP IPv4）
WG_URL="https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${ARCH}"
API_URL="https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/amd64"
TMP_API="./warpapi_tmp"
# 路由表号与名字
RT_TABLE_NUM=200
RT_TABLE_NAME="warp_main"

# ======= 颜色 =======
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
info(){ echo -e "\033[36m$1\033[0m"; }

# ======= 权限检查 =======
if [ "$(id -u)" -ne 0 ]; then
    red "请以 root 身份运行脚本"
    exit 1
fi

# ======= 基本操作函数 =======
warp_status() {
    echo "========================"
    echo "🌍 WARP IP 信息"
    echo "========================"
    echo "本机公网 IPv4: $(curl -4s https://ip.gs || echo 'N/A')"
    echo "本机公网 IPv6: $(curl -6s https://ip.gs || echo 'N/A')"
    echo ""
    # 注意：若没有 warp 接口，--interface warp0 会报错；这里使用容错
    if ip link show warp0 >/dev/null 2>&1; then
        echo "WARP (出口) IPv4: $(curl -4s https://ip.gs --interface warp0 2>/dev/null || echo 'N/A')"
        echo "WARP (出口) IPv6: $(curl -6s https://ip.gs --interface warp0 2>/dev/null || echo 'N/A')"
    else
        echo "WARP (出口) IPv4: N/A (warp0 未就绪)"
        echo "WARP (出口) IPv6: N/A (warp0 未就绪)"
    fi
    echo ""
    echo "Cloudflare trace:"
    curl -s https://www.cloudflare.com/cdn-cgi/trace || echo "trace 获取失败"
    echo ""
}

warp_stop() {
    yellow "🛑 停止 warp-go ..."
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl stop $SERVICE_NAME || true
    elif [ -f /etc/init.d/$SERVICE_NAME ]; then
        rc-service $SERVICE_NAME stop || true
    fi
    pkill -f warp-go 2>/dev/null || true
    sleep 1
    green "✔ warp-go stopped"
}

warp_start() {
    yellow "🚀 启动 warp-go ..."
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl start $SERVICE_NAME
    elif [ -f /etc/init.d/$SERVICE_NAME ]; then
        rc-service $SERVICE_NAME start
    fi
    green "✔ warp-go start command issued"
}

warp_restart() {
    yellow "🔄 重启 warp-go ..."
    warp_stop
    warp_start
}

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

# ======= 参数支持 =======
case "${1:-}" in
    status) warp_status; exit 0 ;;
    start) warp_start; exit 0 ;;
    stop) warp_stop; exit 0 ;;
    restart) warp_restart; exit 0 ;;
    uninstall)
        yellow "🛑 卸载中..."
        warp_stop
        # 删除 ip rule (基于 SSH_IPV4 变量，如果存在)
        if [ -n "${SSH_IPV4:-}" ]; then
            ip rule del from "${SSH_IPV4}" lookup ${RT_TABLE_NAME} priority 100 2>/dev/null || true
        fi
        # 删除 route table entry
        ip -4 route flush table ${RT_TABLE_NAME} 2>/dev/null || true
        # 删除 /etc/iproute2/rt_tables 中的行（谨慎）
        if [ -f /etc/iproute2/rt_tables ]; then
            sed -i "/^${RT_TABLE_NUM} ${RT_TABLE_NAME}\$/d" /etc/iproute2/rt_tables || true
        fi
        # 删除服务文件
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
            systemctl disable $SERVICE_NAME 2>/dev/null || true
            rm -f /etc/systemd/system/${SERVICE_NAME}.service
            systemctl daemon-reload || true
        fi
        if [ -f /etc/init.d/$SERVICE_NAME ]; then
            rc-update del $SERVICE_NAME default >/dev/null 2>&1 || true
            rm -f /etc/init.d/$SERVICE_NAME
        fi
        rm -rf "$CONF_DIR"
        rm -f "$WG_BIN"
        green "✅ 已卸载完成"
        exit 0
    ;;
esac

# ======= 清理旧进程和准备目录 =======
yellow "清理旧进程/文件..."
warp_stop || true
rm -f "$WG_BIN" 2>/dev/null || true
mkdir -p "$CONF_DIR"

# ======= 系统识别与依赖安装 =======
if [ -f /etc/os-release ]; then
    . /etc/os-release
    SYS=$ID
else
    red "无法识别系统"
    exit 1
fi
yellow "检测系统：$SYS"

SYSTEMD=1
if [ "$SYS" = "alpine" ]; then
    info "安装依赖 (alpine)"
    apk update
    apk add --no-cache bash curl wget iproute2 wireguard-tools openrc ca-certificates
    SYSTEMD=0
else
    if command -v apt-get >/dev/null 2>&1; then
        info "安装依赖 (debian/ubuntu)"
        apt-get update
        apt-get install -y curl wget iproute2 wireguard-tools ca-certificates
    fi
    SYSTEMD=1
fi

# ======= 下载 warp-go =======
yellow "下载 warp-go 中..."
if ! wget -q -O "$WG_BIN" "$WG_URL"; then
    red "warp-go 下载失败，请检查网络"
    exit 1
fi
chmod +x "$WG_BIN"

# ======= 获取 warpapi 信息（生成私钥等） =======
yellow "申请 WARP 账户..."
if ! wget -q -O "$TMP_API" "$API_URL"; then
    red "warpapi 下载失败"
    exit 1
fi
chmod +x "$TMP_API"
API_OUTPUT=$($TMP_API 2>/dev/null || true)
private_key=$(echo "$API_OUTPUT" | awk -F': ' '/private_key/{print $2}' | tr -d '\r' || true)
device_id=$(echo "$API_OUTPUT" | awk -F': ' '/device_id/{print $2}' | tr -d '\r' || true)
warp_token=$(echo "$API_OUTPUT" | awk -F': ' '/token/{print $2}' | tr -d '\r' || true)
rm -f "$TMP_API"

if [ -z "$private_key" ] || [ -z "$device_id" ] || [ -z "$warp_token" ]; then
    yellow "警告：warpapi 未返回完整信息，继续但可能需要手动配置 warp.conf"
fi

# ======= 检测网络栈 =======
yellow "检测网络环境..."
IPv4=0; IPv6=0
if ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then IPv4=1; yellow "✔ IPv4 可用"; fi
if ping6 -c1 -W1 2606:4700:4700::1111 >/dev/null 2>&1; then IPv6=1; yellow "✔ IPv6 可用"; fi

# ======= 获取 VPS 公网 IP（入站需保留） =======
SSH_IPV4=$(curl -4s https://ip.gs || true)
SSH_IPV6=$(curl -6s https://ip.gs || true)
info "检测到 VPS 公网 IPv4: ${SSH_IPV4:-N/A}, IPv6: ${SSH_IPV6:-N/A}"

# ======= 捕获默认 IPv4 路由信息 (用于策略路由) =======
MAIN_DEV=""
MAIN_GW=""
if ip -4 route show default >/dev/null 2>&1; then
    # 尝试获取网关与设备
    MAIN_GW=$(ip -4 route show default | awk '/default/ {print $3; exit}' || true)
    MAIN_DEV=$(ip -4 route show default | awk '/default/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);break}}; exit}' || true)
    # fallback 使用 ip route get
    if [ -z "$MAIN_GW" ] || [ -z "$MAIN_DEV" ]; then
        ROUTE_OUT=$(ip route get 1.1.1.1 2>/dev/null || true)
        MAIN_GW=$(echo "$ROUTE_OUT" | awk '/via/ {for(i=1;i<=NF;i++){if($i=="via"){print $(i+1);break}}}' || true)
        MAIN_DEV=$(echo "$ROUTE_OUT" | awk '/dev/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);break}}}' || true)
    fi
fi
info "主网卡: ${MAIN_DEV:-N/A}, 网关: ${MAIN_GW:-N/A}"

# ======= 选择 WARP 端点（优先 IPv4 endpoint，保证 IPv4-only 拿到 WARP IPv4） =======
# IPv4 endpoint (Cloudflare warp IPv4 endpoint)
ENDPOINT_IPV4="162.159.192.1:2408"
# IPv6 endpoint (备用)
ENDPOINT_IPV6="[2606:4700:d0::a29f:c005]:2408"

# 首选 IPv4 endpoint；如果主机无法访问 IPv4 endpoint（无 IPv4 出口），则改用 IPv6 endpoint
ENDPOINT="$ENDPOINT_IPV4"
if [ "$IPv4" -eq 0 ] && [ "$IPv6" -eq 1 ]; then
    # 无 IPv4 出口，只能用 IPv6 endpoint
    ENDPOINT="$ENDPOINT_IPV6"
fi
info "使用 WARP endpoint: $ENDPOINT"

# ======= 写 warp.conf（Full-tunnel）并使用 ExcludeRoutes 作为冗余（主力是策略路由） =======
EXCLUDE_LINES=""
[ -n "$SSH_IPV4" ] && EXCLUDE_LINES="${EXCLUDE_LINES}ExcludeRoutes = ${SSH_IPV4}/32\n"
[ -n "$SSH_IPV6" ] && EXCLUDE_LINES="${EXCLUDE_LINES}ExcludeRoutes = ${SSH_IPV6}/128\n"

cat > "$CONF" <<EOF
[Account]
Device = ${device_id}
PrivateKey = ${private_key}
Token = ${warp_token}
Type = free
Name = WARP
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0, ::/0
KeepAlive = 30
${EXCLUDE_LINES}
EOF

green "已写入 warp.conf 到 $CONF"

# ======= 确保 /etc/iproute2/rt_tables 存在并包含自定义表 ======
if [ ! -d /etc/iproute2 ]; then
    mkdir -p /etc/iproute2
fi

if [ ! -f /etc/iproute2/rt_tables ]; then
    cat > /etc/iproute2/rt_tables <<'EOF'
# reserved values
255	local
254	main
253	default
0	unspec
# custom tables
200	warp_main
EOF
    info "已创建 /etc/iproute2/rt_tables 并添加 warp_main"
else
    if ! grep -qE "^[[:space:]]*${RT_TABLE_NUM}[[:space:]]+${RT_TABLE_NAME}" /etc/iproute2/rt_tables; then
        echo "${RT_TABLE_NUM} ${RT_TABLE_NAME}" >> /etc/iproute2/rt_tables
        info "已向 /etc/iproute2/rt_tables 添加 ${RT_TABLE_NUM} ${RT_TABLE_NAME}"
    else
        info "/etc/iproute2/rt_tables 已包含 ${RT_TABLE_NAME}"
    fi
fi

# ======= 在自定义表中添加原主路由（仅在能探测到 MAIN_GW 和 MAIN_DEV 时） =======
if [ -n "$MAIN_GW" ] && [ -n "$MAIN_DEV" ]; then
    ip -4 route flush table ${RT_TABLE_NAME} 2>/dev/null || true
    ip -4 route add default via "$MAIN_GW" dev "$MAIN_DEV" table ${RT_TABLE_NAME} || true
    info "已在路由表 ${RT_TABLE_NAME} 中添加默认路由 via ${MAIN_GW} dev ${MAIN_DEV}"
else
    yellow "未能检测到主网关或主网卡，脚本会继续，但策略路由需要手动设置（见脚本说明）"
fi

# ======= 添加 ip rule: 从 VPS 公网 IP 源走该表，优先级 100 =======
if [ -n "$SSH_IPV4" ]; then
    if ! ip rule show | grep -q "from ${SSH_IPV4} lookup ${RT_TABLE_NAME}"; then
        ip rule add from "${SSH_IPV4}" lookup ${RT_TABLE_NAME} priority 100
        info "已添加 ip rule: from ${SSH_IPV4} lookup ${RT_TABLE_NAME}"
    else
        info "ip rule 已存在: from ${SSH_IPV4} lookup ${RT_TABLE_NAME}"
    fi
fi

# ======= 创建服务 unit（systemd / OpenRC） =======
if [ "$SYSTEMD" -eq 1 ]; then
    yellow "创建 systemd 服务..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<SERVICEUNIT
[Unit]
Description=warp-go service
After=network.target

[Service]
ExecStart=${WG_BIN} --config=${CONF}
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICEUNIT

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}
    systemctl restart ${SERVICE_NAME} || true
else
    yellow "创建 OpenRC 服务..."
    SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
    cat > "$SERVICE_FILE" <<'OPENRC'
#!/sbin/openrc-run
command="/usr/local/bin/warp-go"
command_args="--config=/etc/warp/warp.conf"
command_background="yes"
pidfile="/var/run/warp-go.pid"
OPENRC
    chmod +x "$SERVICE_FILE"
    rc-update add ${SERVICE_NAME} default >/dev/null 2>&1 || true
    rc-service ${SERVICE_NAME} restart || true
fi

# ======= 等待 WARP 生效（最多 30 秒），并判断是否获得 WARP IP（通过比对公网 IP） =======
yellow "⏳ 等待 WARP 生效（最多 30 秒）..."
FOUND_WARP_IPV4=""
FOUND_WARP_IPV6=""
for i in $(seq 1 30); do
    CUR4=$(curl -4s --max-time 5 https://ip.gs || true)
    CUR6=$(curl -6s --max-time 5 https://ip.gs || true)

    # 判定逻辑：若外网 IPv4 变化且与 SSH_IPV4 不同 -> 视为 WARP IPv4
    if [ -n "$CUR4" ] && [ -n "$SSH_IPV4" ] && [ "$CUR4" != "$SSH_IPV4" ]; then
        FOUND_WARP_IPV4="$CUR4"
        green "✅ 检测到 WARP IPv4: $FOUND_WARP_IPV4"
        break
    fi

    # IPv6 判定
    if [ -n "$CUR6" ] && [ -n "$SSH_IPV6" ] && [ "$CUR6" != "$SSH_IPV6" ]; then
        FOUND_WARP_IPV6="$CUR6"
        green "✅ 检测到 WARP IPv6: $FOUND_WARP_IPV6"
        break
    fi

    # 若 VPS 本来没有公网 IPv4（SSH_IPV4 为空），只要 CUR4 非空则视为成功（IPv6-only 情况可能出现）
    if [ -z "$SSH_IPV4" ] && [ -n "$CUR4" ]; then
        FOUND_WARP_IPV4="$CUR4"
        green "✅ 检测到 WARP IPv4: $FOUND_WARP_IPV4"
        break
    fi

    sleep 1
done

if [ -z "$FOUND_WARP_IPV4" ] && [ -z "$FOUND_WARP_IPV6" ]; then
    red "⚠ 未检测到 WARP 分配的公网 IP（超时或失败）。请检查日志："
    if [ "$SYSTEMD" -eq 1 ]; then
        echo "journalctl -u ${SERVICE_NAME} -n 200 --no-pager"
    else
        echo "请查看系统日志（/var/log/messages /var/log/daemon.log），并运行 ps aux | grep warp-go"
    fi
else
    green "👍 WARP 隧道建立成功"
fi

# ======= 若脚本未带参数则进入交互菜单 =======
if [ -z "${1:-}" ]; then
    while true; do show_menu; done
fi
