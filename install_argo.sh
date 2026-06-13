#!/usr/bin/env bash
# =============================================================================
# Xray-2go + Argo 临时隧道 一键安装脚本（无交互）
# 基于 upstream 最新 install_argo.sh 修订：只保留 Argo VMess 节点
# =============================================================================

set -euo pipefail

RED='\033[1;91m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
BOLD='\033[1m'
RESET='\033[0m'

r()  { echo -e "${RED}$*${RESET}"; }
g()  { echo -e "${GREEN}$*${RESET}"; }
y()  { echo -e "${YELLOW}$*${RESET}"; }
p()  { echo -e "${PURPLE}$*${RESET}"; }
c()  { echo -e "${CYAN}$*${RESET}"; }
b()  { echo -e "${BOLD}$*${RESET}"; }

step()  { echo -e "\n${CYAN}┌─ ${BOLD}[$(printf '%02d' $STEP_NUM)/$STEP_TOTAL]${RESET}${CYAN} $*${RESET}"; STEP_NUM=$((STEP_NUM+1)); }
ok()    { echo -e "${GREEN}└─ ✓ $*${RESET}"; }
info()  { echo -e "${YELLOW}│  $*${RESET}"; }
fail()  { echo -e "${RED}└─ ✗ $*${RESET}" >&2; exit 1; }
warn()  { echo -e "${YELLOW}└─ ⚠ $*${RESET}"; }

STEP_NUM=1
STEP_TOTAL=10

OS_NAME="$(uname -s)"
ARCH_RAW="$(uname -m)"
IS_MACOS=false
HAS_SYSTEMD=false
[[ "${OS_NAME}" == "Darwin" ]] && IS_MACOS=true
command -v systemctl >/dev/null 2>&1 && HAS_SYSTEMD=true

# root 检查与权限变量
IS_ROOT=false
[[ $EUID -eq 0 ]] && IS_ROOT=true

if $IS_MACOS; then
    if $IS_ROOT; then
        WORK_DIR="/usr/local/etc/xray-argo"
        BIN_PATH="/usr/local/bin/2go"
    else
        WORK_DIR="$HOME/Library/Application Support/xray-argo"
        BIN_PATH="$HOME/.local/bin/2go"
    fi
else
    if $IS_ROOT; then
        WORK_DIR="/etc/xray-argo"
        BIN_PATH="/usr/bin/2go"
    else
        WORK_DIR="$HOME/.local/share/xray-argo"
        BIN_PATH="$HOME/.local/bin/2go"
    fi
fi

CONFIG_FILE="${WORK_DIR}/config.json"
URL_FILE="${WORK_DIR}/url.txt"
SUB_FILE="${WORK_DIR}/sub.txt"
ARGO_LOG="${WORK_DIR}/argo.log"
XRAY_LOG="${WORK_DIR}/xray.log"
ARGO_PORT="${PORT:-$(awk 'BEGIN { srand(); print int(50000 + rand() * 15535) }')}"

if [[ -n "${TERM:-}" ]]; then
    clear || true
fi

echo -e "${PURPLE}"
cat << 'BANNER'
  ╔═══════════════════════════════════════════════╗
  ║     Xray-2go + Argo 临时隧道 一键安装         ║
  ║         VMess · WebSocket · Cloudflare        ║
  ╚═══════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"
echo -e "  系统 : ${CYAN}${OS_NAME} / ${ARCH_RAW}${RESET}"
echo -e "  目录 : ${CYAN}${WORK_DIR}${RESET}"
echo -e "  时间 : ${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo ""

base64_nowrap() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w0 "$@"
    else
        base64 "$@" | tr -d '\n'
    fi
}

gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

random_port() {
    if command -v shuf &>/dev/null; then
        shuf -i 50000-65535 -n 1
    elif command -v jot &>/dev/null; then
        jot -r 1 50000 65535
    else
        awk 'BEGIN { srand(); print int(50000 + rand() * 15535) }'
    fi
}

download_with_progress() {
    local url="$1"
    local output="$2"
    local label="$3"
    local tmp_file="${output}.tmp"

    info "下载: ${label}"

    local sources=(
        "${url}"
        "https://ghfast.top/${url}"
        "https://ghproxy.com/${url}"
        "https://github.moeyy.xyz/${url}"
        "https://p.ff11.tk/${url}"
    )

    local attempt=0
    for src_url in "${sources[@]}"; do
        attempt=$((attempt + 1))
        rm -f "$tmp_file"

        if [[ $attempt -eq 1 ]]; then
            info "尝试 [${attempt}/${#sources[@]}] 直连 GitHub"
        else
            local mirror_host
            mirror_host=$(echo "$src_url" | awk -F/ '{print $3}')
            info "尝试 [${attempt}/${#sources[@]}] 镜像: ${mirror_host}"
        fi

        if [[ -e /dev/tty ]] && [[ -r /dev/tty ]] && [[ -w /dev/tty ]] && [[ -t 1 ]]; then
            if curl -fL --progress-bar --connect-timeout 15 --speed-limit 5120 --speed-time 20 -o "$tmp_file" "$src_url" 2>/dev/tty; then
                mv "$tmp_file" "$output"
                local size
                size=$(du -sh "$output" 2>/dev/null | cut -f1)
                ok "${label} 下载完成 (${size})"
                return 0
            fi
        else
            if curl -fL --connect-timeout 15 --speed-limit 5120 --speed-time 20 -o "$tmp_file" "$src_url"; then
                mv "$tmp_file" "$output"
                local size
                size=$(du -sh "$output" 2>/dev/null | cut -f1)
                ok "${label} 下载完成 (${size})"
                return 0
            fi
        fi

        warn "下载失败，尝试下一个源..."
    done

    rm -f "$tmp_file"
    fail "${label} 所有下载源均失败，请检查网络连接"
}

step "检测系统架构"
XRAY_ASSET=""
ARGO_ASSET=""

if $IS_MACOS; then
    case "${ARCH_RAW}" in
        'x86_64') XRAY_ASSET="Xray-macos-64.zip"; ARGO_ASSET="cloudflared-darwin-amd64.tgz" ;;
        'arm64'|'aarch64') XRAY_ASSET="Xray-macos-arm64-v8a.zip"; ARGO_ASSET="cloudflared-darwin-arm64.tgz" ;;
        *) fail "macOS 暂不支持该架构: ${ARCH_RAW}" ;;
    esac
else
    case "${ARCH_RAW}" in
        'x86_64') XRAY_ASSET="Xray-linux-64.zip"; ARGO_ASSET="cloudflared-linux-amd64" ;;
        'aarch64'|'arm64') XRAY_ASSET="Xray-linux-arm64-v8a.zip"; ARGO_ASSET="cloudflared-linux-arm64" ;;
        'armv7l') XRAY_ASSET="Xray-linux-arm32-v7a.zip"; ARGO_ASSET="cloudflared-linux-armhf" ;;
        'i386'|'i686') XRAY_ASSET="Xray-linux-32.zip"; ARGO_ASSET="cloudflared-linux-386" ;;
        's390x') XRAY_ASSET="Xray-linux-s390x.zip"; ARGO_ASSET="cloudflared-linux-s390x" ;;
        *) fail "暂不支持的架构: ${ARCH_RAW}" ;;
    esac
fi

info "系统平台 : $($IS_MACOS && echo macOS || echo Linux)"
info "CPU 架构 : ${ARCH_RAW}"
info "Xray 包  : ${XRAY_ASSET}"
info "Argo 包  : ${ARGO_ASSET}"
ok "架构检测完成"

step "检查并安装依赖"
if $IS_MACOS; then
    for cmd in curl unzip jq; do
        if command -v "$cmd" &>/dev/null; then
            info "${cmd} ✓ ($(command -v "$cmd"))"
        else
            if [[ "$cmd" == "jq" ]]; then
                warn "jq 未安装，请先运行: brew install jq"
                warn "继续安装，但 change_config 功能可能受限"
            else
                fail "依赖 ${cmd} 未找到，请手动安装"
            fi
        fi
    done
else
    PKGS_NEEDED=()
    for pkg in curl unzip jq; do
        command -v "$pkg" &>/dev/null || PKGS_NEEDED+=("$pkg")
    done
    if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
        if $IS_ROOT; then
            info "需要安装: ${PKGS_NEEDED[*]}"
            if command -v apt &>/dev/null; then
                DEBIAN_FRONTEND=noninteractive apt-get update -qq
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS_NEEDED[@]}"
            elif command -v dnf &>/dev/null; then
                dnf install -y -q "${PKGS_NEEDED[@]}"
            elif command -v yum &>/dev/null; then
                yum install -y -q "${PKGS_NEEDED[@]}"
            elif command -v apk &>/dev/null; then
                apk add --quiet "${PKGS_NEEDED[@]}"
            else
                fail "无法识别的包管理器，请手动安装: ${PKGS_NEEDED[*]}"
            fi
        else
            warn "缺少依赖: ${PKGS_NEEDED[*]}"
            if [[ " ${PKGS_NEEDED[*]} " == *" jq "* ]]; then
                warn "继续安装，但 change_config 功能可能受限"
                PKGS_CRITICAL=()
                for p in "${PKGS_NEEDED[@]}"; do [[ "$p" != "jq" ]] && PKGS_CRITICAL+=("$p"); done
                [[ ${#PKGS_CRITICAL[@]} -gt 0 ]] && fail "请手动安装缺失的关键依赖: ${PKGS_CRITICAL[*]}"
            else
                fail "请手动安装缺失的依赖: ${PKGS_NEEDED[*]}"
            fi
        fi
    fi
fi
ok "依赖检查完成"

step "准备安装目录"
if $IS_MACOS || ! $HAS_SYSTEMD; then
    pkill -f "${WORK_DIR}/xray run" &>/dev/null || true
    pkill -f "${WORK_DIR}/argo tunnel" &>/dev/null || true
    info "已停止旧 xray / argo 进程"
else
    if $IS_ROOT; then
        systemctl stop xray 2>/dev/null || true
        systemctl stop tunnel 2>/dev/null || true
    else
        systemctl --user stop xray 2>/dev/null || true
        systemctl --user stop tunnel 2>/dev/null || true
    fi
    info "已停止旧 systemd 服务"
fi
mkdir -p "${WORK_DIR}"
mkdir -p "$(dirname "${BIN_PATH}")"
chmod 755 "${WORK_DIR}"
info "安装目录 : ${WORK_DIR}"
ok "目录准备完成"

step "下载 Xray-core"
XRAY_URL="https://github.com/opengaoling/xray-onekey-script-persist-firewall/releases/latest/download/${XRAY_ASSET}"
XRAY_ZIP="${WORK_DIR}/xray.zip"
download_with_progress "$XRAY_URL" "$XRAY_ZIP" "Xray-core (${XRAY_ASSET})"

step "下载 cloudflared (Argo 隧道)"
ARGO_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/${ARGO_ASSET}"
ARGO_OUT="${WORK_DIR}/argo_raw"
download_with_progress "$ARGO_URL" "$ARGO_OUT" "cloudflared (${ARGO_ASSET})"

step "解压并配置二进制文件"
info "解压 Xray-core..."
unzip -o "${XRAY_ZIP}" -d "${WORK_DIR}/" > /dev/null 2>&1
rm -f "${XRAY_ZIP}" "${WORK_DIR}/geosite.dat" "${WORK_DIR}/geoip.dat" "${WORK_DIR}/README.md" "${WORK_DIR}/LICENSE"
[[ -f "${WORK_DIR}/xray" ]] || fail "Xray 解压失败，未找到 ${WORK_DIR}/xray"
chmod +x "${WORK_DIR}/xray"
info "xray 版本: $("${WORK_DIR}/xray" version 2>/dev/null | head -1 || echo '未知')"

if [[ "${ARGO_ASSET}" == *.tgz ]] || [[ "${ARGO_ASSET}" == *.tar.gz ]]; then
    info "解压 cloudflared..."
    tar -xzf "${ARGO_OUT}" -C "${WORK_DIR}/" > /dev/null 2>&1
    rm -f "${ARGO_OUT}"
    [[ -f "${WORK_DIR}/cloudflared" ]] && mv -f "${WORK_DIR}/cloudflared" "${WORK_DIR}/argo"
else
    mv -f "${ARGO_OUT}" "${WORK_DIR}/argo"
fi
[[ -f "${WORK_DIR}/argo" ]] || fail "cloudflared 处理失败，未找到 ${WORK_DIR}/argo"
chmod +x "${WORK_DIR}/argo"
info "argo 版本: $("${WORK_DIR}/argo" version 2>/dev/null | head -1 || echo '未知')"
ok "二进制文件就绪"

step "生成节点配置"
UUID="${UUID:-$(gen_uuid)}"
VMESS_WS_PORT=$(random_port)
while [[ "${VMESS_WS_PORT}" == "${ARGO_PORT}" ]]; do VMESS_WS_PORT=$(random_port); done

info "UUID           : ${UUID}"
info "Argo Main Port : ${ARGO_PORT}"
info "Internal Port  : ${VMESS_WS_PORT}"

cat > "${CONFIG_FILE}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": ${ARGO_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}" }],
        "decryption": "none",
        "fallbacks": [
          { "path": "/vmess-argo", "dest": ${VMESS_WS_PORT} },
          { "dest": 80 }
        ]
      },
      "streamSettings": { "network": "tcp" }
    },
    {
      "port": ${VMESS_WS_PORT}, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [{ "id": "${UUID}", "alterId": 0 }] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess-argo" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    }
  ],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
ok "配置文件生成完成: ${CONFIG_FILE}"

step "启动 Xray 服务"
if $IS_MACOS || ! $HAS_SYSTEMD; then
    "${WORK_DIR}/xray" run -c "${CONFIG_FILE}" < /dev/null > "${XRAY_LOG}" 2>&1 &
    XRAY_PID=$!
    disown "$XRAY_PID" 2>/dev/null || true
    info "Xray PID: ${XRAY_PID}"
    sleep 2
    if kill -0 "$XRAY_PID" 2>/dev/null; then
        ok "Xray 已在后台启动 (PID: ${XRAY_PID})"
    else
        r "Xray 启动失败，日志如下:"
        tail -20 "${XRAY_LOG}" 2>/dev/null || true
        fail "Xray 进程已退出，请检查配置"
    fi
else
    if $IS_ROOT; then
        SERVICE_FILE="/etc/systemd/system/xray.service"
        SYSTEMCTL_CMD="systemctl"
    else
        SERVICE_FILE="$HOME/.config/systemd/user/xray.service"
        SYSTEMCTL_CMD="systemctl --user"
        mkdir -p "$(dirname "$SERVICE_FILE")"
    fi

    cat > "$SERVICE_FILE" << SVCEOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=${WORK_DIR}/xray run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s

[Install]
$( $IS_ROOT && echo "WantedBy=multi-user.target" || echo "WantedBy=default.target" )
SVCEOF
    $SYSTEMCTL_CMD daemon-reload
    $SYSTEMCTL_CMD enable xray --now
    sleep 2
    if $SYSTEMCTL_CMD is-active --quiet xray; then
        ok "Xray systemd 服务已启动"
    else
        r "Xray 服务启动失败:"
        $SYSTEMCTL_CMD status xray --no-pager | tail -20 || true
        fail "请检查配置文件: ${CONFIG_FILE}"
    fi
    if $IS_ROOT; then
        iptables -F >/dev/null 2>&1 && iptables -P INPUT ACCEPT >/dev/null 2>&1 && iptables -P FORWARD ACCEPT >/dev/null 2>&1 && iptables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
        command -v ip6tables &>/dev/null && ip6tables -F >/dev/null 2>&1 && ip6tables -P INPUT ACCEPT >/dev/null 2>&1 || true
        info "已配置 iptables 放行规则"
    fi
fi

step "启动 Argo 临时隧道 & 获取域名"

# 1. 针对 Linux Systemd 系统，预先创建服务模板
if ! $IS_MACOS && $HAS_SYSTEMD; then
    if $IS_ROOT; then
        TUNNEL_SERVICE_FILE="/etc/systemd/system/tunnel.service"
        SYSTEMCTL_CMD="systemctl"
    else
        TUNNEL_SERVICE_FILE="$HOME/.config/systemd/user/tunnel.service"
        SYSTEMCTL_CMD="systemctl --user"
        mkdir -p "$(dirname "$TUNNEL_SERVICE_FILE")"
    fi

    cat > "$TUNNEL_SERVICE_FILE" << TEOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=${WORK_DIR}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol auto
StandardOutput=append:${ARGO_LOG}
StandardError=append:${ARGO_LOG}
Restart=on-failure
RestartSec=5s

[Install]
$( $IS_ROOT && echo "WantedBy=multi-user.target" || echo "WantedBy=default.target" )
TEOF
    $SYSTEMCTL_CMD daemon-reload
    $SYSTEMCTL_CMD enable tunnel >/dev/null 2>&1 || true
fi

MAX_ARGO_RETRIES=5
ARGO_RETRY_COUNT=0
ARGO_DOMAIN=""

while [[ $ARGO_RETRY_COUNT -lt $MAX_ARGO_RETRIES ]]; do
    ARGO_RETRY_COUNT=$((ARGO_RETRY_COUNT + 1))
    [[ $ARGO_RETRY_COUNT -gt 1 ]] && warn "正在重试 [${ARGO_RETRY_COUNT}/${MAX_ARGO_RETRIES}]..."
    
    rm -f "${ARGO_LOG}"
    
    # 2. 启动/重启进程
    if ! $IS_MACOS && $HAS_SYSTEMD; then
        $SYSTEMCTL_CMD restart tunnel
    else
        "${WORK_DIR}/argo" tunnel --url "http://localhost:${ARGO_PORT}" --no-autoupdate --edge-ip-version auto --protocol auto < /dev/null > "${ARGO_LOG}" 2>&1 &
        ARGO_PID=$!
        disown "$ARGO_PID" 2>/dev/null || true
    fi
    
    # 3. 等待日志中出现域名
    for i in $(seq 1 15); do
        sleep 2
        ARGO_DOMAIN=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${ARGO_LOG}" 2>/dev/null | tail -1)
        [[ -n "${ARGO_DOMAIN}" ]] && break
        printf "\r  ${CYAN}│  等待域名展示... %ds${RESET}" $((i*2))
    done
    echo ""

    if [[ -n "${ARGO_DOMAIN}" ]]; then
        info "已获域名: ${ARGO_DOMAIN}，正在实时检测 (需 5-10s)..."
        sleep 8
        HTTP_CODE=$(curl -s -L -o /dev/null -w "%{http_code}" --max-time 10 "https://${ARGO_DOMAIN}" || echo "000")
        if [[ "${HTTP_CODE}" == "530" || "${HTTP_CODE}" == "404" ]]; then
            warn "检测到 HTTP ${HTTP_CODE} (隧道未就绪)，正在拉起重试..."
            if ! $IS_MACOS && $HAS_SYSTEMD; then $SYSTEMCTL_CMD stop tunnel; else kill "$ARGO_PID" 2>/dev/null || true; fi
            sleep 3
            ARGO_DOMAIN=""
        else
            ok "连通性检测通过 (HTTP ${HTTP_CODE})"
            break
        fi
    else
        warn "未能从日志获取域名，正在重新启动..."
        if ! $IS_MACOS && $HAS_SYSTEMD; then $SYSTEMCTL_CMD stop tunnel; else kill "$ARGO_PID" 2>/dev/null || true; fi
        sleep 2
    fi
done

if [[ -z "${ARGO_DOMAIN}" ]]; then
    fail "在 ${MAX_ARGO_RETRIES} 次尝试后仍未能建立健康的隧道，请检查网络或稍后重试"
fi

step "生成节点订阅信息"
CFIP="${CFIP:-}"
CFPORT="${CFPORT:-443}"
USE_CFIP=false
if [[ -n "${CFIP}" ]]; then
    USE_CFIP=true
fi

info "获取公网 IP..."
PUBLIC_IP=$(curl -s --max-time 5 ipv4.ip.sb 2>/dev/null || true)
if [[ -z "${PUBLIC_IP}" ]]; then
    IPV6=$(curl -s --max-time 5 ipv6.ip.sb 2>/dev/null || true)
    PUBLIC_IP="[${IPV6}]"
fi
info "公网 IP: ${PUBLIC_IP}"

ISP=$(curl -sm 4 -H "User-Agent: Mozilla" "https://api.ip.sb/geoip" 2>/dev/null | awk -F'"' '{for(i=1;i<=NF;i++){if($i=="country_code")cc=$(i+2);if($i=="isp")isp=$(i+2)};if(cc&&isp)print cc"-"isp}' | sed 's/ /_/g' || echo "vps")
info "ISP: ${ISP}"

DIRECT_ADD="${ARGO_DOMAIN}"
DIRECT_PORT="443"
if $USE_CFIP; then
    NODE_ADD="${CFIP}"
    NODE_PORT="${CFPORT}"
    NODE_NAME="${ISP}-Argo-VMess-CF"
else
    NODE_ADD="${DIRECT_ADD}"
    NODE_PORT="${DIRECT_PORT}"
    NODE_NAME="${ISP}-Argo-VMess"
fi

VMESS_ARGO_WS="vmess://$(echo "{\"v\":\"2\",\"ps\":\"${NODE_NAME}\",\"add\":\"${NODE_ADD}\",\"port\":\"${NODE_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"aes-128-gcm\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_DOMAIN}\",\"path\":\"/vmess-argo?ed=2560\",\"tls\":\"tls\",\"sni\":\"${ARGO_DOMAIN}\",\"alpn\":\"\",\"fp\":\"chrome\",\"insecure\":\"0\"}" | base64_nowrap)"

cat > "${URL_FILE}" << URLEOF
${VMESS_ARGO_WS}
URLEOF

if ! $IS_MACOS; then
    base64_nowrap "${URL_FILE}" > "${SUB_FILE}"
fi
ok "节点信息已写入: ${URL_FILE}"

cat > "${WORK_DIR}/manage.sh" << MANAGE
#!/usr/bin/env bash
WORK_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
IS_MACOS=false
HAS_SYSTEMD=false
IS_ROOT=false
[[ "\$(uname -s)" == "Darwin" ]] && IS_MACOS=true
command -v systemctl >/dev/null 2>&1 && HAS_SYSTEMD=true
[[ \$EUID -eq 0 ]] && IS_ROOT=true

SYSTEMCTL_CMD="systemctl"
if ! \$IS_ROOT && \$HAS_SYSTEMD; then
    SYSTEMCTL_CMD="systemctl --user"
fi

case "\${1:-status}" in
    start)
        if \$IS_MACOS && ! \$IS_ROOT; then
            launchctl load -w "\$HOME/Library/LaunchAgents/com.xray.argo.plist" 2>/dev/null || true
            launchctl load -w "\$HOME/Library/LaunchAgents/com.argo.tunnel.plist" 2>/dev/null || true
            echo "macOS services started via launchctl"
        elif \$IS_MACOS || ! \$HAS_SYSTEMD; then
            "\$WORK_DIR/xray" run -c "\$WORK_DIR/config.json" < /dev/null > "\$WORK_DIR/xray.log" 2>&1 &
            disown \$! 2>/dev/null || true
            "\$WORK_DIR/argo" tunnel --url "http://localhost:${ARGO_PORT}" --no-autoupdate --edge-ip-version auto --protocol auto < /dev/null > "\$WORK_DIR/argo.log" 2>&1 &
            disown \$! 2>/dev/null || true
        else
            \$SYSTEMCTL_CMD start xray tunnel
        fi ;;
    stop)
        if \$IS_MACOS && ! \$IS_ROOT; then
            launchctl unload -w "\$HOME/Library/LaunchAgents/com.xray.argo.plist" 2>/dev/null || true
            launchctl unload -w "\$HOME/Library/LaunchAgents/com.argo.tunnel.plist" 2>/dev/null || true
            echo "macOS services stopped via launchctl"
        elif \$IS_MACOS || ! \$HAS_SYSTEMD; then
            pkill -f "\$WORK_DIR/xray run" && echo "Xray stopped" || echo "Xray not running"
            pkill -f "\$WORK_DIR/argo tunnel" && echo "Argo stopped" || echo "Argo not running"
        else
            \$SYSTEMCTL_CMD stop xray tunnel
        fi ;;
    restart)
        "\$0" stop; sleep 1; "\$0" start ;;
    status)
        if \$IS_MACOS && ! \$IS_ROOT; then
            launchctl list com.xray.argo >/dev/null 2>&1 && echo "Xray: running (launchd)" || echo "Xray: stopped"
            launchctl list com.argo.tunnel >/dev/null 2>&1 && echo "Argo: running (launchd)" || echo "Argo: stopped"
        elif \$IS_MACOS || ! \$HAS_SYSTEMD; then
            pgrep -f "\$WORK_DIR/xray run" > /dev/null && echo "Xray: running" || echo "Xray: stopped"
            pgrep -f "\$WORK_DIR/argo tunnel" > /dev/null && echo "Argo: running" || echo "Argo: stopped"
        else
            \$SYSTEMCTL_CMD status xray --no-pager -l
            \$SYSTEMCTL_CMD status tunnel --no-pager -l
        fi ;;
    nodes)
        cat "\$WORK_DIR/url.txt" ;;
    log-xray)
        if \$IS_MACOS || ! \$HAS_SYSTEMD; then tail -50 "\$WORK_DIR/xray.log"; else journalctl \$(! \$IS_ROOT && echo "--user") -u xray -n 50; fi ;;
    log-argo)
        tail -50 "\$WORK_DIR/argo.log" ;;
    uninstall)
        echo -e "\033[33m警告：这将停止服务并删除所有相关文件和配置！\033[0m"
        read -p "确定要卸载吗？(y/n): " confirm
        [[ "\$confirm" != "y" ]] && echo "已取消" && exit 0
        "\$0" stop
        if ! \$IS_MACOS && \$HAS_SYSTEMD; then
            \$SYSTEMCTL_CMD disable xray tunnel >/dev/null 2>&1 || true
            if \$IS_ROOT; then
                rm -f /etc/systemd/system/xray.service /etc/systemd/system/tunnel.service
            else
                rm -f "\$HOME/.config/systemd/user/xray.service" "\$HOME/.config/systemd/user/tunnel.service"
            fi
            \$SYSTEMCTL_CMD daemon-reload
        elif \$IS_MACOS && ! \$IS_ROOT; then
            rm -f "\$HOME/Library/LaunchAgents/com.xray.argo.plist" "\$HOME/Library/LaunchAgents/com.argo.tunnel.plist"
        fi
        echo "正在删除安装目录: \$WORK_DIR"
        rm -rf "\$WORK_DIR"
        echo "卸载成功！" ;;
    *)
        echo "用法: \$0 {start|stop|restart|status|nodes|log-xray|log-argo|uninstall}" ;;
esac
MANAGE
chmod +x "${WORK_DIR}/manage.sh"
ln -sf "${WORK_DIR}/manage.sh" "${BIN_PATH}" 2>/dev/null || true
[[ -L "${BIN_PATH}" ]] && ok "快捷命令已创建: 2go {start|stop|restart|status|nodes|log-xray|log-argo|uninstall}"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}${BOLD}                    ✅ 安装完成！                             ${RESET}${CYAN}║${RESET}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${CYAN}║${RESET}  Xray   : ${GREEN}running${RESET}"
[[ "${ARGO_DOMAIN}" != "<argo-domain-pending>" ]] && \
echo -e "${CYAN}║${RESET}  Argo   : ${GREEN}${ARGO_DOMAIN}${RESET}" || \
echo -e "${CYAN}║${RESET}  Argo   : ${YELLOW}等待域名 (查看 ${ARGO_LOG})${RESET}"
echo -e "${CYAN}║${RESET}  配置   : ${CYAN}${CONFIG_FILE}${RESET}"
echo -e "${CYAN}║${RESET}  节点   : ${CYAN}${URL_FILE}${RESET}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${CYAN}║${RESET}${BOLD}  节点链接                                                    ${RESET}${CYAN}║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

echo -e "${YELLOW}── Argo VMess-WS ─────────────────────────────────────────────${RESET}"
echo -e "${PURPLE}${VMESS_ARGO_WS}${RESET}"
echo ""

echo -e "${CYAN}─── 管理命令 ──────────────────────────────────────────────────${RESET}"
echo -e "  ${GREEN}2go status${RESET}    查看运行状态"
echo -e "  ${GREEN}2go nodes${RESET}     查看节点链接"
echo -e "  ${GREEN}2go restart${RESET}   重启服务"
echo -e "  ${GREEN}2go log-argo${RESET}  查看 Argo 日志"
echo -e "  ${GREEN}2go uninstall${RESET} 一键卸载"
echo ""

if $IS_MACOS; then
    if ! $IS_ROOT; then
        info "正在配置 macOS launchd 用户服务..."
        PLIST_DIR="$HOME/Library/LaunchAgents"
        mkdir -p "$PLIST_DIR"
        
        # Xray plist
        cat > "${PLIST_DIR}/com.xray.argo.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xray.argo</string>
    <key>ProgramArguments</key>
    <array>
        <string>${WORK_DIR}/xray</string>
        <string>run</string>
        <string>-c</string>
        <string>${CONFIG_FILE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${XRAY_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${XRAY_LOG}</string>
    <key>WorkingDirectory</key>
    <string>${WORK_DIR}</string>
</dict>
</plist>
EOF

        # Argo plist
        cat > "${PLIST_DIR}/com.argo.tunnel.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.argo.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>${WORK_DIR}/argo</string>
        <string>tunnel</string>
        <string>--url</string>
        <string>http://localhost:${ARGO_PORT}</string>
        <string>--no-autoupdate</string>
        <string>--edge-ip-version</string>
        <string>auto</string>
        <string>--protocol</string>
        <string>auto</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${ARGO_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${ARGO_LOG}</string>
    <key>WorkingDirectory</key>
    <string>${WORK_DIR}</string>
</dict>
</plist>
EOF
        launchctl load -w "${PLIST_DIR}/com.xray.argo.plist" 2>/dev/null || true
        launchctl load -w "${PLIST_DIR}/com.argo.tunnel.plist" 2>/dev/null || true
        ok "macOS 用户服务已配置并设为开机自启"
    else
        warn "macOS 提示: 当前以 root 运行，未配置 launchd。如需开机自启，请以普通用户身份安装。"
    fi
fi

# 启用 lingering (Linux 非 root)
if ! $IS_ROOT && ! $IS_MACOS && $HAS_SYSTEMD; then
    if command -v loginctl > /dev/null 2>&1; then
        info "正在启用用户 lingering（让服务在登出后继续运行）..."
        loginctl enable-linger "$USER" 2>/dev/null || true
    fi
fi

# 自动清理脚本自身
if [[ -f "$0" && "$0" == *"install_argo.sh"* ]]; then
    rm -f "$0"
fi
