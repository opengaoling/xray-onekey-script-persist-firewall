#!/usr/bin/env bash
# =============================================================================
# Xray-2go 原生反向代理（VMess + WS/直连）
# 支持 Cloudflare CDN 与直连 IP，使用 VMess 反代隧道做内网穿透
# 版本: 1.5.0 (2026-04-28)
# =============================================================================

set -euo pipefail

# 颜色定义
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
BOLD='\033[1m'
RESET='\033[0m'

# 辅助函数
r()  { echo -e "${RED}$*${RESET}"; }
g()  { echo -e "${GREEN}$*${RESET}"; }
y()  { echo -e "${YELLOW}$*${RESET}"; }
b()  { echo -e "${BLUE}$*${RESET}"; }
p()  { echo -e "${PURPLE}$*${RESET}"; }
c()  { echo -e "${CYAN}$*${RESET}"; }

step()  { echo -e "\n${CYAN}┌─ ${BOLD}[$STEP_NUM]${RESET}${CYAN} $*${RESET}"; STEP_NUM=$((STEP_NUM+1)); }
ok()    { echo -e "${GREEN}└─ ✓ $*${RESET}"; }
info()  { echo -e "${YELLOW}│  $*${RESET}"; }
fail()  { echo -e "${RED}└─ ✗ $*${RESET}" >&2; exit 1; }

STEP_NUM=1
IS_ROOT=false
[[ $EUID -eq 0 ]] && IS_ROOT=true

# 目录与路径
LOOKUP_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="${HOME:-}"
if [[ -z "${TARGET_HOME}" || ( "$IS_ROOT" == "true" && -n "${SUDO_USER:-}" ) ]]; then
    if command -v getent >/dev/null 2>&1; then
        TARGET_HOME="$(getent passwd "${LOOKUP_USER}" 2>/dev/null | cut -d: -f6)"
    fi
    if [[ -z "${TARGET_HOME}" && -r /etc/passwd ]]; then
        TARGET_HOME="$(awk -F: -v user="${LOOKUP_USER}" '$1 == user { print $6; exit }' /etc/passwd)"
    fi
fi
[[ -z "${TARGET_HOME}" ]] && fail "无法确定用户目录，请先设置 HOME 环境变量"
WORK_DIR="${TARGET_HOME}/.local/share/xray-rev"
XRAY_BIN="${TARGET_HOME}/.local/bin/xray-rev"
CONFIG_FILE="${WORK_DIR}/config.json"

# 检查权限与 systemd
HAS_SYSTEMD=false
command -v systemctl >/dev/null 2>&1 && HAS_SYSTEMD=true
SYSTEMCTL_CMD="systemctl --user"
USER_SYSTEMD_UID=""
if [[ "$IS_ROOT" == "true" && -n "${SUDO_USER:-}" ]]; then
    USER_SYSTEMD_UID="$(id -u "$SUDO_USER" 2>/dev/null || true)"
fi

run_user_systemctl() {
    if [[ "$IS_ROOT" == "true" && -n "${SUDO_USER:-}" && -n "${USER_SYSTEMD_UID}" ]]; then
        su - "$SUDO_USER" -c "XDG_RUNTIME_DIR=/run/user/${USER_SYSTEMD_UID} systemctl --user $*"
    else
        $SYSTEMCTL_CMD "$@"
    fi
}

has_user_systemd() {
    $HAS_SYSTEMD || return 1
    run_user_systemctl --quiet is-active default.target >/dev/null 2>&1 || \
    run_user_systemctl --quiet is-system-running >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# 核心逻辑：安装组件
# -----------------------------------------------------------------------------

install_xray() {
    step "下载并安装 Xray-core"
    mkdir -p "${WORK_DIR}"
    ARCH_RAW="$(uname -m)"
    case "${ARCH_RAW}" in
        'x86_64') XRAY_ASSET="Xray-linux-64.zip" ;;
        'aarch64'|'arm64') XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
        *) XRAY_ASSET="Xray-linux-64.zip" ;;
    esac

    URL="https://github.com/obkj/xray-onekey-script/releases/latest/download/${XRAY_ASSET}"
    curl -fL -o "${WORK_DIR}/xray.zip" "${URL}"
    unzip -o "${WORK_DIR}/xray.zip" -d "${WORK_DIR}/" > /dev/null 2>&1
    mkdir -p "$(dirname "${XRAY_BIN}")"
    [[ -f "${WORK_DIR}/xray" ]] || fail "Xray 内核文件缺失，解压后未找到 xray 可执行文件"
    mv -f "${WORK_DIR}/xray" "${XRAY_BIN}"
    chmod +x "${XRAY_BIN}"
    [[ -x "${XRAY_BIN}" ]] || fail "Xray 内核安装失败，未生成可执行文件 ${XRAY_BIN}"
    rm -f "${WORK_DIR}/xray.zip"
    ok "Xray 安装完成"
}

detect_public_ip() {
    local ip=""
    ip="$(curl -4fsS https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] || ip="$(curl -4fsS https://ipv4.icanhazip.com 2>/dev/null || true)"
    printf '%s' "$ip" | tr -d '\r\n'
}

open_firewall_port() {
    local port="$1"
    [[ -z "$port" ]] && return

    if [[ "$IS_ROOT" != "true" ]]; then
        y "非 root 运行，未自动放行端口 ${port}/tcp；请手动放行该端口"
        return
    fi

    info "放行端口 ${port}/tcp"

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${port}/tcp" >/dev/null
        ufw reload >/dev/null || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null
        firewall-cmd --reload >/dev/null
    elif command -v iptables >/dev/null 2>&1; then
        add_iptables_port "$port"
    else
        y "未检测到可用防火墙命令，请手动放行 ${port}/tcp"
    fi
}

close_firewall_port() {
    local port="$1"
    [[ -z "$port" ]] && return
    [[ "$IS_ROOT" != "true" ]] && return

    info "关闭端口 ${port}/tcp"

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --remove-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        remove_iptables_port "$port"
    fi
}

add_iptables_port() {
    local port="$1"
    local reject_line

    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        reject_line="$(iptables -L INPUT -n -v --line-numbers | awk '$4 == "REJECT" {print $1; exit}')"
        if [[ -n "$reject_line" ]]; then
            iptables -I INPUT "$reject_line" -p tcp --dport "$port" -j ACCEPT
        else
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        fi
    fi

    persist_iptables_port "$port" add
}

remove_iptables_port() {
    local port="$1"

    while iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; do
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT || break
    done

    persist_iptables_port "$port" remove
}

persist_iptables_port() {
    local port="$1"
    local action="$2"
    local rules_file="${IPTABLES_RULES_FILE:-/etc/iptables/rules.v4}"
    local rule="-A INPUT -p tcp -m tcp --dport ${port} -j ACCEPT"
    local tmp_file

    [[ -z "$port" ]] && return

    if [[ "$action" == "add" ]]; then
        if [[ ! -f "$rules_file" ]]; then
            if command -v iptables-save >/dev/null 2>&1; then
                mkdir -p "$(dirname "$rules_file")"
                iptables-save > "$rules_file"
                validate_iptables_rules_file "$rules_file"
            else
                y "未找到 iptables-save，端口 ${port}/tcp 当前已放行但重启后可能失效"
            fi
            return
        fi

        if grep -Fxq -- "$rule" "$rules_file"; then
            return
        fi

        tmp_file="$(mktemp)"
        awk -v rule="$rule" '
            !inserted && index($0, "-A INPUT ") == 1 && $0 ~ / -j REJECT/ {
                print rule
                inserted=1
            }
            !inserted && $0 == "COMMIT" {
                print rule
                inserted=1
            }
            { print }
        ' "$rules_file" > "$tmp_file" && mv "$tmp_file" "$rules_file"
        validate_iptables_rules_file "$rules_file"
    elif [[ "$action" == "remove" && -f "$rules_file" ]]; then
        tmp_file="$(mktemp)"
        grep -Fvx -- "$rule" "$rules_file" > "$tmp_file" || true
        mv "$tmp_file" "$rules_file"
        validate_iptables_rules_file "$rules_file"
    fi
}

validate_iptables_rules_file() {
    local rules_file="$1"

    if command -v iptables-restore >/dev/null 2>&1; then
        if ! iptables-restore --test < "$rules_file" >/dev/null 2>&1; then
            y "${rules_file} 未通过 iptables-restore 校验；运行时防火墙规则仍已应用"
        fi
    fi

    if ! command -v netfilter-persistent >/dev/null 2>&1 && ! systemctl list-unit-files netfilter-persistent.service >/dev/null 2>&1; then
        y "未检测到 netfilter-persistent；如系统启动时不加载 ${rules_file}，请安装 iptables-persistent/netfilter-persistent"
    fi
}

generate_vmess_link() {
    local ps="$1"
    local address="$2"
    local port="$3"
    local uuid="$4"
    local network="$5"
    local ws_path="$6"
    local host="$7"
    local tls_mode="$8"
    local sni="$9"

    jq -cn \
        --arg ps "$ps" \
        --arg add "$address" \
        --arg port "$port" \
        --arg id "$uuid" \
        --arg net "$network" \
        --arg path "$ws_path" \
        --arg host "$host" \
        --arg tls "$tls_mode" \
        --arg sni "$sni" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:"none",host:$host,path:$path,tls:$tls,sni:$sni}' | base64 | tr -d '\r\n'
}

build_client_import_token() {
    local conn_mode="$1"
    local uuid="$2"
    local server_addr="$3"
    local server_port="$4"
    local rev_domain="$5"
    local tunnel_path="${6:-}"

    jq -cn \
        --arg ver "1" \
        --arg conn_mode "$conn_mode" \
        --arg uuid "$uuid" \
        --arg server_addr "$server_addr" \
        --arg server_port "$server_port" \
        --arg rev_domain "$rev_domain" \
        --arg tunnel_path "$tunnel_path" \
        '{ver:$ver,conn_mode:$conn_mode,uuid:$uuid,server_addr:$server_addr,server_port:$server_port,rev_domain:$rev_domain,tunnel_path:$tunnel_path}' | base64 | tr -d '\r\n' | sed 's/+/-/g; s/\//_/g' | sed 's#^#xrayrev://v1/#'
}

parse_client_import_token() {
    local import_token="$1"
    local encoded_payload
    local payload
    local parsed
    local token_ver
    local parsed_conn_mode
    local parsed_uuid
    local parsed_server_addr
    local parsed_server_port
    local parsed_rev_domain
    local parsed_tunnel_path

    [[ "$import_token" == xrayrev://v1/* ]] || return 1
    encoded_payload="${import_token#xrayrev://v1/}"
    payload="$(printf '%s' "$encoded_payload" | sed 's/-/+/g; s/_/\//g' | base64 -d 2>/dev/null)" || return 1
    parsed="$(printf '%s' "$payload" | jq -er '[.ver, .conn_mode, .uuid, .server_addr, .server_port, .rev_domain, (.tunnel_path // "")] | @tsv' 2>/dev/null)" || return 1

    IFS=$'\t' read -r token_ver parsed_conn_mode parsed_uuid parsed_server_addr parsed_server_port parsed_rev_domain parsed_tunnel_path <<< "$parsed"
    [[ "$token_ver" == "1" ]] || return 1
    [[ "$parsed_conn_mode" == "1" || "$parsed_conn_mode" == "2" ]] || return 1
    [[ -n "$parsed_uuid" && -n "$parsed_server_addr" && -n "$parsed_server_port" && -n "$parsed_rev_domain" ]] || return 1
    [[ "$parsed_conn_mode" != "1" || -n "$parsed_tunnel_path" ]] || return 1

    UUID="$parsed_uuid"
    CONN_MODE="$parsed_conn_mode"
    SERVER_ADDR="$parsed_server_addr"
    SERVER_PORT="$parsed_server_port"
    REV_DOMAIN="$parsed_rev_domain"
    TUNNEL_PATH="$parsed_tunnel_path"
}

get_server_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    # 优先从元数据读取
    SERVER_ADDR=$(jq -r '._server_addr // empty' "$CONFIG_FILE")
    CONN_MODE=$(jq -r '._conn_mode // empty' "$CONFIG_FILE")
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$CONFIG_FILE")
    
    # 自动识别连接模式 (针对旧版本)
    if [[ -z "$CONN_MODE" ]]; then
        local net=$(jq -r '.inbounds[0].streamSettings.network // empty' "$CONFIG_FILE")
        [[ "$net" == "ws" ]] && CONN_MODE="1" || CONN_MODE="2"
    fi
}

cleanup_old_service() {
    # 停止并清理旧版本的 Xray 反代服务，确保新配置被干净加载
    if has_user_systemd 2>/dev/null; then
        run_user_systemctl stop xray-rev >/dev/null 2>&1 || true
        run_user_systemctl disable xray-rev >/dev/null 2>&1 || true
    fi
    # 强制杀掉所有残留进程
    pkill -f "${XRAY_BIN}" 2>/dev/null || true
    sleep 1
}

restart_service() {
    pkill -f "${XRAY_BIN}" || true
    "${XRAY_BIN}" run -c "${CONFIG_FILE}" > /dev/null 2>&1 &
}

setup_service() {
    step "配置系统服务"
    cleanup_old_service
    mkdir -p "$(dirname "$XRAY_BIN")"
    mkdir -p "${TARGET_HOME}/.config/systemd/user"
    if has_user_systemd; then
        SVCPATH="${TARGET_HOME}/.config/systemd/user"
        cat > "$SVCPATH/xray-rev.service" << EOF
[Unit]
Description=Xray Reverse Proxy (CF Mode)
After=network.target

[Service]
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure

[Install]
WantedBy=default.target
EOF
        run_user_systemctl daemon-reload
        run_user_systemctl enable xray-rev --now >/dev/null 2>&1 || true
        run_user_systemctl restart xray-rev
        ok "服务已启动并设为开机自启"
    else
        info "未检测到可用的 user systemd，会改为直接后台启动"
        restart_service
        ok "服务已在后台启动"
    fi
}

# -----------------------------------------------------------------------------
# 功能模块：服务端
# -----------------------------------------------------------------------------

install_portal() {
    get_server_config || true
    
    c "\n--- 安装服务端 (Portal) ---"
    read -p "请输入 UUID (留空使用当前或随机): " NEW_UUID
    UUID=${NEW_UUID:-${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")}}

    # 初始化默认识别域名
    RAND_STR=$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)
    REV_DOMAIN="rev_${RAND_STR}.local"

    echo -e "\n请选择连接方式 (当前: ${CONN_MODE:-2}):"
    echo -e "  1) ${CYAN}Cloudflare 模式${RESET} (VMess + WS + TLS, 单路径回源, 适合套 CDN)"
    echo -e "  2) ${CYAN}直连 IP 模式${RESET} (TCP, 双端口, 适合直接连接, 无需域名)"
    read -p "请选择 (1/2, 默认 ${CONN_MODE:-2}): " NEW_CONN_MODE
    CONN_MODE=${NEW_CONN_MODE:-${CONN_MODE:-2}}

    if [[ "$CONN_MODE" == "1" ]]; then
        RANDOM_PORT=$(awk 'BEGIN { srand(); print int(10000 + rand() * 50000) }')
        read -p "请输入服务端监听端口 (默认 ${RANDOM_PORT}): " LISTEN_PORT
        LISTEN_PORT=${LISTEN_PORT:-${RANDOM_PORT}}

        # VMess+WS 入站使用同一个路径承载用户流量和 Bridge 隧道流量。
        # 服务端通过 reverse domain 识别隧道连接，不能依赖 routing.path 做分流。
        RAND_USER=$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)

        read -p "请输入 VMess WS 路径 (默认 /vmess_${RAND_USER}): " USER_PATH
        USER_PATH=${USER_PATH:-/vmess_${RAND_USER}}
        TUNNEL_PATH=${USER_PATH}
        read -p "请输入用于客户端连接的域名: " SHARE_DOMAIN
        [[ -z "${SHARE_DOMAIN}" ]] && fail "必须输入用于客户端连接的域名"
    else
        RAND_EXT=$(awk 'BEGIN { srand(); print int(10000 + rand() * 45000) }')
        RAND_TUN=$(awk 'BEGIN { srand(); print int(45001 + rand() * 15000) }')
        read -p "请输入用户访问端口 (默认 ${RAND_EXT}): " EXT_PORT
        EXT_PORT=${EXT_PORT:-${RAND_EXT}}
        read -p "请输入隧道连接端口 (默认 ${RAND_TUN}): " TUNNEL_PORT
        TUNNEL_PORT=${TUNNEL_PORT:-${RAND_TUN}}
        SHARE_DOMAIN="$(detect_public_ip)"
        if [[ -n "${SHARE_DOMAIN}" ]]; then
            info "已自动获取公网 IP: ${SHARE_DOMAIN}"
        else
            read -p "自动获取公网 IP 失败，请手动输入服务端 IP: " SHARE_DOMAIN
            [[ -z "${SHARE_DOMAIN}" ]] && fail "必须输入服务端 IP"
        fi
    fi

    install_xray

    if [[ "$CONN_MODE" == "1" ]]; then
        cat > "${CONFIG_FILE}" << EOF
{
  "_info": "Generated by Xray-Reverse-Onekey",
  "_server_addr": "${SHARE_DOMAIN}",
  "_conn_mode": "${CONN_MODE}",
  "log": { "loglevel": "none" },
  "reverse": { "portals": [{ "tag": "portal", "domain": "${REV_DOMAIN}" }] },
  "inbounds": [
    {
      "tag": "ext_in", "port": ${LISTEN_PORT}, "protocol": "vmess",
      "settings": { "clients": [{ "id": "${UUID}", "alterId": 0, "security": "aes-128-gcm" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "${USER_PATH}" } }
    }
  ],
  "routing": {
    "rules": [
      { "type": "field", "domain": ["full:${REV_DOMAIN}"], "outboundTag": "portal" },
      { "type": "field", "inboundTag": ["ext_in"], "outboundTag": "portal" }
    ]
  },
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
    else
        cat > "${CONFIG_FILE}" << EOF
{
  "_info": "Generated by Xray-Reverse-Onekey",
  "_server_addr": "${SHARE_DOMAIN}",
  "_conn_mode": "${CONN_MODE}",
  "log": { "loglevel": "none" },
  "reverse": { "portals": [{ "tag": "portal", "domain": "${REV_DOMAIN}" }] },
  "inbounds": [
    { "tag": "ext_in", "port": ${EXT_PORT}, "protocol": "vmess", "settings": { "clients": [{ "id": "${UUID}", "alterId": 0, "security": "aes-128-gcm" }] } },
    { "tag": "tunnel_in", "port": ${TUNNEL_PORT}, "protocol": "vmess", "settings": { "clients": [{ "id": "${UUID}", "alterId": 0, "security": "aes-128-gcm" }] } }
  ],
  "routing": {
    "rules": [
      { "type": "field", "domain": ["full:${REV_DOMAIN}"], "outboundTag": "portal" },
      { "type": "field", "inboundTag": ["ext_in", "tunnel_in"], "outboundTag": "portal" }
    ]
  },
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
    fi
    if [[ "$CONN_MODE" == "1" ]]; then
        open_firewall_port "$LISTEN_PORT"
    else
        open_firewall_port "$EXT_PORT"
        open_firewall_port "$TUNNEL_PORT"
    fi
    setup_service
    if [[ "$CONN_MODE" == "1" ]]; then
        IMPORT_TOKEN="$(build_client_import_token "$CONN_MODE" "$UUID" "$SHARE_DOMAIN" "443" "$REV_DOMAIN" "$TUNNEL_PATH")"
        VMESS_LINK="vmess://$(generate_vmess_link "xray-rev-cf" "${SHARE_DOMAIN}" "443" "${UUID}" "ws" "${USER_PATH}" "${SHARE_DOMAIN}" "tls" "${SHARE_DOMAIN}")"
        g "\n✅ 服务端安装完成！(Cloudflare 模式)"
        echo -e "-------------------------------------------------"
        echo -e "请在 CF Origin Rules 中配置转发到端口: ${CYAN}${LISTEN_PORT}${RESET}"
        echo -e "接入域名: ${CYAN}${SHARE_DOMAIN}${RESET}"
        echo -e "\n${BOLD}--- 客户端一键配置 (最简便) ---${RESET}"
        echo -e "客户端导入串: ${GREEN}${IMPORT_TOKEN}${RESET}"
        echo -e "\n--- 其它详细参数 ---"
        echo -e "UUID: ${PURPLE}${UUID}${RESET}"
        echo -e "VMess WS 路径: ${CYAN}${USER_PATH}${RESET}"
        echo -e "识别域名: ${CYAN}${REV_DOMAIN}${RESET}"
        echo -e "V2rayN 链接: ${GREEN}${VMESS_LINK}${RESET}"
        echo -e "-------------------------------------------------"
    else
        IMPORT_TOKEN="$(build_client_import_token "$CONN_MODE" "$UUID" "$SHARE_DOMAIN" "$TUNNEL_PORT" "$REV_DOMAIN")"
        VMESS_LINK="vmess://$(generate_vmess_link "xray-rev-direct" "${SHARE_DOMAIN}" "${EXT_PORT}" "${UUID}" "tcp" "" "" "" "")"
        g "\n✅ 服务端安装完成！(直连 IP 模式)"
        echo -e "-------------------------------------------------"
        echo -e "用户访问端口: ${CYAN}${EXT_PORT}${RESET}"
        echo -e "客户端隧道端口: ${CYAN}${TUNNEL_PORT}${RESET}"
        echo -e "\n${BOLD}--- 客户端一键配置 (最简便) ---${RESET}"
        echo -e "客户端导入串: ${GREEN}${IMPORT_TOKEN}${RESET}"
        echo -e "\n--- 其它详细参数 ---"
        echo -e "UUID: ${PURPLE}${UUID}${RESET}"
        echo -e "服务端地址: ${CYAN}${SHARE_DOMAIN}${RESET}"
        echo -e "客户端连接端口: ${CYAN}${TUNNEL_PORT}${RESET}"
        echo -e "识别域名: ${CYAN}${REV_DOMAIN}${RESET}"
        echo -e "V2rayN 链接: ${GREEN}${VMESS_LINK}${RESET}"
        echo -e "-------------------------------------------------"
    fi
}

# -----------------------------------------------------------------------------
# 功能模块：客户端
# -----------------------------------------------------------------------------

install_bridge() {
    c "\n--- 安装客户端 (Bridge) ---"

    IMPORT_TOKEN=""
    IMPORT_SUCCESS=false
    read -p "请输入服务端一键导入串 (留空走手动配置): " IMPORT_TOKEN
    if [[ -n "$IMPORT_TOKEN" ]]; then
        if parse_client_import_token "$IMPORT_TOKEN"; then
            IMPORT_SUCCESS=true
            BRIDGE_MODE=2
            info "已导入服务端参数，将默认使用出口模式完成安装"
        else
            y "导入串解析失败，已切换为手动配置"
        fi
    fi

    if [[ -z "${UUID:-}" ]]; then
        read -p "请输入 UUID: " UUID
        [[ -z "${UUID}" ]] && fail "必须输入 UUID"
    fi

    if [[ -z "${CONN_MODE:-}" ]]; then
        echo -e "\n请选择连接方式 (当前: ${CONN_MODE:-2}):"
        echo -e "  1) ${CYAN}Cloudflare 模式${RESET} (WS + TLS, 端口 443)"
        echo -e "  2) ${CYAN}直连 IP 模式${RESET} (TCP, 自定义端口)"
        read -p "请选择 (1/2, 默认 ${CONN_MODE:-2}): " NEW_CONN_MODE
        CONN_MODE=${NEW_CONN_MODE:-${CONN_MODE:-2}}
    fi

    if [[ -z "${SERVER_ADDR:-}" ]]; then
        read -p "请输入公网服务器 IP 或域名: " SERVER_ADDR
        [[ -z "${SERVER_ADDR}" ]] && fail "必须输入地址"
    fi

    if [[ "$CONN_MODE" == "1" ]]; then
        if [[ -z "${TUNNEL_PATH:-}" ]]; then
            read -p "请输入 VMess WS 路径 (默认 /vmess): " TUNNEL_PATH
            TUNNEL_PATH=${TUNNEL_PATH:-/vmess}
        fi
        STREAM_SETTINGS="{\"network\": \"ws\", \"security\": \"tls\", \"tlsSettings\": {\"serverName\": \"${SERVER_ADDR}\"}, \"wsSettings\": {\"path\": \"${TUNNEL_PATH}\"}}"
        SERVER_PORT=443
    else
        if [[ -z "${SERVER_PORT:-}" ]]; then
            read -p "请输入服务端隧道端口: " SERVER_PORT
            [[ -z "${SERVER_PORT}" ]] && fail "必须输入端口"
        fi
        STREAM_SETTINGS="{\"network\": \"tcp\"}"
    fi

    if [[ -z "${REV_DOMAIN:-}" ]]; then
        read -p "请输入识别域名 (需与服务端一致): " REV_DOMAIN
        [[ -z "${REV_DOMAIN}" ]] && fail "必须输入识别域名"
    fi

    if [[ "$IMPORT_SUCCESS" != "true" ]]; then
        echo -e "\n请选择客户端工作模式:"
        echo -e "  1) ${CYAN}转发模式${RESET} - 将流量转发到本地特定服务 (如 Web)"
        echo -e "  2) ${CYAN}出口模式${RESET} - 将客户端作为上网出口 (访问 YouTube 等)"
        read -p "请选择 (1/2, 默认 2): " BRIDGE_MODE
        BRIDGE_MODE=${BRIDGE_MODE:-2}
    else
        # 即使导入了，也默认提示一下模式选择，但默认值设为 2
        read -p "请选择客户端工作模式 (1:转发, 2:出口, 默认 2): " BRIDGE_MODE
        BRIDGE_MODE=${BRIDGE_MODE:-2}
    fi

    if [[ "$BRIDGE_MODE" == "1" ]]; then
        read -p "请输入内网服务目标 (默认 127.0.0.1:80): " LOCAL_TARGET
        LOCAL_TARGET=${LOCAL_TARGET:-127.0.0.1:80}
        OUTBOUND_SETTINGS="{\"redirect\": \"${LOCAL_TARGET}\"}"
    else
        OUTBOUND_SETTINGS="{}"
        info "已选择出口模式，流量将直接发往互联网"
    fi

    install_xray

    cat > "${CONFIG_FILE}" << EOF
{
  "log": { "loglevel": "none" },
  "reverse": { "bridges": [{ "tag": "bridge", "domain": "${REV_DOMAIN}" }] },
  "outbounds": [
    {
      "tag": "tunnel_out", "protocol": "vmess",
      "settings": { "vnext": [{ "address": "${SERVER_ADDR}", "port": ${SERVER_PORT}, "users": [{ "id": "${UUID}", "alterId": 0, "security": "aes-128-gcm" }] }] },
      "streamSettings": ${STREAM_SETTINGS}
    },
    { "tag": "local_service", "protocol": "freedom", "settings": ${OUTBOUND_SETTINGS} },
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["bridge"], "domain": ["full:${REV_DOMAIN}"], "outboundTag": "tunnel_out" },
      { "type": "field", "inboundTag": ["bridge"], "outboundTag": "local_service" }
    ]
  }
}
EOF
    setup_service
    g "\n✅ 客户端安装完成！"
    echo -e "已通过域名 ${CYAN}${SERVER_ADDR}${RESET} 建立隧道"
    if [[ "$BRIDGE_MODE" == "1" ]]; then
        echo -e "内网目标: ${CYAN}${LOCAL_TARGET}${RESET}"
    else
        echo -e "工作模式: ${CYAN}出口模式${RESET}"
    fi
}

# -----------------------------------------------------------------------------
# 辅助模块：管理
# -----------------------------------------------------------------------------

show_status() {
    if has_user_systemd; then
        run_user_systemctl status xray-rev --no-pager || y "服务未运行"
    else
        pgrep -f "${XRAY_BIN}" > /dev/null && g "Xray 正在运行" || r "Xray 已停止"
    fi
}

uninstall() {
    read -p "确定要卸载吗？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    if [[ -f "$CONFIG_FILE" ]]; then
        jq -r '.inbounds[]?.port // empty' "$CONFIG_FILE" | while read -r port; do
            close_firewall_port "$port"
        done
    fi
    if has_user_systemd; then
        run_user_systemctl stop xray-rev >/dev/null 2>&1 || true
        run_user_systemctl disable xray-rev >/dev/null 2>&1 || true
        rm -f "$TARGET_HOME/.config/systemd/user/xray-rev.service"
        run_user_systemctl daemon-reload
    else
        rm -f "$TARGET_HOME/.config/systemd/user/xray-rev.service"
    fi
    pkill -f "${XRAY_BIN}" || true
    rm -rf "${WORK_DIR}"
    rm -f "${XRAY_BIN}"
    g "卸载成功！"
}

# -----------------------------------------------------------------------------
# 主菜单
# -----------------------------------------------------------------------------

main_menu() {
    clear 2>/dev/null || true
    p "================================================="
    p "    Xray 原生反代 (VMess+WS+CF) 一键管理脚本     "
    p "              版本: 1.5.0 (2026-04-28)           "
    p "================================================="
    echo -e "  1) ${GREEN}安装服务端 (Portal)${RESET}"
    echo -e "  2) ${GREEN}安装客户端 (Bridge)${RESET}"
    echo -e "  3) ${BLUE}查看运行状态${RESET}"
    echo -e "  4) ${YELLOW}添加新客户端配置 (仅服务端)${RESET}"
    echo -e "  5) ${PURPLE}管理 VMess 端口映射 (仅服务端)${RESET}"
    echo -e "  6) ${RED}一键卸载${RESET}"
    echo -e "  7) ${CYAN}查看配置与一键导入串${RESET}"
    echo -e "  0) 退出"
    echo -e "-------------------------------------------------"
    read -p "请输入选项: " choice
    
    case "$choice" in
        1) install_portal ;;
        2) install_bridge ;;
        3) show_status ;;
        4) add_portal_client ;;
        5) manage_vmess_mapping ;;
        6) uninstall ;;
        7) show_config ;;
        *) exit 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# 高级功能：在服务端增加新客户端
# -----------------------------------------------------------------------------

add_portal_client() {
    [[ ! -f "$CONFIG_FILE" ]] && fail "未找到配置文件，请先安装服务端"
    [[ "$(jq -r '.reverse.bridges // empty' "$CONFIG_FILE")" != "" ]] && fail "当前设备是客户端角色，无法添加服务端配置"

    get_server_config || fail "获取服务端配置失败"
    
    c "\n--- 为服务端添加新客户端 ---"
    read -p "请输入新客户端的识别域名 (如 reverse2.local): " NEW_REV_DOMAIN
    [[ -z "${NEW_REV_DOMAIN}" ]] && fail "必须输入域名"
    
    NEW_TUNNEL_PATH=""
    if [[ "$CONN_MODE" == "1" ]]; then
        NEW_TUNNEL_PATH=$(jq -r '.inbounds[] | select(.tag=="ext_in") | .streamSettings.wsSettings.path // empty' "$CONFIG_FILE" | head -n 1)
    fi

    NEW_TAG="portal_$(date +%s)"
    
    # 使用 jq 动态修改配置
    tmp_config="${CONFIG_FILE}.tmp"
    if [[ "$CONN_MODE" == "1" ]]; then
        jq ".reverse.portals += [{\"tag\": \"${NEW_TAG}\", \"domain\": \"${NEW_REV_DOMAIN}\"}] | 
            .routing.rules = [{\"type\": \"field\", \"domain\": [\"full:${NEW_REV_DOMAIN}\"], \"outboundTag\": \"${NEW_TAG}\"}] + .routing.rules" \
            "$CONFIG_FILE" > "$tmp_config" && mv "$tmp_config" "$CONFIG_FILE"
    else
        jq ".reverse.portals += [{\"tag\": \"${NEW_TAG}\", \"domain\": \"${NEW_REV_DOMAIN}\"}] | 
            .routing.rules = [{\"type\": \"field\", \"domain\": [\"full:${NEW_REV_DOMAIN}\"], \"outboundTag\": \"${NEW_TAG}\"}] + .routing.rules" \
            "$CONFIG_FILE" > "$tmp_config" && mv "$tmp_config" "$CONFIG_FILE"
    fi

    restart_service
    
    # 生成导入串
    if [[ "$CONN_MODE" == "1" ]]; then
        IMPORT_TOKEN="$(build_client_import_token "$CONN_MODE" "$UUID" "$SERVER_ADDR" "443" "$NEW_REV_DOMAIN" "$NEW_TUNNEL_PATH")"
    else
        # 直连模式下，由于是共用隧道端口，所以 SERVER_PORT 还是原来的
        local tunnel_port=$(jq -r '.inbounds[] | select(.tag=="tunnel_in") | .port' "$CONFIG_FILE")
        IMPORT_TOKEN="$(build_client_import_token "$CONN_MODE" "$UUID" "$SERVER_ADDR" "$tunnel_port" "$NEW_REV_DOMAIN")"
    fi

    g "\n✅ 客户端添加成功！"
    echo -e "-------------------------------------------------"
    echo -e "识别域名: ${CYAN}${NEW_REV_DOMAIN}${RESET}"
    [[ -n "$NEW_TUNNEL_PATH" ]] && echo -e "VMess WS 路径: ${CYAN}${NEW_TUNNEL_PATH}${RESET}"
    echo -e "\n${BOLD}--- 客户端一键配置 ---${RESET}"
    echo -e "客户端导入串: ${GREEN}${IMPORT_TOKEN}${RESET}"
    echo -e "-------------------------------------------------"
}

# -----------------------------------------------------------------------------
# 映射管理：VMess 端口 -> 客户端标签
# -----------------------------------------------------------------------------

manage_vmess_mapping() {
    [[ ! -f "$CONFIG_FILE" ]] && fail "未找到配置文件"
    
    echo -e "\n--- VMess 端口映射管理 ---"
    echo -e "  1) 添加新端口映射"
    echo -e "  2) 查看当前映射列表"
    echo -e "  3) 删除端口映射"
    echo -e "  0) 返回主菜单"
    read -p "选择操作: " sub_choice
    
    case "$sub_choice" in
        1)
            # 列出可选客户端
            echo -e "\n可用客户端列表:"
            jq -r '.reverse.portals[] | "- \(.domain) (tag: \(.tag))"' "$CONFIG_FILE"
            read -p "请输入要映射的客户端识别域名: " TARGET_DOMAIN
            TARGET_TAG=$(jq -r ".reverse.portals[] | select(.domain==\"$TARGET_DOMAIN\") | .tag" "$CONFIG_FILE")
            [[ -z "$TARGET_TAG" ]] && fail "找不到该客户端"
            
            read -p "请输入新 VMess 端口: " NEW_PORT
            read -p "请输入该端口的 UUID (留空使用全局): " NEW_UUID
            GLOBAL_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
            NEW_UUID=${NEW_UUID:-$GLOBAL_UUID}
            
            MAP_TAG="map_${NEW_PORT}"
            
            # 增加入站和路由
            tmp_config="${CONFIG_FILE}.tmp"
            jq ".inbounds += [{\"tag\": \"${MAP_TAG}\", \"port\": ${NEW_PORT}, \"protocol\": \"vmess\", \"settings\": {\"clients\": [{\"id\": \"${NEW_UUID}\", \"alterId\": 0}]}}] |
                .routing.rules = [{\"type\": \"field\", \"inboundTag\": [\"${MAP_TAG}\"], \"outboundTag\": \"${TARGET_TAG}\"}] + .routing.rules" \
                "$CONFIG_FILE" > "$tmp_config" && mv "$tmp_config" "$CONFIG_FILE"
            
            open_firewall_port "$NEW_PORT"
            restart_service
            g "✅ 映射添加成功！端口 ${NEW_PORT} -> 客户端 ${TARGET_DOMAIN}"
            ;;
        2)
            echo -e "\n当前 VMess 端口映射列表:"
            jq -r '.routing.rules[] | select(.inboundTag != null) | "端口: \(.inboundTag[0]) -> 目标标签: \(.outboundTag)"' "$CONFIG_FILE" | sed 's/map_//g'
            read -p "按回车继续..."
            ;;
        3)
            read -p "请输入要删除映射的端口号: " DEL_PORT
            MAP_TAG="map_${DEL_PORT}"
            tmp_config="${CONFIG_FILE}.tmp"
            jq "del(.inbounds[] | select(.tag == \"${MAP_TAG}\")) | 
                del(.routing.rules[] | select(.inboundTag != null and .inboundTag[0] == \"${MAP_TAG}\"))" \
                "$CONFIG_FILE" > "$tmp_config" && mv "$tmp_config" "$CONFIG_FILE"
            
            close_firewall_port "$DEL_PORT"
            restart_service
            g "✅ 映射端口 ${DEL_PORT} 已删除"
            ;;
        *) return ;;
    esac
}

show_config() {
    [[ -f "$CONFIG_FILE" ]] || fail "未找到配置文件"
    get_server_config || true
    
    echo -e "\n--- 当前配置信息 ---"
    if [[ "$(jq -r '.reverse.portals // empty' "$CONFIG_FILE")" != "" ]]; then
        echo -e "角色: ${GREEN}服务端 (Portal)${RESET}"
        echo -e "UUID: ${PURPLE}${UUID:-未知}${RESET}"
        echo -e "地址: ${CYAN}${SERVER_ADDR:-未知}${RESET}"
        
        echo -e "\n可用客户端及导入串:"
        jq -c '.reverse.portals[]' "$CONFIG_FILE" | while read -r portal; do
            local domain=$(echo "$portal" | jq -r '.domain')
            local tag=$(echo "$portal" | jq -r '.tag')
            
            echo -e "\n[ 客户端: ${CYAN}${domain}${RESET} ]"
            if [[ "$CONN_MODE" == "1" ]]; then
                local tunnel_path=$(jq -r '.inbounds[] | select(.tag=="ext_in") | .streamSettings.wsSettings.path // empty' "$CONFIG_FILE" | head -n 1)
                local token=$(build_client_import_token "$CONN_MODE" "$UUID" "$SERVER_ADDR" "443" "$domain" "$tunnel_path")
                echo -e "导入串: ${GREEN}${token}${RESET}"
            else
                local tunnel_port=$(jq -r '.inbounds[] | select(.tag=="tunnel_in") | .port' "$CONFIG_FILE" | head -n 1)
                local token=$(build_client_import_token "$CONN_MODE" "$UUID" "$SERVER_ADDR" "$tunnel_port" "$domain")
                echo -e "导入串: ${GREEN}${token}${RESET}"
            fi
        done
    else
        echo -e "角色: ${GREEN}客户端 (Bridge)${RESET}"
        jq -r '.outbounds[] | select(.tag=="tunnel_out") | "连接到: \(.settings.vnext[0].address):\(.settings.vnext[0].port)"' "$CONFIG_FILE"
        jq -r '.reverse.bridges[0] | "识别域名: \(.domain)"' "$CONFIG_FILE"
    fi
    echo -e "\n-------------------------------------------------"
    read -p "按回车继续..."
}

# 检查环境并启动
command -v curl &>/dev/null || fail "缺少 curl，请先安装"
command -v unzip &>/dev/null || fail "缺少 unzip，请先安装"
command -v jq &>/dev/null || (if $IS_ROOT; then apt-get update -qq && apt-get install -y -qq jq; else fail "缺少 jq，请先安装"; fi)

main_menu
