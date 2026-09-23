#!/bin/bash
#
# TOS 性能监测 — 卸载脚本
#
# 用法：sudo bash uninstall.sh
#
# 默认保留采集数据（/var/lib/tos-perfmon）；加 --purge 一并删除。
#
set -e

APPID=tos-perfmon
PURGE=0
[ "$1" = "--purge" ] && PURGE=1

log() { printf '\033[36m[%s]\033[0m %s\n' "$APPID" "$*"; }
ok()  { printf '\033[32m  ✓\033[0m %s\n' "$*"; }

[ "$(id -u)" = "0" ] || { echo "请用 root 或 sudo 执行"; exit 1; }

log "停止服务"
systemctl stop "$APPID" 2>/dev/null || true
systemctl disable "$APPID" 2>/dev/null || true
ok "已停止"

log "移除 nginx 配置"
if [ -f "/etc/nginx/conf.d/$APPID-app.conf" ]; then
    rm -f "/etc/nginx/conf.d/$APPID-app.conf"
    nginx -t >/dev/null 2>&1 && { systemctl restart nginx 2>/dev/null || systemctl reload nginx 2>/dev/null || true; }
    ok "已移除"
else
    ok "无残留"
fi

log "卸载软件包"
dpkg --purge "$APPID" >/dev/null 2>&1 || true
rm -rf "/usr/local/$APPID"
rm -f "/etc/systemd/system/$APPID.service"
systemctl daemon-reload 2>/dev/null || true
ok "已卸载"

if [ "$PURGE" = "1" ]; then
    log "清除数据与用户"
    rm -rf "/var/lib/$APPID" "/var/log/$APPID"
    userdel -r "$APPID" 2>/dev/null || true
    ok "已清除"
else
    log "保留数据目录 /var/lib/$APPID（如需删除请加 --purge）"
fi

echo
echo "卸载完成。"
