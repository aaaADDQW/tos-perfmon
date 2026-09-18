#!/bin/bash
#
# TOS PerfMon — 构建脚本
#
# 用法:
#   ./build.sh              # 构建 deb
#   ./build.sh --install    # 构建并安装到本机
#
set -e
cd "$(dirname "$0")"

APP_ID="tos-perfmon"
VERSION=$(python3 -c "import json;print(json.load(open('pkg/usr/local/$APP_ID/config.ini'))['version'])" 2>/dev/null || echo "1.0.0")
PLATFORM="x86_64"
DEB_NAME="${APP_ID}_${PLATFORM}.deb"

echo "=========================================="
echo " 构建 $APP_ID v$VERSION ($PLATFORM)"
echo "=========================================="
echo ""

# --- 1. 准备目录 ---
echo "[1/6] 准备目录结构"
PKG="pkg"
APP_DIR="$PKG/usr/local/$APP_ID"

# 清理编译产物
find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find . -name "*.pyc" -delete 2>/dev/null || true
rm -f "$APP_DIR/webui.bz2"
rm -rf "$APP_DIR/webui"

# --- 2. 打包 WebUI ---
echo "[2/6] 打包 WebUI → webui.bz2"
if [ -d "webui" ]; then
    tar -cjf "$APP_DIR/webui.bz2" -C webui .
    echo "      $(du -h "$APP_DIR/webui.bz2" | cut -f1) webui.bz2"
else
    echo "      ⚠ 未找到 webui/ 目录"
fi

# --- 3. 语法检查 ---
echo "[3/6] 语法检查"
if command -v python3 > /dev/null; then
    python3 -m py_compile "$APP_DIR/bin/$APP_ID"
    echo "      ✅ bin/$APP_ID 语法正确"
    find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
fi

# --- 4. 校验 config.ini ---
echo "[4/6] 校验 config.ini"
python3 - "$APP_DIR/config.ini" "$APP_ID" "$VERSION" <<'PYEOF'
import json, sys
cfg_path, app_id, version = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cfg = json.load(open(cfg_path, encoding='utf-8'))
except Exception as e:
    print('      ❌ config.ini 不是合法 JSON: %s' % e); sys.exit(1)

errs = []
# 必填字段
for k in ['id','icon','version','category','platform','application_type','system_id','package','exec','recommend','beta','low_version']:
    if k not in cfg:
        errs.append('缺少必填字段: %s' % k)
# 一致性
if cfg.get('id') != app_id:
    errs.append('id(%s) != 应用目录名(%s)' % (cfg.get('id'), app_id))
if cfg.get('package') != app_id:
    errs.append('package(%s) != %s' % (cfg.get('package'), app_id))
if cfg.get('system_id') != app_id:
    errs.append('system_id(%s) != %s' % (cfg.get('system_id'), app_id))
if cfg.get('version') != version:
    errs.append('config.ini version(%s) != DEBIAN/control version(%s)' % (cfg.get('version'), version))
# 互斥字段
if 'type' in cfg and 'open_path' in cfg:
    errs.append('type 与 open_path 互斥，不能同时出现')
if cfg.get('type') == 'iframe' and cfg.get('path') != '/%s/' % app_id:
    errs.append('iframe 模式 path 必须为 /%s/' % app_id)
if cfg.get('icon') != '/images/icons/%s.svg' % app_id:
    errs.append('icon 路径必须为 /images/icons/%s.svg' % app_id)

if errs:
    print('      ❌ 校验失败:')
    for e in errs: print('         · %s' % e)
    sys.exit(1)
print('      ✅ config.ini 校验通过')
PYEOF

# --- 5. 设置权限 ---
echo "[5/6] 设置文件权限"
chmod 755 "$APP_DIR/bin/$APP_ID"
chmod 644 "$APP_DIR/config.ini"
chmod 644 "$APP_DIR/$APP_ID.lang"
chmod 644 "$APP_DIR/images/icons/$APP_ID.svg"
chmod 644 "$APP_DIR/init.d/$APP_ID.service"
chmod 755 "$PKG/DEBIAN/preinst" "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postrm"
echo "      ✅ 权限已设置"

# --- 6. 构建 deb ---
echo "[6/6] 构建 deb 包"
rm -f "$DEB_NAME"
dpkg-deb --build "$PKG" "$DEB_NAME" 2>&1 | sed 's/^/      /'

echo ""
echo "=========================================="
echo " ✅ 构建完成: $DEB_NAME"
echo "=========================================="
ls -lh "$DEB_NAME" | awk '{print " 大小: "$5}'
echo ""
echo "包内文件清单:"
dpkg-deb -c "$DEB_NAME" | awk '{printf "  %s\n", $6}'
echo ""
echo "包信息:"
dpkg-deb -I "$DEB_NAME" | grep -E "Package|Version|Architecture|Depends" | sed 's/^/ /'

# --- 可选安装 ---
if [ "$1" = "--install" ]; then
    echo ""
    echo "=========================================="
    echo " 安装到本机"
    echo "=========================================="
    # 创建应用用户（平台会自动创建，手工装需要自己建）
    if ! id -u "$APP_ID" > /dev/null 2>&1; then
        echo "创建用户 $APP_ID"
        useradd -r -s /usr/sbin/nologin -d "/var/lib/$APP_ID" "$APP_ID" 2>/dev/null || true
    fi
    dpkg -i "$DEB_NAME"
    echo ""
    echo "服务状态:"
    systemctl status "$APP_ID" --no-pager 2>&1 | head -12 | sed 's/^/ /'
fi

echo ""
echo "完成。"
