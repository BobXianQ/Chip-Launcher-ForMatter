#!/bin/bash

# ============================================
# 简单主机名修改脚本 (仅修改两个文件)
# ============================================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查root权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：需要root权限，请使用 sudo ./change_hostname.sh${NC}"
   exit 1
fi

echo -e "${BLUE}当前主机名: ${GREEN}$(hostname)${NC}"
echo ""

# 输入新主机名
read -p "请输入新的主机名: " NEW_HOSTNAME

# 验证非空
if [[ -z "$NEW_HOSTNAME" ]]; then
    echo -e "${RED}错误：主机名不能为空${NC}"
    exit 1
fi

# 验证格式
if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]]; then
    echo -e "${RED}错误：主机名只能包含字母、数字和连字符，且不能以连字符开头或结尾${NC}"
    exit 1
fi

# 确认
echo -e "${YELLOW}即将把主机名改为: ${NEW_HOSTNAME}${NC}"
read -p "确认继续？(y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "已取消"
    exit 0
fi

# 1. 修改 /etc/hostname
echo "$NEW_HOSTNAME" > /etc/hostname
echo -e "${GREEN}✓ 已修改 /etc/hostname${NC}"

# 2. 修改 /etc/hosts 中的 127.0.1.1 条目
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1\s*.*$/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
fi
echo -e "${GREEN}✓ 已修改 /etc/hosts${NC}"

# 3. 立即生效（hostnamectl 同步写入内核，优先使用）
hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || hostname -F /etc/hostname 2>/dev/null
echo -e "${GREEN}✓ hostname 已立即生效${NC}"

# 4. 禁止 cloud-init 重启后覆盖主机名（Ubuntu Raspberry Pi 镜像必须）
CLOUD_CFG="/etc/cloud/cloud.cfg"
CLOUD_CFG_D="/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg"
if [ -d "/etc/cloud/cloud.cfg.d" ]; then
    echo "preserve_hostname: true" > "$CLOUD_CFG_D"
    echo -e "${GREEN}✓ 已写入 $CLOUD_CFG_D（防止重启被 cloud-init 重置）${NC}"
elif [ -f "$CLOUD_CFG" ]; then
    if grep -q "preserve_hostname" "$CLOUD_CFG"; then
        sed -i "s/^\s*preserve_hostname:.*/preserve_hostname: true/" "$CLOUD_CFG"
    else
        sed -i "1s/^/preserve_hostname: true\n/" "$CLOUD_CFG"
    fi
    echo -e "${GREEN}✓ 已更新 $CLOUD_CFG preserve_hostname: true${NC}"
fi

echo -e "${GREEN}✅ 主机名已改为: $(hostname)${NC}"
echo -e "${YELLOW}提示：重启系统后所有服务将完全使用新主机名${NC}"
