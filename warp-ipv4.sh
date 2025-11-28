#!/bin/bash

set -e

CONFIG_FILE="/etc/wireguard/wgcf.conf"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 运行此脚本！"
        exit 1
    fi
}

detect_os() {
    if command -v apk >/dev/null 2>&1; then
        OS="alpine"
    elif command -v apt >/dev/null 2>&1; then
        OS="debian"
    elif command -v yum >/dev/null 2>&1; then
        OS="centos"
    else
        echo "不支持的系统"
        exit 1
    fi
}

install_pkg() {
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache wireguard-tools curl
    elif [ "$OS" = "debian" ]; then
        apt update && apt install -y wireguard-tools curl
    else
        yum install -y wireguard-tools curl
    fi
}

generate_wgcf() {
    echo "生成 Warp 账户与配置..."
    wgcf=$(which wgcf || true)

    if [ -z "$wgcf" ]; then
        wget -O /usr/local/bin/wgcf https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_amd64
        chmod +x /usr/local/bin/wgcf
    fi

    wgcf register --accept-tos
    wgcf generate
    mv wgcf-profile.conf $CONFIG_FILE
}

fix_ipv4_routing() {
    echo "强制配置为优先获取 WARP IPv4（兼容 IPv6 Only / IPv4 Only）..."

    # 删除默认 IPv6 设置（避免卡死）
    sed -i '/^Address =/d' $CONFIG_FILE
    sed -i '/^DNS =/d' $CONFIG_FILE

    # 强制写入 WARP IPv4
    cat >> $CONFIG_FILE <<EOF
Address = 172.16.0.2/32
DNS = 1.1.1.1
EOF

    # 允许路由所有出站流量
    sed -i '/AllowedIPs/d' $CONFIG_FILE
    echo "AllowedIPs = 0.0.0.0/0" >> $CONFIG_FILE
}

enable_service() {
    echo "启动 WARP..."
    wg-quick down wgcf >/dev/null 2>&1 || true
    wg-quick up wgcf
    echo "WARP 已启动。"
}

disable_service() {
    echo "停止 WARP..."
    wg-quick down wgcf >/dev/null 2>&1 || true
}

show_warp_ip() {
    echo "当前 WARP IPv4 地址："
    curl -4 --interface wgcf http://ipinfo.io/ip 2>/dev/null || echo "未获取到 WARP IPv4"
}

uninstall_warp() {
    echo "卸载 WARP..."
    disable_service
    rm -f $CONFIG_FILE
    rm -f ~/.wgcf*
    rm -f /usr/local/bin/wgcf
    echo "卸载完成"
}

install_warp() {
    install_pkg
    generate_wgcf
    fix_ipv4_routing
    enable_service
    show_warp_ip
}

menu() {
    case "$1" in
        install)
            install_warp
            ;;
        uninstall)
            uninstall_warp
            ;;
        start)
            enable_service
            ;;
        stop)
            disable_service
            ;;
        ip)
            show_warp_ip
            ;;
        *)
            echo "使用方法："
            echo " bash warp-ipv4.sh install   # 安装 WARP IPv4"
            echo " bash warp-ipv4.sh uninstall # 卸载"
            echo " bash warp-ipv4.sh start     # 启动 WARP"
            echo " bash warp-ipv4.sh stop      # 停止 WARP"
            echo " bash warp-ipv4.sh ip        # 查看 WARP IPv4"
            ;;
    esac
}

check_root
detect_os
menu "$1"
