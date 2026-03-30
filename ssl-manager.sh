#!/bin/bash

# ============================================================
#  SSL 证书管理工具 v2.0
#  基于 acme.sh，支持 Cloudflare / 阿里云 / 腾讯云 DNS API
#  适用于小内存 VPS，零常驻进程，自动续期
# ============================================================

set -o pipefail

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- 全局配置 ---
ACME_HOME="${HOME}/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
ACME_CONF="${ACME_HOME}/account.conf"
DEFAULT_CERT_BASE="/etc/ssl/acme"
LOG_FILE="/tmp/ssl-manager-$(date +%Y%m%d%H%M%S).log"

# --- 基础工具函数 ---
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║         SSL 证书管理工具 v2.0                 ║"
    echo "  ║         acme.sh + DNS API 自动化              ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

info()    { echo -e "  ${BLUE}[信息]${NC} $1"; }
ok()      { echo -e "  ${GREEN}[ OK ]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[警告]${NC} $1"; }
err()     { echo -e "  ${RED}[错误]${NC} $1"; }
dim()     { echo -e "  ${DIM}$1${NC}"; }

confirm() {
    local prompt="$1 [y/N]: "
    local answer
    read -r -p "  $prompt" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

press_enter() {
    echo ""
    read -r -p "  按 Enter 键继续..." _
}

# 写日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 检查命令是否存在
require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        err "$1 未安装，请先安装: $2"
        return 1
    fi
    return 0
}

# 检查网络连通性
check_network() {
    if ! curl -sS --max-time 5 -o /dev/null https://acme-v02.api.letsencrypt.org/directory 2>/dev/null; then
        err "无法连接到 Let's Encrypt，请检查网络"
        dim "尝试: curl -I https://acme-v02.api.letsencrypt.org/directory"
        return 1
    fi
    return 0
}

# 验证域名格式
validate_domain() {
    local domain="$1"
    # 去掉通配符前缀再验证
    domain="${domain#\*.}"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        err "域名格式无效: $domain"
        return 1
    fi
    return 0
}

# ============================================================
#  acme.sh 安装与管理
# ============================================================

check_acme_installed() {
    [ -f "$ACME_BIN" ] && [ -x "$ACME_BIN" ]
}

get_acme_version() {
    if check_acme_installed; then
        "$ACME_BIN" --version 2>&1 | grep -oP 'v[\d.]+' | head -1
    fi
}

install_acme() {
    info "正在安装 acme.sh ..."
    echo ""

    read -r -p "  请输入你的邮箱 (用于证书通知，可随意填): " user_email
    user_email="${user_email:-admin@example.com}"

    curl -fsSL https://get.acme.sh | sh -s email="$user_email" 2>&1 | tee -a "$LOG_FILE"

    if [ ${PIPESTATUS[0]} -eq 0 ] && [ -f "$ACME_BIN" ]; then
        source "$ACME_HOME/acme.sh.env" 2>/dev/null
        ok "acme.sh 安装完成"
        log "acme.sh installed successfully"
        return 0
    else
        err "acme.sh 安装失败"
        err "日志: $LOG_FILE"
        log "acme.sh installation FAILED"
        return 1
    fi
}

upgrade_acme() {
    info "正在升级 acme.sh ..."
    "$ACME_BIN" --upgrade 2>&1 | tee -a "$LOG_FILE"
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        ok "升级完成: $(get_acme_version)"
    else
        err "升级失败，请检查网络"
    fi
}

# ============================================================
#  DNS API 配置（支持多家）
# ============================================================

# 获取当前已配置的 DNS 提供商
get_configured_dns() {
    if [ ! -f "$ACME_CONF" ]; then
        echo "none"
        return
    fi
    if grep -q "SAVED_CF_Token\|SAVED_CF_Key" "$ACME_CONF" 2>/dev/null; then
        echo "cloudflare"
    elif grep -q "SAVED_Ali_Key" "$ACME_CONF" 2>/dev/null; then
        echo "aliyun"
    elif grep -q "SAVED_DP_Id" "$ACME_CONF" 2>/dev/null; then
        echo "dnspod"
    else
        echo "none"
    fi
}

get_dns_provider_name() {
    case "$1" in
        cloudflare) echo "Cloudflare" ;;
        aliyun)     echo "阿里云 DNS" ;;
        dnspod)     echo "腾讯云 DNSPod" ;;
        *)          echo "未配置" ;;
    esac
}

get_dns_hook() {
    case "$1" in
        cloudflare) echo "dns_cf" ;;
        aliyun)     echo "dns_ali" ;;
        dnspod)     echo "dns_dp" ;;
        *)          echo "" ;;
    esac
}

setup_dns_provider() {
    echo ""
    echo -e "  ${BOLD}── DNS API 配置 ──${NC}"
    echo ""

    local current=$(get_configured_dns)
    if [ "$current" != "none" ]; then
        ok "当前已配置: $(get_dns_provider_name "$current")"
        echo ""
        if ! confirm "是否重新配置？"; then
            return 0
        fi
    fi

    echo ""
    echo "  请选择你的 DNS 服务商："
    echo ""
    echo "  1) Cloudflare"
    echo "  2) 阿里云 DNS"
    echo "  3) 腾讯云 DNSPod"
    echo ""
    read -r -p "  请选择 [1-3]: " dns_choice

    case "$dns_choice" in
        1) setup_cloudflare ;;
        2) setup_aliyun ;;
        3) setup_dnspod ;;
        *) err "无效选项"; return 1 ;;
    esac
}

setup_cloudflare() {
    echo ""
    echo -e "  ${BOLD}Cloudflare 认证方式选择：${NC}"
    echo ""
    echo "  1) API Token      ${DIM}(推荐，权限更精细)${NC}"
    echo "  2) Global API Key  ${DIM}(和 x-ui 一样的方式，需要邮箱 + Key)${NC}"
    echo ""
    read -r -p "  请选择 [1-2] (默认 1): " cf_auth_type

    case "$cf_auth_type" in
        2)  setup_cloudflare_global_key ;;
        *)  setup_cloudflare_api_token ;;
    esac
}

setup_cloudflare_api_token() {
    echo ""
    info "Cloudflare API Token 获取方式:"
    dim "1. 打开 https://dash.cloudflare.com/profile/api-tokens"
    dim "2. 点击 Create Token"
    dim "3. 选择模板 \"Edit zone DNS\""
    dim "4. Zone Resources 选择你的域名（或 All zones）"
    dim "5. 创建后复制 Token"
    echo ""

    read -r -p "  请输入 Cloudflare API Token: " cf_token
    cf_token=$(echo "$cf_token" | xargs)

    if [ -z "$cf_token" ]; then
        err "Token 不能为空"
        return 1
    fi

    if [ ${#cf_token} -lt 20 ]; then
        err "Token 长度异常，请检查是否复制完整"
        return 1
    fi

    # 验证 Token 是否有效
    info "正在验证 Token ..."
    local verify_result
    verify_result=$(curl -sS -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $cf_token" \
        -H "Content-Type: application/json" 2>&1)

    if echo "$verify_result" | grep -q '"success":true'; then
        ok "Token 验证通过"
    else
        err "Token 验证失败，请检查 Token 是否正确且有 DNS 编辑权限"
        dim "API 返回: $(echo "$verify_result" | grep -o '"message":"[^"]*"' | head -1)"
        if ! confirm "仍然要保存此 Token 吗？（不推荐）"; then
            return 1
        fi
    fi

    export CF_Token="$cf_token"
    export CF_Zone_ID=""

    # 写入 acme.sh 配置
    if [ -f "$ACME_CONF" ]; then
        sed -i '/^SAVED_CF_Token=/d' "$ACME_CONF"
        sed -i '/^SAVED_CF_Zone_ID=/d' "$ACME_CONF"
        sed -i '/^SAVED_CF_Key=/d' "$ACME_CONF"
        sed -i '/^SAVED_CF_Email=/d' "$ACME_CONF"
    fi
    echo "SAVED_CF_Token='$cf_token'" >> "$ACME_CONF"

    ok "Cloudflare API Token 配置已保存"
    log "Cloudflare DNS configured (API Token)"
    return 0
}

setup_cloudflare_global_key() {
    echo ""
    info "Cloudflare Global API Key 获取方式 (和 x-ui 相同):"
    dim "1. 打开 https://dash.cloudflare.com/profile/api-tokens"
    dim "2. 在页面下方找到 Global API Key，点击 View"
    dim "3. 复制 Key"
    echo ""

    read -r -p "  请输入 Cloudflare 注册邮箱: " cf_email
    cf_email=$(echo "$cf_email" | xargs)
    if [ -z "$cf_email" ]; then
        err "邮箱不能为空"
        return 1
    fi

    read -r -p "  请输入 Global API Key: " cf_key
    cf_key=$(echo "$cf_key" | xargs)
    if [ -z "$cf_key" ]; then
        err "Key 不能为空"
        return 1
    fi

    # 验证 Key 是否有效
    info "正在验证 Global API Key ..."
    local verify_result
    verify_result=$(curl -sS -X GET "https://api.cloudflare.com/client/v4/user" \
        -H "X-Auth-Email: $cf_email" \
        -H "X-Auth-Key: $cf_key" \
        -H "Content-Type: application/json" 2>&1)

    if echo "$verify_result" | grep -q '"success":true'; then
        ok "Global API Key 验证通过"
    else
        err "验证失败，请检查邮箱和 Key 是否正确"
        dim "API 返回: $(echo "$verify_result" | grep -o '"message":"[^"]*"' | head -1)"
        if ! confirm "仍然要保存吗？（不推荐）"; then
            return 1
        fi
    fi

    export CF_Key="$cf_key"
    export CF_Email="$cf_email"

    # 写入 acme.sh 配置
    if [ -f "$ACME_CONF" ]; then
        sed -i '/^SAVED_CF_Token=/d' "$ACME_CONF"
        sed -i '/^SAVED_CF_Key=/d' "$ACME_CONF"
        sed -i '/^SAVED_CF_Email=/d' "$ACME_CONF"
    fi
    echo "SAVED_CF_Key='$cf_key'" >> "$ACME_CONF"
    echo "SAVED_CF_Email='$cf_email'" >> "$ACME_CONF"

    ok "Cloudflare Global API Key 配置已保存"
    log "Cloudflare DNS configured (Global API Key)"
    return 0
}

setup_aliyun() {
    echo ""
    info "阿里云 AccessKey 获取方式:"
    dim "1. 打开 https://ram.console.aliyun.com/manage/ak"
    dim "2. 创建 AccessKey（建议使用 RAM 子账号，仅授予 DNS 权限）"
    echo ""

    read -r -p "  请输入 Ali_Key (AccessKey ID): " ali_key
    read -r -p "  请输入 Ali_Secret (AccessKey Secret): " ali_secret

    ali_key=$(echo "$ali_key" | xargs)
    ali_secret=$(echo "$ali_secret" | xargs)

    if [ -z "$ali_key" ] || [ -z "$ali_secret" ]; then
        err "Key 和 Secret 都不能为空"
        return 1
    fi

    export Ali_Key="$ali_key"
    export Ali_Secret="$ali_secret"

    if [ -f "$ACME_CONF" ]; then
        sed -i '/^SAVED_Ali_Key=/d' "$ACME_CONF"
        sed -i '/^SAVED_Ali_Secret=/d' "$ACME_CONF"
    fi
    echo "SAVED_Ali_Key='$ali_key'" >> "$ACME_CONF"
    echo "SAVED_Ali_Secret='$ali_secret'" >> "$ACME_CONF"

    ok "阿里云 DNS 配置已保存"
    log "Aliyun DNS configured"
    return 0
}

setup_dnspod() {
    echo ""
    info "腾讯云 DNSPod Token 获取方式:"
    dim "1. 打开 https://console.dnspod.cn/account/token/token"
    dim "2. 创建 API Token"
    echo ""

    read -r -p "  请输入 DP_Id (Token ID): " dp_id
    read -r -p "  请输入 DP_Key (Token): " dp_key

    dp_id=$(echo "$dp_id" | xargs)
    dp_key=$(echo "$dp_key" | xargs)

    if [ -z "$dp_id" ] || [ -z "$dp_key" ]; then
        err "ID 和 Key 都不能为空"
        return 1
    fi

    export DP_Id="$dp_id"
    export DP_Key="$dp_key"

    if [ -f "$ACME_CONF" ]; then
        sed -i '/^SAVED_DP_Id=/d' "$ACME_CONF"
        sed -i '/^SAVED_DP_Key=/d' "$ACME_CONF"
    fi
    echo "SAVED_DP_Id='$dp_id'" >> "$ACME_CONF"
    echo "SAVED_DP_Key='$dp_key'" >> "$ACME_CONF"

    ok "腾讯云 DNSPod 配置已保存"
    log "DNSPod DNS configured"
    return 0
}

# ============================================================
#  证书存放路径管理
# ============================================================

# 让用户选择证书安装路径
# 注意：菜单输出到 stderr，只有最终路径输出到 stdout
choose_cert_install_dir() {
    local domain="$1"

    echo "" >&2
    echo -e "  ${BOLD}证书安装路径选择：${NC}" >&2
    echo "" >&2
    echo -e "  1) x-ui 平铺    ${DIM}/root/cert/  (privkey.pem + fullchain.pem 直接放这里)${NC}" >&2
    echo -e "  2) 3x-ui 子目录 ${DIM}/root/cert/${domain}/${NC}" >&2
    echo -e "  3) Nginx 路径   ${DIM}/etc/nginx/ssl/${domain}/${NC}" >&2
    echo -e "  4) 默认路径     ${DIM}${DEFAULT_CERT_BASE}/${domain}/${NC}" >&2
    echo -e "  5) 自定义路径" >&2
    echo "" >&2
    read -r -p "  请选择 [1-5] (默认 1): " path_choice

    local install_dir
    case "$path_choice" in
        2)  install_dir="/root/cert/${domain}" ;;
        3)  install_dir="/etc/nginx/ssl/${domain}" ;;
        4)  install_dir="${DEFAULT_CERT_BASE}/${domain}" ;;
        5)
            read -r -p "  请输入完整路径: " install_dir
            install_dir=$(echo "$install_dir" | xargs)
            if [ -z "$install_dir" ]; then
                install_dir="/root/cert"
                warn "路径为空，使用默认 /root/cert/" >&2
            fi
            ;;
        *)  install_dir="/root/cert" ;;
    esac

    # 创建目录
    if ! mkdir -p "$install_dir" 2>/dev/null; then
        err "无法创建目录: $install_dir" >&2
        err "请检查权限或路径是否合法" >&2
        return 1
    fi

    # 检查目录可写
    if ! touch "$install_dir/.write_test" 2>/dev/null; then
        err "目录不可写: $install_dir" >&2
        rm -f "$install_dir/.write_test" 2>/dev/null
        return 1
    fi
    rm -f "$install_dir/.write_test" 2>/dev/null

    echo "$install_dir"
    return 0
}

# ============================================================
#  核心功能：申请证书
# ============================================================

# 查找 acme.sh 内已存在的同域名证书
find_existing_cert() {
    local domain="$1"
    # acme.sh --list 输出中查找（精确匹配主域名列）
    "$ACME_BIN" --list 2>/dev/null | awk -v d="$domain" 'NR>1 && $1==d'
}

# 查找同一根域名下的所有证书
find_related_certs() {
    local domain="$1"
    # 提取根域名（最后两段，如 g00dwill.top）
    local root_domain
    root_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    "$ACME_BIN" --list 2>/dev/null | awk -v r="$root_domain" 'NR>1 && index($0, r)'
}

issue_cert() {
    echo ""
    echo -e "  ${BOLD}── 申请新证书 ──${NC}"
    echo ""

    # 前置检查：DNS 是否已配置
    local dns_provider
    dns_provider=$(get_configured_dns)
    if [ "$dns_provider" = "none" ]; then
        err "尚未配置 DNS API，请先配置"
        echo ""
        if confirm "现在去配置？"; then
            setup_dns_provider
            dns_provider=$(get_configured_dns)
            if [ "$dns_provider" = "none" ]; then
                return 1
            fi
        else
            return 1
        fi
    fi

    local dns_hook
    dns_hook=$(get_dns_hook "$dns_provider")
    info "当前 DNS 服务商: $(get_dns_provider_name "$dns_provider")"

    # 前置检查：网络
    if ! check_network; then
        return 1
    fi

    # 输入域名
    echo ""
    echo -e "  ${BOLD}请选择证书类型：${NC}"
    echo ""
    echo "  1) 顶级域名 + 泛域名  (如 example.com + *.example.com)"
    echo "  2) 仅顶级域名          (如 example.com)"
    echo "  3) 子域名 + 泛子域名   (如 sub.example.com + *.sub.example.com)"
    echo "  4) 仅子域名             (如 sub.example.com)"
    echo "  5) 自定义多域名组合"
    echo ""
    read -r -p "  请选择 [1-5]: " cert_type

    local domains=()
    local cert_id=""  # 证书标识（acme.sh 用第一个域名作为标识）

    case "$cert_type" in
        1)
            read -r -p "  请输入顶级域名 (如 example.com): " input_domain
            input_domain=$(echo "$input_domain" | xargs | tr 'A-Z' 'a-z')
            if ! validate_domain "$input_domain"; then return 1; fi
            domains=("$input_domain" "*.$input_domain")
            cert_id="$input_domain"
            ;;
        2)
            read -r -p "  请输入域名 (如 example.com): " input_domain
            input_domain=$(echo "$input_domain" | xargs | tr 'A-Z' 'a-z')
            if ! validate_domain "$input_domain"; then return 1; fi
            domains=("$input_domain")
            cert_id="$input_domain"
            ;;
        3)
            read -r -p "  请输入子域名 (如 awsjp.example.com): " input_domain
            input_domain=$(echo "$input_domain" | xargs | tr 'A-Z' 'a-z')
            if ! validate_domain "$input_domain"; then return 1; fi
            domains=("$input_domain" "*.$input_domain")
            cert_id="$input_domain"
            ;;
        4)
            read -r -p "  请输入子域名 (如 awsjp.example.com): " input_domain
            input_domain=$(echo "$input_domain" | xargs | tr 'A-Z' 'a-z')
            if ! validate_domain "$input_domain"; then return 1; fi
            domains=("$input_domain")
            cert_id="$input_domain"
            ;;
        5)
            echo ""
            echo "  请逐个输入域名，输入空行结束:"
            dim "  支持通配符，如 *.example.com"
            echo ""
            while true; do
                read -r -p "  添加域名 (回车结束): " d
                d=$(echo "$d" | xargs | tr 'A-Z' 'a-z')
                [ -z "$d" ] && break
                # 通配符域名只验证去掉 *. 后的部分
                local check_d="${d#\*.}"
                if ! validate_domain "$check_d"; then
                    continue
                fi
                domains+=("$d")
                ok "已添加: $d"
            done
            if [ ${#domains[@]} -eq 0 ]; then
                err "至少需要一个域名"
                return 1
            fi
            cert_id="${domains[0]}"
            ;;
        *)
            err "无效选项"
            return 1
            ;;
    esac

    # --- 边界条件：检查是否已存在完全相同的证书 ---
    local exist_action=""
    echo ""
    local existing
    existing=$(find_existing_cert "$cert_id")
    if [ -n "$existing" ]; then
        warn "检测到已存在相同主域名的证书:"
        echo ""
        echo -e "    ${YELLOW}${existing}${NC}"
        echo ""
        echo "  请选择操作："
        echo "  1) 强制重新申请（覆盖旧证书）"
        echo "  2) 仅续期现有证书"
        echo "  3) 取消"
        echo ""
        read -r -p "  请选择 [1-3]: " exist_action
        case "$exist_action" in
            1)  info "将强制重新申请" ;;
            2)
                info "正在续期 ${cert_id} ..."
                # 检测是 ECC 还是 RSA
                if [ -d "$ACME_HOME/${cert_id}_ecc" ]; then
                    "$ACME_BIN" --renew -d "$cert_id" --ecc --force 2>&1 | tee -a "$LOG_FILE"
                else
                    "$ACME_BIN" --renew -d "$cert_id" --force 2>&1 | tee -a "$LOG_FILE"
                fi
                return $?
                ;;
            *)
                warn "已取消"
                return 0
                ;;
        esac
    fi

    # --- 边界条件：检查同根域名下的其他证书（仅提示，不阻止）---
    local related
    related=$(find_related_certs "$cert_id")
    if [ -n "$related" ]; then
        echo ""
        info "同根域名下已有以下证书（不影响本次申请）:"
        echo ""
        echo "$related" | while IFS= read -r line; do
            dim "  $line"
        done
        echo ""
        dim "  acme.sh 和 Let's Encrypt 均允许同一域名签发多张证书，互不冲突"
        echo ""
    fi

    # 选择证书安装路径
    local install_dir
    install_dir=$(choose_cert_install_dir "$cert_id")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # 检查目标路径是否已有证书文件
    if [ -f "$install_dir/fullchain.pem" ] || [ -f "$install_dir/privkey.pem" ]; then
        warn "目标路径已有证书文件:"
        [ -f "$install_dir/fullchain.pem" ] && dim "  $install_dir/fullchain.pem"
        [ -f "$install_dir/privkey.pem" ]   && dim "  $install_dir/privkey.pem"
        echo ""
        if ! confirm "是否覆盖？"; then
            warn "已取消"
            return 0
        fi
    fi

    # 选择 CA
    echo ""
    echo -e "  ${BOLD}选择证书颁发机构：${NC}"
    echo ""
    echo "  1) Let's Encrypt  ${DIM}(默认，最广泛使用)${NC}"
    echo "  2) ZeroSSL        ${DIM}(不限制速率)${NC}"
    echo "  3) Buypass        ${DIM}(挪威 CA)${NC}"
    echo ""
    read -r -p "  请选择 [1-3] (默认 1): " ca_choice

    local ca_args=""
    local ca_name=""
    case "$ca_choice" in
        2)  ca_args="--server zerossl"; ca_name="ZeroSSL" ;;
        3)  ca_args="--server buypass"; ca_name="Buypass" ;;
        *)  ca_args="--server letsencrypt"; ca_name="Let's Encrypt" ;;
    esac

    # 选择密钥类型
    echo ""
    echo -e "  ${BOLD}选择密钥类型：${NC}"
    echo ""
    echo "  1) ECC P-256  ${DIM}(默认，更快更安全，推荐)${NC}"
    echo "  2) RSA 2048   ${DIM}(兼容性更好，老设备支持)${NC}"
    echo ""
    read -r -p "  请选择 [1-2] (默认 1): " key_choice

    local key_args=""
    local ecc_flag="--ecc"
    case "$key_choice" in
        2)  key_args="--keylength 2048"; ecc_flag="" ;;
        *)  key_args="--keylength ec-256"; ecc_flag="--ecc" ;;
    esac

    # 选择续期后 reload 命令
    echo ""
    local reload_cmd=""
    if confirm "是否配置证书续期后自动重载服务？"; then
        echo ""
        echo "  请选择你的服务："
        echo "  1) Nginx              ${DIM}(systemctl reload nginx)${NC}"
        echo "  2) x-ui / 3x-ui       ${DIM}(x-ui restart)${NC}"
        echo "  3) Apache             ${DIM}(systemctl reload apache2)${NC}"
        echo "  4) 自定义命令"
        echo "  5) 不配置"
        echo ""
        read -r -p "  请选择 [1-5]: " svc_choice
        case "$svc_choice" in
            1)
                if command -v nginx &>/dev/null; then
                    reload_cmd="systemctl reload nginx"
                else
                    warn "nginx 未检测到，仍然配置？"
                    if confirm "继续？"; then
                        reload_cmd="systemctl reload nginx"
                    fi
                fi
                ;;
            2)
                # 自动检测 x-ui 或 3x-ui
                if command -v x-ui &>/dev/null; then
                    reload_cmd="x-ui restart"
                elif command -v 3x-ui &>/dev/null; then
                    reload_cmd="3x-ui restart"
                elif systemctl list-units --type=service 2>/dev/null | grep -q "x-ui"; then
                    reload_cmd="systemctl restart x-ui"
                else
                    warn "未检测到 x-ui，请输入正确的重启命令"
                    read -r -p "  重启命令: " reload_cmd
                fi
                ;;
            3)  reload_cmd="systemctl reload apache2" ;;
            4)
                read -r -p "  请输入自定义 reload 命令: " reload_cmd
                ;;
            *)  reload_cmd="" ;;
        esac
    fi

    # --- 确认摘要 ---
    echo ""
    echo -e "  ${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}║         申请确认                     ║${NC}"
    echo -e "  ${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  域名:       ${GREEN}${domains[*]}${NC}"
    echo -e "  CA:         ${GREEN}${ca_name}${NC}"
    echo -e "  密钥:       ${GREEN}$([ -n "$ecc_flag" ] && echo 'ECC P-256' || echo 'RSA 2048')${NC}"
    echo -e "  DNS 验证:   ${GREEN}$(get_dns_provider_name "$dns_provider")${NC}"
    echo -e "  证书路径:   ${GREEN}${install_dir}/${NC}"
    [ -n "$reload_cmd" ] && \
    echo -e "  续期 Reload: ${GREEN}${reload_cmd}${NC}"
    echo ""

    if ! confirm "确认申请？"; then
        warn "已取消"
        return 0
    fi

    # --- 构建并执行申请命令 ---
    # 构建域名参数数组（正确处理通配符）
    local -a issue_cmd=("$ACME_BIN" "--issue")
    for d in "${domains[@]}"; do
        issue_cmd+=("-d" "$d")
    done
    issue_cmd+=("--dns" "$dns_hook")
    [ -n "$ca_args" ] && issue_cmd+=($ca_args)
    [ -n "$key_args" ] && issue_cmd+=($key_args)

    local force_flag=""
    if [ "$exist_action" = "1" ]; then
        force_flag="--force"
        issue_cmd+=("--force")
    fi

    echo ""
    info "正在申请证书..."
    dim "命令: acme.sh --issue -d ${domains[*]} --dns $dns_hook $ca_args $key_args $force_flag"
    echo ""

    log "Issuing cert: domains=${domains[*]}, ca=$ca_name, dns=$dns_provider"

    "${issue_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
    local issue_result=${PIPESTATUS[0]}

    if [ $issue_result -ne 0 ]; then
        echo ""
        err "证书申请失败！"
        echo ""
        # 智能错误诊断
        local last_log
        last_log=$(tail -20 "$LOG_FILE" 2>/dev/null)
        if echo "$last_log" | grep -qi "rate limit"; then
            err "触发了 Let's Encrypt 速率限制"
            dim "  同一域名每周最多申请 5 张证书"
            dim "  建议：等待一周后重试，或切换到 ZeroSSL (主菜单选 7)"
        elif echo "$last_log" | grep -qi "timeout\|timed out"; then
            err "DNS 验证超时"
            dim "  可能原因: DNS API 权限不足，或 DNS 传播慢"
            dim "  建议：检查 Token 权限，确保域名 DNS 在当前服务商"
        elif echo "$last_log" | grep -qi "invalid\|unauthorized"; then
            err "DNS API 认证失败"
            dim "  建议：重新配置 DNS API Token（主菜单选 6）"
        elif echo "$last_log" | grep -qi "NXDOMAIN\|not found"; then
            err "域名 DNS 记录未找到"
            dim "  请确认域名已在 $(get_dns_provider_name "$dns_provider") 托管"
        fi
        dim "  完整日志: $LOG_FILE"
        log "Certificate issuance FAILED for ${domains[*]}"
        return 1
    fi

    # --- 安装证书到指定路径 ---
    echo ""
    info "正在安装证书到 $install_dir/ ..."

    local -a inst_cmd=("$ACME_BIN" "--install-cert" "-d" "$cert_id")
    inst_cmd+=("--key-file" "$install_dir/privkey.pem")
    inst_cmd+=("--fullchain-file" "$install_dir/fullchain.pem")
    inst_cmd+=("--cert-file" "$install_dir/cert.pem")
    inst_cmd+=("--ca-file" "$install_dir/ca.pem")
    [ -n "$ecc_flag" ] && inst_cmd+=("--ecc")
    [ -n "$reload_cmd" ] && inst_cmd+=("--reloadcmd" "$reload_cmd")

    "${inst_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo ""
        ok "证书申请并安装成功！"
        echo ""
        echo -e "  ${BOLD}证书文件：${NC}"
        echo -e "    完整证书链: ${CYAN}${install_dir}/fullchain.pem${NC}"
        echo -e "    私钥文件:   ${CYAN}${install_dir}/privkey.pem${NC}"
        echo -e "    证书文件:   ${CYAN}${install_dir}/cert.pem${NC}"
        echo -e "    CA 证书:    ${CYAN}${install_dir}/ca.pem${NC}"
        echo ""

        # 显示证书信息
        if [ -f "$install_dir/fullchain.pem" ]; then
            local expiry
            expiry=$(openssl x509 -enddate -noout -in "$install_dir/fullchain.pem" 2>/dev/null | cut -d= -f2)
            local san
            san=$(openssl x509 -noout -ext subjectAltName -in "$install_dir/fullchain.pem" 2>/dev/null | grep -oP 'DNS:[^ ,]+' | tr '\n' ' ')
            echo -e "  ${BOLD}证书详情：${NC}"
            echo -e "    域名: ${GREEN}${san}${NC}"
            echo -e "    到期: ${GREEN}${expiry}${NC}"
            [ -n "$reload_cmd" ] && \
            echo -e "    续期自动执行: ${GREEN}${reload_cmd}${NC}"
        fi

        # 确保自动续期已开启
        echo ""
        ensure_cron
        log "Certificate installed successfully for ${domains[*]} at $install_dir"
    else
        err "证书安装失败"
        log "Certificate installation FAILED for ${domains[*]}"
        return 1
    fi
}

# ============================================================
#  证书列表 & 详情
# ============================================================

list_certs() {
    echo ""
    echo -e "  ${BOLD}── 已管理的证书 ──${NC}"
    echo ""

    local cert_list
    cert_list=$("$ACME_BIN" --list 2>/dev/null)

    if [ -z "$cert_list" ] || [ "$(echo "$cert_list" | wc -l)" -le 1 ]; then
        warn "暂无已申请的证书"
        return 0
    fi

    # 显示 acme.sh 管理的证书
    echo "$cert_list"
    echo ""

    # 扫描已安装的证书文件并显示详情
    local found_installed=false

    # 扫描常见路径
    local search_dirs=("$DEFAULT_CERT_BASE" "/etc/nginx/ssl" "/root/cert" "/etc/ssl")
    for base_dir in "${search_dirs[@]}"; do
        [ ! -d "$base_dir" ] && continue
        while IFS= read -r cert_file; do
            [ -z "$cert_file" ] && continue
            found_installed=true
            local dir
            dir=$(dirname "$cert_file")
            local domain_name
            domain_name=$(basename "$dir")

            local expiry issuer san days_left color
            expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            issuer=$(openssl x509 -issuer -noout -in "$cert_file" 2>/dev/null | sed 's/.*O = //' | cut -d',' -f1)
            san=$(openssl x509 -noout -ext subjectAltName -in "$cert_file" 2>/dev/null | grep -oP 'DNS:[^\s,]+' | sed 's/DNS://g' | tr '\n' ' ')

            if [ -n "$expiry" ]; then
                local expiry_epoch now_epoch
                expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
                now_epoch=$(date +%s)
                if [ -n "$expiry_epoch" ]; then
                    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                    if [ "$days_left" -le 0 ]; then
                        color="$RED"; days_left="已过期"
                    elif [ "$days_left" -le 7 ]; then
                        color="$RED"; days_left="${days_left}天"
                    elif [ "$days_left" -le 30 ]; then
                        color="$YELLOW"; days_left="${days_left}天"
                    else
                        color="$GREEN"; days_left="${days_left}天"
                    fi
                fi
            fi

            echo -e "  ${CYAN}${BOLD}${domain_name}${NC}"
            echo -e "    域名: ${san:-N/A}"
            echo -e "    路径: $dir/"
            echo -e "    颁发: ${issuer:-N/A}"
            echo -e "    到期: ${expiry:-N/A}  (剩余 ${color}${days_left}${NC})"
            echo ""
        done < <(find "$base_dir" -name "fullchain.pem" -type f 2>/dev/null)
    done

    if ! $found_installed; then
        dim "  未找到已安装的证书文件"
        dim "  提示: 证书申请后会自动安装到你选择的路径"
    fi
}

# ============================================================
#  续期管理
# ============================================================

renew_certs() {
    echo ""
    echo -e "  ${BOLD}── 续期证书 ──${NC}"
    echo ""

    local cert_list
    cert_list=$("$ACME_BIN" --list 2>/dev/null | tail -n +2)

    if [ -z "$cert_list" ]; then
        warn "暂无可续期的证书"
        return 0
    fi

    echo "  1) 续期所有证书"
    echo "  2) 续期指定域名的证书"
    echo ""
    read -r -p "  请选择 [1-2]: " renew_choice

    case "$renew_choice" in
        1)
            echo ""
            info "正在续期所有证书..."
            echo ""
            "$ACME_BIN" --cron --force 2>&1 | tee -a "$LOG_FILE"
            echo ""
            if [ ${PIPESTATUS[0]} -eq 0 ]; then
                ok "续期任务完成"
            else
                warn "部分证书续期可能失败，请查看上方日志"
            fi
            ;;
        2)
            echo ""
            info "当前证书列表:"
            echo ""
            "$ACME_BIN" --list 2>/dev/null
            echo ""
            read -r -p "  请输入要续期的主域名: " renew_domain
            renew_domain=$(echo "$renew_domain" | xargs | tr 'A-Z' 'a-z')
            if [ -z "$renew_domain" ]; then
                err "域名不能为空"
                return 1
            fi

            # 检查证书是否存在（尝试 ECC 和 RSA）
            local found=false
            if [ -d "$ACME_HOME/${renew_domain}_ecc" ]; then
                found=true
                info "正在续期 $renew_domain (ECC)..."
                "$ACME_BIN" --renew -d "$renew_domain" --ecc --force 2>&1 | tee -a "$LOG_FILE"
            fi
            if [ -d "$ACME_HOME/${renew_domain}" ] && [ ! -d "$ACME_HOME/${renew_domain}_ecc" ]; then
                found=true
                info "正在续期 $renew_domain (RSA)..."
                "$ACME_BIN" --renew -d "$renew_domain" --force 2>&1 | tee -a "$LOG_FILE"
            fi

            if ! $found; then
                err "未找到域名 $renew_domain 的证书"
                dim "请确认域名拼写正确（应为申请时的主域名，不含通配符）"
                dim "使用 \"查看证书列表\" 查看所有已管理的域名"
            fi
            ;;
        *)
            err "无效选项"
            ;;
    esac
}

# ============================================================
#  删除证书
# ============================================================

remove_cert() {
    echo ""
    echo -e "  ${BOLD}── 删除证书 ──${NC}"
    echo ""

    local cert_list
    cert_list=$("$ACME_BIN" --list 2>/dev/null)
    echo "$cert_list"
    echo ""

    read -r -p "  请输入要删除的主域名: " del_domain
    del_domain=$(echo "$del_domain" | xargs | tr 'A-Z' 'a-z')
    if [ -z "$del_domain" ]; then
        err "域名不能为空"
        return 1
    fi

    # 查找相关文件
    echo ""
    info "将删除以下内容:"
    local items_found=false

    # acme.sh 内部 ECC
    if [ -d "$ACME_HOME/${del_domain}_ecc" ]; then
        dim "  acme.sh 内部: $ACME_HOME/${del_domain}_ecc/"
        items_found=true
    fi
    # acme.sh 内部 RSA
    if [ -d "$ACME_HOME/${del_domain}" ]; then
        dim "  acme.sh 内部: $ACME_HOME/${del_domain}/"
        items_found=true
    fi
    # 已安装的证书
    local installed_dirs=()
    for base in "$DEFAULT_CERT_BASE" "/etc/nginx/ssl" "/root/cert"; do
        if [ -d "$base/$del_domain" ]; then
            dim "  已安装证书: $base/$del_domain/"
            installed_dirs+=("$base/$del_domain")
            items_found=true
        fi
    done

    if ! $items_found; then
        err "未找到 $del_domain 的相关证书"
        return 1
    fi

    echo ""
    warn "此操作不可恢复！"
    if ! confirm "确认删除 $del_domain 的所有证书？"; then
        warn "已取消"
        return 0
    fi

    # 执行删除
    "$ACME_BIN" --remove -d "$del_domain" --ecc 2>/dev/null
    "$ACME_BIN" --remove -d "$del_domain" 2>/dev/null

    # 删除已安装的文件
    for dir in "${installed_dirs[@]}"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            dim "  已删除: $dir"
        fi
    done

    ok "证书 $del_domain 已删除"
    log "Removed certificate for $del_domain"
}

# ============================================================
#  自动续期（Cron）管理
# ============================================================

ensure_cron() {
    local cron_exists
    cron_exists=$(crontab -l 2>/dev/null | grep -c "acme.sh.*--cron")
    if [ "$cron_exists" -eq 0 ]; then
        info "正在添加自动续期定时任务..."
        local minute=$((RANDOM % 60))
        local hour=$(( (RANDOM % 4) + 1 ))  # 凌晨 1-4 点
        local cron_job="$minute $hour * * * \"$ACME_BIN\" --cron --home \"$ACME_HOME\" > /dev/null 2>&1"
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        ok "已添加定时任务: 每天 ${hour}:$(printf '%02d' $minute) 自动检查续期"
        log "Cron job added: $cron_job"
    else
        ok "自动续期已开启"
    fi
}

manage_cron() {
    echo ""
    echo -e "  ${BOLD}── 自动续期管理 ──${NC}"
    echo ""

    local cron_lines
    cron_lines=$(crontab -l 2>/dev/null | grep "acme.sh")

    if [ -n "$cron_lines" ]; then
        ok "自动续期状态: 已开启"
        echo ""
        echo -e "  ${BOLD}当前定时任务:${NC}"
        echo "$cron_lines" | while IFS= read -r line; do
            echo -e "    ${CYAN}${line}${NC}"
        done
        echo ""
        echo "  1) 保持不变"
        echo "  2) 关闭自动续期"
        echo "  3) 重置定时任务（重新随机时间）"
        echo ""
        read -r -p "  请选择 [1-3]: " cron_action
        case "$cron_action" in
            2)
                crontab -l 2>/dev/null | grep -v "acme.sh" | crontab -
                warn "自动续期已关闭"
                warn "请记得手动续期证书！"
                log "Cron job removed"
                ;;
            3)
                crontab -l 2>/dev/null | grep -v "acme.sh" | crontab -
                ensure_cron
                ;;
            *)
                info "保持不变"
                ;;
        esac
    else
        warn "自动续期状态: 未开启"
        echo ""
        if confirm "是否开启自动续期？（强烈推荐）"; then
            ensure_cron
        fi
    fi
}

# ============================================================
#  环境诊断
# ============================================================

diagnose() {
    echo ""
    echo -e "  ${BOLD}── 环境诊断 ──${NC}"
    echo ""

    echo -e "  ${BOLD}[基础环境]${NC}"
    if [ -f /etc/os-release ]; then
        local os_name
        os_name=$(. /etc/os-release && echo "$PRETTY_NAME")
        ok "系统: $os_name"
    fi

    if check_acme_installed; then
        ok "acme.sh: $(get_acme_version) ($ACME_BIN)"
    else
        err "acme.sh: 未安装"
    fi

    for cmd in curl openssl crontab socat; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd: 已安装"
        else
            if [ "$cmd" = "socat" ]; then
                dim "$cmd: 未安装（仅 standalone 模式需要，DNS 模式不影响）"
            else
                err "$cmd: 未安装"
            fi
        fi
    done

    echo ""
    echo -e "  ${BOLD}[DNS 配置]${NC}"
    local dns_p
    dns_p=$(get_configured_dns)
    if [ "$dns_p" != "none" ]; then
        ok "DNS 服务商: $(get_dns_provider_name "$dns_p")"
    else
        err "DNS API: 未配置"
    fi

    echo ""
    echo -e "  ${BOLD}[自动续期]${NC}"
    local cron_count
    cron_count=$(crontab -l 2>/dev/null | grep -c "acme.sh")
    if [ "$cron_count" -gt 0 ]; then
        ok "Cron 任务: $cron_count 条已配置"
        crontab -l 2>/dev/null | grep "acme.sh" | while IFS= read -r line; do
            dim "  $line"
        done
    else
        err "Cron 任务: 未配置（证书不会自动续期！）"
    fi

    # 检查 cron 服务是否在运行
    if systemctl is-active cron &>/dev/null || systemctl is-active crond &>/dev/null; then
        ok "Cron 服务: 正在运行"
    else
        err "Cron 服务: 未运行！定时任务不会执行！"
        dim "  修复: systemctl start cron && systemctl enable cron"
    fi

    echo ""
    echo -e "  ${BOLD}[网络连通]${NC}"
    if check_network; then
        ok "Let's Encrypt API: 可达"
    fi

    # ---- 自动续期健康检查 ----
    echo ""
    echo -e "  ${BOLD}[证书续期状态]${NC}"
    echo ""

    local cert_list
    cert_list=$("$ACME_BIN" --list 2>/dev/null | tail -n +2)

    if [ -z "$cert_list" ]; then
        warn "暂无已管理的证书"
    else
        local all_healthy=true
        local now_epoch
        now_epoch=$(date +%s)

        while IFS= read -r line; do
            local domain key_len san ca created renew_date
            domain=$(echo "$line" | awk '{print $1}')
            key_len=$(echo "$line" | awk '{print $2}' | tr -d '"')
            san=$(echo "$line" | awk '{print $3}')
            ca=$(echo "$line" | awk '{print $5}')
            created=$(echo "$line" | awk '{print $6}')
            renew_date=$(echo "$line" | awk '{print $7}')

            echo -e "  ${CYAN}${BOLD}${domain}${NC}"

            # 检查 acme.sh 内部证书目录是否存在
            local cert_home=""
            if [ "$key_len" = "ec-256" ] || [ "$key_len" = "ec-384" ]; then
                cert_home="$ACME_HOME/${domain}_ecc"
            else
                cert_home="$ACME_HOME/${domain}"
            fi

            if [ -d "$cert_home" ]; then
                ok "  acme.sh 证书目录: $cert_home"
            else
                err "  acme.sh 证书目录不存在: $cert_home"
                all_healthy=false
            fi

            # 检查 conf 文件中是否记录了 dns hook（自动续期必须）
            local conf_file="$cert_home/${domain}.conf"
            if [ -f "$conf_file" ]; then
                local saved_api
                saved_api=$(grep "^Le_API=" "$conf_file" 2>/dev/null)
                local saved_dns
                saved_dns=$(grep "^Le_Dns=" "$conf_file" 2>/dev/null)
                if [ -n "$saved_dns" ]; then
                    local dns_val
                    dns_val=$(echo "$saved_dns" | cut -d"'" -f2 | cut -d"=" -f2)
                    ok "  DNS 验证方式: $dns_val (自动续期可用)"
                else
                    warn "  DNS 验证方式: 未检测到（可能使用手动模式，自动续期会失败！）"
                    all_healthy=false
                fi
            fi

            # 检查已安装证书文件是否存在
            local install_fullchain=""
            local install_key=""
            if [ -f "$conf_file" ]; then
                install_fullchain=$(grep "^Le_RealFullChainPath=" "$conf_file" 2>/dev/null | cut -d"'" -f2)
                install_key=$(grep "^Le_RealKeyPath=" "$conf_file" 2>/dev/null | cut -d"'" -f2)
            fi

            if [ -n "$install_fullchain" ] && [ -f "$install_fullchain" ]; then
                ok "  证书文件: $install_fullchain"

                # 检查证书有效期
                local expiry
                expiry=$(openssl x509 -enddate -noout -in "$install_fullchain" 2>/dev/null | cut -d= -f2)
                if [ -n "$expiry" ]; then
                    local expiry_epoch
                    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
                    if [ -n "$expiry_epoch" ]; then
                        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                        if [ "$days_left" -le 0 ]; then
                            err "  有效期: 已过期！($expiry)"
                            all_healthy=false
                        elif [ "$days_left" -le 7 ]; then
                            err "  有效期: 剩余 ${days_left} 天 ⚠️  即将过期！($expiry)"
                            all_healthy=false
                        elif [ "$days_left" -le 30 ]; then
                            warn "  有效期: 剩余 ${days_left} 天 ($expiry)"
                        else
                            ok "  有效期: 剩余 ${days_left} 天 ($expiry)"
                        fi
                    fi
                fi
            elif [ -n "$install_fullchain" ]; then
                err "  证书文件不存在: $install_fullchain"
                all_healthy=false
            else
                warn "  未配置安装路径（证书仅在 acme.sh 内部，未安装到外部目录）"
            fi

            if [ -n "$install_key" ] && [ -f "$install_key" ]; then
                ok "  私钥文件: $install_key"
            elif [ -n "$install_key" ]; then
                err "  私钥文件不存在: $install_key"
                all_healthy=false
            fi

            # 检查 reload 命令是否配置
            local reload_cmd=""
            if [ -f "$conf_file" ]; then
                reload_cmd=$(grep "^Le_ReloadCmd=" "$conf_file" 2>/dev/null | cut -d"'" -f2)
            fi
            if [ -n "$reload_cmd" ]; then
                ok "  续期后重载: $reload_cmd"
            else
                dim "  续期后重载: 未配置（续期后需手动重启服务）"
            fi

            # 下次续期时间
            if [ -n "$renew_date" ] && [ "$renew_date" != "" ]; then
                local renew_epoch
                renew_epoch=$(date -d "$renew_date" +%s 2>/dev/null)
                if [ -n "$renew_epoch" ]; then
                    local renew_days=$(( (renew_epoch - now_epoch) / 86400 ))
                    if [ "$renew_days" -le 0 ]; then
                        info "  下次续期: 今天（下次 cron 执行时会自动续签）"
                    else
                        info "  下次续期: ${renew_days} 天后 ($renew_date)"
                    fi
                fi
            fi

            # CA
            dim "  颁发机构: ${ca:-N/A} | 密钥: ${key_len}"
            echo ""

        done <<< "$cert_list"

        # 总结
        echo -e "  ${BOLD}[续期健康总结]${NC}"
        echo ""
        if $all_healthy; then
            ok "所有证书自动续期状态正常 ✓"
            dim "  acme.sh 会在证书到期前 30 天自动续签"
            dim "  Cron 定时任务每天自动检查"
        else
            err "部分证书存在问题，请检查上方标红的项目"
        fi
    fi

    echo ""
    echo -e "  ${BOLD}[系统资源]${NC}"
    free -h 2>/dev/null | head -2 | while IFS= read -r line; do
        dim "$line"
    done
    echo ""
    df -h / 2>/dev/null | head -2 | while IFS= read -r line; do
        dim "$line"
    done

    echo ""
    dim "运行日志: $LOG_FILE"
}

# ============================================================
#  切换默认 CA
# ============================================================

switch_ca() {
    echo ""
    echo -e "  ${BOLD}── 切换默认 CA ──${NC}"
    echo ""
    echo "  1) Let's Encrypt  ${DIM}(广泛使用，每周限 5 张/域名)${NC}"
    echo "  2) ZeroSSL        ${DIM}(无速率限制，需注册)${NC}"
    echo "  3) Buypass        ${DIM}(挪威 CA，180 天有效期)${NC}"
    echo ""
    read -r -p "  请选择 [1-3]: " ca
    case "$ca" in
        1)  "$ACME_BIN" --set-default-ca --server letsencrypt
            ok "默认 CA 已切换为 Let's Encrypt" ;;
        2)  "$ACME_BIN" --set-default-ca --server zerossl
            ok "默认 CA 已切换为 ZeroSSL" ;;
        3)  "$ACME_BIN" --set-default-ca --server buypass
            ok "默认 CA 已切换为 Buypass" ;;
        *)  err "无效选项" ;;
    esac
}

# ============================================================
#  主菜单
# ============================================================

main_menu() {
    while true; do
        print_banner

        # 状态栏
        local dns_p cert_count cron_status
        dns_p=$(get_configured_dns)
        cert_count=$("$ACME_BIN" --list 2>/dev/null | tail -n +2 | wc -l)
        cron_status=$(crontab -l 2>/dev/null | grep -c "acme.sh")

        echo -e "  ${DIM}DNS: $(get_dns_provider_name "$dns_p") | 证书: ${cert_count}个 | 自动续期: $([ "$cron_status" -gt 0 ] && echo '已开启' || echo '未开启')${NC}"
        echo ""

        echo -e "  ${BOLD}请选择操作：${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC} 申请新证书"
        echo -e "  ${GREEN}2)${NC} 查看证书列表"
        echo -e "  ${GREEN}3)${NC} 续期证书"
        echo -e "  ${GREEN}4)${NC} 删除证书"
        echo ""
        echo -e "  ${GREEN}5)${NC} 自动续期管理"
        echo -e "  ${GREEN}6)${NC} DNS API 配置"
        echo -e "  ${GREEN}7)${NC} 切换默认 CA"
        echo -e "  ${GREEN}8)${NC} 升级 acme.sh"
        echo -e "  ${GREEN}9)${NC} 环境诊断"
        echo ""
        echo -e "  ${GREEN}0)${NC} 退出"
        echo ""
        read -r -p "  请选择 [0-9]: " choice

        case "$choice" in
            1) issue_cert;         press_enter ;;
            2) list_certs;         press_enter ;;
            3) renew_certs;        press_enter ;;
            4) remove_cert;        press_enter ;;
            5) manage_cron;        press_enter ;;
            6) setup_dns_provider; press_enter ;;
            7) switch_ca;          press_enter ;;
            8) upgrade_acme;       press_enter ;;
            9) diagnose;           press_enter ;;
            0)
                echo ""
                info "再见！日志: $LOG_FILE"
                echo ""
                exit 0
                ;;
            *)
                err "无效选项"
                sleep 1
                ;;
        esac
    done
}

# ============================================================
#  入口
# ============================================================

main() {
    # root 检查
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 用户运行此脚本"
        dim "sudo bash $0"
        exit 1
    fi

    # 依赖检查
    require_cmd curl "apt install curl / yum install curl" || exit 1
    require_cmd openssl "apt install openssl / yum install openssl" || exit 1

    # acme.sh 检查
    if ! check_acme_installed; then
        echo ""
        warn "acme.sh 未安装"
        if confirm "是否立即安装？"; then
            install_acme || exit 1
        else
            err "acme.sh 是必须的，退出"
            exit 1
        fi
    else
        ok "acme.sh $(get_acme_version) 已就绪"
    fi

    # DNS 配置检查（仅提示，不强制）
    local dns_p
    dns_p=$(get_configured_dns)
    if [ "$dns_p" = "none" ]; then
        echo ""
        warn "DNS API 尚未配置，申请证书前需要先配置"
        if confirm "现在配置？"; then
            setup_dns_provider
        fi
    else
        ok "DNS: $(get_dns_provider_name "$dns_p") 已配置"
    fi

    sleep 1
    main_menu
}

main "$@"