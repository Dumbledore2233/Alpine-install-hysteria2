#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        apk add --no-cache bash
    fi
    exec bash "$0" "$@"
fi

set -euo pipefail

CONFIG_FILE="/etc/hysteria/config.yaml"
CERT_FILE="/etc/hysteria/server.crt"
KEY_FILE="/etc/hysteria/server.key"
BIN_FILE="/usr/local/bin/hysteria"
SERVICE_FILE="/etc/init.d/hysteria"
DEFAULT_SNI="bing.com"

get_cap_net_admin() {
    local cap_hex=""
    cap_hex=$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null || true)
    if [ -n "$cap_hex" ] && (( (16#$cap_hex & 0x1000) != 0 )); then
        echo 1
    else
        echo 0
    fi
}

HAS_NET_ADMIN=$(get_cap_net_admin)

prompt_port_or_range() {
    local prompt_label="${1:-监听端口或端口范围}"
    local current_default="${2:-}"
    local default_port="$current_default"
    if [ -z "$default_port" ]; then
        default_port=$(shuf -i 10000-60000 -n 1)
    fi

    while true; do
        if [ "$HAS_NET_ADMIN" -eq 1 ]; then
            read -r -p "请输入 Hysteria 2 ${prompt_label} [默认 $default_port]（单端口示例：20000；端口范围示例：30000-40000）: " PORT_INPUT
        else
            read -r -p "请输入 Hysteria 2 单个${prompt_label} [默认 $default_port]（例如：20000；当前不允许输入端口范围）: " PORT_INPUT
        fi

        PORT_INPUT=${PORT_INPUT:-$default_port}

        if [ "$HAS_NET_ADMIN" -eq 0 ] && [[ "$PORT_INPUT" == *-* ]]; then
            echo "错误：当前进程缺少 CAP_NET_ADMIN，只允许输入单个端口，请重新输入。"
            continue
        fi

        if [[ "$PORT_INPUT" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]]; then
            START_PORT=$((10#${BASH_REMATCH[1]}))
            END_PORT=$START_PORT
            if [ -n "${BASH_REMATCH[3]:-}" ]; then
                END_PORT=$((10#${BASH_REMATCH[3]}))
            fi
            if (( START_PORT >= 1 && START_PORT <= 65535 &&
                  END_PORT >= 1 && END_PORT <= 65535 &&
                  START_PORT <= END_PORT )); then
                if [ -n "${BASH_REMATCH[3]:-}" ]; then
                    PORT_INPUT="${START_PORT}-${END_PORT}"
                else
                    PORT_INPUT="${START_PORT}"
                fi
                FIRST_PORT="$START_PORT"
                return 0
            fi
        fi
        echo "错误：端口格式无效。请输入 1-65535 范围内的端口，或合法的起止端口范围。"
    done
}

prompt_bandwidth_mbps() {
    local current_up="${1:-100}"
    local current_down="${2:-200}"
    local up_num=""
    local down_num=""

    while true; do
        read -r -p "请输入服务器上传带宽数值（单位自动为 mbps，0 表示不限）[默认 $current_up]: " up_num
        up_num=${up_num:-$current_up}
        if [[ "$up_num" =~ ^[0-9]+$ ]]; then
            break
        fi
        echo "错误：请输入非负整数（仅数字，无需输入单位）。"
    done

    while true; do
        read -r -p "请输入服务器下载带宽数值（单位自动为 mbps，0 表示不限）[默认 $current_down]: " down_num
        down_num=${down_num:-$current_down}
        if [[ "$down_num" =~ ^[0-9]+$ ]]; then
            break
        fi
        echo "错误：请输入非负整数（仅数字，无需输入单位）。"
    done

    BW_UP="${up_num} mbps"
    BW_DOWN="${down_num} mbps"
}

generate_password() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' |
            sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
    fi
}

ensure_cert() {
    mkdir -p /etc/hysteria
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -subj "/CN=${DEFAULT_SNI}" \
            -addext "subjectAltName = DNS:${DEFAULT_SNI}" \
            -days 36500
        chmod 600 "$KEY_FILE"
    fi
}

write_config() {
    local listen_spec="$1"
    local password="$2"
    local up_bw="$3"
    local down_bw="$4"

    mkdir -p /etc/hysteria
    cat > "$CONFIG_FILE" <<EOF
listen: :$listen_spec

# 有域名时可改用 ACME/CA 证书
# acme:
#   domains:
#     - test.heybro.bid
#   email: xxx@gmail.com

# 使用自签名证书
tls:
  cert: $CERT_FILE
  key: $KEY_FILE

auth:
  type: password
  password: $password

bandwidth:
  up: $up_bw
  down: $down_bw

masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOF
}

ensure_openrc_service() {
    cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

name="hysteria"
description="Hysteria 2 server"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"

depend() {
    need net
    after networking
}
EOF
    chmod +x "$SERVICE_FILE"
    rc-update add hysteria default >/dev/null 2>&1 || true
}

restart_and_check_service() {
    if service hysteria restart; then
        :
    else
        service hysteria start
    fi

    if ! service hysteria status; then
        echo "警告：Hysteria 服务状态检查未通过，请检查配置和日志。"
    fi
}

read_config_values() {
    local raw_listen=""
    raw_listen=$(awk '
        /^listen:[[:space:]]*/ {
            sub(/^listen:[[:space:]]*/, "", $0)
            sub(/[[:space:]]*#.*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            gsub(/^["'\'']|["'\'']$/, "", $0)
            sub(/^:/, "", $0)
            print $0
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null || true)

    CFG_LISTEN="$raw_listen"
    if [[ "$raw_listen" == *-* ]]; then
        CFG_PORT="${raw_listen%%-*}"
        CFG_HOP_RANGE="$raw_listen"
    else
        CFG_PORT="$raw_listen"
        CFG_HOP_RANGE="无（未配置端口跳跃）"
    fi

    CFG_PASS=$(awk '
        /^[[:space:]]*password:[[:space:]]*/ {
            sub(/^[[:space:]]*password:[[:space:]]*/, "", $0)
            sub(/[[:space:]]*#.*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            gsub(/^["'\'']|["'\'']$/, "", $0)
            print $0
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null || true)

    CFG_UP=$(awk '
        /^bandwidth:/ { in_bw=1; next }
        in_bw && /^[^[:space:]]/ { in_bw=0 }
        in_bw && /^[[:space:]]*up:[[:space:]]*/ {
            sub(/^[[:space:]]*up:[[:space:]]*/, "", $0)
            sub(/[[:space:]]*#.*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            gsub(/^["'\'']|["'\'']$/, "", $0)
            print $0
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null || true)

    CFG_DOWN=$(awk '
        /^bandwidth:/ { in_bw=1; next }
        in_bw && /^[^[:space:]]/ { in_bw=0 }
        in_bw && /^[[:space:]]*down:[[:space:]]*/ {
            sub(/^[[:space:]]*down:[[:space:]]*/, "", $0)
            sub(/[[:space:]]*#.*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            gsub(/^["'\'']|["'\'']$/, "", $0)
            print $0
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null || true)
}

get_ipv4() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        ip=$(wget -4 -qO- -T 5 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s' "$ip"
    fi
}

get_ipv6() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -6 -fsS --max-time 5 https://api6.ipify.org 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        ip=$(wget -6 -qO- -T 5 https://api6.ipify.org 2>/dev/null || true)
    fi
    if [[ "$ip" == *:* && "$ip" != *[!0-9a-fA-F:]* ]]; then
        printf '%s' "$ip"
    fi
}

make_url() {
    local address="$1"
    local label="$2"
    local pass="$3"
    local port="$4"
    local sha256="$5"
    local url_host="$address"
    if [[ "$address" == *:* ]]; then
        url_host="[$address]"
    fi
    printf 'hysteria2://%s@%s:%s?insecure=1&pinSHA256=%s&sni=%s#hysteria2-alpine-%s' \
        "$pass" "$url_host" "$port" "$sha256" "$DEFAULT_SNI" "$label"
}

print_parsed_summary_and_urls() {
    read_config_values
    local server_ipv4=""
    local server_ipv6=""
    local cert_sha256=""
    local url_count=0

    server_ipv4=$(get_ipv4 || true)
    server_ipv6=$(get_ipv6 || true)
    if [ -f "$CERT_FILE" ] && command -v openssl >/dev/null 2>&1; then
        cert_sha256=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
    fi

    echo "------------------------------------------------------------------------"
    echo "解析后的当前配置信息："
    echo "端口：${CFG_PORT:-未解析到}"
    echo "端口跳跃范围：${CFG_HOP_RANGE:-未解析到}"
    echo "密码：${CFG_PASS:-未解析到}"
    echo "带宽：上传 ${CFG_UP:-未设置} / 下载 ${CFG_DOWN:-未设置}"
    echo "------------------------------------------------------------------------"

    if [ -n "$server_ipv4" ]; then
        echo "IPv4 链接："
        make_url "$server_ipv4" "ipv4-$server_ipv4" "$CFG_PASS" "$CFG_PORT" "$cert_sha256"
        echo
        url_count=$((url_count + 1))
    fi
    if [ -n "$server_ipv6" ]; then
        echo "IPv6 链接："
        make_url "$server_ipv6" "ipv6-$server_ipv6" "$CFG_PASS" "$CFG_PORT" "$cert_sha256"
        echo
        url_count=$((url_count + 1))
    fi
    if [ "$url_count" -eq 0 ]; then
        echo "警告：未能自动获取公网 IPv4 或 IPv6 地址。"
    fi
}

print_cert_only() {
    echo "------------------------------------------------------------------------"
    echo "自签名证书 ($CERT_FILE)："
    if [ -f "$CERT_FILE" ]; then
        cat "$CERT_FILE"
    else
        echo "未找到自签名证书文件 $CERT_FILE"
    fi
    echo "------------------------------------------------------------------------"
}

update_config_key() {
    local key="$1"
    local val="$2"
    if grep -qE "^[[:space:]]*${key}:" "$CONFIG_FILE"; then
        sed -i -E "s|^([[:space:]]*${key}:).*|\1 ${val}|" "$CONFIG_FILE"
    else
        echo "  ${key}: ${val}" >> "$CONFIG_FILE"
    fi
}

update_bandwidth_in_config() {
    local up_val="$1"
    local down_val="$2"
    if grep -qE "^bandwidth:" "$CONFIG_FILE"; then
        awk -v up="$up_val" -v down="$down_val" '
            /^bandwidth:/ { in_bw=1; print; next }
            in_bw && /^[^[:space:]]/ { in_bw=0 }
            in_bw && /^[[:space:]]*up:/ { print "  up: " up; next }
            in_bw && /^[[:space:]]*down:/ { print "  down: " down; next }
            { print }
        ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
        cat >> "$CONFIG_FILE" <<EOF

bandwidth:
  up: $up_val
  down: $down_val
EOF
    fi
}

manage_menu() {
    echo "检测到已安装 Hysteria 2，跳过更新依赖与安装流程。"
    print_parsed_summary_and_urls
    print_cert_only

    while true; do
        echo ""
        echo "请选择操作："
        echo "1. 端口"
        echo "2. 端口跳跃"
        echo "3. 密码"
        echo "4. 带宽"
        echo "5. URL查看"
        echo "6. 自签证书查看"
        echo "0. 退出"
        read -r -p "输入选项 [0-6]: " choice

        case "$choice" in
            1)
                read_config_values
                prompt_port_or_range "新的监听端口或端口范围" "${CFG_LISTEN:-20000}"
                update_config_key "listen" ":${PORT_INPUT}"
                restart_and_check_service
                echo "端口已更新为 :${PORT_INPUT}"
                ;;
            2)
                if [ "$HAS_NET_ADMIN" -eq 0 ]; then
                    echo "错误：当前进程缺少 CAP_NET_ADMIN，不支持端口跳跃，已拒绝修改端口跳跃。"
                    continue
                fi
                read_config_values
                default_hop=""
                if [[ "${CFG_HOP_RANGE:-}" == *-* ]]; then
                    default_hop="$CFG_HOP_RANGE"
                fi
                while true; do
                    if [ -n "$default_hop" ]; then
                        read -r -p "请输入新的端口跳跃范围 [默认 $default_hop]（格式：起始端口-结束端口，例如：30000-40000）: " new_range
                        new_range=${new_range:-$default_hop}
                    else
                        read -r -p "请输入新的端口跳跃范围（格式：起始端口-结束端口，例如：30000-40000）: " new_range
                    fi
                    if [[ "$new_range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
                        s_p=$((10#${BASH_REMATCH[1]}))
                        e_p=$((10#${BASH_REMATCH[2]}))
                        if (( s_p >= 1 && s_p <= 65535 && e_p >= 1 && e_p <= 65535 && s_p <= e_p )); then
                            update_config_key "listen" ":${s_p}-${e_p}"
                            restart_and_check_service
                            echo "端口跳跃范围已更新为 :${s_p}-${e_p}"
                            break
                        fi
                    fi
                    echo "错误：请输入合法的端口范围（如 30000-40000，起始端口 <= 结束端口）。"
                done
                ;;
            3)
                read_config_values
                new_pass=$(generate_password)
                read -r -p "请输入新密码 [回车自动生成随机密码]: " custom_pass
                final_pass="${custom_pass:-$new_pass}"
                update_config_key "password" "$final_pass"
                restart_and_check_service
                echo "密码已更新为：$final_pass"
                ;;
            4)
                read_config_values
                cur_up_num="${CFG_UP%% *}"
                cur_down_num="${CFG_DOWN%% *}"
                prompt_bandwidth_mbps "${cur_up_num:-100}" "${cur_down_num:-200}"
                update_bandwidth_in_config "$BW_UP" "$BW_DOWN"
                restart_and_check_service
                echo "带宽已更新为：上传 $BW_UP / 下载 $BW_DOWN"
                ;;
            5)
                print_parsed_summary_and_urls
                ;;
            6)
                print_cert_only
                ;;
            0)
                echo "已退出菜单。"
                break
                ;;
            *)
                echo "无效选项，请输入 0-6。"
                ;;
        esac
    done
}

install_flow() {
    if [ "$HAS_NET_ADMIN" -eq 1 ]; then
        echo "当前进程具有 CAP_NET_ADMIN：将安装端口跳跃所需的网络工具，并允许输入端口范围。"
    else
        echo "当前进程缺少 CAP_NET_ADMIN：跳过端口跳跃所需的网络工具，仅允许输入单个端口。"
    fi

    apk add --no-cache wget curl openssl openrc coreutils

    if [ "$HAS_NET_ADMIN" -eq 1 ]; then
        apk add --no-cache iptables ip6tables
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) HY_ARCH="amd64" ;;
        aarch64 | arm64) HY_ARCH="arm64" ;;
        armv7l) HY_ARCH="armv7" ;;
        *)
            echo "------------------------------------------------------------------------"
            echo "错误：不支持的系统架构: $ARCH"
            echo "------------------------------------------------------------------------"
            exit 1
            ;;
    esac

    echo "检测到系统架构为: $ARCH，将下载 Hysteria 客户端 ($HY_ARCH)..."

    mkdir -p /usr/local/bin
    wget -O "$BIN_FILE" \
        "https://download.hysteria.network/app/latest/hysteria-linux-$HY_ARCH"
    chmod +x "$BIN_FILE"

    if ! "$BIN_FILE" version >/dev/null 2>&1; then
        echo "错误：Hysteria 下载后未能通过版本检查，请检查下载文件和系统兼容性。"
        exit 1
    fi
    echo "Hysteria 下载完成。"

    prompt_port_or_range "监听端口或端口范围" ""
    GENPASS=$(generate_password)
    prompt_bandwidth_mbps "100" "200"

    ensure_cert
    write_config "$PORT_INPUT" "$GENPASS" "$BW_UP" "$BW_DOWN"
    ensure_openrc_service
    restart_and_check_service

    manage_menu
}

if [ -x "$BIN_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    manage_menu
else
    install_flow
fi
