#!/bin/bash

# Xray Reality One-Key Installer
# Adapted for Xray-core with VLESS-XTLS-uTLS-REALITY

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# root 检查与权限变量
IS_ROOT=false
[[ $EUID -eq 0 ]] && IS_ROOT=true

if $IS_ROOT; then
    XRAY_BIN_DIR="/usr/local/bin"
    XRAY_BIN_PATH="${XRAY_BIN_DIR}/xray"
    XRAY_ETC_DIR="/usr/local/etc/xray"
    XRAY_LOG_DIR="/var/log/xray"
    XRAY_SHORTCUT_PATH="${XRAY_BIN_DIR}/xr"
    SYSTEMD_FILE="/etc/systemd/system/xray.service"
    SYSTEMCTL_CMD="systemctl"
    
    if [[ -f /etc/openwrt_release ]]; then
        XRAY_BIN_DIR="/usr/bin"
        XRAY_BIN_PATH="${XRAY_BIN_DIR}/xray"
        XRAY_ETC_DIR="/etc/xray"
        XRAY_SHORTCUT_PATH="${XRAY_BIN_DIR}/xr"
    fi
else
    XRAY_BIN_DIR="$HOME/.local/bin"
    XRAY_BIN_PATH="${XRAY_BIN_DIR}/xray"
    XRAY_ETC_DIR="$HOME/.local/share/xray"
    XRAY_LOG_DIR="$HOME/.local/state/xray/log"
    XRAY_SHORTCUT_PATH="${XRAY_BIN_DIR}/xr"
    SYSTEMD_FILE="$HOME/.config/systemd/user/xray.service"
    SYSTEMCTL_CMD="systemctl --user"
fi

XRAY_CONFIG_FILE="${XRAY_ETC_DIR}/config.json"
XRAY_PUBLIC_KEY_FILE="${XRAY_ETC_DIR}/public.key"
XRAY_SHARE_LINK_FILE="${XRAY_ETC_DIR}/share_link.txt"

check_root() {
    if ! $IS_ROOT; then
        echo -e "${YELLOW}Warning: Running as non-root user. Installation will be local to your home directory.${PLAIN}"
    fi
}

install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${PLAIN}"
    if $IS_ROOT; then
        if [[ -f /etc/debian_version ]]; then
            apt-get update
            apt-get install -y curl wget tar unzip jq net-tools qrencode procps gawk
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y curl wget tar unzip jq net-tools qrencode procps
        elif [[ -f /etc/openwrt_release ]] || [[ -f /etc/opkg.conf ]]; then
            opkg update
            opkg install bash curl wget-ssl unzip jq ca-bundle net-tools-netstat qrencode
        elif [[ -f /etc/alpine-release ]]; then
            apk update
            apk add bash curl wget tar unzip jq util-linux net-tools qrencode ca-certificates
        else
            echo -e "${RED}Unsupported OS for automatic dependency installation. Please install manually.${PLAIN}"
        fi
    else
        echo -e "${YELLOW}Non-root mode: Checking for required dependencies...${PLAIN}"
        for cmd in curl wget tar unzip jq qrencode; do
            if ! command -v $cmd >/dev/null 2>&1; then
                if [[ "$cmd" == "qrencode" ]]; then
                    echo -e "${YELLOW}Warning: 'qrencode' not found. QR code display will be skipped.${PLAIN}"
                else
                    echo -e "${RED}Error: Dependency '$cmd' not found. Please install it manually.${PLAIN}"
                    exit 1
                fi
            fi
        done
        echo -e "${GREEN}Dependencies check completed.${PLAIN}"
    fi
}

install_xray_core() {
    echo -e "${YELLOW}Downloading Xray-core...${PLAIN}"
    # Get latest release version
    LATEST_VER=$(curl -s https://api.github.com/repos/obkj/xray-onekey-script/releases/latest | jq -r .tag_name)
    if [[ -z "$LATEST_VER" ]]; then
        echo -e "${RED}Failed to fetch latest Xray version.${PLAIN}"
        exit 1
    fi
    
    echo -e "${GREEN}Latest version: ${LATEST_VER}${PLAIN}"
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="64" ;;
        aarch64) ARCH="arm64-v8a" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH${PLAIN}"; exit 1 ;;
    esac

    DOWNLOAD_URL="https://github.com/obkj/xray-onekey-script/releases/download/${LATEST_VER}/Xray-linux-${ARCH}.zip"
    
    mkdir -p /tmp/xray
    wget -O /tmp/xray/xray.zip "$DOWNLOAD_URL"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Download failed.${PLAIN}"
        exit 1
    fi

    unzip -o /tmp/xray/xray.zip -d /tmp/xray
    mkdir -p "$XRAY_BIN_DIR"
    mv /tmp/xray/xray "$XRAY_BIN_PATH"
    chmod +x "$XRAY_BIN_PATH"
    rm -rf /tmp/xray
    
    mkdir -p "$XRAY_ETC_DIR"
    mkdir -p "$XRAY_LOG_DIR"
}

generate_config() {
    echo -e "${YELLOW}Generating configuration...${PLAIN}"
    
    # Generate UUID
    UUID=$($XRAY_BIN_PATH uuid)
    
    # Generate Keys
    KEYS=$($XRAY_BIN_PATH x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYS" | grep -i "Password" | awk '{print $NF}')
    
    if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}Error: Failed to generate Xray keys.${PLAIN}"
        echo -e "${RED}Debug: $KEYS${PLAIN}"
        exit 1
    fi
    
    # Save Public Key for later retrieval
    echo "$PUBLIC_KEY" > "$XRAY_PUBLIC_KEY_FILE"
    
    # Generate ShortId
    SHORT_ID=$($XRAY_BIN_PATH uuid | tr -d '-' | head -c 16)
    
    # Generate VLESS Port
    echo -e "${YELLOW}Generating random high port for VLESS (50000+)...${PLAIN}"
    while true; do
        PORT=$((RANDOM % 15536 + 50000))
        if command -v netstat >/dev/null; then
            if netstat -tuln | grep -q ":$PORT "; then
                continue
            fi
        elif command -v ss >/dev/null; then
            if ss -tuln | grep -q ":$PORT "; then
                continue
            fi
        fi
        echo -e "Using VLESS Port: ${GREEN}${PORT}${PLAIN}"
        break
    done

    # Generate VMess Port
    echo -e "${YELLOW}Generating random high port for VMess (50000+)...${PLAIN}"
    while true; do
        VMESS_PORT=$((RANDOM % 15536 + 50000))
        if [[ $VMESS_PORT -eq $PORT ]]; then
            continue
        fi
        if command -v netstat >/dev/null; then
            if netstat -tuln | grep -q ":$VMESS_PORT "; then
                continue
            fi
        elif command -v ss >/dev/null; then
            if ss -tuln | grep -q ":$VMESS_PORT "; then
                continue
            fi
        fi
        echo -e "Using VMess Port: ${GREEN}${VMESS_PORT}${PLAIN}"
        break
    done
    
    # Generate VMess UUID
    VMESS_UUID=$($XRAY_BIN_PATH uuid)
    
    DEST="www.microsoft.com"
    echo -e "Using default SNI/Dest: ${GREEN}${DEST}${PLAIN}"

    cat > "$XRAY_CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "none",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "serverNames": [
            "${DEST}"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "port": $VMESS_PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$VMESS_UUID",
            "alterId": 0
          }
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
}

setup_service() {
    echo -e "${YELLOW}Setting up Service...${PLAIN}"
    
    if $IS_ROOT && [[ -f /etc/openwrt_release ]]; then
        cat > "/etc/init.d/xray" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

PROG=$XRAY_BIN_PATH
CONF=$XRAY_CONFIG_FILE

start_service() {
	procd_open_instance
	procd_set_param command "\$PROG" run -config "\$CONF"
	procd_set_param respawn
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param user root
	procd_close_instance
}
EOF
        chmod +x /etc/init.d/xray
        /etc/init.d/xray enable
        /etc/init.d/xray restart
    elif $IS_ROOT && [[ -f /etc/alpine-release ]]; then
        cat > "/etc/init.d/xray" <<EOF
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="$XRAY_BIN_PATH"
command_args="run -config $XRAY_CONFIG_FILE"
command_background=true
pidfile="/run/xray.pid"

depend() {
    need net
    use dns
}
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default
        service xray restart
    elif [[ -f /etc/openwrt_release ]] || [[ -f /etc/alpine-release ]]; then
        echo -e "${RED}Error: Non-root service setup is not supported on OpenWrt/Alpine in this script.${PLAIN}"
        echo -e "${YELLOW}Please run as root or set up the service manually.${PLAIN}"
    else
        if ! $IS_ROOT; then
            mkdir -p "$(dirname "$SYSTEMD_FILE")"
        fi
        
        cat > "$SYSTEMD_FILE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
$( $IS_ROOT && echo "User=root" )
$( $IS_ROOT && echo "CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE" )
$( $IS_ROOT && echo "AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE" )
NoNewPrivileges=true
ExecStart=$XRAY_BIN_PATH run -config $XRAY_CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23

[Install]
$( $IS_ROOT && echo "WantedBy=multi-user.target" || echo "WantedBy=default.target" )
EOF

        $SYSTEMCTL_CMD daemon-reload
        $SYSTEMCTL_CMD enable xray
        $SYSTEMCTL_CMD restart xray
        
        if ! $IS_ROOT && command -v loginctl >/dev/null 2>&1; then
            echo -e "${YELLOW}Enabling lingering for user $USER...${PLAIN}"
            loginctl enable-linger "$USER" || true
        fi
    fi
}

is_running() {
    if [[ -f "$SYSTEMD_FILE" ]]; then
        $SYSTEMCTL_CMD is-active xray >/dev/null 2>&1
        return $?
    else
        # OpenWrt / Alpine (check process)
        pgrep -f "xray run" >/dev/null 2>&1
        return $?
    fi
}

create_shortcut() {
    echo -e "${YELLOW}Creating shortcut 'xr'...${PLAIN}"
    mkdir -p "$(dirname "$XRAY_SHORTCUT_PATH")"
    wget -O "$XRAY_SHORTCUT_PATH" https://raw.githubusercontent.com/obkj/xray-onekey-script/main/install.sh
    chmod +x "$XRAY_SHORTCUT_PATH"
    echo -e "${GREEN}Shortcut 'xr' created. You can run this script by typing 'xr'.${PLAIN}"
    if ! $IS_ROOT; then
        echo -e "${YELLOW}Note: Since you are not root, please ensure $XRAY_BIN_DIR is in your PATH to use 'xr'.${PLAIN}"
    fi
}

restart_service() {
    echo -e "${YELLOW}Restarting Xray service...${PLAIN}"
    if $IS_ROOT && ([[ -f /etc/openwrt_release ]] || [[ -f /etc/alpine-release ]]); then
        /etc/init.d/xray restart
    else
        $SYSTEMCTL_CMD restart xray
    fi
}

show_info() {
    if [[ ! -f "$XRAY_CONFIG_FILE" ]]; then
        echo -e "${RED}Xray config not found!${PLAIN}"
        return
    fi

    if [[ -z "$UUID" ]] || [[ "$UUID" == "null" ]]; then
        UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG_FILE")
        PORT=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG_FILE")
        DEST=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG_FILE")
        SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG_FILE")
        
        VMESS_UUID=$(jq -r '.inbounds[1].settings.clients[0].id' "$XRAY_CONFIG_FILE")
        VMESS_PORT=$(jq -r '.inbounds[1].port' "$XRAY_CONFIG_FILE")
    fi

    if [[ -z "$PUBLIC_KEY" ]] || [[ "$PUBLIC_KEY" == "null" ]]; then
        if [[ -f "$XRAY_PUBLIC_KEY_FILE" ]]; then
            PUBLIC_KEY=$(cat "$XRAY_PUBLIC_KEY_FILE")
        else
            PUBLIC_KEY="unknown"
        fi
    fi

    # Get IP
    IP=$(curl -s4 -m 5 ifconfig.me || curl -s4 -m 5 api.ip.sb/ip)

    # Get ISP Info (Remark)
    REMARK=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" | tr -d '\n' | awk -F\" '{c="";o="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="org")o=$(x+2)};if(c&&o)print c"-"o}' | sed 's/ /_/g' || echo "VPS")

    SHARE_LINK="vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST}&sid=${SHORT_ID}&spx=%2F#${REMARK}"
    VMESS_SHARE_LINK=$(echo -n "{\"v\":\"2\",\"ps\":\"${REMARK}_vmess\",\"add\":\"${IP}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"scy\":\"aes-128-gcm\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\"}" | base64 -w 0)
    VMESS_LINK="vmess://${VMESS_SHARE_LINK}"

    if command -v qrencode >/dev/null; then
        echo -e "${YELLOW}VLESS QR Code:${PLAIN}"
        qrencode -t ANSIUTF8 "${SHARE_LINK}"
        echo -e ""
        echo -e "${YELLOW}VMess QR Code:${PLAIN}"
        qrencode -t ANSIUTF8 "${VMESS_LINK}"
        echo -e ""
    fi
    echo -e "----------------vless Share Link----------------"
    echo -e "${GREEN}${SHARE_LINK}${PLAIN}"
    echo -e "----------------vmess Share Link----------------"
    echo -e "${GREEN}${VMESS_LINK}${PLAIN}"
    echo -e "------------------------------------------------"

    # Save share links to file
    echo "VLESS: ${SHARE_LINK}" > "$XRAY_SHARE_LINK_FILE"
    echo "VMESS: ${VMESS_LINK}" >> "$XRAY_SHARE_LINK_FILE"
}

open_port() {
    local port=$1
    [[ -z "$port" ]] && return

    if ! $IS_ROOT; then
        echo -e "${YELLOW}Skipping port opening (requires root). Please ensure port $port is open in your firewall.${PLAIN}"
        return
    fi

    echo -e "${YELLOW}Opening port $port...${PLAIN}"

    if [[ -f /etc/openwrt_release ]]; then
        uci set firewall.xray=rule
        uci set firewall.xray.name='xray'
        uci set firewall.xray.src='wan'
        uci set firewall.xray.dest_port="$port"
        uci set firewall.xray.proto='tcp'
        uci set firewall.xray.target='ACCEPT'
        uci commit firewall
        /etc/init.d/firewall restart
    elif command -v ufw >/dev/null; then
        ufw allow "$port"/tcp
        ufw reload
    elif command -v firewall-cmd >/dev/null; then
        firewall-cmd --zone=public --add-port="$port"/tcp --permanent
        firewall-cmd --reload
    elif command -v iptables >/dev/null; then
        add_iptables_port "$port"
    fi
}

close_port() {
    local port=$1
    [[ -z "$port" ]] && return

    if ! $IS_ROOT; then
        return
    fi

    echo -e "${YELLOW}Closing port $port...${PLAIN}"

    if [[ -f /etc/openwrt_release ]]; then
        uci delete firewall.xray
        uci commit firewall
        /etc/init.d/firewall restart
    elif command -v ufw >/dev/null; then
        ufw delete allow "$port"/tcp
        ufw reload
    elif command -v firewall-cmd >/dev/null; then
        firewall-cmd --zone=public --remove-port="$port"/tcp --permanent
        firewall-cmd --reload
    elif command -v iptables >/dev/null; then
        remove_iptables_port "$port"
    fi
}

add_iptables_port() {
    local port=$1
    local reject_line

    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        reject_line=$(iptables -L INPUT -n -v --line-numbers | awk '$4 == "REJECT" {print $1; exit}')
        if [[ -n "$reject_line" ]]; then
            iptables -I INPUT "$reject_line" -p tcp --dport "$port" -j ACCEPT
        else
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        fi
    fi

    persist_iptables_port "$port" add
}

remove_iptables_port() {
    local port=$1

    while iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; do
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT || break
    done

    persist_iptables_port "$port" remove
}

persist_iptables_port() {
    local port=$1
    local action=$2
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
                echo -e "${YELLOW}Warning: iptables-save not found. Port $port is open now but may not persist after reboot.${PLAIN}"
            fi
            return
        fi

        if grep -Fxq -- "$rule" "$rules_file"; then
            return
        fi

        tmp_file=$(mktemp)
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
        tmp_file=$(mktemp)
        grep -Fvx -- "$rule" "$rules_file" > "$tmp_file" || true
        mv "$tmp_file" "$rules_file"
        validate_iptables_rules_file "$rules_file"
    fi
}

validate_iptables_rules_file() {
    local rules_file=$1

    if command -v iptables-restore >/dev/null 2>&1; then
        if ! iptables-restore --test < "$rules_file" >/dev/null 2>&1; then
            echo -e "${YELLOW}Warning: $rules_file failed iptables-restore validation. Runtime firewall rule was still applied.${PLAIN}"
        fi
    fi

    if ! command -v netfilter-persistent >/dev/null 2>&1 && ! systemctl list-unit-files netfilter-persistent.service >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: netfilter-persistent is not installed. Install iptables-persistent/netfilter-persistent if this system does not load $rules_file on boot.${PLAIN}"
    fi
}

install_full() {
    install_dependencies
    install_xray_core
    generate_config
    open_port $PORT
    open_port $VMESS_PORT
    setup_service
    create_shortcut
    
    if is_running; then
        show_info
    else
        echo -e "${RED}Xray failed to start! Please check logs.${PLAIN}"
        if [[ -f /etc/systemd/system/xray.service ]]; then
            journalctl -u xray --no-pager | tail -n 10
        fi
    fi
}

uninstall_xray() {
    echo -e "${YELLOW}Uninstalling Xray...${PLAIN}"
    if [[ -f "$XRAY_CONFIG_FILE" ]]; then
        PORTS=$(jq -r '.inbounds[].port' "$XRAY_CONFIG_FILE")
        for port in $PORTS; do
            close_port $port
        done
    fi

    if $IS_ROOT && ([[ -f /etc/openwrt_release ]] || [[ -f /etc/alpine-release ]]); then
        /etc/init.d/xray stop
        if command -v rc-update >/dev/null; then
            rc-update del xray default
        else
            /etc/init.d/xray disable
        fi
        rm -f /etc/init.d/xray
    else
        $SYSTEMCTL_CMD stop xray
        $SYSTEMCTL_CMD disable xray
        rm -f "$SYSTEMD_FILE"
        $SYSTEMCTL_CMD daemon-reload
    fi
    
    rm -f "$XRAY_BIN_PATH"
    rm -rf "$XRAY_ETC_DIR"
    rm -rf "$XRAY_LOG_DIR"
    rm -f "$XRAY_SHORTCUT_PATH"
    
    echo -e "${GREEN}Xray uninstalled.${PLAIN}"
}

change_port() {
    if [[ ! -f "$XRAY_CONFIG_FILE" ]]; then
        echo -e "${RED}Xray not installed.${PLAIN}"
        return
    fi
    
    OLD_VLESS_PORT=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG_FILE")
    OLD_VMESS_PORT=$(jq -r '.inbounds[1].port' "$XRAY_CONFIG_FILE")
    
    echo -e "Current VLESS Port: ${GREEN}${OLD_VLESS_PORT}${PLAIN}"
    echo -e "Current VMess Port: ${GREEN}${OLD_VMESS_PORT}${PLAIN}"
    
    read -p "Enter new VLESS Port (default random): " NEW_VLESS_PORT
    if [[ -z "$NEW_VLESS_PORT" ]]; then
        while true; do
            NEW_VLESS_PORT=$((RANDOM % 15536 + 50000))
            if command -v netstat >/dev/null; then
                if netstat -tuln | grep -q ":$NEW_VLESS_PORT "; then continue; fi
            elif command -v ss >/dev/null; then
                if ss -tuln | grep -q ":$NEW_VLESS_PORT "; then continue; fi
            fi
            break
        done
    fi
    echo -e "Using VLESS Port: ${GREEN}${NEW_VLESS_PORT}${PLAIN}"
    
    read -p "Enter new VMess Port (default random): " NEW_VMESS_PORT
    if [[ -z "$NEW_VMESS_PORT" ]]; then
        while true; do
            NEW_VMESS_PORT=$((RANDOM % 15536 + 50000))
            if [[ $NEW_VMESS_PORT -eq $NEW_VLESS_PORT ]]; then continue; fi
            if command -v netstat >/dev/null; then
                if netstat -tuln | grep -q ":$NEW_VMESS_PORT "; then continue; fi
            elif command -v ss >/dev/null; then
                if ss -tuln | grep -q ":$NEW_VMESS_PORT "; then continue; fi
            fi
            break
        done
    fi
    echo -e "Using VMess Port: ${GREEN}${NEW_VMESS_PORT}${PLAIN}"
    
    TMP_FILE=$(mktemp)
    jq --arg vless_port "$NEW_VLESS_PORT" --arg vmess_port "$NEW_VMESS_PORT" \
       '.inbounds[0].port = ($vless_port|tonumber) | .inbounds[1].port = ($vmess_port|tonumber)' \
       "$XRAY_CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$XRAY_CONFIG_FILE"
    
    close_port $OLD_VLESS_PORT
    close_port $OLD_VMESS_PORT
    open_port $NEW_VLESS_PORT
    open_port $NEW_VMESS_PORT
    
    restart_service
    show_info
}

change_sni() {
    if [[ ! -f "$XRAY_CONFIG_FILE" ]]; then
        echo -e "${RED}Xray not installed.${PLAIN}"
        return
    fi

    read -p "Enter new SNI/Dest (e.g. www.google.com): " NEW_DEST
    [[ -z "$NEW_DEST" ]] && echo -e "${RED}SNI cannot be empty${PLAIN}" && return
    
    TMP_FILE=$(mktemp)
    jq --arg dest "$NEW_DEST" \
       '.inbounds[0].streamSettings.realitySettings.serverNames = [$dest] | .inbounds[0].streamSettings.realitySettings.dest = ($dest + ":443")' \
       "$XRAY_CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$XRAY_CONFIG_FILE"
       
    restart_service
    show_info
}

toggle_bbr() {
    if ! $IS_ROOT; then
        echo -e "${RED}Error: Modifying BBR requires root privileges.${PLAIN}"
        return
    fi
    if [[ -f /etc/sysctl.conf ]]; then
        if grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
            echo -e "${YELLOW}Disabling BBR...${PLAIN}"
            sed -i '/net.core.default_qdisc=fq/d' /etc/sysctl.conf
            sed -i '/net.ipv4.tcp_congestion_control=bbr/d' /etc/sysctl.conf
            sysctl -p
            echo -e "${GREEN}BBR disabled.${PLAIN}"
        else
            echo -e "${YELLOW}Enabling BBR...${PLAIN}"
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p
            echo -e "${GREEN}BBR enabled.${PLAIN}"
        fi
    fi
}

menu() {
    clear
    echo -e "Xray Reality Management Script"
    echo -e "--------------------------------"
    if is_running; then
        echo -e "Status: ${GREEN}Running${PLAIN}"
    else
        echo -e "Status: ${RED}Stopped${PLAIN}"
    fi
    echo -e "--------------------------------"
    echo -e "1. Install Xray"
    echo -e "2. Uninstall Xray"
    echo -e "3. Change Port"
    echo -e "4. Change SNI"
    echo -e "5. Show Info"
    if grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        echo -e "6. Disable BBR"
    else
        echo -e "6. Enable BBR"
    fi
    echo -e "0. Exit"
    echo -e "--------------------------------"
    read -p "Choose an option: " choice
    
    case $choice in
        1) install_full ;;
        2) uninstall_xray ;;
        3) change_port ;;
        4) change_sni ;;
        5) show_info ;;
        6) toggle_bbr ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option${PLAIN}" ;;
    esac
}

main() {
    check_root
    menu
}

main
