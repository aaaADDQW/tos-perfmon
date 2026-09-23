#!/bin/bash
#
# TOS 性能监测 — 一键安装脚本
#
# 用法（在 TNAS 上以 test 用户执行，需要 sudo/root 权限）：
#     sudo bash install.sh
#
# 作用：
#   1. 安装 deb 包
#   2. 若平台未创建运行用户，自动补建
#   3. 配置 nginx 反向代理并重载
#   4. 启动服务并打印访问地址
#
set -e

APPID=tos-perfmon
PORT=8790
DEB="$(dirname "$0")/${APPID}_1.0.0_amd64.deb"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$APPID" "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 或 sudo 执行"
[ -f "$DEB" ] || die "找不到安装包: $DEB"

log "1/5 安装 deb 包"
dpkg -i "$DEB" >/dev/null 2>&1 || dpkg -i "$DEB"
ok "已安装"

log "2/5 检查运行用户"
# 平台安装时会自动建用户；手工 dpkg -i 时需补建，否则 systemd 报 217/USER
if id -u "$APPID" >/dev/null 2>&1; then
    ok "用户 $APPID 已存在"
else
    useradd -m -s /bin/bash -d "/home/$APPID" "$APPID" 2>/dev/null || true
    if id -u "$APPID" >/dev/null 2>&1; then
        ok "已创建用户 $APPID"
    else
        warn "创建用户失败，服务可能无法启动"
    fi
fi

# 数据目录授权（采集需要写权限）
mkdir -p "/var/lib/$APPID" "/var/log/$APPID"
chown -R "$APPID:$APPID" "/var/lib/$APPID" "/var/log/$APPID" 2>/dev/null || true
ok "数据目录已授权"

log "3/5 配置 nginx 反向代理"
SRC="/usr/local/$APPID/nginx/$APPID.conf"
DST="/etc/nginx/conf.d/$APPID-app.conf"
if [ -f "$SRC" ]; then
    cp -f "$SRC" "$DST"
    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx 2>/dev/null || systemctl reload nginx 2>/dev/null || true
        ok "nginx 已配置并重载"
    else
        rm -f "$DST"
        die "nginx 配置校验失败，已回滚"
    fi
else
    warn "未找到 $SRC，跳过 nginx 配置"
fi

log "4/5 启动服务"
systemctl daemon-reload
systemctl enable "$APPID" >/dev/null 2>&1 || true
systemctl restart "$APPID" || true
sleep 3

if systemctl is-active --quiet "$APPID"; then
    ok "服务运行中"
else
    warn "服务未运行，最近日志："
    journalctl -u "$APPID" --no-pager -n 15 | sed 's/^/      /'
    die "启动失败"
fi

log "5/5 连通性自检"
CODE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || echo 000)
if [ "$CODE" = "200" ]; then
    ok "后端 http://127.0.0.1:$PORT 正常"
else
    die "后端无响应 (HTTP $CODE)"
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo "=========================================="
echo " 安装完成"
echo "=========================================="
echo " 访问地址: http://${IP:-<TNAS_IP>}:8181/$APPID/"
echo " 本机自测: curl http://127.0.0.1:8181/$APPID/api/status"
echo " 查看日志: journalctl -u $APPID -f"
echo " 卸载:     sudo bash uninstall.sh"
echo "=========================================="
