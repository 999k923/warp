#!/bin/bash
set -euo pipefail

# warp-cf-final.sh
# CFwarp-style final script:
# - 优先使用 IPv4 endpoint (保证 IPv4-only 能拿到 WARP IPv4)
# - 不等待 wg/wrap 接口生效（避免卡住）
# - 使用策略路由保留入站回程 (ip rule + custom table)
# - 兼容 Alpine (OpenRC) 与 Debian/Ubuntu (systemd)
# - 支持 start|stop|restart|status|uninstall + 菜单

WG_BIN="/usr/local/bin/warp-go"
CONF_DIR="/etc/warp"
CONF="$CONF_DIR/warp.conf"
SERVICE_NAME="warp-go"
ARCH="amd64"
WG_URL="https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${ARCH}"
API_URL="https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/amd64"
TMP_API="./warpapi_tmp"
RT_TABLE_NUM=200
RT_TABLE_NAME="warp_main"

red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
info(){ echo -e "\033[36m$1\033[0m"; }

if [ "$(id -u)" -ne 0 ]; then
    red "请以 root 身份运行脚本"
    exit 1
fi

warp_status(){
    echo "========================"
    echo "🌍 WARP IP 信息"
    echo "========================"
    echo "本机公网 IPv4: $(curl -4s https://ip.gs || echo 'N/A')"
    echo "本机公网 IPv6: $(curl -6s https://ip.gs || echo 'N/A')"
    if ip link show warp0 >/dev/null 2>&1; then
        echo "WARP 出口 IPv4: $(curl -4s https://ip.gs --interface warp0 2>/dev/null || echo 'N/A')"
        echo "WARP 出口 IPv6: $(curl -6s https://ip.gs --interface warp0 2>/dev/null || echo 'N/A')"
    else
        echo "WARP 出口 IPv4: N/A (warp0 未就绪)"
        echo "WARP 出口 IPv6: N/A (warp0 未就绪)"
    fi
    echo ""
    echo "Cloudflare trace:"
    curl -s https://www.cloudflare.com/cdn-cgi/trace || echo "trace 获取失败"
    echo ""
}

warp_stop(){
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

warp_start(){
    yellow "🚀 启动 warp-go ..."
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl start $SERVICE_NAME || true
    elif [ -f /etc/init.d/$SERVICE_NAME ]; then
        rc-service $SERVICE_NAME start || true
    fi
    green "✔ warp-go start command issued"
}

warp_restart(){
    yellow "🔄 重启 warp-go ..."
    warp_stop
    warp_start
}

show_menu(){
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
    read -rp "请选择操作 [0-5]: " c
    case "$c" in
        1) warp_status ;;
        2) warp_start ;;
        3) warp_stop ;;
        4) warp_restart ;;
        5) bash "$0" uninstall ;;
        0) exit 0 ;;
        *) red "无效选项"; show_menu ;;
    esac
}

# 参数处理
case "${1:-}" in
    status) warp_status; exit 0 ;;
    start) warp_start; exit 0 ;;
    stop) warp_stop; exit 0 ;;
    restart) warp_restart; exit 0 ;;
    uninstall)
        yellow "🛑 卸载中..."
        warp_stop
        # 删除 ip rule (基于
