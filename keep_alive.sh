#!/bin/bash

# ======================================================================
# TUIC & Argo 保活脚本
# ======================================================================

AGSBX_DIR="$HOME/agsbx"
SINGBOX_PATH="$AGSBX_DIR/sing-box"
CLOUDFLARED_PATH="$AGSBX_DIR/cloudflared"
CONFIG_PATH="$AGSBX_DIR/sb.json"
VARS_PATH="$AGSBX_DIR/variables.conf"
LOG_FILE="$AGSBX_DIR/keep_alive.log"

# 加载变量
[ -f "$VARS_PATH" ] && . "$VARS_PATH"

log() {
    echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

# 检查并启动 sing-box
check_singbox() {
    if [ -f "$SINGBOX_PATH" ] && [ -f "$CONFIG_PATH" ]; then
        if ! pgrep -f "$SINGBOX_PATH" >/dev/null 2>&1; then
            nohup "$SINGBOX_PATH" run -c "$CONFIG_PATH" >> "$AGSBX_DIR/sing-box.log" 2>&1 &
            log "sing-box 已启动"
        fi
    fi
}

# 检查并启动 cloudflared
check_cloudflared() {
    if [ -f "$CLOUDFLARED_PATH" ]; then
        if ! pgrep -f "$CLOUDFLARED_PATH" >/dev/null 2>&1; then
            if [ -n "$ARGO_TOKEN" ] && [ -n "$ARGO_DOMAIN" ]; then
                cat > "$AGSBX_DIR/config.yml" <<EOF
log-level: info
ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://127.0.0.1:${ARGO_LOCAL_PORT}
  - service: http_status:404
EOF
                nohup "$CLOUDFLARED_PATH" tunnel --config "$AGSBX_DIR/config.yml" run --token "$ARGO_TOKEN" >> "$AGSBX_DIR/argo.log" 2>&1 &
                log "cloudflared (Argo) 已启动"
            else
                nohup "$CLOUDFLARED_PATH" tunnel --url "http://127.0.0.1:${ARGO_LOCAL_PORT}" >> "$AGSBX_DIR/argo.log" 2>&1 &
                log "cloudflared (临时 Argo) 已启动"
            fi
        fi
    fi
}

# 无限循环保活
while true; do
    check_singbox
    check_cloudflared
    sleep 10
done
