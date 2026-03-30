#!/bin/bash
set -euo pipefail

#=============================================================================
# Hysteria2 端口跳跃 (Port Hopping) 一键配置脚本
# 功能：
#   1. 自动检测网卡接口
#   2. 交互式输入端口范围和目标端口
#   3. 配置 iptables 规则（UDP 端口重定向）
#   4. 创建 systemd 服务，确保重启后自动生效
#   5. 验证规则是否成功生效
#   6. 支持卸载（--uninstall）
#=============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_PATH="/root/hy2-port-redirect.sh"
SERVICE_PATH="/etc/systemd/system/hy2-port-redirect.service"

#=============================================================================
# 卸载模式
#=============================================================================
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    echo ""
    echo -e "${YELLOW}正在卸载 Hysteria2 端口跳跃配置...${NC}"

    # 停止并禁用服务 (ExecStop 会自动清理 iptables)
    if systemctl is-active hy2-port-redirect.service &>/dev/null; then
        systemctl stop hy2-port-redirect.service 2>/dev/null || true
        echo "  服务已停止，iptables 规则已自动清除"
    else
        # 服务未运行，手动清理可能残留的规则
        if [ -f "$SCRIPT_PATH" ]; then
            OLD_IFACE=$(grep '^IFACE=' "$SCRIPT_PATH" 2>/dev/null | head -1 | cut -d'"' -f2 || true)
            OLD_START=$(grep '^PORT_START=' "$SCRIPT_PATH" 2>/dev/null | head -1 | cut -d'=' -f2 || true)
            OLD_END=$(grep '^PORT_END=' "$SCRIPT_PATH" 2>/dev/null | head -1 | cut -d'=' -f2 || true)
            OLD_RPORT=$(grep '^REDIRECT_PORT=' "$SCRIPT_PATH" 2>/dev/null | head -1 | cut -d'=' -f2 || true)
            if [ -n "$OLD_IFACE" ] && [ -n "$OLD_START" ] && [ -n "$OLD_END" ] && [ -n "$OLD_RPORT" ]; then
                iptables -t nat -D PREROUTING -i "$OLD_IFACE" -p udp --dport "$OLD_START:$OLD_END" -j REDIRECT --to-ports "$OLD_RPORT" 2>/dev/null || true
                ip6tables -t nat -D PREROUTING -i "$OLD_IFACE" -p udp --dport "$OLD_START:$OLD_END" -j REDIRECT --to-ports "$OLD_RPORT" 2>/dev/null || true
                echo "  iptables 规则已手动清除"
            fi
        fi
    fi

    if systemctl is-enabled hy2-port-redirect.service &>/dev/null; then
        systemctl disable hy2-port-redirect.service 2>/dev/null || true
        echo "  服务已禁用"
    fi

    # 删除文件
    rm -f "$SCRIPT_PATH" "$SERVICE_PATH"
    systemctl daemon-reload 2>/dev/null || true
    echo -e "  ${GREEN}卸载完成${NC}"
    echo ""
    exit 0
fi

echo ""
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}   Hysteria2 端口跳跃 (Port Hopping) 一键配置脚本${NC}"
echo -e "${CYAN}======================================================${NC}"
echo ""

#=============================================================================
# 0. 检查 root 权限
#=============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 用户或 sudo 运行此脚本${NC}"
    exit 1
fi

#=============================================================================
# 检查是否已存在旧配置
#=============================================================================
if [ -f "$SCRIPT_PATH" ] && systemctl is-active hy2-port-redirect.service &>/dev/null; then
    echo -e "${YELLOW}检测到已有端口跳跃配置正在运行:${NC}"
    OLD_IFACE=$(grep '^IFACE=' "$SCRIPT_PATH" 2>/dev/null | head -1 | cut -d'"' -f2 || true)
    OLD_START=$(grep '^PORT_START=' "$SCRIPT_PATH" 2>/dev/null | head -1 | cut -d'=' -f2 || true)
    OLD_END=$(grep '^PORT_END=' "$SCRIPT_PATH" 2>/dev/null | head -1 | cut -d'=' -f2 || true)
    OLD_RPORT=$(grep '^REDIRECT_PORT=' "$SCRIPT_PATH" 2>/dev/null | head -1 | cut -d'=' -f2 || true)
    echo "  网卡: $OLD_IFACE | 跳跃范围: UDP $OLD_START-$OLD_END → $OLD_RPORT"
    echo ""
    read -rp "  是否覆盖旧配置？[y/N]: " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        echo "  已取消。如需卸载旧配置，请运行: $0 --uninstall"
        exit 0
    fi
    # 通过 systemctl stop 触发 ExecStop 清理旧规则
    systemctl stop hy2-port-redirect.service 2>/dev/null || true
    echo -e "  ${GREEN}旧配置已清理${NC}"
    echo ""
fi

#=============================================================================
# 1. 自动检测网卡
#=============================================================================
echo -e "${YELLOW}[步骤 1] 检测网卡接口...${NC}"
echo ""

# 获取默认路由所用的网卡
DEFAULT_IFACE=$(ip route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

# 获取所有活跃的、有 IPv4 地址的非 lo 网卡
mapfile -t ALL_IFACES < <(ip -o link show up | awk -F': ' '{print $2}' | grep -v '^lo$' | sed 's/@.*//')

if [ ${#ALL_IFACES[@]} -eq 0 ]; then
    echo -e "${RED}错误: 未检测到任何活跃的网络接口${NC}"
    exit 1
fi

echo "  检测到以下活跃网卡:"
echo ""
for i in "${!ALL_IFACES[@]}"; do
    iface="${ALL_IFACES[$i]}"
    ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1 || true)
    [ -z "$ip_addr" ] && ip_addr="(无 IPv4 地址)"

    if [ "$iface" = "$DEFAULT_IFACE" ]; then
        echo -e "    ${GREEN}[$((i+1))] $iface  -  $ip_addr  ← 默认路由网卡 (推荐)${NC}"
    else
        echo "    [$((i+1))] $iface  -  $ip_addr"
    fi
done
echo ""

# 让用户选择
if [ ${#ALL_IFACES[@]} -eq 1 ]; then
    SELECTED_IFACE="${ALL_IFACES[0]}"
    echo -e "  只检测到一个网卡，自动选择: ${GREEN}$SELECTED_IFACE${NC}"
else
    DEFAULT_IDX=1
    for i in "${!ALL_IFACES[@]}"; do
        if [ "${ALL_IFACES[$i]}" = "$DEFAULT_IFACE" ]; then
            DEFAULT_IDX=$((i+1))
            break
        fi
    done

    while true; do
        read -rp "  请选择网卡 [1-${#ALL_IFACES[@]}] (直接回车选择默认 $DEFAULT_IDX): " choice
        choice=${choice:-$DEFAULT_IDX}
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#ALL_IFACES[@]} ]; then
            SELECTED_IFACE="${ALL_IFACES[$((choice-1))]}"
            break
        else
            echo -e "  ${RED}无效选择，请重新输入${NC}"
        fi
    done
fi
echo ""
echo -e "  选定网卡: ${GREEN}$SELECTED_IFACE${NC}"
echo ""

#=============================================================================
# 2. 输入端口配置
#=============================================================================
echo -e "${YELLOW}[步骤 2] 配置端口参数...${NC}"
echo ""

# 目标端口 (Hysteria2 监听端口)
while true; do
    read -rp "  请输入 Hysteria2 监听端口 (目标端口) [默认: 43251]: " REDIRECT_PORT
    REDIRECT_PORT=${REDIRECT_PORT:-43251}
    if [[ "$REDIRECT_PORT" =~ ^[0-9]+$ ]] && [ "$REDIRECT_PORT" -ge 1 ] && [ "$REDIRECT_PORT" -le 65535 ]; then
        break
    else
        echo -e "  ${RED}无效端口号，请输入 1-65535 之间的数字${NC}"
    fi
done

# 跳跃端口范围 - 起始端口
while true; do
    read -rp "  请输入跳跃端口范围 - 起始端口 [默认: 20000]: " PORT_START
    PORT_START=${PORT_START:-20000}
    if [[ "$PORT_START" =~ ^[0-9]+$ ]] && [ "$PORT_START" -ge 1 ] && [ "$PORT_START" -le 65535 ]; then
        break
    else
        echo -e "  ${RED}无效端口号，请输入 1-65535 之间的数字${NC}"
    fi
done

# 跳跃端口范围 - 结束端口
while true; do
    read -rp "  请输入跳跃端口范围 - 结束端口 [默认: 42000]: " PORT_END
    PORT_END=${PORT_END:-42000}
    if [[ "$PORT_END" =~ ^[0-9]+$ ]] && [ "$PORT_END" -ge 1 ] && [ "$PORT_END" -le 65535 ] && [ "$PORT_END" -gt "$PORT_START" ]; then
        break
    else
        echo -e "  ${RED}结束端口必须大于起始端口 ($PORT_START)，且不超过 65535${NC}"
    fi
done

# 检查：跳跃范围不能包含目标端口
if [ "$REDIRECT_PORT" -ge "$PORT_START" ] && [ "$REDIRECT_PORT" -le "$PORT_END" ]; then
    echo ""
    echo -e "  ${RED}⚠ 错误: 目标端口 $REDIRECT_PORT 在跳跃范围 $PORT_START-$PORT_END 内！${NC}"
    echo -e "  ${RED}  这会导致循环转发。目标端口必须在跳跃范围之外。${NC}"
    exit 1
fi

echo ""
echo -e "  ${CYAN}配置确认:${NC}"
echo -e "    网卡接口:     ${GREEN}$SELECTED_IFACE${NC}"
echo -e "    跳跃端口范围: ${GREEN}$PORT_START - $PORT_END${NC} (UDP)"
echo -e "    目标端口:     ${GREEN}$REDIRECT_PORT${NC}"
echo ""

read -rp "  确认以上配置？[Y/n]: " confirm
confirm=${confirm:-Y}
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "  已取消操作。"
    exit 0
fi
echo ""

#=============================================================================
# 3. 创建 iptables 重定向脚本 (支持 add/remove 参数)
#=============================================================================
echo -e "${YELLOW}[步骤 3] 创建 iptables 规则脚本...${NC}"

if [ -f "$SCRIPT_PATH" ]; then
    BACKUP="${SCRIPT_PATH}.bak.$(date +%s)"
    cp "$SCRIPT_PATH" "$BACKUP"
    echo "  已备份旧脚本: $BACKUP"
fi

cat > "$SCRIPT_PATH" <<'OUTER_EOF'
#!/bin/bash

# ====== 配置 (由安装脚本自动生成) ======
IFACE="__IFACE__"
PORT_START=__PORT_START__
PORT_END=__PORT_END__
REDIRECT_PORT=__REDIRECT_PORT__
# ========================================

LOG_TAG="hy2-port-redirect"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    logger -t "$LOG_TAG" "$1" 2>/dev/null || true
}

ACTION="${1:-add}"

# 确保 iptables 可用
if ! command -v iptables &>/dev/null; then
    log "错误: iptables 未安装"
    exit 1
fi

# 检查网卡是否存在，不存在则自动回退到默认路由网卡
if ! ip link show "$IFACE" &>/dev/null; then
    log "警告: 网卡 $IFACE 不存在，尝试自动检测..."
    DETECTED=$(ip route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    if [ -z "$DETECTED" ]; then
        log "错误: 无法检测到默认网卡"
        exit 1
    fi
    IFACE="$DETECTED"
    log "自动回退到网卡: $IFACE"
fi

add_rules() {
    # IPv4
    local exist_v4
    exist_v4=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -- "-i $IFACE.*--dport $PORT_START:$PORT_END.*--to-ports $REDIRECT_PORT" || true)
    if [ -z "$exist_v4" ]; then
        iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport "$PORT_START:$PORT_END" -j REDIRECT --to-ports "$REDIRECT_PORT"
        log "✅ IPv4 规则已添加: $IFACE UDP $PORT_START:$PORT_END → $REDIRECT_PORT"
    else
        log "ℹ️  IPv4 规则已存在，跳过"
    fi

    # IPv6 (仅在 ip6tables 可用时)
    if command -v ip6tables &>/dev/null; then
        local exist_v6
        exist_v6=$(ip6tables -t nat -S PREROUTING 2>/dev/null | grep -- "-i $IFACE.*--dport $PORT_START:$PORT_END.*--to-ports $REDIRECT_PORT" || true)
        if [ -z "$exist_v6" ]; then
            ip6tables -t nat -A PREROUTING -i "$IFACE" -p udp --dport "$PORT_START:$PORT_END" -j REDIRECT --to-ports "$REDIRECT_PORT"
            log "✅ IPv6 规则已添加: $IFACE UDP $PORT_START:$PORT_END → $REDIRECT_PORT"
        else
            log "ℹ️  IPv6 规则已存在，跳过"
        fi
    fi
}

remove_rules() {
    # 循环删除，防止有多条重复规则
    local removed=0
    while iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport "$PORT_START:$PORT_END" -j REDIRECT --to-ports "$REDIRECT_PORT" 2>/dev/null; do
        removed=$((removed + 1))
    done
    if [ "$removed" -gt 0 ]; then
        log "IPv4: 已移除 $removed 条规则"
    else
        log "IPv4: 无规则需要移除"
    fi

    if command -v ip6tables &>/dev/null; then
        removed=0
        while ip6tables -t nat -D PREROUTING -i "$IFACE" -p udp --dport "$PORT_START:$PORT_END" -j REDIRECT --to-ports "$REDIRECT_PORT" 2>/dev/null; do
            removed=$((removed + 1))
        done
        if [ "$removed" -gt 0 ]; then
            log "IPv6: 已移除 $removed 条规则"
        fi
    fi
}

case "$ACTION" in
    add|start)
        add_rules
        ;;
    remove|stop)
        remove_rules
        ;;
    *)
        echo "用法: $0 {add|remove}"
        exit 1
        ;;
esac

# 显示当前规则状态
log "--- 当前 IPv4 NAT PREROUTING REDIRECT 规则 ---"
iptables -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null | grep -E "REDIRECT|Chain" || log "(无 REDIRECT 规则)"
OUTER_EOF

# 替换占位符
sed -i "s|__IFACE__|$SELECTED_IFACE|g" "$SCRIPT_PATH"
sed -i "s|__PORT_START__|$PORT_START|g" "$SCRIPT_PATH"
sed -i "s|__PORT_END__|$PORT_END|g" "$SCRIPT_PATH"
sed -i "s|__REDIRECT_PORT__|$REDIRECT_PORT|g" "$SCRIPT_PATH"

chmod +x "$SCRIPT_PATH"
echo -e "  脚本已创建: ${GREEN}$SCRIPT_PATH${NC}"
echo ""

#=============================================================================
# 4. 创建 systemd 服务 (带 ExecStop 自动清理)
#=============================================================================
echo -e "${YELLOW}[步骤 4] 创建 systemd 开机启动服务...${NC}"

if [ -f "$SERVICE_PATH" ]; then
    BACKUP="${SERVICE_PATH}.bak.$(date +%s)"
    cp "$SERVICE_PATH" "$BACKUP"
    echo "  已备份旧服务文件: $BACKUP"
fi

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Hysteria2 Port Hopping - iptables UDP redirect ($PORT_START:$PORT_END -> $REDIRECT_PORT)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_PATH add
ExecStop=$SCRIPT_PATH remove

[Install]
WantedBy=multi-user.target
EOF

echo -e "  服务文件已创建: ${GREEN}$SERVICE_PATH${NC}"
echo ""

#=============================================================================
# 5. 启用并启动服务
#=============================================================================
echo -e "${YELLOW}[步骤 5] 启用并启动服务...${NC}"

systemctl daemon-reload
echo "  systemd 配置已重新加载"

systemctl enable hy2-port-redirect.service 2>/dev/null
echo "  服务已设置为开机自启"

if systemctl start hy2-port-redirect.service; then
    echo -e "  ${GREEN}服务启动成功${NC}"
else
    echo -e "  ${RED}服务启动失败，查看详情:${NC}"
    systemctl status hy2-port-redirect.service --no-pager
    exit 1
fi
echo ""

#=============================================================================
# 6. 最终验证
#=============================================================================
echo -e "${YELLOW}[步骤 6] 验证规则是否生效...${NC}"
echo ""

sleep 1

echo "  IPv4 NAT PREROUTING 规则:"
RULE_OUTPUT=$(iptables -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null || true)
if echo "$RULE_OUTPUT" | grep -q "REDIRECT.*dpts:$PORT_START:$PORT_END.*redir ports $REDIRECT_PORT"; then
    echo "$RULE_OUTPUT" | grep -E "REDIRECT|num" | head -5 | sed 's/^/    /'
    echo ""
    echo -e "  ${GREEN}✅ IPv4 端口跳跃规则已生效！${NC}"
else
    echo -e "  ${RED}❌ 未检测到 IPv4 端口跳跃规则${NC}"
    echo "  调试信息:"
    echo "$RULE_OUTPUT" | sed 's/^/    /'
fi

echo ""

if command -v ip6tables &>/dev/null; then
    RULE6_OUTPUT=$(ip6tables -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null || true)
    if echo "$RULE6_OUTPUT" | grep -q "REDIRECT.*dpts:$PORT_START:$PORT_END.*redir ports $REDIRECT_PORT"; then
        echo -e "  ${GREEN}✅ IPv6 端口跳跃规则已生效！${NC}"
    else
        echo -e "  ${YELLOW}ℹ️  IPv6 规则未检测到 (可能无 IPv6 环境，不影响使用)${NC}"
    fi
fi

echo ""
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}   配置完成！${NC}"
echo -e "${CYAN}======================================================${NC}"
echo ""
echo -e "  网卡:       ${GREEN}$SELECTED_IFACE${NC}"
echo -e "  跳跃范围:   ${GREEN}UDP $PORT_START - $PORT_END${NC}"
echo -e "  目标端口:   ${GREEN}$REDIRECT_PORT${NC}"
echo -e "  开机自启:   ${GREEN}已启用${NC}"
echo ""
echo -e "  ${CYAN}常用命令:${NC}"
echo "    查看状态:      systemctl status hy2-port-redirect"
echo "    查看规则:      iptables -t nat -L PREROUTING -n -v --line-numbers"
echo "    重启服务:      systemctl restart hy2-port-redirect"
echo "    停止 (清除规则): systemctl stop hy2-port-redirect"
echo "    卸载全部:      $0 --uninstall"
echo ""
echo -e "  ${CYAN}客户端 OpenClash 配置参考:${NC}"
echo "    port: $REDIRECT_PORT"
echo "    ports: $PORT_START-$PORT_END"
echo ""
