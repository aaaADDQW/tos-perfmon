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
# 官方规范: 单包模式文件名为 <appid>_<version>_<arch>.deb
# 例: myapp_1.0.0_amd64.deb  (arch 用 amd64，不是 x86_64)
DEB_NAME="${APP_ID}_${VERSION}_amd64.deb"

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
    # ⚠️ 必须保留 webui/ 这一层目录，解压后为 <app>/webui/index.html。
    # 平台按 /usr/local/<app_id>/webui/ 定位前端入口；若把内容铺到应用根目录
    # (<app>/index.html)，平台找不到前端，会回退加载默认平台页面，
    # 表现为桌面上多开一个"套娃"的管理平台窗口。
    # 对照平台应用：MultimediaServer/docker/calendar 均为 <app>/webui/index.html
    tar -cjf "$APP_DIR/webui.bz2" webui
    echo "      $(du -h "$APP_DIR/webui.bz2" | cut -f1) webui.bz2"
    echo "      内容: $(tar -tjf "$APP_DIR/webui.bz2" | head -3 | tr '\n' ' ')"
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
# 官方必填字段（见 config.ini 文档字段参考表）
REQUIRED = ['id','icon','exec','version','category','platform',
            'application_type','system_id','package','publisher']
for k in REQUIRED:
    if k not in cfg:
        errs.append('缺少必填字段: %s' % k)

# id 字符集：小写字母开头，仅 a-z0-9-
import re as _re
if not _re.fullmatch(r'[a-z][a-z0-9-]{0,49}', str(cfg.get('id',''))):
    errs.append('id 必须小写字母开头、仅含 a-z0-9-、最长 50: %r' % cfg.get('id'))

# 一致性（目录结构文档"强制对应关系"）
if cfg.get('id') != app_id:
    errs.append('id(%s) != 应用目录名(%s)' % (cfg.get('id'), app_id))
if cfg.get('package') != app_id:
    errs.append('package(%s) != %s' % (cfg.get('package'), app_id))
if cfg.get('system_id') != app_id:
    errs.append('system_id(%s) != %s' % (cfg.get('system_id'), app_id))
if cfg.get('version') != version:
    errs.append('config.ini version(%s) != DEBIAN/control version(%s)' % (cfg.get('version'), version))
if cfg.get('icon') != '/images/icons/%s.svg' % app_id:
    errs.append('icon 路径必须为 /images/icons/%s.svg' % app_id)

# 互斥：iframe 模式禁止 open_path；外部打开必须有 open_path 且禁止 type
if 'type' in cfg and 'open_path' in cfg:
    errs.append('type 与 open_path 互斥，不能同时出现')
if cfg.get('exec') is True and not cfg.get('path'):
    errs.append('exec=true 时 path 必填')
if cfg.get('type') == 'iframe' and cfg.get('path') != '/%s/' % app_id:
    errs.append('iframe 模式 path 必须为 /%s/，当前 %r' % (app_id, cfg.get('path')))

# 外部打开必须自带 nginx 反向代理配置
if cfg.get('open_path') is True:
    import os as _os
    nf = _os.path.join(_os.path.dirname(cfg_path), 'nginx', '%s.conf' % app_id)
    if not _os.path.isfile(nf):
        errs.append('open_path=true 必须提供 nginx/%s.conf' % app_id)

# low_version 必须 TOS7.0 及以上
lv = str(cfg.get('low_version',''))
if lv and not _re.fullmatch(r'TOS\d+\.\d+', lv):
    errs.append('low_version 必须形如 "TOS7.0"，当前 %r' % lv)

# 分类最多 3 个
if len(cfg.get('category') or []) > 3:
    errs.append('category 最多 3 个，当前 %d 个' % len(cfg.get('category')))

# 类型检查
if cfg.get('relation') is not None and not isinstance(cfg.get('relation'), list):
    errs.append('relation 必须是数组，当前 %s' % type(cfg.get('relation')).__name__)

# 保留字段
RESERVED = ['host_network','container_runtime','sandbox','auto_update',
            'upstream_url','license','min_memory','min_cpu','min_disk']
for k in RESERVED:
    if k in cfg:
        errs.append('使用了保留字段: %s' % k)

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

# ⚠️ 必须显式指定 gzip。
# Ubuntu 22.04 的 dpkg-deb 默认用 zstd (data.tar.zst)，而 TOS 应用中心的
# Go 解析器 (ParseDebFromStream) 只支持 gzip/xz，不认 zstd，会直接抛
# "file not found in deb" → 前端显示 "应用包解析失败"。
dpkg-deb -Z gzip --build "$PKG" "$DEB_NAME" 2>&1 | sed 's/^/      /'

# 校验压缩格式
COMP=$(ar t "$DEB_NAME" | grep -E '^data\.tar' || true)
case "$COMP" in
    data.tar.gz) echo "      ✅ 压缩格式: gzip ($COMP)" ;;
    *) echo "      ❌ 压缩格式错误: $COMP (必须为 data.tar.gz)"; exit 1 ;;
esac

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
