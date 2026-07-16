#!/usr/bin/env python3
"""
Thread Dataset Vendor Stack Version TLV Parser

解析 `ot-ctl dataset active -x` 输出的 hex 字符串，
提取 Vendor Stack Version TLV (type=37) 中的 Build/Revision/Minor/Major 值。

Usage:
    python parse_vendor_stack_version.py <dataset_hex_string>

Examples:
    # 从 ot-ctl dataset active -x 输出
    python parse_vendor_stack_version.py "0e080000000000010000..."
    python parse_vendor_stack_version.py 0e080000000000010000
"""

import sys
import struct

# ── TLV 类型常量 ──
VENDOR_STACK_VERSION_TLV_TYPE = 37  # OT_MESHCOP_TLV_VENDOR_STACK_VERSION_TLV

# ── VendorStackVersionTlv 位域常量（与 C++ 代码一致）──
# mBuildRevision (uint16 big-endian):
#   bits 15-4: Build (12-bit),  bits 3-0: Revision (4-bit)
BUILD_OFFSET = 4
BUILD_MASK   = 0xFFF << BUILD_OFFSET   # 0xFFF0
REV_OFFSET   = 0
REV_MASK     = 0xF                     # 0x000F

# mMinorMajor (uint8):
#   bits 7-4: Minor (4-bit),  bits 3-0: Major (4-bit)
MINOR_OFFSET = 4
MINOR_MASK   = 0xF << MINOR_OFFSET     # 0xF0
MAJOR_OFFSET = 0
MAJOR_MASK   = 0xF                     # 0x0F

# ── TLV 类型名称表（仅用于打印）──
TLV_TYPE_NAMES = {
    0:  "Channel",
    1:  "PAN ID",
    2:  "Extended PAN ID",
    3:  "Network Name",
    4:  "PSKc",
    5:  "Network Key",
    6:  "Network Key Sequence",
    7:  "Mesh Local Prefix",
    8:  "Steering Data",
    9:  "Border Agent Locator",
    10: "Commissioner ID",
    11: "Commissioner Session ID",
    12: "Security Policy",
    14: "Active Timestamp",
    15: "Commissioner UDP Port",
    16: "State",
    33: "Vendor Name",
    34: "Vendor Model",
    35: "Vendor SW Version",
    36: "Vendor Data",
    37: "Vendor Stack Version",
    51: "Pending Timestamp",
    52: "Delay Timer",
    53: "Channel Mask",
    56: "Scan Duration",
}


def parse_tlv_sequence(data: bytes):
    """
    解析 Thread TLV 序列，返回 {type: value_bytes} 字典。
    仅处理标准 TLV 格式: [Type(1)] [Length(1)] [Value(Length)]
    """
    tlvs = {}
    offset = 0
    while offset < len(data):
        if offset + 1 >= len(data):
            break
        tlv_type = data[offset]
        length   = data[offset + 1]
        if offset + 2 + length > len(data):
            break
        value = data[offset + 2 : offset + 2 + length]
        tlvs[tlv_type] = value
        offset += 2 + length
    return tlvs


def parse_vendor_stack_version(value: bytes):
    """
    解析 Vendor Stack Version TLV 的 Value (6 bytes)。

    结构: [OUI(3)] [BuildRevision(2, BE)] [MinorMajor(1)]

    返回: (dict, None) 或 (None, error_str)
    """
    if len(value) < 6:
        return None, f"Expected at least 6 bytes, got {len(value)}"

    # ── OUI: 3 bytes, big-endian ──
    oui = (value[0] << 16) | (value[1] << 8) | value[2]

    # ── mBuildRevision: 2 bytes, big-endian ──
    build_revision = struct.unpack('>H', value[3:5])[0]
    build_val   = (build_revision >> BUILD_OFFSET) & (BUILD_MASK >> BUILD_OFFSET)
    revision_val = build_revision & REV_MASK

    # ── mMinorMajor: 1 byte ──
    minor_major = value[5]
    minor_val   = (minor_major & MINOR_MASK) >> MINOR_OFFSET
    major_val   = minor_major & MAJOR_MASK

    return {
        "OUI":      oui,
        "Build":    build_val,
        "Revision": revision_val,
        "Minor":    minor_val,
        "Major":    major_val,
    }, None


def format_version(v):
    """格式化版本号: 'v{Minor}.{Major}.b{Build}r{Revision}'"""
    return f"v{v['Major']}.{v['Minor']}.b{v['Build']}r{v['Revision']} (OUI=0x{v['OUI']:06X})"


def print_dataset_summary(tlvs):
    """打印数据集中所有 TLV 的概要。"""
    print("Dataset TLVs:")
    for t, v in sorted(tlvs.items()):
        name = TLV_TYPE_NAMES.get(t, f"Unknown(0x{t:02X})")
        if t == VENDOR_STACK_VERSION_TLV_TYPE:
            parsed, err = parse_vendor_stack_version(v)
            if parsed:
                print(f"  [{t:>3}] {name}: {format_version(parsed)}")
            else:
                print(f"  [{t:>3}] {name}: <parse error: {err}>  hex={v.hex()}")
        else:
            print(f"  [{t:>3}] {name}: {v.hex()}")


def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python parse_vendor_stack_version.py <dataset_hex_string>")
        print()
        print("Example:")
        print('  python parse_vendor_stack_version.py "0e080000000000010000..."')
        print()
        print("Tip: 从 ot-ctl dataset active -x 获取 hex 字符串")
        sys.exit(1)

    # ── 清理输入 ──
    hex_str = sys.argv[1]
    hex_str = hex_str.removeprefix("0x").removeprefix("0X")
    hex_str = hex_str.strip().replace(" ", "").replace("\n", "").replace("\t", "")

    try:
        data = bytes.fromhex(hex_str)
    except ValueError as e:
        print(f"Error: invalid hex string: {e}", file=sys.stderr)
        sys.exit(1)

    # ── 解析 ──
    tlvs = parse_tlv_sequence(data)
    print_dataset_summary(tlvs)

    print()
    if VENDOR_STACK_VERSION_TLV_TYPE in tlvs:
        value = tlvs[VENDOR_STACK_VERSION_TLV_TYPE]
        parsed, err = parse_vendor_stack_version(value)
        if parsed:
            print("=== Vendor Stack Version ===")
            print(f"  OUI:      0x{parsed['OUI']:06X}")
            print(f"  Build:    {parsed['Build']} (0x{parsed['Build']:03X})")
            print(f"  Revision: {parsed['Revision']} (0x{parsed['Revision']:X})")
            print(f"  Minor:    {parsed['Minor']}")
            print(f"  Major:    {parsed['Major']}")
            print(f"  Version:  {format_version(parsed)}")
        else:
            print(f"Parse error: {err}", file=sys.stderr)
            sys.exit(1)
    else:
        print("Vendor Stack Version TLV (type=37) not found in this dataset.")
        sys.exit(1)


if __name__ == "__main__":
    main()
