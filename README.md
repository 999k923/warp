
一键运行命令直接获取warp ipv4，没有其他多余功能，只支持纯ipv6
==

```bash
wget -O warp-ipv4.sh https://raw.githubusercontent.com/999k923/warp/main/warp-ipv4.sh && chmod +x warp-ipv4.sh && ./warp-ipv4.sh
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
