#!/bin/bash

# 用法提示
usage() {
    cat <<EOF
用法: $0 -M MAJOR -m MINOR -r REV -b BUILD -d DATA [-o OUI]

必选参数:
  -M MAJOR     Major 版本
  -m MINOR     Minor 版本
  -r REV       Revision
  -b BUILD     Build 号
  -d DATA      Vendor Data 字符串

可选参数:
  -o OUI       厂商 OUI (十六进制 3 字节, 默认: 0090FB)
  -h           显示此帮助

示例:
  $0 -M 1 -m 2 -r 3 -b 2748 -d "QBR_v3.1.445"
  $0 -o 0090FB -M 2 -m 3 -r 1 -b 3000 -d "MyData"
EOF
    exit 0
}

# 初始化
OUI="0090FB"
MAJOR=""
MINOR=""
REV=""
BUILD=""
VENDOR_DATA=""

# 解析命令行参数
while getopts "o:M:m:r:b:d:h" opt; do
    case $opt in
        o) OUI="$OPTARG" ;;
        M) MAJOR="$OPTARG" ;;
        m) MINOR="$OPTARG" ;;
        r) REV="$OPTARG" ;;
        b) BUILD="$OPTARG" ;;
        d) VENDOR_DATA="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# 校验必填参数
if [ -z "$MAJOR" ] || [ -z "$MINOR" ] || [ -z "$REV" ] || [ -z "$BUILD" ] || [ -z "$VENDOR_DATA" ]; then
    echo "错误: 缺少必填参数，请使用 -h 查看帮助" >&2
    exit 1
fi

# 校验 MAJOR/MINOR/REV/BUILD 必须是非负整数
for var in MAJOR MINOR REV BUILD; do
    if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
        echo "错误: $var 必须是非负整数 (当前值: ${!var})" >&2
        exit 1
    fi
done

# 校验取值范围 (根据 TLV 位宽)
if [ "$MAJOR" -gt 15 ]; then
    echo "错误: MAJOR 取值范围 0-15 (当前: $MAJOR)" >&2
    exit 1
fi
if [ "$MINOR" -gt 15 ]; then
    echo "错误: MINOR 取值范围 0-15 (当前: $MINOR)" >&2
    exit 1
fi
if [ "$REV" -gt 15 ]; then
    echo "错误: REV 取值范围 0-15 (当前: $REV)" >&2
    exit 1
fi
if [ "$BUILD" -gt 4095 ]; then
    echo "错误: BUILD 取值范围 0-4095 (当前: $BUILD)" >&2
    exit 1
fi

# 校验 OUI 必须是恰好 3 字节 (6 位十六进制)
if ! [[ "$OUI" =~ ^[0-9A-Fa-f]{6}$ ]]; then
    echo "错误: OUI 必须是恰好 6 位十六进制字符串 (当前: $OUI)" >&2
    exit 1
fi

echo "=== 参数 ==="
echo "  OUI:        $OUI"
echo "  MAJOR:      $MAJOR"
echo "  MINOR:      $MINOR"
echo "  REV:        $REV"
echo "  BUILD:      $BUILD"
echo "  VendorData: $VENDOR_DATA"
echo ""

echo "=== Commissioner 状态 ==="
COMM_STATE=$(sudo ot-ctl commissioner state 2>&1 | head -1)
echo "  $COMM_STATE"

if [ "$COMM_STATE" != "active" ]; then
    echo "  → 启动 Commissioner..."
    sudo ot-ctl commissioner start
    sleep 3
fi

RAW=$(sudo ot-ctl dataset active -x 2>&1 | head -1)
CLEAN_HEX=$(echo "$RAW" | grep -oE '^[0-9A-Fa-f]+')
echo ""
echo "=== 当前 Active Dataset ==="
echo "  $CLEAN_HEX"

# 动态构造 Payload: Timestamp + Vendor Stack Version + Vendor Data
PAYLOAD=$(python3 -c "
import sys, re
h = sys.argv[1]
vd = sys.argv[2]
oui = sys.argv[3]
major= int(sys.argv[4])
minor= int(sys.argv[5])
rev  = int(sys.argv[6])
build = int(sys.argv[7])

# Timestamp: 从 dataset 继承+1, 防止被忽略
m = re.search(r'(?i)0E08([0-9A-Fa-f]{16})', h)
if m:
    sec = int(m.group(1)[:12], 16) + 1
    tck = int(m.group(1)[12:], 16)
else:
    sec = 1
    tck = 0
ts = f'0E08{sec:012X}{tck:04X}'

# Vendor Stack Version TLV (0x25) — 确保不溢出 16/8 位
bv = ((build << 4) | rev) & 0xFFFF
mv = ((minor << 4) | major) & 0xFF
vs = f'2506{oui}{bv:04X}{mv:02X}'

# Vendor Data TLV (0x24)
vd_hex = f'24{len(vd):02X}{vd.encode().hex()}'

print(ts + vs + vd_hex)
" "$CLEAN_HEX" "$VENDOR_DATA" "$OUI" "$MAJOR" "$MINOR" "$REV" "$BUILD")

echo ""
echo "=== 发送 MGMT_ACTIVE_SET ==="
echo "  Payload: $PAYLOAD"
sudo ot-ctl dataset mgmtsetcommand active -x "$PAYLOAD"

echo ""
echo "=== 验证 ==="
NEW_RAW=$(sudo ot-ctl dataset active -x 2>&1 | head -1)
NEW_HEX=$(echo "$NEW_RAW" | grep -oE '^[0-9A-Fa-f]+')

python3 -c "
import sys
h = sys.argv[1]
# 传入期望值用于比对
exp_oui   = sys.argv[2]
exp_major = int(sys.argv[3])
exp_minor = int(sys.argv[4])
exp_rev   = int(sys.argv[5])
exp_build = int(sys.argv[6])
exp_vd    = sys.argv[7]

data = bytes.fromhex(h)
print('  Active Dataset TLVs:')
i = 0
ok = False
while i < len(data):
    t = data[i]; l = data[i+1]; v = data[i+2:i+2+l]
    if t == 0x0E:
        s = int.from_bytes(v[:6],'big'); tk = int.from_bytes(v[6:],'big')
        print(f'    Active Timestamp: seconds={s}, ticks={tk}')
    elif t == 0x25:
        built = int.from_bytes(v[3:5],'big')
        oui_found = v[:3].hex().upper()
        build_found = built>>4
        rev_found   = built&0xF
        minor_found = v[5]>>4
        major_found = v[5]&0xF
        print(f'    Vendor Stack Version: OUI=0x{v[:3].hex()} Major={major_found} Minor={minor_found} Rev={rev_found} Build={build_found}')
        # 比对
        if (oui_found == exp_oui.upper() and build_found == exp_build and
            rev_found == exp_rev and minor_found == exp_minor and major_found == exp_major):
            ok = True
    elif t == 0x24:
        vd_found = v.decode('utf-8',errors='replace')
        print(f'    Vendor Data: {vd_found}')
        if vd_found != exp_vd:
            ok = False
    i += 2 + l

print()
if ok:
    print('✅ 写入成功 — 新值已生效')
else:
    print('❌ 写入失败或值不匹配')
" "$NEW_HEX" "$OUI" "$MAJOR" "$MINOR" "$REV" "$BUILD" "$VENDOR_DATA"
