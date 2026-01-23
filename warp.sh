#!/bin/bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export LANG=en_US.UTF-8

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}

[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit

release=""
if [[ -f /etc/redhat-release ]]; then
  release="Centos"
elif grep -qi '^ID=alpine' /etc/os-release 2>/dev/null; then
  release="Alpine"
elif cat /etc/issue 2>/dev/null | grep -q -E -i "debian"; then
  release="Debian"
elif cat /etc/issue 2>/dev/null | grep -q -E -i "ubuntu"; then
  release="Ubuntu"
elif cat /etc/issue 2>/dev/null | grep -q -E -i "centos|red hat|redhat"; then
  release="Centos"
elif cat /etc/issue 2>/dev/null | grep -q -E -i "alpine"; then
  release="Alpine"
elif cat /proc/version 2>/dev/null | grep -q -E -i "debian"; then
  release="Debian"
elif cat /proc/version 2>/dev/null | grep -q -E -i "ubuntu"; then
  release="Ubuntu"
elif cat /proc/version 2>/dev/null | grep -q -E -i "centos|red hat|redhat"; then
  release="Centos"
elif cat /proc/version 2>/dev/null | grep -q -E -i "alpine"; then
  release="Alpine"
else
  red "不支持当前的系统，请选择使用Ubuntu,Debian,Centos,Alpine系统。" && exit
fi

cpujg(){
  case $(uname -m) in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) red "目前脚本不支持$(uname -m)架构" && exit;;
  esac
}

pkg_install(){
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  fi
}

ensure_warpgo_init(){
  if command -v systemctl >/dev/null 2>&1; then
    return
  fi
  if [[ ! -f /etc/init.d/warp-go ]]; then
cat > /etc/init.d/warp-go << 'EORC'
#!/sbin/openrc-run

description="warp-go service"
command="/usr/local/bin/warp-go"
command_args="--config=/usr/local/bin/warp.conf"
pidfile="/run/warp-go.pid"
command_background="yes"

depend() {
  need net
}
EORC
    chmod +x /etc/init.d/warp-go
  fi
}

if ! command -v systemctl >/dev/null 2>&1; then
systemctl(){
  local action="$1"
  shift
  case "$action" in
    start|stop|restart)
      for svc in "$@"; do
        case "$svc" in
          warp-go)
            ensure_warpgo_init
            if command -v rc-service >/dev/null 2>&1; then
              rc-service warp-go "$action" >/dev/null 2>&1
            elif [[ "$action" = "stop" ]]; then
              pkill -15 warp-go >/dev/null 2>&1
            else
              /usr/local/bin/warp-go --config=/usr/local/bin/warp.conf >/dev/null 2>&1 &
            fi
            ;;
        esac
      done
      ;;
    enable|disable)
      for svc in "$@"; do
        case "$svc" in
          warp-go)
            ensure_warpgo_init
            if command -v rc-update >/dev/null 2>&1; then
              if [[ "$action" = "enable" ]]; then
                rc-update add warp-go default >/dev/null 2>&1
              else
                rc-update del warp-go default >/dev/null 2>&1
              fi
            fi
            ;;
        esac
      done
      ;;
    is-active)
      if command -v rc-service >/dev/null 2>&1; then
        rc-service warp-go status >/dev/null 2>&1 && echo active || echo inactive
      else
        pgrep warp-go >/dev/null 2>&1 && echo active || echo inactive
      fi
      ;;
    daemon-reload) : ;;
    *) : ;;
  esac
}
fi

v4v6(){
  v4=$(curl -s4m5 icanhazip.com -k)
  v6=$(curl -s6m5 icanhazip.com -k)
}

checkwgcf(){
  wgcfv6=$(curl -s6m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
  wgcfv4=$(curl -s4m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
}

warpip(){
  v4v6
  if [[ -z $v4 ]]; then
    endpoint=[2606:4700:d0::a29f:c001]:2408
  else
    endpoint=162.159.192.1:2408
  fi
}

install_deps(){
  case "$release" in
    "Centos") pkg_install epel-release iproute iputils;;
    "Debian"|"Ubuntu") pkg_install iproute2 openresolv dnsutils iputils-ping;;
    "Alpine") pkg_install iproute2 iputils bind-tools openresolv;;
  esac
}

write_warp_conf(){
  if [[ ! -s /usr/local/bin/warp.conf ]]; then
    cpujg
    curl -L -o warpapi -# --retry 2 https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/$cpu
    chmod +x warpapi
    output=$(./warpapi)
    private_key=$(echo "$output" | awk -F ': ' '/private_key/{print $2}')
    device_id=$(echo "$output" | awk -F ': ' '/device_id/{print $2}')
    warp_token=$(echo "$output" | awk -F ': ' '/token/{print $2}')
    rm -rf warpapi
cat > /usr/local/bin/warp.conf <<EOF
[Account]
Device = $device_id
PrivateKey = $private_key
Token = $warp_token
Type = free
Name = WARP
MTU  = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = $endpoint
# AllowedIPs = 0.0.0.0/0
# AllowedIPs = ::/0
KeepAlive = 30
EOF
  fi
  chmod +x /usr/local/bin/warp.conf
  sed -i '0,/AllowedIPs/{/AllowedIPs/d;}' /usr/local/bin/warp.conf
  sed -i '/KeepAlive/a [Script]' /usr/local/bin/warp.conf
}

write_systemd_unit(){
  if command -v systemctl >/dev/null 2>&1; then
mkdir -p /etc/systemd/system
cat > /etc/systemd/system/warp-go.service << EOF
[Unit]
Description=warp-go service
After=network.target
Documentation=https://gitlab.com/ProjectWARP/warp-go
[Service]
WorkingDirectory=/root/
ExecStart=/usr/local/bin/warp-go --config=/usr/local/bin/warp.conf
Environment="LOG_LEVEL=verbose"
RemainAfterExit=yes
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  fi
}

install_warpgo(){
  install_deps
  cpujg
  wget -N https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_${cpu} -O /usr/local/bin/warp-go && chmod +x /usr/local/bin/warp-go
  write_systemd_unit
  ensure_warpgo_init
}

set_allowed_ips(){
  local mode="$1"
  case "$mode" in
    v4) sed -i "s#.*AllowedIPs.*#AllowedIPs = 0.0.0.0/0#g" /usr/local/bin/warp.conf ;;
    v4v6) sed -i "s#.*AllowedIPs.*#AllowedIPs = 0.0.0.0/0,::/0#g" /usr/local/bin/warp.conf ;;
  esac
  sed -i "/Endpoint6/d" /usr/local/bin/warp.conf
  sed -i "/Endpoint/s/.*/Endpoint = $endpoint/" /usr/local/bin/warp.conf
}

start_warp(){
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable warp-go >/dev/null 2>&1
  systemctl restart warp-go >/dev/null 2>&1
}

install_monitor(){
cat > /usr/local/bin/warp-monitor.sh << 'EOF'
#!/bin/bash
wgcfv6=$(curl -s6m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
wgcfv4=$(curl -s4m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
if [[ ! $wgcfv4 =~ on|plus && ! $wgcfv6 =~ on|plus ]]; then
  systemctl restart warp-go >/dev/null 2>&1
fi
EOF
  chmod +x /usr/local/bin/warp-monitor.sh
  crontab -l 2>/dev/null | grep -v 'warp-monitor.sh' > /tmp/warp-cron.tmp || true
  echo '@reboot /usr/local/bin/warp-monitor.sh' >> /tmp/warp-cron.tmp
  echo '*/5 * * * * /usr/local/bin/warp-monitor.sh' >> /tmp/warp-cron.tmp
  crontab /tmp/warp-cron.tmp
  rm -f /tmp/warp-cron.tmp
}

apply_mode(){
  local mode="$1"
  warpip
  install_warpgo
  write_warp_conf
  set_allowed_ips "$mode"
  start_warp
  install_monitor
  checkwgcf
  if [[ $wgcfv4 =~ on|plus || $wgcfv6 =~ on|plus ]]; then
    green "WARP启动成功"
  else
    red "WARP启动失败，请稍后再试"
  fi
}

menu(){
  echo
  green "1. 获取 WARP IPv4"
  green "2. 获取 WARP IPv4 + IPv6"
  read -p "请选择：" choice
  case "$choice" in
    1) apply_mode v4;;
    2) apply_mode v4v6;;
    *) red "输入错误"; exit 1;;
  esac
}

menu
