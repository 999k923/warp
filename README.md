只适用于ipv6only vps的warp，有ipv4别安装。
==
一键运行命令直接获取warp ipv4，没有其他多余功能
=
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/999k923/warp/refs/heads/main/warp-ipv4.sh)
```

运行命令管理warp：
=
```bash
wget -O warp-ipv4.sh https://raw.githubusercontent.com/999k923/warp/main/warp-ipv4.sh
chmod +x warp-ipv4.sh
```
管理菜单
=
```bash
bash warp-ipv4.sh install      # 安装（默认）
bash warp-ipv4.sh uninstall    # 卸载
bash warp-ipv4.sh status       # 显示当前 WARP IP 信息（v4/v6/trace）
bash warp-ipv4.sh stop         # 停止 warp-go
bash warp-ipv4.sh start        # 启动 warp-go
bash warp-ipv4.sh restart      # 重启 warp-go
```
