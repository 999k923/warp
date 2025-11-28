#!/bin/bash
set -euo pipefail

# warp-cf-compat.sh
# A: 使用策略路由保证入站不被劫持（与CFwarp逻辑一致）
# 兼容: Alpine + Debian/Ubuntu
# 功能: install / start / stop / restart / status / uninstall + 菜单

# ======= 配置 =======
WG_BIN="/usr/local/bin/warp-go"
CONF_DIR="/etc/warp"
CONF="$CONF_DIR/warp.conf"
SERVICE_NAME="warp-go"
ARCH="amd64"
WG_URL="https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${ARCH}"
API_URL="https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/amd64"
TMP_API="./warpapi_tmp"
# 路由表号与名字（可自定义）
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
    echo "WARP (出口) IPv4: $(curl -4s https://ip.gs --interface warp0 2>/dev/null || true)"
    echo "WARP (出口) IPv6: $(curl -6s https://ip.gs --interface warp0 2>/dev/null || true)"
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
        # 删除策略路由
        if ip rule show | grep -q "from ${SSH_IPV4:-} lookup $RT_TABLE_NAME"; then
            ip rule del from "${SSH_IPV4}" lookup $RT_TABLE_NAME || true
        fi
        # 删除 route table entry
        ip -4 route flush table $RT_TABLE_NAME 2>/dev/null || true
        # 删除 /etc/iproute2/rt_tables 中的行（谨慎）
        if grep -q "^${RT_TABLE_NUM} ${RT_TABLE_NAME}\$" /etc/iproute2/rt_tables 2>/dev/null; then
            sed -i "/^${RT_TABLE_NUM} ${RT_TABLE_NAME}\$/d" /etc/iproute2/rt_tables
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

# 如果没有获取到，脚本仍继续（用户可用已有 token）
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
# 仅在有默认路由时捕获
MAIN_DEV=""
MAIN_GW=""
if ip -4 route show default >/dev/null 2>&1; then
    # 取默认路由返回最先匹配
    read -r _ MAIN_GW _ MAIN_DEV _ < <(ip -4 route show default | awk '/default/ {print $3,$5; exit}' )
    # Fallback: try parse differently
    if [ -z "$MAIN_GW" ] || [ -z "$MAIN_DEV" ]; then
        # try ip route get
        ROUTE_OUT=$(ip route get 1.1.1.1 2>/dev/null || true)
        # sample: "1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.2"
        MAIN_GW=$(echo "$ROUTE_OUT" | awk '/via/ {for(i=1;i<=NF;i++){if($i=="via"){print $(i+1);break}}}' || true)
        MAIN_DEV=$(echo "$ROUTE_OUT" | awk '/dev/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);break}}}' || true)
    fi
fi

info "主网卡: ${MAIN_DEV:-N/A}, 网关: ${MAIN_GW:-N/A}"

# ======= 选择 WARP 端点（按 CFwarp 逻辑：优先 IPv4 endpoint，让 IPv4-only 也能拿到 WARP IPv4） =======
# 这里我们默认使用 IPv4 endpoint so IPv4-only 也能获取 WARP IPv4 (与你要求一致)
ENDPOINT="162.159.192.1:2408"
# 若你需要强制 IPv6 endpoint 可调整
info "使用 WARP endpoint: $ENDPOINT"

# ======= 写 warp.conf（Full-tunnel）并使用 ExcludeRoutes 作为冗余（但主力是策略路由） =======
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

# ======= 创建策略路由表 (rt_tables) 与 ip rules，保证来自主公网 IP 的流量走主路由表 =======
# 创建 /etc/iproute2/rt_tables 条目（如果未存在）
if ! grep -qE "^${RT_TABLE_NUM}\s+${RT_TABLE_NAME}\$" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "${RT_TABLE_NUM} ${RT_TABLE_NAME}" >> /etc/iproute2/rt_tables
fi

# 在表里添加默认路由指向之前记录的网关（仅当 MAIN_GW 与 MAIN_DEV 可用）
if [ -n "$MAIN_GW" ] && [ -n "$MAIN_DEV" ]; then
    # 删除旧表的 default（防止重复）
    ip -4 route flush table $RT_TABLE_NAME 2>/dev/null || true
    ip -4 route add default via "$MAIN_GW" dev "$MAIN_DEV" table $RT_TABLE_NAME || true
    info "已在路由表 $RT_TABLE_NAME 中添加默认路由 via $MAIN_GW dev $MAIN_DEV"
fi

# 添加 ip rule: 从 SSH_IPV4 源走该表，优先级设置为 100
if [ -n "$SSH_IPV4" ]; then
    # check exists
    if ! ip rule show | grep -q "from ${SSH_IPV4} lookup ${RT_TABLE_NAME}"; then
        ip rule add from "${SSH_IPV4}" lookup $RT_TABLE_NAME priority 100
        info "已添加 ip rule: from ${SSH_IPV4} lookup ${RT_TABLE_NAME}"
    else
        info "ip rule 已存在: from ${SSH_IPV4} lookup ${RT_TABLE_NAME}"
    fi
fi

# (可选) IPv6 策略：如果有公网 IPv6 与默认路由，添加对应 IPv6 路由表
# 这里为简单起见不做 IPv6 表，若需要可扩展

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

# ======= 等待 WARP 生效（30s），并判断是否确实拿到 WARP IP（对比原 public IP） =======
yellow "⏳ 等待 WARP 生效（最多 30 秒）..."
FOUND_WARP_IPV4=""
FOUND_WARP_IPV6=""
for i in $(seq 1 30); do
    CUR4=$(curl -4s --max-time 5 https://ip.gs || true)
    CUR6=$(curl -6s --max-time 5 https://ip.gs || true)

    # 判定逻辑：如果外网 IPv4 变化且与 SSH_IPV4 不同 -> 视为 WARP IPv4
    if [ -n "$CUR4" ] && [ -n "$SSH_IPV4" ] && [ "$CUR4" != "$SSH_IPV4" ]; then
        FOUND_WARP_IPV4="$CUR4"
        green "✅ 检测到 WARP IPv4: $FOUND_WARP_IPV4"
        break
    fi

    # IPv6 判断（若你期望也拿到 IPv6）
    if [ -n "$CUR6" ] && [ -n "$SSH_IPV6" ] && [ "$CUR6" != "$SSH_IPV6" ]; then
        FOUND_WARP_IPV6="$CUR6"
        green "✅ 检测到 WARP IPv6: $FOUND_WARP_IPV6"
        break
    fi

    # 若 VPS 本来没有公网 IPv4（SSH_IPV4 为空），只要 CUR4 非空且与之前不同则也视为成功
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

# ======= 最后：进入菜单（若未给参数） =======
if [ -z "${1:-}" ]; then
    while true; do show_menu; done
fi
