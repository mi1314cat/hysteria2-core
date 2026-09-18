#!/bin/bash

# 颜色变量定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 检查是否为root用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用root用户运行此脚本！\n" && exit 1

# 系统信息
SYSTEM_NAME=$(grep -i pretty_name /etc/os-release | cut -d \" -f2)
CORE_ARCH=$(arch)

# 配置目录 (在 /root/catmi 下为本脚本单独建立)
INSTALL_DIR="/root/catmi/hy2"

# 伪装域名候选列表 (内置 4 个, 可选自定义或回车随机)
MASQ_DOMAINS=("bing.com" "cloudflare.com" "microsoft.com" "apple.com")

# 介绍信息
show_banner() {
    clear
    cat << "EOF"
                       |\__/,|   (\\
                     _.|o o  |_   ) )
       -------------(((---(((-------------------
                    catmi.Hysteria 2 
       -----------------------------------------
EOF
    echo -e "${GREEN}System: ${PLAIN}${SYSTEM_NAME}"
    echo -e "${GREEN}Architecture: ${PLAIN}${CORE_ARCH}"
    echo -e "${GREEN}Version: ${PLAIN}2.1.0 (multi-node + client + status)"
    echo -e "----------------------------------------"
}

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

print_ok() {
    echo -e "${GREEN}[OK]${PLAIN} $1"
}

print_warning() {
    echo -e "${YELLOW}[Warning]${PLAIN} $1"
}

# URL percent-encode (分享链接 auth/obfs-password 等 base64 含 + / =; 不编码会被第三方 parse_qsl 吃掉)
uri_encode() {
    python3 - "$1" <<'PYEOF' 2>/dev/null
import sys, urllib.parse
sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))
PYEOF
}


# 生成端口的函数
generate_port() {
    local protocol="$1" user_input port udp_used tcp_used
    udp_used=$(ss -ulHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)
    tcp_used=$(ss -tlHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)
    while :; do
        port=$((RANDOM % 10001 + 10000))
        read -p "请为 ${protocol} 输入监听端口(默认为随机生成): " user_input
        port=${user_input:-$port}
        if echo "$udp_used" | grep -qE "^${port}$" || echo "$tcp_used" | grep -qE "^${port}$"; then
            echo "端口 $port 被占用(TCP/UDP), 请输入其他端口; 若是现有 hysteria 节点占用, 可用 '菜单2卸载' 或手动 systemctl stop hysteria-server 释放"
            continue
        fi
        echo "$port"; return 0
    done
}

# 选择伪装域名 (内置列表 / 自定义 / 回车随机) -> 全局 MASQ_DOMAIN
select_masq_domain() {
    echo "请选择伪装域名: "
    for i in "${!MASQ_DOMAINS[@]}"; do
        echo "$((i + 1)). ${MASQ_DOMAINS[$i]}"
    done
    echo "$((${#MASQ_DOMAINS[@]} + 1)). 自定义域名"
    read -p "请输入选项 [1-$((${#MASQ_DOMAINS[@]} + 1))], 直接回车随机: " domain_choice

    if [[ -z "$domain_choice" ]]; then
        # 回车 -> 随机
        MASQ_DOMAIN=${MASQ_DOMAINS[$((RANDOM % ${#MASQ_DOMAINS[@]}))]}
        print_info "已随机选择伪装域名: ${MASQ_DOMAIN}"
    elif [[ "$domain_choice" =~ ^[0-9]+$ ]] && (( domain_choice >= 1 && domain_choice <= ${#MASQ_DOMAINS[@]} )); then
        MASQ_DOMAIN=${MASQ_DOMAINS[$((domain_choice - 1))]}
        print_info "已选择伪装域名: ${MASQ_DOMAIN}"
    elif [[ "$domain_choice" =~ ^[0-9]+$ ]] && (( domain_choice == ${#MASQ_DOMAINS[@]} + 1 )); then
        read -p "请输入自定义伪装域名 (如 example.com): " MASQ_DOMAIN
        [[ -z "$MASQ_DOMAIN" ]] && MASQ_DOMAIN="bing.com"
        print_info "已设置自定义伪装域名: ${MASQ_DOMAIN}"
    else
        MASQ_DOMAIN=${MASQ_DOMAINS[$((RANDOM % ${#MASQ_DOMAINS[@]}))]}
        print_info "输入无效, 已随机选择: ${MASQ_DOMAIN}"
    fi
}

# ================================
# 从证书提取域名 (SAN → CN → 文件名, 与 X/M 内核版一致)
# ================================
extract_cert_domain() {
    local crt="$1" dom=""
    if command -v openssl >/dev/null 2>&1 && [[ -f "$crt" ]]; then
        dom=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null |
            grep -oE "DNS:[^,]+" | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')
        [[ -z "$dom" ]] && dom=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null |
            grep -oE "CN *= *[^,]+" | head -1 | sed 's/.*CN *= *//' | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi
    [[ -z "$dom" ]] && dom=$(basename "$crt" | sed -E 's/\.(crt|pem)$//; s/_cert$//' | sed 's/^cert-//')
    echo "$dom"
}

cert_not_expired() {
    [[ -f "$1" ]] || return 1
    openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1
}

cert_is_trusted() {
    openssl x509 -in "$1" -noout -issuer 2>/dev/null | \
        grep -qiE "Let.?s Encrypt|ZeroSSL|Sectigo|Google Trust|DigiCert|GlobalSign|R[0-9]{2,}"
}

find_key_for_cert() {
    local crt="$1" k
    k="${crt%.crt}.key"; [[ -f "$k" ]] && { echo "$k"; return; }
    k="${crt%.pem}.key"; [[ -f "$k" ]] && { echo "$k"; return; }
    k="${crt%_cert.pem}_key.pem"; [[ -f "$k" ]] && { echo "$k"; return; }
    k="$(dirname "$crt")/server.key"; [[ -f "$k" ]] && { echo "$k"; return; }
    echo ""
}

clean_input2() { echo "$1" | tr -d '\000-\037'; }

# ================================
# 真证书扫描 (多路径 + key 配对 + 过期剔除; hysteria 无 SAFE_PATHS, 真证书直接引用原路径)
# ================================
scan_certs() {
    FOUND_CERTS=()
    SEEN_TMP=()
    local f k d i src cid
    shopt -s nullglob
    local -a search_dirs=() labels=()
    [[ -d /root/catmi/cloudflare/certs ]] && { search_dirs+=(/root/catmi/cloudflare/certs); labels+=(cf-origin); }
    [[ -d /root/catmi/mihomo/conf/certs ]] && { search_dirs+=(/root/catmi/mihomo/conf/certs); labels+=(mihomo-certs); }
    [[ -f /etc/hysteria/server.crt ]] && { search_dirs+=(/etc/hysteria); labels+=(hysteria-self); }
    [[ -d /root/catmi ]] && { search_dirs+=(/root/catmi); labels+=(catmi-root); }
    [[ -d /etc/v2ray-agent/tls ]] && { search_dirs+=(/etc/v2ray-agent/tls); labels+=(v2ray-agent); }
    [[ -d /root/.acme.sh ]] && { search_dirs+=(/root/.acme.sh); labels+=(acme.sh); }
    [[ -d /etc/nginx/certs ]] && { search_dirs+=(/etc/nginx/certs); labels+=(nginx-certs); }
    [[ -d /home/web/certs ]] && { search_dirs+=(/home/web/certs); labels+=(web-certs); }
    # 现役证书: 旧 hysteria 配置里 tls.cert 引用 (提取 CERT_PATH, 用于 CA:TRUE 放行 + 在用标注)
    REF_CERT=""
    [[ -f /etc/hysteria/config.yaml ]] && REF_CERT=$(awk "/^  cert:/{print \$2; exit}" /etc/hysteria/config.yaml 2>/dev/null)
    [[ -z "$REF_CERT" && -f /etc/hysteria/config_server.yaml ]] && REF_CERT=$(awk "/^  cert:/{print \$2; exit}" /etc/hysteria/config_server.yaml 2>/dev/null)

    if command -v docker >/dev/null 2>&1; then
        cid=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx | head -1)
        if [[ -n "$cid" ]]; then
            src=$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/certs"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
            [[ -n "$src" && -d "$src" ]] && { search_dirs+=("$src"); labels+=("docker-nginx($cid)"); }
        fi
    fi
    for ((i=0; i<${#search_dirs[@]}; i++)); do
        d="${search_dirs[$i]}"
        for f in "$d"/*.pem "$d"/*.crt; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *_key.pem || "$f" == *key*.pem ]] && continue
            case "$(basename "$f")" in
                ca.cer|fullchain.cer|*.issuer.cer|chain.cer|key.pem) continue ;;
            esac
            local dup=false sf
            for sf in "${SEEN_TMP[@]:-}"; do [[ "$sf" == "$f" ]] && dup=true && break; done
            $dup && continue
            SEEN_TMP+=("$f")
            # CA 证书默认跳过; 但若它是现役在用证书(被现有配置引用)则放行
            if openssl x509 -in "$f" -noout -text 2>/dev/null | grep -q "CA:TRUE"; then
                [[ "$f" == "$REF_CERT" ]] || continue
            fi
            cert_not_expired "$f" || continue
            k=$(find_key_for_cert "$f")
            FOUND_CERTS+=("$f|$k|${labels[$i]}")
        done
    done
    shopt -u nullglob

    # ---- 优化: 按证书内容去重 + 识别"现役在用"优先排序 ----
    if ((${#FOUND_CERTS[@]} > 0)); then
        local DEDUP=() seen_tp="" tp pair_k lbl2 inuse_cfg
        # "在用"判定来源1: 旧 hysteria 配置里 tls.cert 引用
        local used_paths=""
        for p in $(grep -hoE '^  cert: .*' /etc/hysteria/config.yaml 2>/dev/null | awk '{print $2}'); do
            used_paths+="$p "
        done
        # 来源2: mihomo 子配置里的 cert 引用 (1451 编排链)
        for p in $(grep -rhoE 'cert: *[^ ]' /root/catmi/mihomo/conf/config.d/ 2>/dev/null | grep -oE '/[^ ]+'); do
            used_paths+="$p "
        done
        local -a NEW=()
        local -A TP_SEEN=()
        for pair in "${FOUND_CERTS[@]}"; do
            local f="${pair%%|*}" rest
            tp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | md5sum | cut -d' ' -f1)
            if [[ -n "${TP_SEEN[$tp]:-}" ]]; then
                # 同一内容证书: 保留第一条, 补充来源标注
                lbl2=""
                [[ "$used_paths" == *" $f "* ]] && lbl2="YES"
                continue
            fi
            TP_SEEN[$tp]=1
            local pair_rest="${pair#*|}"
            local orig_lbl="${pair_rest##*|}"
            local is_inuse=""
            local f_tp
            f_tp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | md5sum | cut -d' ' -f1)
            for p in $used_paths; do
                [[ "$p" == "$f" ]] && is_inuse="⚑在用"
                # 多副本场景: 引用路径不同但证书相同也算在用
                [[ -f "$p" ]] && [[ "$f_tp" == "$(openssl x509 -in "$p" -noout -fingerprint -sha256 2>/dev/null | md5sum | cut -d' ' -f1)" ]] && is_inuse="⚑在用"
            done
            local final_lbl="$orig_lbl"
            [[ -n "$is_inuse" ]] && final_lbl="${orig_lbl}($is_inuse)"
            NEW+=("$f|${pair_rest%%|*}|$final_lbl")
        done
        # 排序: 在用 → 普通证书
        local -a IN=() NORM=()
        for pair in "${NEW[@]}"; do
            [[ "${pair##*|}" == *"⚑在用"* ]] && IN+=("$pair") || NORM+=("$pair")
        done
        FOUND_CERTS=()
        [[ ${#IN[@]} -gt 0 ]] && FOUND_CERTS+=("${IN[@]}")
        [[ ${#NORM[@]} -gt 0 ]] && FOUND_CERTS+=("${NORM[@]}")
    fi
}

# ================================
# 证书方案选择 (默认自签; 扫描/手动可选)
# 输出全局: CERT_PATH, KEY_PATH, CERT_DOMAIN, CERT_TRUSTED
# ================================
ask_cert() {
    CERT_TRUSTED=false
    local choice f pair lbl default_choice="" usable=()
    echo "  证书方案：" >&2
    echo "  1) 自签证书 (默认, ECDSA+SAN, 无需域名)" >&2
    echo "  2) 扫描本机已有证书 (ACME/nginx/CF Origin CA, CA可信)" >&2
    echo "  3) 手动输入证书路径" >&2
    printf "  选择 (默认1): " >&2
    read -r choice
    choice=$(clean_input2 "$choice")

    case "$choice" in
        2)
            scan_certs
            if ((${#FOUND_CERTS[@]} == 0)); then
                print_warning "未扫描到可用证书, 退回自签"
                CERT_PATH="/etc/hysteria/server.crt"; KEY_PATH="/etc/hysteria/server.key"; CERT_DOMAIN="$MASQ_DOMAIN"; CERT_TRUSTED=false
                return 0
            fi
            echo "  检测到已有证书:" >&2
            local i=1
            usable=()
            for pair in "${FOUND_CERTS[@]}"; do
                f="${pair%%|*}"; k="${pair#*|}"; k="${k%%|*}"; lbl="${pair##*|}"
                if [[ -n "$k" && -f "$k" ]] && cert_not_expired "$f"; then
                    echo "    $i) $(extract_cert_domain "$f") (有密钥, 来源: $lbl)" >&2
                    [[ -z "$default_choice" ]] && default_choice="$i"
                    usable+=("$i|${f%%|*}|$k")
                else
                    echo "    $i) $(extract_cert_domain "$f") (无密钥或已过期, 忽略)" >&2
                fi
                ((i++))
            done
            echo "    $i) 手动输入路径" >&2
            echo "    $((i+1))) 退回自签" >&2
            printf "  选择 (默认 ${default_choice:-1}): " >&2
            read -r choice
            choice=$(clean_input2 "$choice")
            [[ -z "$choice" ]] && choice="$default_choice"

            # 手动路径 / 退回自签
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" == "$i" || "$choice" == "$((i+1))" ]]; then
                if [[ "$choice" == "$i" ]]; then
                    printf "  证书 crt 路径: " >&2; read -r f
                    CERT_PATH=$(clean_input2 "$f")
                    printf "  证书 key 路径: " >&2; read -r f
                    KEY_PATH=$(clean_input2 "$f")
                    if [[ -f "$CERT_PATH" ]] && [[ -f "$KEY_PATH" ]] && cert_not_expired "$CERT_PATH"; then :; else
                        print_warning "路径无效, 退回自签"
                        CERT_PATH="/etc/hysteria/server.crt"; KEY_PATH="/etc/hysteria/server.key"; CERT_DOMAIN="$MASQ_DOMAIN"; CERT_TRUSTED=false
                        return 0
                    fi
                else
                    CERT_PATH="/etc/hysteria/server.crt"; KEY_PATH="/etc/hysteria/server.key"; CERT_DOMAIN="$MASQ_DOMAIN"; CERT_TRUSTED=false
                    return 0
                fi
            fi

            # 选号查表 (覆盖所有显示序号)
            local matched="" p
            for p in "${usable[@]}"; do
                if [[ "${p%%|*}" == "$choice" ]]; then matched="$p"; break; fi
            done
            if [[ -n "$matched" ]]; then
                CERT_PATH="${matched#*|}"; CERT_PATH="${CERT_PATH%%|*}"
                KEY_PATH="${matched##*|}"
            elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice < i )); then
                print_error "序号 $choice 的证书无可用 key 或已过期, 退回自签"
                CERT_PATH="/etc/hysteria/server.crt"; KEY_PATH="/etc/hysteria/server.key"; CERT_DOMAIN="$MASQ_DOMAIN"; CERT_TRUSTED=false
                return 0
            fi

            # 通用校验 + 副本 (hysteria-server 以 hysteria 用户运行, /root 不可读)
            CERT_DOMAIN=$(extract_cert_domain "$CERT_PATH")
            cert_is_trusted "$CERT_PATH" && CERT_TRUSTED=true
            if [[ "$CERT_PATH" != "/etc/hysteria/"* ]]; then
                cp -f "$CERT_PATH" "/etc/hysteria/cert-${CERT_DOMAIN}.crt"
                cp -f "$KEY_PATH" "/etc/hysteria/key-${CERT_DOMAIN}.key"
                chown hysteria "/etc/hysteria/cert-${CERT_DOMAIN}.crt" "/etc/hysteria/key-${CERT_DOMAIN}.key" 2>/dev/null
                CERT_PATH="/etc/hysteria/cert-${CERT_DOMAIN}.crt"
                KEY_PATH="/etc/hysteria/key-${CERT_DOMAIN}.key"
                print_info "外部证书已复制到 /etc/hysteria/ (LE 续期后需重新安装/复制)"
            fi
            print_ok "使用证书: $CERT_DOMAIN (crt=$CERT_PATH key=$KEY_PATH)"
            return 0
            ;;
        3)
            printf "  证书 crt 路径: " >&2; read -r f
            CERT_PATH=$(clean_input2 "$f")
            printf "  证书 key 路径: " >&2; read -r f
            KEY_PATH=$(clean_input2 "$f")
            if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] && cert_not_expired "$CERT_PATH"; then
                CERT_DOMAIN=$(extract_cert_domain "$CERT_PATH")
                cert_is_trusted "$CERT_PATH" && CERT_TRUSTED=true
                if [[ "$CERT_PATH" != "/etc/hysteria/"* ]]; then
                    cp -f "$CERT_PATH" "/etc/hysteria/cert-${CERT_DOMAIN}.crt"
                    cp -f "$KEY_PATH" "/etc/hysteria/key-${CERT_DOMAIN}.key"
                    chown hysteria "/etc/hysteria/cert-${CERT_DOMAIN}.crt" "/etc/hysteria/key-${CERT_DOMAIN}.key" 2>/dev/null
                    CERT_PATH="/etc/hysteria/cert-${CERT_DOMAIN}.crt"
                    KEY_PATH="/etc/hysteria/key-${CERT_DOMAIN}.key"
                    print_info "外部证书已复制到 /etc/hysteria/"
                fi
                print_ok "使用手动证书: $CERT_DOMAIN"
                return 0
            fi
            print_warning "路径无效或证书已过期, 退回自签"
            CERT_PATH="/etc/hysteria/server.crt"; KEY_PATH="/etc/hysteria/server.key"; CERT_DOMAIN="$MASQ_DOMAIN"; CERT_TRUSTED=false
            return 0
            ;;
    esac

    # 默认: 自签
    CERT_PATH="/etc/hysteria/server.crt"
    KEY_PATH="/etc/hysteria/server.key"
    CERT_DOMAIN="$MASQ_DOMAIN"
    CERT_TRUSTED=false
    return 0
}


# ================================
# 端口跳跃 (hysteria 2.8+ 原生端口区间监听, 默认不开启)
# 开启后 listen=:起始-结束 (内核自动配 nft/iptables, 关闭时自动清理)
# 6 道防呆与 X/M 内核版一致
# ================================
ask_port_hopping() {
    HOP_RANGE=""
    local yn range start end used_ports conflicts
    printf "是否开启 UDP 端口跳跃? (默认: 否, y/N): " >&2
    read -r yn
    case "$(clean_input2 "$yn")" in
        y|Y) ;;
        *) return 0 ;;
    esac

    used_ports=$(ss -ulHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)
    while true; do
        printf "跳跃范围 (默认: 30000-31000, 起始端口将作为主监听端口): " >&2
        read -r range
        range=$(clean_input2 "$range")
        [[ -z "$range" ]] && range="30000-31000"

        if ! echo "$range" | grep -qE '^[0-9]+-[0-9]+$'; then
            print_error "范围格式应为 起始-结束, 例如 30000-31000"
            continue
        fi
        start="${range%-*}"; end="${range#*-}"
        (( start >= 1024 && start <= end && end <= 65535 )) || {
            print_error "范围不合法: $range (要求 1024 ≤ 起始 ≤ 结束 ≤ 65535)"; continue; }
        (( end - start > 10000 )) && print_warning "跨度 $((end-start)) 个端口偏大, 建议 1-2 千"

        conflicts=$(seq "$start" "$end" | grep -Fxf <(echo "$used_ports") | head -5 | paste -sd' ')
        [[ -n "$conflicts" ]] && { print_error "范围 $range 与已监听 UDP 服务冲突: $conflicts"; continue; }

        if iptables -t nat -S PREROUTING 2>/dev/null | grep -qE "dport ${start}:${end}"; then
            print_error "iptables 已有 $start:$end 的转发规则 (可能与内核自动规则冲突)"; continue
        fi

        break
    done

    HOP_RANGE="$range"
    PORT="$start"   # 主端口 = 区间第一个端口 (内核行为)
    print_info "端口跳跃已开启: $range (主端口 $start, 由 hysteria 内核自动配置防火墙)"
    command -v nft >/dev/null || command -v iptables >/dev/null || \
        print_warning "未检测到 nft/iptables, hysteria 内核将无法自动配置端口转发"
}

# ================================
# obfs 混淆 (salamander, 默认不开)
# 输出全局: OBFS_PASSWORD
# ================================
ask_obfs() {
    OBFS_PASSWORD=""
    local yn
    printf "是否开启 salamander 流量混淆? (默认: 否, y/N): " >&2
    read -r yn
    case "$(clean_input2 "$yn")" in
        y|Y) ;;
        *) return 0 ;;
    esac
    OBFS_PASSWORD=$(openssl rand -hex 16)
    print_info "obfs salamander 已开启"
}

# ================================
# ECH (hysteria >= 2.12.3, 默认不开)
# 输出全局: ECH_ENABLED, ECH_PUBLIC_NAME
# 注意: ECH 只对官方 hysteria 客户端生效, mihomo/v2rayN 等不支持
# ================================
ask_ech() {
    ECH_ENABLED=false
    local yn ver
    printf "是否开启 ECH (加密 SNI)? (默认: 否, y/N): " >&2
    read -r yn
    case "$(clean_input2 "$yn")" in
        y|Y) ;;
        *) return 0 ;;
    esac
    ver=$(hysteria version 2>/dev/null | grep -wiE 'Version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -z "$ver" ]]; then
        print_error "未检测到 hysteria 内核版本, 无法确认支持 ECH, 已跳过"
        return 1
    fi
    local mnajr minor patch
    major=$(echo "$ver" | cut -d. -f1); minor=$(echo "$ver" | cut -d. -f2); patch=$(echo "$ver" | cut -d. -f3)
    (( major > 2 || (major == 2 && (minor > 12 || (minor == 12 && patch >= 3))) )) || {
        print_error "ECH 需要 hysteria >= 2.12.3 (当前: $ver), 已跳过"
        return 1
    }
    ECH_ENABLED=true

    # ECH 外层伪装域名 (public-name): 与伪装域名解耦, 可独立选择
    echo "" >&2
    echo "  ECH 外层伪装域名 (public-name, 需为未墙的热门大域名):" >&2
    echo "  1) 当前伪装域名: $MASQ_DOMAIN (默认)" >&2
    echo "  2) cloudflare.com" >&2
    echo "  3) www.google.com" >&2
    echo "  4) www.apple.com" >&2
    echo "  5) www.microsoft.com" >&2
    echo "  6) www.amazon.com" >&2
    printf "  选择或直接输入域名 (默认1): " >&2
    read -r pn
    pn=$(clean_input2 "$pn")
    case "$pn" in
        ""|1) ECH_PUBLIC_NAME="$MASQ_DOMAIN" ;;
        2) ECH_PUBLIC_NAME="cloudflare.com" ;;
        3) ECH_PUBLIC_NAME="www.google.com" ;;
        4) ECH_PUBLIC_NAME="www.apple.com" ;;
        5) ECH_PUBLIC_NAME="www.microsoft.com" ;;
        6) ECH_PUBLIC_NAME="www.amazon.com" ;;
        *)
            if [[ "$pn" =~ ^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$ ]]; then
                ECH_PUBLIC_NAME="$pn"
            else
                print_warning "非法域名格式, 使用伪装域名 $MASQ_DOMAIN"
                ECH_PUBLIC_NAME="$MASQ_DOMAIN"
            fi
            ;;
    esac
    print_info "ECH 将在安装完成后用 'hysteria ech' 生成密钥 (外层=$ECH_PUBLIC_NAME, 仅官方客户端可用)"
    return 0
}

# 生成自签证书 (CN 与伪装域名一致)
gen_selfsigned_cert() {
    local domain="$1"
CERT_PATH="/etc/hysteria/server.crt"; KEY_PATH="/etc/hysteria/server.key"
    openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$KEY_PATH" -out "$CERT_PATH" \
    -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" -days 36500 && \
    chown hysteria /etc/hysteria/server.key && \
    chown hysteria /etc/hysteria/server.crt
    print_info "已生成自签证书 (CN=${domain})"
}

# 创建快捷方式
create_shortcut() {
    cat > /usr/local/bin/catmihy2 << 'EOF'
#!/bin/bash
bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/hy2-panel.sh)
EOF
    chmod +x /usr/local/bin/catmihy2
    print_info "快捷方式 'catmihy2' 已创建，可使用 'catmihy2' 命令运行脚本"
}

# 安装 Hysteria 2
install_hysteria() {
    print_info "开始安装 Hysteria 2..."

    # ---- 单节点防呆: 已有节点检测 + 确认替换 + 自动备份 ----
    if [[ -f /etc/hysteria/config.yaml ]]; then
        local old_port old_cert old_masq
        old_port=$(awk "/^listen:/{print \$2; exit}" /etc/hysteria/config.yaml 2>/dev/null | tr -d ':')
        old_cert=$(awk "/^  cert:/{print \$2; exit}" /etc/hysteria/config.yaml 2>/dev/null)
        old_masq=$(awk "/url: https:\/\//{print \$2}" /etc/hysteria/config.yaml 2>/dev/null | cut -d/ -f3)
        local svc_state="停止"
        systemctl is-active --quiet hysteria-server.service && svc_state="运行中"
        echo -e "${YELLOW}!! 检测到已有 Hysteria 2 节点 (单节点模型将被以下新节点替换) !!${PLAIN}"
        echo "    端口: $old_port  证书: $old_cert  伪装域名: $old_masq  服务: $svc_state"
        local TS_BAK; TS_BAK=$(date +%m%d%H%M%S)
        local BAK="/tmp/hysteria-preinst-${TS_BAK}.tar.gz"
        tar -czf "$BAK" /etc/hysteria "$INSTALL_DIR" 2>/dev/null &&             echo "旧节点已自动备份: $BAK (恢复: tar -C / -xzf $BAK 之后 systemctl restart hysteria-server)"
        printf "是否停用当前节点并安装新节点? 1) 继续(默认) 2) 取消安装: "
        read -r rep_choice
        rep_choice=${rep_choice:-1}
        if [[ "$rep_choice" != "1" ]]; then
            print_warning "已取消安装, 原节点保持不变"
            return 1
        fi
        systemctl is-active --quiet hysteria-server.service && {
            print_info "停止并备份现有 hysteria-server..."
            systemctl stop hysteria-server.service
            systemctl disable hysteria-server.service 2>/dev/null
        }
    fi

    mkdir -p "$INSTALL_DIR"

    # 安装依赖
    bash <(curl -fsSL https://get.hy2.sh/)

    # 选择伪装域名
    select_masq_domain

    # 生成自签证书 (CN = 伪装域名)
    gen_selfsigned_cert "$MASQ_DOMAIN"

    # 证书方案 (默认自签; 真证书/手动路径可选)
    ask_cert "$MASQ_DOMAIN"

    # 生成随机密码
    AUTH_PASSWORD=$(openssl rand -base64 16)

    # 提示输入监听端口号
    PORT=$(generate_port "Hysteria")

    # 可选特性 (全部默认不配置)
    ask_port_hopping      # 可选: hysteria 原生端口区间监听
    ask_obfs              # 可选: salamander 混淆
    ask_ech               # 可选: ECH (需 hysteria >= 2.12.3)

    # 获取公网 IP 地址
    PUBLIC_IP_V4=$(curl -s https://api.ipify.org)
    PUBLIC_IP_V6=$(curl -s https://api64.ipify.org)
    echo "公网 IPv4 地址: $PUBLIC_IP_V4"
    echo "公网 IPv6 地址: $PUBLIC_IP_V6"

    # 选择使用哪个公网 IP 地址
    echo "请选择要使用的公网 IP 地址:"
    echo "1. $PUBLIC_IP_V4 (默认)"
    echo "2. $PUBLIC_IP_V6"
    echo "3. 自定义 IP"
    read -p "请输入对应的数字选择: " IP_CHOICE

    case "$IP_CHOICE" in
        1)
            PUBLIC_IP=$PUBLIC_IP_V4
            ;;
        2)
            PUBLIC_IP=$PUBLIC_IP_V6
            ;;
        3)
            read -p "请输入自定义的公网 IP 地址: " PUBLIC_IP
            ;;
        *)
            PUBLIC_IP=$PUBLIC_IP_V4
            ;;
    esac

    # ECH 密钥生成 (hysteria >= 2.12.3 官方 'hysteria ech' 子命令)
    ECH_PEM=""; ECH_CONFIG=""; ECH_PUBLIC_NAME="${ECH_PUBLIC_NAME:-$MASQ_DOMAIN}"
    if [[ "$ECH_ENABLED" == "true" ]]; then
        ECH_PEM="/etc/hysteria/ech.pem"
        ECH_PUBLIC_NAME="${ECH_PUBLIC_NAME:-$MASQ_DOMAIN}"
        print_info "生成 ECH 密钥 (public-name=$ECH_PUBLIC_NAME)..."
        mkdir -p /etc/hysteria
        ECH_OUT=$( hysteria ech --public-name "$ECH_PUBLIC_NAME" -o "$ECH_PEM" --overwrite 2>&1 )
        ECH_CONFIG=$(awk '/BEGIN ECH CONFIGS/{f=1;next}/END ECH CONFIGS/{f=0}f' "$ECH_PEM" | tr -d '\n')
        [[ -z "$ECH_CONFIG" ]] && ECH_CONFIG=$(echo "$ECH_OUT" | grep -oE '[A-Za-z0-9+/=]{200,}' | head -1)
        if [[ -n "$ECH_CONFIG" ]]; then
            print_info "ECH configList 提取成功 (已写入分享链接参数)"
        else
            print_warning "未能从 hysteria ech 输出解析 configList, 链接未带 ech 参数"
        fi
        chown hysteria "$ECH_PEM" 2>/dev/null
    fi

    # 创建服务端配置
    create_server_config

    # 创建客户端配置
    create_client_config

    # 启动服务 (已在运行时必须 restart 才能加载新配置)
    if systemctl is-active --quiet hysteria-server.service; then
        systemctl restart hysteria-server.service
    else
        systemctl enable --now hysteria-server.service
    fi

    print_info "Hysteria 2 安装完成！"
    print_info "服务器地址：${PUBLIC_IP}"
    print_info "端口：${PORT}"
    print_info "密码：${AUTH_PASSWORD}"
    print_info "伪装域名：${MASQ_DOMAIN}"
    print_info "配置文件已保存到：${INSTALL_DIR}/config.yaml"
    [[ -n "$HOP_RANGE" ]] && print_info "端口跳跃：$HOP_RANGE (内核原生, 防火墙自动配置/清理)"
    [[ -n "$OBFS_PASSWORD" ]] && print_info "obfs salamander 混淆：已开启"
    [[ "$ECH_ENABLED" == "true" ]] && print_info "ECH：已开启 (官方客户端 tls.ech=${ECH_CONFIG:-见 server 日志})"
}

# 创建服务端配置
create_server_config() {
    # 端口跳跃: hysteria 原生端口区间监听 (开启时 listen=:起始-结束)
    local HY2_LISTEN=":$PORT"
    [[ -n "$HOP_RANGE" ]] && HY2_LISTEN=":${HOP_RANGE}"

    # obfs 混淆块 (默认无)
    local OBFS_BLOCK=""
    [[ -n "$OBFS_PASSWORD" ]] && OBFS_BLOCK="obfs:
  type: salamander
  salamander:
    password: $OBFS_PASSWORD"

    # ECH 块 (默认无)
    local ECH_BLOCK=""
    [[ "$ECH_ENABLED" == "true" && -n "$ECH_PEM" && -f "$ECH_PEM" ]] && ECH_BLOCK="ech:
  keyPath: $ECH_PEM"

   cat << EOF > /etc/hysteria/config.yaml
listen: "${HY2_LISTEN}"

tls:
  cert: $CERT_PATH
  key: $KEY_PATH

auth:
  type: password
  password: $AUTH_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://${MASQ_DOMAIN}
    rewriteHost: true
$OBFS_BLOCK
$ECH_BLOCK
quic:
  initStreamReceiveWindow: 8388608 
  maxStreamReceiveWindow: 8388608 
  initConnReceiveWindow: 20971520 
  maxConnReceiveWindow: 20971520 
  maxIdleTimeout: 30s 
  maxIncomingStreams: 1024 
  disablePathMTUDiscovery: false    
EOF

}

# 创建客户端配置 (Clash Meta 格式 + 分享链接)
create_client_config() {
    # 证书指纹: 自签时用 pin(锁叶子证书); 真证书不用
    local CERT_PIN=""
    CERT_PIN=$(openssl x509 -in "$CERT_PATH" -outform der 2>/dev/null | sha256sum | awk '{print tolower($1)}')
    [[ "$CERT_PIN" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]] && CERT_PIN=""
    local PIN_PART=""
    [[ "$CERT_TRUSTED" != "true" && -n "$CERT_PIN" ]] && PIN_PART="&pin=${CERT_PIN}"

    # SNI: 真证书用证书里的域名; 自签用伪装域名
    local sni="$MASQ_DOMAIN"
    [[ "$CERT_TRUSTED" == "true" && -n "$CERT_DOMAIN" ]] && sni="$CERT_DOMAIN"

    # mihomo 客户端 TLS 字段 (真证书: 正常校验; 自签: skip + fingerprint 锁证书)
    local fp_lines="    skip-cert-verify: false"
    [[ "$CERT_TRUSTED" != "true" ]] && fp_lines="    skip-cert-verify: true"$'\n'"    fingerprint: $CERT_PIN"

    # 端口跳跃 (mihomo 字段)
    local ports_lines=""
    [[ -n "$HOP_RANGE" ]] && ports_lines="    ports: $HOP_RANGE"$'\n'"    hop-interval: 10"

    # obfs (mihomo 字段)
    local obfs_lines=""
    [[ -n "$OBFS_PASSWORD" ]] && obfs_lines="    obfs: salamander"$'\n'"    obfs-password: $OBFS_PASSWORD"

    # 链接参数
    local link_obfs="obfs=none"
    [[ -n "$OBFS_PASSWORD" ]] && link_obfs="obfs=salamander&obfs-password=$(uri_encode "$OBFS_PASSWORD")"
    local insecure="insecure=0"
    [[ "$CERT_TRUSTED" != "true" ]] && insecure="insecure=1"

    # ECH (仅官方 hysteria 客户端; mihomo/v2rayN 不识别)
    local ech_note="" ech_link=""
    if [[ "$ECH_ENABLED" == "true" && -n "$ECH_CONFIG" ]]; then
        ech_link="&ech=$ECH_CONFIG"
        ech_note="   注意: ECH 仅官方 hysteria 客户端支持, mihomo/v2rayN 等不识别该参数"
    fi

    cat << EOF > "$INSTALL_DIR/config.yaml"

  - name: Hy2-Hysteria2
    server: $PUBLIC_IP
    port: $PORT
    type: hysteria2
    up: "45 Mbps"
    down: "150 Mbps"
    sni: $sni
    password: $AUTH_PASSWORD
$fp_lines
$ports_lines
$obfs_lines
    alpn:
      - h3

**********************************************************************************************************************
   hysteria2://$(uri_encode "$AUTH_PASSWORD")@$PUBLIC_IP:$PORT?$insecure&sni=${sni}&alpn=h3&$link_obfs&upmbps=45&downmbps=150${PIN_PART}${ech_link}#HY2
$ech_note

EOF
    mkdir -p "$INSTALL_DIR/out" "$INSTALL_DIR/../out"
    cp "$INSTALL_DIR/config.yaml" "$INSTALL_DIR/out/hy2_client.yaml"
    # 或在上方文件中找分享链接出来
}

# =====================================================================
# 多节点架构 (v2.0) — default 节点 = /etc/hysteria/config.yaml (hysteria-server.service, 向后兼容)
# 新节点 = /etc/hysteria/hy2-<name>.yaml + hysteria-server@hy2-<名称>.service (官方 @ 模板)
# 客户端导出 = /root/catmi/hy2/nodes/<name>/{client.yaml, share.txt}
# =====================================================================
NODES_OUT_DIR="${INSTALL_DIR}/nodes"

ensure_node_dirs() {
    mkdir -p "$NODES_OUT_DIR" "$INSTALL_DIR/out"
}

sanitize_node_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | cut -c1-24
}

# 节点名列表 (default 恒在首位)
scan_nodes() {
    NODE_NAMES=()
    [[ -f /etc/hysteria/config.yaml ]] && NODE_NAMES+=("default")
    local f
    shopt -s nullglob
    for f in /etc/hysteria/*.yaml; do
        local b=$(basename "$f" .yaml)
        [[ "$b" == config ]] && continue      # default 节点单独注册
        NODE_NAMES+=("$b")
    done
    shopt -u nullglob
}

node_file() {
    [[ "$1" == "default" ]] && echo "/etc/hysteria/config.yaml" || echo "/etc/hysteria/$1.yaml"
}

# 从节点 yaml 提取元素 (本脚本生成的固定结构可安全 awk)
node_get() {
    local f="$1" key="$2"
    case "$key" in
        listen)   awk '/^listen:/{print $2; exit}' "$f";;
        cert)     awk '/^  cert:/{print $2; exit}' "$f";;
        auth)     sed -n 's/^  password: //p' "$f" | head -1;;
        masq)     awk '/url: https:\/\//{print $2; exit}' "$f" | cut -d/ -f3;;
        obfs_pw)  awk '/^obfs:/{f=1;next} f&&/^  salamander:/{g=1;next} g&&/^    password:/{print $2; exit} /^quic:|^ech:/{f=0;g=0}' "$f";;
        ech_key)  awk '/^ech:/{f=1;next} f&&/^  keyPath:/{print $2; exit}' "$f";;
        listen_clean) node_get "$f" listen | tr -d ':" ';;
    esac
}

# 本机对外的 IP 地址 (服务端导出客户端时使用, 越准确越好)
detect_public_ip() {
    NODE_PUBLIC_IP=${NODE_PUBLIC_IP:-$(curl -4 -s --max-time 5 https://api.ipify.org || hostname -I 2>/dev/null | awk '{print $1}')}
    if [[ "$NODE_PUBLIC_IP" == 104.28.* || "$NODE_PUBLIC_IP" == "" ]]; then
        NODE_PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
}

# 生成节点客户端配置 + 分享链接 (服务端唯一来源)
node_export_client() {
    local name="$1"
    local sf; sf=$(node_file "$name")
    [[ -f "$sf" ]] || { print_error "节点 $name 不存在, 无法导出"; return 1; }
    ensure_node_dirs
    detect_public_ip

    local listen cert authp masq obfs_pw ech_pem sni pinhex port_start rest
    listen=$(node_get "$sf" listen)
    cert=$(node_get "$sf" cert)
    authp=$(node_get "$sf" auth)
    masq=$(node_get "$sf" masq)
    obfs_pw=$(node_get "$sf" obfs_pw)
    ech_pem=$(node_get "$sf" ech_key)

    # sni 必须等于服务器 TLS 证书里的域名 (CN/SAN), 否则 quic-go 服务端 TLS 校验拒绝 (CRYPTO_ERROR 0x150)
    # ← 之前真证书分支误用 masquerade 域名, 造成 sni 与证书不一致连不上
    sni=$(extract_cert_domain "$cert")
    [[ "$sni" == *.* ]] || sni=""
    [[ -z "$sni" ]] && sni="$masq"

    pinhex=$(openssl x509 -in "$cert" -outform der 2>/dev/null | sha256sum | awk '{print tolower($1)}')
    [[ "$pinhex" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]] && pinhex=""

    local out_dir="${NODES_OUT_DIR}/${name}"
    local outc="$out_dir/client.yaml" outl="$out_dir/share.txt"
    mkdir -p "$out_dir"

    # 端口/跳跃 (剥引号; 单口或区间)
    local clean
    clean=$(echo "$listen" | sed 's/[" ]//g; s/^[^0-9]*//')
    local rest port_start is_range=false
    if [[ "$clean" =~ ^[0-9]+\-[0-9]+$ ]]; then
        is_range=true
        rest="$clean"
        port_start="${clean%%-*}"
    else
        rest="$clean"
        port_start="$clean"
    fi

    local obfs_block=""
    if [[ -n "$obfs_pw" ]]; then
        obfs_block="obfs:
  type: salamander
  salamander:
    password: ${obfs_pw}"
    fi

    local ech_line_client="" ech_param=""
    if [[ -n "$ech_pem" && -f "$ech_pem" ]]; then
        local ecfg
        ecfg=$(awk '/BEGIN ECH CONFIGS/{f=1;next}/END ECH CONFIGS/{f=0}f' "$ech_pem" | tr -d '\n')
        if [[ -n "$ecfg" ]]; then
            ech_line_client="  ech: ${ecfg}"
            # URI 参数里的 ech base64 含 + / =, 必须百分号编码 (否则第三方 parse_qsl 把 + 当空格)
            ech_param="ech=$(uri_encode "$ecfg")"
        fi
    fi

    local insec_field=false link_insec="insecure=0" pin_field=""
    # 用本函数(实际可信 CA)判定, 不再引用未定义的 $issuer (历史 bug: 真证书节点被恒标 insecure)
    if cert_is_trusted "$cert"; then
        : # 真证书, mihomo 不需要 skip
    else
        insec_field=true
        link_insec="insecure=1"
        [[ -n "$pinhex" ]] && pin_field="  pinSHA256: ${pinhex}"
    fi

    local hop_lines="" mport_param=""
    if $is_range; then
        hop_lines="transport:
  udp:
    hopInterval: 30s"
        mport_param="&mport=${rest}"
    fi

    # ---------- 客户端 yaml (官方内核 + mihomo 样例两种形态合一) ----------
    cat > "$outc" <<EOF
# ============================================================
# HY2 节点 [${name}] 客户端配置 (服务端 hy2-panel 导出, $(date +"%F %T"))
# 服务端节点文件: $sf
# ============================================================

# ---------- mihomo / Clash.Meta 用这一段 ----------
proxies:
  - name: HY2-x
    server: ${NODE_PUBLIC_IP}
    port: ${port_start}
    type: hysteria2
    sni: ${sni}
    password: ${authp}
    skip-cert-verify: ${insec_field}
$( [[ "$insec_field" == "true" && -n "$pinhex" ]] && echo "    fingerprint: ${pinhex}" )
$( $is_range && echo "    ports: ${rest}" && echo "    hop-interval: 10" || echo "" )
$( [[ -n "$obfs_pw" ]] && echo "    obfs: salamander" && echo "    obfs-password: ${obfs_pw}" || echo "" )
    alpn:
      - h3

# ---------- 官方 hysteria 内核客户端 (支持 ECH/socks5+http 同口) ----------
server: ${NODE_PUBLIC_IP}:${rest}
auth: ${authp}

tls:
  sni: ${sni}
  insecure: ${insec_field}
${pin_field}
${ech_line_client}

$( [[ -n "$obfs_pw" ]] && echo "obfs:
  type: salamander
  salamander:
    password: ${obfs_pw}" || echo "# obfs: 未启用" )
$( [[ -n "$hop_lines" ]] && echo "" && cat <<< "$hop_lines" )

socks5:
  listen: 127.0.0.1:10808

http:
  listen: 127.0.0.1:8080
EOF
    

    # ---------- share link ----------
    local link
    link="hysteria2://$(uri_encode "$authp")@${NODE_PUBLIC_IP}:${port_start}?${link_insec}&sni=${sni}&alpn=h3"
    if [[ -n "$obfs_pw" ]]; then
        link="${link}&obfs=salamander&obfs-password=$(uri_encode "$obfs_pw")"
    else
        link="${link}&obfs=none"
    fi
    link="${link}&upmbps=45&downmbps=150"
    [[ -n "$mport_param" ]] && link="${link}${mport_param}"
    [[ -n "$ech_param" ]] && link="${link}&${ech_param}"
    link="${link}#${name}"
    echo "$link" > "$outl"
    printf "导出完成: %s\n        %s\n" "$outc" "$outl"
}

node_export_all() {
    ensure_node_dirs
    scan_nodes
    local n
    for n in "${NODE_NAMES[@]:-}"; do
        node_export_client "$n" | sed "s/^/  [$n] /"
    done
}

# =====================================================================
# 新增节点 (多节点流程, 复用单节点交互组件; official @ systemd 模板)
# =====================================================================
node_add() {
    ensure_node_dirs
    printf "节点名称 (默认 hnode%s): " "$(date +%H%M)"
    read -r name
    name=$(sanitize_node_name "${name:-hnode$(date +%H%M)}")
    local sf; sf=$(node_file "$name")
    [[ -f "$sf" ]] && { print_error "节点 $name 已存在 ($sf), 先删除或换名"; return 1; }

    # —— 伪装域名
    select_masq_domain

    # —— 证书方案 (真证书走副本; 自签则本节点独立一张)
    ask_cert "$MASQ_DOMAIN"
    local ncert="$CERT_PATH" nkey="$KEY_PATH"
    if [[ "$CERT_TRUSTED" != "true" ]]; then
        ncert="/etc/hysteria/server-${name}.crt"
        nkey="/etc/hysteria/server-${name}.key"
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$nkey" -out "$ncert" \
            -subj "/CN=${CERT_DOMAIN}" -addext "subjectAltName=DNS:${CERT_DOMAIN}" -days 36500 >/dev/null 2>&1
        chown hysteria "$ncert" "$nkey"
        chmod 644 "$ncert"; chmod 640 "$nkey"
        CERT_PATH="$ncert"; KEY_PATH="$nkey"; CERT_TRUSTED=false
    fi

    local nauth nport
    nauth=$(openssl rand -base64 16)
    nport=$(generate_port "Hysteria")

    # 端口跳跃 / obfs / ECH (复用现有交互函数)
    HOP_RANGE=""
    ask_port_hopping || return 1
    OBFS_PASSWORD=""
    ask_obfs
    ECH_ENABLED=false; ECH_PUBLIC_NAME="$MASQ_DOMAIN"
    ask_ech

    local nech_pem=""
    if [[ "$ECH_ENABLED" == "true" ]]; then
        nech_pem="/etc/hysteria/ech-${name}.pem"
        print_info "生成 ECH 密钥 (public-name=$ECH_PUBLIC_NAME)..."
        hysteria ech --public-name "$ECH_PUBLIC_NAME" -o "$nech_pem" --overwrite 2>&1 | tail -1
        chown hysteria "$nech_pem" 2>/dev/null
    fi

    local listen_line
    if [[ -n "$HOP_RANGE" ]]; then
        listen_line="listen: \":${HOP_RANGE}\""
    else
        listen_line="listen: \":${nport}\""
    fi

    cat > "$(node_file "$name")" <<EOF
${listen_line}

tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}

auth:
  type: password
  password: ${nauth}

masquerade:
  type: proxy
  proxy:
    url: https://${MASQ_DOMAIN}
    rewriteHost: true
$( [[ -n "$OBFS_PASSWORD" ]] && printf '\nobfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$OBFS_PASSWORD" )
$( [[ -n "$nech_pem" ]] && printf '\nech:\n  keyPath: %s\n' "$nech_pem" )
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
EOF

    SERVER_PUBLIC_IP_CUSTOM=""
    node_export_client "$name" >/dev/null

    printf "立即启动此节点? (y/N): "
    read -r runyn
    if [[ "$(clean_input2 "${runyn:-n}")" =~ ^[Yy] ]]; then
        systemctl enable --now "hysteria-server@${name}.service" >/dev/null 2>&1
        sleep 2
        if systemctl is-active --quiet "hysteria-server@${name}.service"; then
            print_ok "节点 $name 已启动 -> $(node_get "$(node_file "$name")" listen)"
        else
            print_error "启动失败: journalctl -u hysteria-server@${name}.service -n 20"
        fi
    fi
    echo
    echo "  客户端配置: ${NODES_OUT_DIR}/${name}/client.yaml"
    echo "  分享链接  : ${NODES_OUT_DIR}/${name}/share.txt"
}

node_list() {
    scan_nodes
    ((${#NODE_NAMES[@]} == 0)) && { print_warning "未发现节点 (请先执行 '安装' 或 '多节点->新增节点')"; return; }
    local n uf st i=1
    echo "${GREEN}节点列表${PLAIN}"
    for n in "${NODE_NAMES[@]}"; do
        uf=$(node_file "$n")
        if [[ "$n" == "default" ]]; then
            st=$(systemctl is-active hysteria-server.service 2>/dev/null || echo inactive)
        else
            st=$(systemctl is-active "hysteria-server@${n}.service" 2>/dev/null || echo inactive)
        fi
        printf "  %d) %-14s listen=%-13s %s %s\n" "$i" "$n" "$(node_get "$uf" listen)" \
            "$( [[ $st == active ]] && echo "${GREEN}[运行]${PLAIN}" || echo "${RED}[停止]${PLAIN}" )" \
            "masq=$(node_get "$uf" masq) obfs=$( [[ -n "$(node_get "$uf" obfs_pw)" ]] && echo salamander || echo none )"
        ((i++))
    done
}

node_pick() {
    scan_nodes
    ((${#NODE_NAMES[@]} == 0)) && return 1
    local i=1
    for n in "${NODE_NAMES[@]}"; do echo "  $i) $n" >&2; ((i++)); done
    printf "选择节点编号 (1-${#NODE_NAMES[@]}): " >&2
    read -r c < /dev/tty
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#NODE_NAMES[@]} )); then
        echo "${NODE_NAMES[$((c-1))]}"
        return 0
    fi
    return 1
}

node_menu() {
    while true; do
        echo -e "
  ${GREEN}多节点管理${PLAIN} (官方 hysteria-server@<名称>.service 模板)
  ----------------------
  1. 列出节点 / 状态
  2. 新增节点 (四特性可选)
  3. 节点 启动/停止/重启/状态
  4. 删除节点
  5. 导出全部客户端配置 (client.yaml + share link)
  0. 返回
  ----------------------"
        read -p "请输入选项 [0-5]: " nc || { echo "输入流已结束(EOF), 退出"; exit 130; }
        case "$nc" in
            0) return ;;
            1) node_list ;;
            2) node_add ;;
            3)
                local n=$(node_pick) || { print_warning "无节点"; continue; }
                local uf=$(node_file "$n")
                local un="hysteria-server@${n}.service"
                [[ "$n" == "default" ]] && un="hysteria-server.service"
                echo "节点 $n 选项: 1)启动 2)停止 3)重启 4)状态 5)配置验证"
                read -p "选择 [1-5]: " op
                case "$op" in
                    1)
                        if validate_node_cfg "$uf"; then
                            systemctl start "${un}" && print_ok "已启动"
                        else
                            print_error "配置验证未通过, 已阻止启动"
                        fi;;
                    2) systemctl stop "${un}" && print_ok "已停止";;
                    3)
                        if validate_node_cfg "$uf"; then
                            systemctl restart "${un}" && print_ok "已重启"
                        else
                            print_error "配置验证未通过, 已阻止重启"
                        fi;;
                    4) systemctl status "${un}" --no-pager | head -12 ;;
                    5) validate_node_cfg "$uf" && print_ok "配置验证通过" ;;
                esac ;;
            4)
                local n=$(node_pick) || continue
                [[ "$n" == "default" ]] && { print_error "默认节点请用主菜单 2 (卸载)"; continue; }
                printf "确认删除节点 %s? 输入大写 DEL 确认: " "$n"
                read -r dc
                if [[ "$dc" == "DEL" ]]; then
                    systemctl stop "hysteria-server@${n}.service" 2>/dev/null
                    systemctl disable "hysteria-server@${n}.service" 2>/dev/null
                    rm -f /etc/hysteria/${n}.yaml /etc/hysteria/hy2-${n}.yaml /etc/hysteria/server-${n}.crt /etc/hysteria/server-${n}.key /etc/hysteria/ech-${n}.pem
                    rm -rf "${NODES_OUT_DIR:?}/${n}"
                    print_ok "节点 $n 已删除"
                fi ;;
            5)
                ensure_node_dirs
                node_export_all
                ;;
            *) print_error "无效的选项" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

# =====================================================================
# 配置验证器 (启动前通用)
# validate_node_cfg <服务端yaml>  → 0=通过 1=失败 (stderr 打印具体错误)
# =====================================================================
validate_node_cfg() {
    local f="$1"
    local errs=0
    [[ -f "$f" ]] || { echo "节点文件不存在: $f"; return 1; }

    # YAML 语法 (python3 yaml 可用则深度校验)
    if command -v python3 >/dev/null && python3 -c "import yaml" 2>/dev/null; then
        if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null; then
            echo "YAML 语法错误"; errs=$((errs+1))
        fi
    fi

    # listen
    local listen; listen=$(node_get "$f" listen)
    [[ -z "$listen" ]] && { echo "listen 字段缺失/为空"; errs=$((errs+1)); }
    local clean=$(echo "$listen" | sed 's/[" ]//g; s/^[^0-9]*//')
    [[ -n "$clean" && "$clean" =~ ^[0-9]+(-[0-9]+$)?$ ]] || { echo "listen 格式非法: $listen"; errs=$((errs+1)); }
    { local sp_v ep_v; sp="${clean%%-*}"; [[ "$clean" =~ - ]] && ep="${clean##*-}" || ep="$sp" ; } 2>/dev/null
    (( sp >= 1 && sp <= 65535 && ep >= 1 && ep <= 65535 && sp <= ep )) || { echo "listen 端口越界(1-65535 或区间 reversed): $listen"; errs=$((errs+1)); }

    # cert/key 可读且被 hysteria 用户可读
    local cert key
    cert=$(node_get "$f" cert)
    key=$(awk '/^  key:/{print $2; exit}' "$f")
    [[ -f "$cert" ]] || { echo "证书不存在: $cert"; errs=$((errs+1)); }
    [[ -f "$key" ]] || { echo "私钥不存在: $key"; errs=$((errs+1)); }
    if [[ -f "$key" ]]; then
        sudo -u hysteria test -r "$key" 2>/dev/null || { echo "私钥 hysteria 用户不可读 (chown hysteria $key)"; errs=$((errs+1)); }
    fi

    # obfs
    local obfspw; obfspw=$(node_get "$f" obfs_pw)
    if grep -q "^obfs:" "$f" && [[ -z "$obfspw" ]]; then
        echo "obfs 块存在但密码字段缺失"; errs=$((errs+1))
    fi

    # ech keyPath 存在性
    local echp=$(awk '/^ech:/{f=1;next} f&&/^  keyPath:/{print $2; exit}' "$f")
    [[ -n "$echp" && ! -f "$echp" ]] && { echo "ech keyPath 文件不存在: $echp"; errs=$((errs+1)); }

    # 端口冲突 (排除本节点自己已监听的端口)
    if [[ -n "$clean" ]]; then
        local sp ep=""
        if [[ "$clean" =~ - ]]; then sp="${clean%%-*}"; ep="${clean##*-}"; else sp="$clean"; fi
        # ---- ①其它 hysteria 节点 yaml 的端口 (剥离自身 listen) ----
        local other_used="" clash=""
        while IFS= read -r ul; do
            local norm=$(echo "$ul" | sed 's/[": ]//g')
            [[ -z "$norm" || "$norm" == "$clean" ]] && continue
            other_used+=" $norm "
        done < <(grep -h '^listen:' /etc/hysteria/*.yaml 2>/dev/null | sed 's/^listen: *//')
        for up in $other_used; do
            local us="${up%%-*}" ue="${up##*-}"
            (( sp <= ue && ${ep:-$sp} >= us )) && { clash+=" hy节点$us"; }
        done
        # ---- ②非 hysteria 进程的 UDP 监听 (hysteria 的 ss 行含 users:(("hysteria" 排除) ----
        local hycount=0
        hycount=$(ss -ulHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | wc -l)
        local nu_hy=$(ss -ulHnp 2>/dev/null | grep -vF 'users:(("hysteria"' | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)
        for p in $nu_hy; do
            [[ "$p" =~ ^[0-9]+$ ]] && (( p >= sp && p <= ${ep:-$sp} )) && { clash+=" $p"; }
        done
        clash=$(echo "$clash" | tr -s ' ' | xargs)
        if [[ -n "$clash" ]]; then echo "端口与其它服务冲突: $clash"; errs=$((errs+1)); fi
    fi

    return $(( errs > 0 ? 1 : 0 ))
}

# 客户端 yaml 验证器 (结构 + ECH 版本 + 端口)
validate_client_cfg() {
    local f="$1" errs=0
    [[ -f "$f" ]] || { echo "客户端配置不存在: $f"; return 1; }
    local server auth sni ech obfspw
    server=$(awk '/^server:/{print $2; exit}' "$f")
    authp=$(sed -n 's/^auth: //p' "$f" | head -1)
    sni=$(awk '/^  sni:/{print $2; exit}' "$f")
    ech=$(awk '/^  ech:/{print $2; exit}' "$f")
    obfspw=$(awk '/salamander:/{f=1} f&&/^    password:/{print $2; exit}' "$f")

    [[ -z "$server" ]] && { echo "server 字段缺失"; errs=$((errs+1)); }
    [[ -z "$authp" ]] && { echo "auth 字段缺失"; errs=$((errs+1)); }
    [[ -z "$sni" && -z "$ech" ]] && { echo "sni 缺失(无 ECH 时必须显式给 sni)"; errs=$((errs+1)); }
    # ECH 版本
    if [[ -n "$ech" && -x "$CLIENT_BIN" ]]; then
        local ver=$($CLIENT_BIN version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        local mg=${ver%%.*}
        local mid=$(echo "$ver" | cut -d. -f2)
        if (( mg < 2 || (mg == 2 && mid < 12) )); then
            echo "ECH 需要 hysteria >= 2.12.x, 当前: ${ver:-未检测到内核}"; errs=$((errs+1))
        fi
    fi
    return $(( errs > 0 ? 1 : 0 ))
}
# =====================================================================
# 客户端模块 (本机作 HY2 客户端, 适合 CC)
# 目录: /root/catmi/hy2_client/{nodes,current.yaml}; 内核: /usr/local/bin/hysteria
# systemd: hysteria-client.service (由本脚本生成, 使用 current.yaml)
# =====================================================================
CLIENT_DIR="/root/catmi/hy2_client"
CLIENT_NODE_DIR="${CLIENT_DIR}/nodes"
CLIENT_BIN="/usr/local/bin/hysteria"

ensure_client_dirs() {
    mkdir -p "$CLIENT_NODE_DIR"
}

hy_client_arch() {
    case "$(uname -m)" in
        x86_64) echo amd64 ;;
        aarch64|armv8) echo arm64 ;;
        *) echo "unknown-$(uname -m)"; return 1 ;;
    esac
}

# ---------- 内核 ----------
client_kernel_install() {
    local at; at=$(hy_client_arch) || { print_error "未知架构: $(uname -m)"; return 1; }
    if [[ -x "$CLIENT_BIN" ]]; then
        print_info "已安装内核: $($CLIENT_BIN version 2>/dev/null | grep -i '^Version' | head -1)"
    else
        print_warning "未检测到内核 ($CLIENT_BIN)"
    fi
    echo "  1) 从 GitHub 自动下载/更新 (官方 latest, linux-${at})"
    echo "  2) 手动指定内核路径 (如 scp from 服务器)"
    echo "  3) 检查当前内核版本"
    read -p "选择 (默认1): " ck
    case "${ck:-1}" in
        1)
            print_info "下载: https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${at}.tar.gz"
            mkdir -p /tmp/hy2cli
            if curl -fL --connect-timeout 15 -o /tmp/hy2cli/hy2.tar.gz "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${at}.tar.gz" 2>&1; then
                tar -xzf /tmp/hy2cli/hy2.tar.gz -C /tmp/hy2cli
                mv /tmp/hy2cli/hysteria "$CLIENT_BIN" && chmod +x "$CLIENT_BIN"
                print_ok "安装完成."
                rm -rf /tmp/hy2cli
            else
                print_error "GitHub 直连失败 (本机可能无 github 出口). 请在服务器执行:"
                echo "  # 在服务器(x86_64/aarch64 对应)执行后 scp:"
                echo "  curl -L -o /tmp/stage.tar.gz https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${at}.tar.gz"
                echo "  tar -zxf /tmp/stage.tar.gz -C /tmp && scp /tmp/hysteria root@<客户端IP>:/usr/local/bin/hysteria"
                echo "然后回本菜单选 2 手动指定路径"
            fi ;;
        2)
            read -p "已存在内核的绝对路径: " p
            if [[ -x "$p" ]]; then
                mv "$p" "$CLIENT_BIN" 2>/dev/null || cp "$p" "$CLIENT_BIN"
                chmod +x "$CLIENT_BIN"
                print_ok "内核已就位: $CLIENT_BIN -> $($CLIENT_BIN version | grep -i '^Version')"
            else
                print_error "文件不存在或不可执行: $p"
            fi ;;
    esac
}

# ---------- hysteria2:// URI 解析 -> 节点 yaml ----------
client_parse_uri() {
    local uri="$1"
    python3 - "$uri" '/root/catmi/hy2_client' <<'PYEOF'
import sys, urllib.parse, json, base64, os
uri = sys.argv[1].strip()
outdir = sys.argv[2]
# 手动分拆: auth(base64 含 / + =) 与 host:port?query 分离; base64 不含 @,所以首个 @ 之后必是 host
uri = uri.split("#", 1)[0]          # 去掉 #fragment 标签
body = uri.split("://", 1)[1]
auth_part, rest = body.split("@", 1)
hostpart, _, query = rest.partition("?")
# IPv6 literal minors [addr]:port
if hostpart.startswith("["):
    _addr, _, _rest = hostpart[1:].partition("]")
    host = _addr
    port_s = _rest[1:] if _rest.startswith(":") else ""
elif ":" in hostpart:
    host, port_s = hostpart.rsplit(":", 1)
else:
    host, port_s = hostpart, ""
port = int(port_s) if port_s.isdigit() else 443
auth = urllib.parse.unquote(auth_part)
# 手动解析: 不用 parse_qsl (会把 base64 的 + 当空格), unquote 不做 + 转空格
q = {}
for _kv in query.split("&"):
    if "=" in _kv:
        _k, _v = _kv.split("=", 1)
        q[_k] = urllib.parse.unquote(_v)
get = lambda k, d="": q.get(k, d)
mport = get("mport")
sni = get("sni", host)
insecure = get("insecure", "0")
pin = get("pin", "")
ech = get("ech", "")
obfs = get("obfs", "none")
obfspw = get("obfs-password", "")
if not auth or not host:
    print("链接解析失败: 缺认证或主机", file=sys.stderr); sys.exit(1)
# server 地址
import re as _re
server = f"{host}:{port}"
if mport:
    if not _re.fullmatch(r"\d+(?:-\d+)?", mport):
        print(f"链接解析失败: mport 格式非法 '{mport}' (应为 数字 或 数字-数字, 如 45200-45300)", file=sys.stderr); sys.exit(1)
    server = f"{host}:{mport}"
lines = []
lines.append(f"server: {server}")
lines.append(f"auth: {auth}")
lines.append("")
lines.append("tls:")
lines.append(f"  sni: {sni}")
lines.append(f"  insecure: {'true' if insecure in ('1','true') else 'false'}")
if pin:
    # hex -> colon-separated form per doc
    pinctr = ':'.join(pin[i:i+2] for i in range(0, len(pin), 2))
    lines.append(f"  pinSHA256: {pinctr.upper()}")
if ech:
    lines.append(f"  ech: {ech}")
lines.append("")
if obfs != "none" and obfspw:
    lines.append(f"obfs:\n  type: {obfs}\n  {obfs}:\n    password: {obfspw}")
# hopInterval: 若 mport 是 range
if get("mport"):
    lines.append("")
    lines.append("transport:\n  udp:\n    hopInterval: 30s")
# 带宽 (服务端分享链接有值可直接用)
up = get("upmbps"); down = get("downmbps")
if up and down:
    lines.append("")
    lines.append(f"bandwidth:\n  up: {up} mbps\n  down: {down} mbps")
print("\n".join(lines), file=os.sys.stdout)
PYEOF
}

# 从 URI 或 yaml 导入节点到客户端
client_node_import_menu() {
    ensure_client_dirs
    echo "节点导入:"
    echo "  1) 粘贴 hysteria2:// 分享链接"
    echo "  2) 导入已有的 yaml 文件 (服务器导出的 client.yaml 或自己写)"
    read -p "选择 (默认1): " im
    local name
    printf "节点名称 (标识用): "
    read -r name
    name=$(sanitize_node_name "${name:-n$(date +%H%M%S)}")
    local fp="${CLIENT_NODE_DIR}/${name}.yaml"
    if [[ ! -d "$fp" ]]; then :; fi
    case "${im:-1}" in
        1)
            printf "粘贴链接: "
            read -r uri
            [[ "$uri" == hysteria2://* || "$uri" == *hysteria2://* ]] || { print_error "不是 hysteria2 链接"; return 1; }
            uri=$(echo "$uri" | grep -oE "hysteria2://[^#]+" | head -1)
            local gen
            gen=$(client_parse_uri "$uri") || return 1
            # 本地代理监听 (默认自动跳过被占端口)
            local d_s5="127.0.0.1:10808" d_hp="127.0.0.1:8080"
            cc_addr_free "$d_s5" || { d_s5=$(cc_find_free "$d_s5"); print_info "默认 socks5 10808 被占用, 已自动调节为空闲端口 $d_s5"; }
            cc_addr_free "$d_hp" || { d_hp=$(cc_find_free "$d_hp"); print_info "默认 http 8080 被占用, 已自动调节为空闲端口 $d_hp"; }
            read -p "socks5 监听 (默认 $d_s5, 直接回车即用): " s5
            read -p "http   监听 (默认 $d_hp , 直接回车即用): " hp
            s5="${s5:-${d_s5}}"; hp="${hp:-${d_hp}}"
            [[ "${s5:-127.0.0.1:10808}" == 0.0.0.0:* || "${hp:-127.0.0.1:8080}" == 0.0.0.0:8080 ]] && \
                print_warning "监听 0.0.0.0 = 本机全接口暴露, 请自行确认!"
            cat > "${CLIENT_NODE_DIR}/${name}.yaml" <<EOF
# [${name}] (来自 hysteria2 链接导入, "$(date +"%F %T")")
${gen}
socks5:
  listen: ${s5:-127.0.0.1:10808}
http:
  listen: ${hp:-127.0.0.1:8080}
EOF
            print_ok "节点 $name 已导入 -> ${CLIENT_NODE_DIR}/${name}.yaml"
            ;;
        2)
            read -p "yaml 文件路径: " yp
            [[ -f "$yp" ]] || { print_error "文件不存在: $yp"; return 1; }
            cp "$yp" "${CLIENT_NODE_DIR}/${name}.yaml"
            print_ok "节点 $name 已从文件导入";;
    esac
}

client_node_pick() {
    ensure_client_dirs
    local y f
    local -a CL=[]
    shopt -s nullglob
    CL=()
    for y in "${CLIENT_NODE_DIR}"/*.yaml; do
        CL+=("$(basename "$y" .yaml)")
    done
    shopt -u nullglob
    ((${#CL[@]} == 0)) && { print_warning "暂无节点, 请先导入 (菜单 3)"; return 1; }
    local i=1
    for f in "${CL[@]}"; do echo "  $i) $f" >&2; ((i++)); done
    printf "选择节点 (1-${#CL[@]}): " >&2
    if ! read -r c; then
        print_error "输入流已结束(EOF), 退出"; exit 130
    fi
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=${#CL[@]} )); then
        echo "${CL[$((c-1))]}"
        return 0
    fi
    return 1
}

# systemd unit
client_ensure_unit() {
    cat > /etc/systemd/system/hysteria-client.service <<EOF
[Unit]
Description=Hysteria 2 Client (managed by hy2-panel)
After=network.target

[Service]
Type=simple
ExecStart=${CLIENT_BIN} client -c ${CLIENT_DIR}/current.yaml
Restart=on-failure
RestartSec=3
WorkingDirectory=${CLIENT_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

client_start() {
    if ! validate_client_cfg "$CLIENT_DIR/current.yaml"; then
        print_error "客户端配置验证失败, 已阻止启动 (见上方错误)"
        return 1
    fi
    client_ensure_unit
    systemctl enable --now hysteria-client.service; sleep 2
    systemctl is-active hysteria-client.service
}
client_stop()     { systemctl stop hysteria-client.service; }
client_restart()  { systemctl restart hysteria-client.service; }
client_status()   { systemctl status hysteria-client.service --no-pager | head -12; }
client_logs()     { journalctl -u hysteria-client.service -n 40 --no-pager ${1:+-f} ; }

# 健康检查 (进程/监听/真实出站: HTTP/HTTPS/UDP/IPv4/IPv6, 出口 IP 一致性验证)
client_health() {
    echo "${GREEN}----------- 客户端健康检查 (真实出站) -----------${PLAIN}"
    local ok=0 fail=0 item cur="${CLIENT_DIR}/current.yaml"
    # 1 进程
    if systemctl is-active --quiet hysteria-client.service; then ok=$((ok+1)); echo "PASS  客户端进程 hysteria-client.service 运行中"; else fail=$((fail+1)); echo "FAIL  客户端进程未运行"; fi
    # 2 本地端口 listening: 精确匹配 ss 第4列 (端口子串会假阳, e.g. 1080 匹配 10808)
    local ports=$(awk '/^socks5:|^http:/{f=1} f&&/^  listen:/{print $2}' "${cur}" 2>/dev/null | sort -u)
    local p hostp
    for p in $ports; do
        # 精确等值比较: grep -Fx (避免 1080 匹配 10808 的子串假 PASS)
        if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qx "^${p}$"; then ok=$((ok+1)); echo "PASS  本地代理监听 $p"; else fail=$((fail+1)); echo "FAIL  本地代理未监听 $p"; fi
    done
    # 3 真实出站: 隧道断但本机可直连时, 端口探活会假 PASS → 以"隧道出口 IP 一致性"为准
    local sp hp
    sp=$(awk '/^socks5:/{f=1} f&&/^  listen:/{print $2; exit}' "${cur}" 2>/dev/null)
    hp=$(awk '/^http:/{f=1}  f&&/^  listen:/{print $2; exit}' "${cur}" 2>/dev/null)
    [[ -n "$sp" ]] || sp="127.0.0.1:10808"
    [[ -n "$hp" ]] || hp="127.0.0.1:8080"
    local s5="socks5h://${sp}" eip1 eip2 direct
    eip1=$(curl -4 -sx "$s5" --max-time 12 https://api.ipify.org 2>/dev/null)
    if [[ -n "$eip1" && "$eip1" != 127.* ]]; then ok=$((ok+1)); echo "PASS  SOCKS5 → HTTPS 出站 (出口 IPv4: $eip1)"; else fail=$((fail+1)); echo "FAIL  SOCKS5 → HTTPS 出站失败"; fi
    eip2=$(curl -4 -sx "http://${hp}" --max-time 12 https://api.ipify.org 2>/dev/null)
    if [[ -n "$eip2" && "$eip2" == "$eip1" ]]; then ok=$((ok+1)); echo "PASS  HTTP CONNECT 出站 (出口与 SOCKS5 一致: $eip2)"; else fail=$((fail+1)); echo "FAIL  HTTP CONNECT 出站失败或出口不一致 ($eip2 vs $eip1)"; fi
    direct=$(curl -4 -s --max-time 8 http://api.ipify.org 2>/dev/null)
    if [[ -z "$eip1" ]]; then
        : # 出站失败已在上一行计数
    elif [[ -z "$direct" ]]; then
        ok=$((ok+1)); echo "SKIP+PASS  本机无直连参照, 以出口连通判定"
    elif [[ "$eip1" != "$direct" ]]; then
        ok=$((ok+1)); echo "PASS  出口不等于本机直连出口 (验证流量确实走隧道)"
    else
        fail=$((fail+1)); echo "FAIL  隧道出口与本机直连出口相同, 疑似未走隧道"
    fi
    # 4 IPv6 出站
    # AAAA-only 域名 (api6.ipify.org) 强制远端走 IPv6; curl -6 会错误作用于本地到(v4字面量)代理的连接 → 必假失败
    local v6; v6=$(curl -sx "$s5" --max-time 12 https://api6.ipify.org 2>/dev/null)
    local v4x; v4x=$(curl -4 -sx "$s5" --max-time 12 https://api.ipify.org 2>/dev/null)
    if [[ -n "$v6" && "$v6" == *:* ]]; then ok=$((ok+1)); echo "PASS  隧道 IPv6 出站 ($v6)"; else fail=$((fail+1)); echo "FAIL/无  隧道 IPv6 出站不可用 (INFO: ${v6:-无返回})"; fi
    # 5 UDP 出站 (SOCKS5 UDP ASSOCIATE → DNS 1.1.1.1)
    local udpc
    udpc=$(python3 - "$sp" <<'PYEOF' 2>/dev/null
import socket, struct, sys
PROXY=sys.argv[1]
ph,_,pp=PROXY.partition(":")
try:
    s=socket.create_connection((ph,int(pp)),8); s.sendall(b"\x05\x01\x00")
    r=s.recv(2)
    if r[:2]!=b"\x05\x00": raise SystemExit(0)
    s.sendall(b"\x05\x03\x00\x01"+b"\x00"*4+struct.pack("!H",0))
    resp=s.recv(256)
    if resp[1]!=0: raise SystemExit(0)
    u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(5)
    qname=b"".join(bytes([len(w)])+w for w in b"example.com".split(b"."))+b"\x00"
    dnsq=b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"+qname+b"\x00\x00\x01\x00\x01"
    hdr=b"\x00\x00\x00\x01"+socket.inet_aton("1.1.1.1")+struct.pack("!H",53)
    u.sendto(hdr+dnsq,(socket.inet_ntoa(resp[4:8]),struct.unpack("!H",resp[8:10])[0]))
    data,_=u.recvfrom(512)
    print("UDP-DNS OK %d bytes qid=%s" % (len(data), data[10:12].hex()))
except SystemExit: pass
except Exception: pass
PYEOF
)
    if [[ "$udpc" == "UDP-DNS OK "* ]]; then ok=$((ok+1)); echo "PASS  SOCKS5 UDP 出站 ($udpc)"; else fail=$((fail+1)); echo "FAIL  SOCKS5 UDP 出站失败 (DNS 探测超时)"; fi
    echo "失败数: $fail, 通过数: $ok"
    echo "出口 IP 快照: IPv4=$eip1 IPv6=$v6  (时间: $(date +"%F %T"))"
}

# 修改本地代理监听 (socks5/http 地址+端口; 0.0.0.0 = LAN 暴露, 警告)
client_ports_edit() {
    [[ -f "$CLIENT_DIR/current.yaml" ]] || { print_error "尚未设置当前节点 (菜单 4)"; return 1; }
    local cur_s5 cur_hp
    cur_s5=$(awk '/^socks5:/{f=1} f&&/^  listen:/{print $2; exit}' "$CLIENT_DIR/current.yaml")
    cur_hp=$(awk '/^http:/{f=1} f&&/^  listen:/{print $2; exit}' "$CLIENT_DIR/current.yaml")
    print_info "当前: socks5=${cur_s5:-未设置}  http=${cur_hp:-未设置}"
    local lanip=$(hostname -I 2>/dev/null | awk '{print $1}')
    read -p "socks5 监听 [输入: host:port 或纯端口, 默认: ${cur_s5:-${lanip:-127.0.0.1}]:26540}]: " s5
    read -p "http   监听 [同上, 默认: ${cur_hp:-${lanip:-127.0.0.1}:26541}]: " hp
    s5="${s5:-${cur_s5:-${lanip:-127.0.0.1}:26540}}"
    hp="${hp:-${cur_hp:-${lanip:-127.0.0.1}:26541}}"
    # 规范化: 只输入端口时补 LAN IP (默认, 其他设备可直接连); 端口必须 1-65535 数字
    _norm_listen() {   # $1 = 输入, $2 = 默认 host
        local v="$1" h="${2:-192.168.1.1}" p
        [[ "$v" == *:* ]] || v="${h}:${v}"          # 只有端口 -> 补 host
        h="${v%%:*}"; p="${v##*:}"
        [[ "$p" =~ ^[0-9]+$ && $p -ge 1 && $p -le 65535 ]] || { echo "INVALID:$v"; return 1; }
        echo "$h:$p"
    }
    s5=$(_norm_listen "$s5" "${lanip:-127.0.0.1}"); [[ "$s5" == INVALID:* ]] && { print_error "socks5 监听非法: ${s5#INVALID:} (填 host:port 或纯端口)"; return 1; }
    hp=$(_norm_listen "$hp" "${lanip:-127.0.0.1}"); [[ "$hp" == INVALID:* ]] && { print_error "http 监听非法: ${hp#INVALID:}"; return 1; }
    # 占用预检 (排除 hysteria 自身; 若已占用给候选空闲端口)
    if ! cc_addr_free "$s5"; then
        local alt=$(cc_find_free "$s5")
        print_warning "socks5 $s5 已被其他进程占用"
        read -p "改用候选空闲端口 ${alt:-无} 吗? (y/N): " sw
        [[ "$(clean_input2 "${sw:-n}")" =~ ^[Yy] && -n "$alt" ]] && s5="$alt"
    fi
    if ! cc_addr_free "$hp"; then
        local alt2=$(cc_find_free "$hp")
        print_warning "http $hp 已被其他进程占用"
        read -p "改用候选空闲端口 ${alt2:-无} 吗? (y/N): " sw2
        [[ "$(clean_input2 "${sw2:-n}")" =~ ^[Yy] && -n "$alt2" ]] && hp="$alt2"
    fi
    if [[ "$s5" == 0.0.0.0:* || "$hp" == 0.0.0.0:* ]]; then
        print_warning "!!! 监听 0.0.0.0 = 代理暴露给整个局域网/公网, 无认证将成为开放代理, 请确认!"
        read -p "确认继续? (y/N): " cc
        [[ "$(clean_input2 "${cc:-n}")" =~ ^[Yy] ]] || { print_error "已取消"; return 1; }
    fi
    local tmpf="${CLIENT_DIR}/current.yaml.new"
    awk -v s5="$s5" -v hp="$hp" '
        /^socks5:/ {b=1; print; next}
        /^http:/   {b=2; print; next}
        /^(server:|auth:|tls:|obfs:|transport:|proxies:|#)/ {b=0; print; next}
        { if (b==1 && /^  listen:/) print "  listen: " s5
          else if (b==2 && /^  listen:/) print "  listen: " hp
          else print }
    ' "$CLIENT_DIR/current.yaml" > "$tmpf" && mv "$tmpf" "$CLIENT_DIR/current.yaml"
    print_ok "监听已更新: socks5=$s5  http=$hp"
    if systemctl is-active --quiet hysteria-client.service; then
        systemctl restart hysteria-client.service && print_ok "已重启生效"
    fi
    echo
    echo "mihomo/Clash 出站片段 (在其他设备的 mihomo 中, 指向本机):"
    show_proxy_snippet
}

# 输出 mihomo/Clash outbound 片段 (由 current.yaml 监听推导; 127.0.0.1 会自动替换为本机 LAN IP)
show_proxy_snippet() {
    [[ -f "$CLIENT_DIR/current.yaml" ]] || return 1
    local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local s5 hp
    s5=$(awk '/^socks5:/{f=1} f&&/^  listen:/{print $2; exit}' "$CLIENT_DIR/current.yaml")
    hp=$(awk '/^http:/{f=1} f&&/^  listen:/{print $2; exit}' "$CLIENT_DIR/current.yaml" 2>/dev/null)
    local sip="${s5%%:*}"; [[ "$sip" == "$s5" || "$sip" == 127.0.0.1 ]] && sip="${lanip:-$ip}"
    local hip="${hp%%:*}"; [[ "$hip" == "$hp" || "$hip" == 127.0.0.1 ]] && hip="${lanip:-$ip}"
    if [[ -n "$s5" ]]; then
        echo "  - name: HY2-SOCKS5"
        echo "    type: socks5"
        echo "    server: ${sip:-未知IP}"
        echo "    port: ${s5##*:}"
        echo "    udp: true"
    fi
    if [[ -n "$hp" ]]; then
        echo "  - name: HY2-HTTP"
        echo "    type: http"
        echo "    server: ${hip:-未知IP}"
        echo "    port: ${hp##*:}"
    fi
}


# TCP 地址:端口 是否空闲 (排除 hysteria-client 自身监听)
cc_addr_free() {
    local a="$1" p="${1##*:}"
    local used
    used=$(ss -tlnHpn 2>/dev/null | grep -vF 'users:(("hysteria"' | awk '{print $4}' | grep -oE "[0-9]+\$" | sort -un | tr "\n" " ")
    echo "$used" | grep -qw "$p" && return 1 || return 0
}
# 找第一个空闲端口: 输入 host:port; 递增至 +100
cc_find_free() {
    local a="${1%%:*}" p="${1##*:}"
    local used
    used=$(ss -tlnHpn 2>/dev/null | grep -vF 'users:(("hysteria"' | awk '{print $4}' | grep -oE "[0-9]+\$" | sort -un | tr "\n" " ")
    for (( i=0; i<100; i++ )); do
        (( p++ ))
        if ! echo "$used" | grep -qw "${p}"; then
            echo "$a:$p"; return 0
        fi
    done
    return 1   # 100 内无空闲
}

cc_client_module() {
    ensure_client_dirs
    while true; do
        # 当前节点名称: 与 nodes/*.yaml 内容比对得出 (basename current.yaml 恒为字面量, 无信息量)
        local cn="未设置"
        if [[ -f "$CLIENT_DIR/current.yaml" ]]; then
            local ch yl; ch=$(md5sum "$CLIENT_DIR/current.yaml" &>/dev/null; true)
            ch=$(md5sum "$CLIENT_DIR/current.yaml" 2>/dev/null | awk '{print $1}')
            local y cf
            for cf in "${CLIENT_DIR}"/nodes/*.yaml; do
                [[ -f "$cf" ]] || { cn="(手动/未导入)"; break; }
                y=$(md5sum "$cf" 2>/dev/null | awk '{print $1}')
                [[ "$y" == "$ch" ]] && { cn="${cf##*/}"; cn="${cn%.yaml}"; break; }
            done
            [[ "$cn" == "未设置" && "$cf" != "${CLIENT_DIR}/nodes/*.yaml" ]] && cn="(已手动编辑)"
        fi
        echo -e "
  ${GREEN}HY2 客户端面板${PLAIN} (本机作 hysteria2 客户端)
  ----------------------
  服务状态: $(systemctl is-active hysteria-client.service 2>/dev/null | grep -q active && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${RED}未启动${PLAIN}")
  节点    : $cn
  ----------------------
  1. 安装/更新内核 (GitHub latest / 手动指定路径)
  2. 内核版本 (当前已装)
  3. 添加节点 (粘贴 hysteria2:// 链接 或 yaml 文件)
  4. 切换当前节点
  5. 当前节点信息 + mihomo/Clash 出站片段
  6. 启动 / 停止 / 重启 / 状态
  7. 查看日志
  8. 修改本地代理监听 (端口/LAN IP)
  9. 健康检查 (进程/监听/代理 HTTP/HTTPS/UDP/IPv4/IPv6)
  0. 返回
  ----------------------"
        read -p "请输入选项 [0-9]: " ci || { echo "输入流已结束(EOF), 退出"; exit 130; }
        case "$ci" in
            0) return ;;
            1) client_kernel_install ;;
            2) client_kernel_version ;;
            3) client_node_import_menu ;;
            4) client_node_switch ;;
            5) client_show_current ;;
            6) client_ctl_menu ;;
            7) client_do_logs ;;
            8) client_ports_edit ;;
            9) client_health ;;
            *) print_error "无效的选项" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

# ---- 命名一致性补齐 ----
client_ctl_menu() {
    while true; do
        echo "  1) 启动  2) 停止  3) 重启  4) 状态  5) 测试拨号  0) 返回"
        read -p "选择 [0-5]: " c8 || { echo "输入流已结束(EOF), 退出"; exit 130; }
        case "$c8" in
            0) return ;;
            1) client_start ;;
            2) client_stop ;;
            3) client_restart ;;
            4) client_status ;;
            5) client_do_proxy_probe ;;
            *) print_error "无效的选项" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

client_do_logs() {
    echo "1) 最近 40 行  2) 实时跟随 (-f)"
    read -p "选择 (1): " lm || return 1
    case "$lm" in 2) client_logs follow;; *) client_logs;; esac
}

client_kernel_version() {
    [[ -x "$CLIENT_BIN" ]] && $CLIENT_BIN version | head -4 || print_warning "内核未安装"
}

client_node_switch() {
    ensure_client_dirs
    local n=$(client_node_pick) || return 1
    cp "${CLIENT_NODE_DIR}/${n}.yaml" "${CLIENT_DIR}/current.yaml"
    print_ok "当前节点切换为: $n"
}
client_show_current() {
    if [[ -f "${CLIENT_DIR}/current.yaml" ]]; then
        echo "── hysteria 内核配置摘要 (current.yaml) ──"
        grep -E "^(server:|auth:|  sni:|  insecure:|  ech:|  pinSHA256:|type: salamander|    password: |  hopInterval: )" "${CLIENT_DIR}/current.yaml" | head -12
        echo
        echo "── 本机代理入口 ──"
        awk '/^socks5:/{f=1;next} f&&/^  listen:/{print "  socks5: "$2; f=0}' "${CLIENT_DIR}/current.yaml"
        awk '/^http:/{f=1;next} f&&/^  listen:/{print "  http  : "$2; f=0}' "${CLIENT_DIR}/current.yaml"
        echo
        echo "── mihomo/Clash 出站片段 (贴进其他设备 proxies) ──"
        show_proxy_snippet
    else
        print_warning "尚未设置当前节点 (菜单 4)"
    fi
}

# 代理链路探活: socks5 http/https、UDP 由 nginx http 探活可佐证
client_do_proxy_probe() {
    [[ -f "${CLIENT_DIR}/current.yaml" ]] || { print_error "请先选择当前节点 (菜单 4)"; return 1; }
    local sp=$(awk '/^socks5:/{f=1} f&&/listen:/{print $2; exit}' "${CLIENT_DIR}/current.yaml")
    local hpl=$(awk '/^http:/{f=1} f&&/listen:/{print $2; exit}' "${CLIENT_DIR}/current.yaml")
    local s5h="socks5h://${sp:-127.0.0.1:10808}"
    echo -n " socks5 TCP  : "; curl -sx "$s5h" -o /dev/null -w "HTTP %{http_code} %{time_total}s\n" --max-time 10 https://www.gstatic.com/generate_204
    echo -n " HTTPS CONNECT: "; curl -sx socks5h://"${sp:-127.0.0.1:10808}" -o /dev/null -w "HTTP %{http_code}\n" --max-time 10 --connect-to ::https://www.google.com https://www.debian.org 2>/dev/null || \
        curl -sx http://"${hpl:-127.0.0.1:8080}" -o /dev/null -w "HTTP %{http_code}\n" --max-time 10 https://www.debian.org
    echo -n " HTTP 代理   : "; curl -sx http://"${hpl:-127.0.0.1:8080}" -o /dev/null -w "HTTP %{http_code} %{time_total}s\n" --max-time 10 http://example.com
    echo -n " IPv4 连接   : "; curl -4 -sx socks5h://"${sp:-127.0.0.1:10808}" -o /dev/null -w "%{http_code}\n" --max-time 10 https://api.ip.sb/ip 2>/dev/null || echo FAIL
    echo -n " IPv6 连接   : "; curl -sx socks5h://"${sp:-127.0.0.1:10808}" -o /dev/null -w "%{http_code}\n" --max-time 10 https://api6.ipify.org 2>/dev/null || echo FAIL
}

# 卸载 Hysteria 2
uninstall_hysteria() {
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${PLAIN}"
    echo -e "${RED}!!  危险: 即将彻底卸载 Hysteria 2 并删除  ${PLAIN}"
    echo -e "${RED}!!  /etc/hysteria 与 $INSTALL_DIR 全部数据  ${PLAIN}"
    echo -e "${RED}!!  (含后再也买不到的所有节点配置/证书!)  ${PLAIN}"
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${PLAIN}"
    printf "确认要继续? 输入大写 U N I N S T A L L 逐字确认: "
    local confirm
    read -r confirm
    [[ "$confirm" == "UNINSTALL" ]] || { print_warning "已取消 (未删除任何东西)"; return 1; }
    mkdir -p /tmp/hysteria-uninstall-bak
    tar -czf /tmp/hysteria-uninstall-bak/hysteria-$(date +%m%d%H%M).tar.gz /etc/hysteria "$INSTALL_DIR" 2>/dev/null
    print_info "卸载前已自动备份到 /tmp/hysteria-uninstall-bak/"
    print_info "开始卸载 Hysteria 2..."
    systemctl stop hysteria-server.service
    systemctl disable hysteria-server.service
    systemctl stop $RELAY_SERVICE 2>/dev/null
    systemctl disable $RELAY_SERVICE 2>/dev/null
    rm -f /etc/systemd/system/$RELAY_SERVICE
    rm -rf /etc/hysteria
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/catmihy2
    systemctl daemon-reload
    print_info "Hysteria 2 已成功卸载"
}

# 更新 Hysteria 2
update_hysteria() {
    print_info "开始更新 Hysteria 2..."
    if ! bash <(curl -fsSL https://get.hy2.sh/); then
        print_error "更新失败"
        return 1
    fi
    print_info "更新成功"
    systemctl restart hysteria-server.service
}

# 从服务端配置解析当前值 (供客户端管理/修改配置使用)
server_port()    { grep -oP '(?<=listen: ":)[0-9]+' /etc/hysteria/config.yaml; }
server_password(){ grep -oP '(?<=^  password: ).*' /etc/hysteria/config.yaml; }
server_domain()  { grep -oP '(?<=url: https://)[^/]+' /etc/hysteria/config.yaml; }
client_server()  { grep -oP '(?<=server: ).*' "$INSTALL_DIR/config.yaml" | head -1; }

# 查看客户端配置
view_client_config() {
    if [ -f "$INSTALL_DIR/config.yaml" ]; then
        cat "$INSTALL_DIR/config.yaml"
    else
        print_error "客户端配置文件不存在, 请先安装"
    fi
}

# ============== 中继 (TCP/UDP Forwarding, 客户端功能) ==============
# 中继是 Hysteria 客户端的能力: 在客户端机器监听本地端口, 经隧道转发到服务器网络上的任意地址
RELAY_CONF="$INSTALL_DIR/relay.conf"
# 中继服务端信息 (可指定任意 HY2 服务端; 未配置时回退到本机服务端)
RELAY_SERVER_CONF="$INSTALL_DIR/relay-server.conf"
RELAY_SERVICE="hysteria-relayclient.service"

relay_list() {
    echo "==================== 当前中继映射 ===================="
    if [ ! -f "$RELAY_CONF" ]; then
        echo "  (无, relay.conf 不存在)"
        return
    fi
    local n=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        echo "  [$n] $line"
    done < "$RELAY_CONF"
    [[ $n -eq 0 ]] && echo "  (无)"
}

relay_add() {
    print_info "添加中继映射 (客户端机器上: 监听本地端口 -> 转发到服务器网络上的地址)"
    echo "协议: 1) TCP  2) UDP"
    read -p "请选择协议 [1-2]: " proto
    case "$proto" in
        2) proto="udp" ;;
        *) proto="tcp" ;;
    esac

    read -p "客户端本地监听地址 (默认 127.0.0.1): " listen_addr
    listen_addr=${listen_addr:-127.0.0.1}
    read -p "客户端本地监听端口: " listen_port
    while [[ ! "$listen_port" =~ ^[0-9]+$ ]] || [ -z "$listen_port" ]; do
        read -p "端口必须是数字, 重新输入: " listen_port
    done

    read -p "远端地址 (服务器网络上的目标, 如 127.0.0.1:80 或 10.0.0.6:6600): " remote
    [[ -z "$remote" ]] && { print_error "远端地址不能为空"; return; }

    echo "$proto $listen_addr:$listen_port $remote" >> "$RELAY_CONF"
    print_info "已添加: $proto $listen_addr:$listen_port -> $remote"
    print_warning "中继是客户端功能, 请在客户端机器使用生成的原生客户端配置 (不是 Clash 格式)"
}

relay_del() {
    relay_list
    read -p "输入要删除的编号 [回车取消]: " num
    [[ "$num" =~ ^[0-9]+$ ]] || { print_info "已取消"; return; }
    sed -i "${num}d" "$RELAY_CONF" 2>/dev/null
    print_info "已删除第 $num 条"
}

# 读取中继服务端信息 (优先自定义 relay-server.conf, 否则回退本机服务端)
relay_server_info() {
    unset RS_ADDR RS_AUTH RS_SNI
    if [ -f "$RELAY_SERVER_CONF" ]; then
        # shellcheck disable=SC1090
        . "$RELAY_SERVER_CONF"
    fi
    if [ -z "$RS_ADDR" ]; then
        RS_ADDR="$(client_server):$(server_port)"
    fi
    if [ -z "$RS_AUTH" ]; then
        RS_AUTH="$(server_password)"
    fi
    if [ -z "$RS_SNI" ]; then
        RS_SNI="$(server_domain)"
    fi
}

relay_gen_config() {
    [ -f "$RELAY_CONF" ] || { print_error "没有中继映射, 请先添加"; return; }
    relay_server_info
    if [ -z "$RS_ADDR" ] || [ -z "$RS_AUTH" ]; then
        print_error "中继服务端信息不完整, 请先安装本机服务端或配置中继服务端(选项5)"
        return
    fi
    [[ -z "$RS_SNI" ]] && RS_SNI=$(echo "$RS_ADDR" | cut -d: -f1)

    out_file="$INSTALL_DIR/client-relay.yaml"
    {
        echo "# Hysteria 2 客户端配置 (含中继端口映射)"
        echo "# 用法: 拷贝到客户端机器, hysteria client -c client-relay.yaml 运行"
        echo "# 注意: 中继需要原生 hysteria 客户端, Clash 不支持 tcpForwarding/udpForwarding"
        echo "server: $RS_ADDR"
        echo "auth: $RS_AUTH"
        echo "tls:"
        echo "  sni: $RS_SNI"
        echo "  insecure: true"
        echo "socks5:"
        echo "  listen: 127.0.0.1:1080"
        echo "tcpForwarding:"
        n=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            set -- $line
            proto=$1; laddr=$2; remote=$3
            if [ "$proto" = "tcp" ]; then
                echo "  - listen: $laddr"
                echo "    remote: $remote"
            fi
        done < "$RELAY_CONF"
        echo "udpForwarding:"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            set -- $line
            proto=$1; laddr=$2; remote=$3
            if [ "$proto" = "udp" ]; then
                echo "  - listen: $laddr"
                echo "    remote: $remote"
                echo "    timeout: 20s"
            fi
        done < "$RELAY_CONF"
    } > "$out_file"
    print_info "已生成原生客户端配置: $out_file"
    cat "$out_file"
}

# 配置中继服务端 (手动指定任意 HY2 服务端 IP:端口 + 认证密码)
relay_server_set() {
    relay_server_info
    echo "==================== 中继服务端配置 ===================="
    echo "当前: 地址=${RS_ADDR:-未设置}  认证=${RS_AUTH:-未设置}  SNI=${RS_SNI:-未设置}"
    echo "(直接回车保持不变)"
    read -p "服务端地址 (IP:端口, 如 1.2.3.4:16680): " new_addr
    read -p "认证密码: " new_auth
    read -p "SNI 域名 (伪装域名, 可空): " new_sni
    new_addr=${new_addr:-$RS_ADDR}
    new_auth=${new_auth:-$RS_AUTH}
    new_sni=${new_sni:-$RS_SNI}
    if [ -z "$new_addr" ] || [ -z "$new_auth" ]; then
        print_error "地址和认证密码不能都为空"
        return
    fi
    cat > "$RELAY_SERVER_CONF" << EOF
RS_ADDR=$new_addr
RS_AUTH=$new_auth
RS_SNI=$new_sni
EOF
    print_info "中继服务端已保存: $RELAY_SERVER_CONF"
    print_warning "运行中继前请先执行 '生成客户端中继配置' (选项4)"
}

# 启动/停止/状态: systemd 管理中继客户端
relay_service_unit() {
    cat > /etc/systemd/system/$RELAY_SERVICE << EOF
[Unit]
Description=Hysteria 2 Relay Client
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria client -c $INSTALL_DIR/client-relay.yaml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

relay_start() {
    # 启动前自动根据最新 relay.conf / relay-server.conf 重新生成配置,
    # 这样"纯客户端"场景: 配好信息 -> 启动即用, 无需手动分两步
    echo "---------------------- 重新生成中继配置 ----------------------"
    relay_gen_config || { print_error "配置不完整, 无法启动"; return; }
    relay_service_unit
    systemctl daemon-reload
    systemctl enable --now $RELAY_SERVICE >/dev/null 2>&1
    if systemctl is-active --quiet $RELAY_SERVICE; then
        print_info "中继客户端已启动 (systemd: $RELAY_SERVICE, 自动加载最新配置)"
    else
        print_error "启动失败, 查看: journalctl -u $RELAY_SERVICE -n 30"
    fi
}

relay_stop() {
    if systemctl is-active --quiet $RELAY_SERVICE; then
        systemctl disable --now $RELAY_SERVICE >/dev/null 2>&1
        print_info "中继客户端已停止"
    else
        print_info "中继客户端未在运行"
    fi
}

relay_status() {
    echo "==================== 中继客户端状态 ===================="
    if systemctl is-active --quiet $RELAY_SERVICE; then
        echo -e "  运行状态: ${GREEN}运行中${PLAIN} (systemd: $RELAY_SERVICE)"
    else
        echo -e "  运行状态: ${RED}未运行${PLAIN}"
    fi
    echo "  服务端: $( [ -f "$RELAY_SERVER_CONF" ] && grep RS_ADDR "$RELAY_SERVER_CONF" | cut -d= -f2 || echo '本机服务端' )"
    echo "  监听映射: $( [ -f "$RELAY_CONF" ] && grep -c . "$RELAY_CONF" || echo 0 ) 条"
    echo "  最近日志:"
    journalctl -u $RELAY_SERVICE --no-pager -n 3 2>/dev/null | tail -3 || echo "  (无日志)"
}

relay_menu() {
    while true; do
        relay_status_short=$(systemctl is-active $RELAY_SERVICE 2>/dev/null)
        if [ "$relay_status_short" = "active" ]; then
            rs_text="${GREEN}运行中${PLAIN}"
        else
            rs_text="${RED}未运行${PLAIN}"
        fi
        echo -e "
  ${GREEN}中继端口映射 (客户端功能: TCP/UDP Forwarding)${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 查看中继映射
  ${GREEN}2.${PLAIN} 添加中继映射
  ${GREEN}3.${PLAIN} 删除中继映射
  ${GREEN}4.${PLAIN} 生成客户端中继配置
  ${GREEN}5.${PLAIN} 配置中继服务端 (IP:端口 + 认证)
  ${GREEN}6.${PLAIN} 启动中继客户端
  ${GREEN}7.${PLAIN} 停止中继客户端
  ${GREEN}8.${PLAIN} 查看中继客户端状态
  ${GREEN}0.${PLAIN} 返回
  ----------------------
  中继客户端: ${rs_text}
  ----------------------"
        read -p "请输入选项 [0-8]: " rc || { echo "输入流已结束(EOF), 退出"; exit 130; }
        case "$rc" in
            0) return ;;
            1) relay_list ;;
            2) relay_add ;;
            3) relay_del ;;
            4) relay_gen_config ;;
            5) relay_server_set ;;
            6) relay_start ;;
            7) relay_stop ;;
            8) relay_status ;;
            *) echo -e "${RED}无效的选项 ${rc}${PLAIN}" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

# 客户端管理子菜单
client_menu() {
    while true; do
        echo -e "
  ${GREEN}客户端管理 (服务端侧)${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 查看客户端配置 (Clash 格式 + 分享链接)
  ${GREEN}2.${PLAIN} 中继端口映射 (TCP/UDP Forwarding)
  ${GREEN}3.${PLAIN} 查看全部节点导出的客户端文件 (含分享链接)
  ${GREEN}0.${PLAIN} 返回
  ----------------------"
        read -p "请输入选项 [0-3]: " cc || { echo "输入流已结束(EOF), 退出"; exit 130; }
        case "$cc" in
            0) return ;;
            1) view_client_config ;;
            2) relay_menu ;;
            3)
                ensure_node_dirs
                for f in "${NODES_OUT_DIR}"/*/share.txt; do
                    [[ -f "$f" ]] && { echo "=== $(basename "$(dirname "$f")") ==="; cat "$f"; }
                done
                ;;
            *) echo -e "${RED}无效的选项 ${cc}${PLAIN}" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

# 修改配置
modify_config() {
    # 获取当前的端口和密码
    current_port=$(server_port)
    current_password=$(server_password)
    current_domain=$(server_domain)

    echo "当前配置: 端口=${current_port}, 伪装域名=${current_domain}"
    echo "1) 修改端口和密码"
    echo "2) 修改伪装域名 (重新生成证书, 需同步更新客户端)"
    read -p "请选择 [1-2]: " mtype

    if [[ "$mtype" == "2" ]]; then
        # ---- 修改伪装域名 (证书 + masquerade + 客户端 sni 三处联动) ----
        select_masq_domain
        gen_selfsigned_cert "$MASQ_DOMAIN"
        sed -i "s|^    url: https://.*|    url: https://${MASQ_DOMAIN}|" /etc/hysteria/config.yaml
        # 同步客户端配置中的 sni
        sed -i "s|^    sni: .*|    sni: ${MASQ_DOMAIN}|" "$INSTALL_DIR/config.yaml"
        sed -i "s|sni=[^&]*|sni=${MASQ_DOMAIN}|" "$INSTALL_DIR/config.yaml"
        systemctl restart hysteria-server.service
        print_info "伪装域名已修改为: ${MASQ_DOMAIN} (证书/masquerade/客户端已同步)"
        return
    fi

    read -p "请输入新的端口号 (当前: ${current_port}, 默认随机生成): " new_port
    new_port=${new_port:-$(generate_port "Hysteria")}

    read -p "请输入新的密码 (当前: ${current_password}, 默认随机生成): " new_password
    new_password=${new_password:-$(openssl rand -base64 16)}

    # 输出修改前的配置
    echo "修改前服务端配置内容:"
    cat /etc/hysteria/config.yaml

    # 修改服务端配置，保持 listen 行格式
    if sed -i "s|^listen: \":[0-9]*\"|listen: \":${new_port}\"|" /etc/hysteria/config.yaml; then
        echo "成功修改服务端的端口号"
    else
        echo "修改服务端的端口号失败"
        return 1
    fi

    # 修改服务端密码 (只改 auth: 块内的 password 行; 盲改全局 password 会破坏 obfs 密码)
    if grep -q '^auth:' /etc/hysteria/config.yaml && sed -i "/^auth:/{n;s|^ *password: .*|  password: ${new_password}|;}" /etc/hysteria/config.yaml; then
        echo "成功修改服务端的密码"
    else
        echo "修改服务端的密码失败"
        return 1
    fi

    # 客户端配置
    # (原 7890 逻辑为误写, 已移除)

    # 修改客户端中的代理端口为服务端新端口
    if sed -i "s|^\s*port: [0-9]*$|    port: ${new_port}|" "$INSTALL_DIR/config.yaml"; then
        echo "成功修改客户端的端口号"
    else
        echo "修改客户端的端口号失败"
        return 1
    fi

    # 修改客户端密码
    if sed -i "s|^\s*password: .*|    password: ${new_password}|" "$INSTALL_DIR/config.yaml"; then
        echo "成功修改客户端的密码"
    else
        echo "修改客户端的密码失败"
        return 1
    fi

    # 同步分享链接中的端口和密码
    if sed -i "s|hysteria2://[^@]*@|hysteria2://${new_password}@|" "$INSTALL_DIR/config.yaml" && \
       sed -i "s|:[0-9]*?sni=|:${new_port}?sni=|" "$INSTALL_DIR/config.yaml"; then
        echo "成功同步分享链接"
    else
        echo "分享链接同步失败 (可忽略, 手动更新)"
    fi

    # 输出修改后的配置
    echo "修改后服务端配置内容:"
    cat /etc/hysteria/config.yaml
    echo "修改后客户端配置内容:"
    cat "$INSTALL_DIR/config.yaml"

    echo "配置已修改为："
    echo "端口：${new_port}"
    echo "密码：${new_password}"

    # 重启服务
    if systemctl restart hysteria-server.service; then
        echo "服务已重启"
    else
        echo "重启服务失败"
    fi
}


# ============== 总状态页 (Server/Client/版本/特性一览 + 真实出站探测) ==============
show_status_overview() {
    clear
    local hyv
    hyv=$(/usr/local/bin/hysteria version 2>/dev/null | grep -wm1 Version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    [[ -z "$hyv" ]] && hyv="未安装"
    local sst="停止(/未装)" cct="停止(/未装)"
    systemctl is-active --quiet hysteria-server.service 2>/dev/null && sst="${GREEN}RUNNING${PLAIN}"
    systemctl is-active --quiet hysteria-client.service 2>/dev/null && cct="${GREEN}RUNNING${PLAIN}" || cct="${RED}未启动${PLAIN}"
    systemctl is-active --quiet hysteria-server.service 2>/dev/null && sst="${GREEN}RUNNING${PLAIN}" || sst="${RED}停止${PLAIN}"
    # 服务端节点特性
    scan_nodes quiet 2>/dev/null
    echo -e "${GREEN}══════════════ HY2 总状态 ══════════════${PLAIN}"
    echo -e "  Server (default): $sst"
    if (( ${#NODE_NAMES[@]} > 0 )); then
        for n in "${NODE_NAMES[@]}"; do
            local st="停止(/未装)"
            if [[ "$n" == "default" ]]; then st=$(systemctl is-active hysteria-server.service 2>/dev/null); else st=$(systemctl is-active "hysteria-server@$n.service" 2>/dev/null); fi
            local uf; uf=$(node_file "$n")
            local lsn ob ex
            lsn=$(node_get "$uf" listen | tr -d '"')
            [[ -n "$(node_get "$uf" obfs_pw)" ]] && ob="Salamander" || ob="无"
            grep -q '^ech:' "$uf" 2>/dev/null && ex="${GREEN}ON${PLAIN}" || ex="off"
            echo -e "   - 节点 $n: ${st} listen=$lsn obfs=$ob ech=$ex"
        done
    fi
    echo
    echo -e "  Client           : $cct"
    local cn="(未导入)"; local y cf ch
    if [[ -f "$CLIENT_DIR/current.yaml" ]]; then
        ch=$(md5sum "$CLIENT_DIR/current.yaml" 2>/dev/null | awk '{print $1}')
        for cf in "${CLIENT_DIR}"/nodes/*.yaml; do
            [[ -f "$cf" ]] || break
            y=$(md5sum "$cf" 2>/dev/null | awk '{print $1}')
            [[ "$y" == "$ch" ]] && { cn="${cf##*/}"; cn="${cn%.yaml}"; break; }
            cn="(已手动编辑)"
        done
    fi
    local sp hm
    sp=$(awk '/^socks5:/{f=1} f&&/^  listen:/{print $2; exit}' "$CLIENT_DIR/current.yaml" 2>/dev/null)
    hp=$(awk '/^http:/{f=1} f&&/^  listen:/{print $2; exit}' "$CLIENT_DIR/current.yaml" 2>/dev/null)
    echo -e "  当前节点          : $cn"
    echo -e "  HY2 Version      : ${hyv}"
    [[ -n "$sp" ]] && echo -e "  SOCKS5           : $sp"
    [[ -n "$hp" ]] && echo -e "  HTTP Proxy       : $hp"
    echo
    # 真实出站探测 (Quick 数秒, 不拖慢菜单)
    if [[ -n "$sp" ]]; then
        local s5="socks5h://${sp}" eip4 eip6
        printf "  IPv4 (隧道 v4)   : 检测中"
        eip4=$(curl -4 -sx "$s5" --max-time 10 https://api.ipify.org 2>/dev/null)
        [[ -n "$eip4" ]] && printf "\r  IPv4 (隧道 v4)   : ${GREEN}PASS${PLAIN} (出口 $eip4)\n" || printf "\r  IPv4 (隧道 v4)   : ${RED}FAIL${PLAIN}\n"
        printf "  IPv6 (隧道 v6)   : 检测中"
        eip6=$(curl -sx "$s5" --max-time 10 https://api6.ipify.org 2>/dev/null)
        [[ -n "$eip6" && "$eip6" == *:* ]] && printf "\r  IPv6 (隧道 v6)   : ${GREEN}PASS${PLAIN} (出口 $eip6)\n" || printf "\r  IPv6 (隧道 v6)   : ${RED}FAIL${PLAIN}\n"
        printf "  UDP (SOCKS5 UDP) : 检测中"
        local udpcs
        udpcs=$(python3 - "$sp" <<'PYEOF' 2>/dev/null
import socket, struct, sys
try:
    ph,_,pp=sys.argv[1].partition(":")
    s=socket.create_connection((ph,int(pp)),8); s.sendall(b"\x05\x01\x00")
    r=s.recv(2)
    if r[:2]!=b"\x05\x00": raise SystemExit
    s.sendall(b"\x05\x03\x00\x01"+b"\x00"*4+struct.pack("!H",0))
    resp=s.recv(256)
    if resp[1]!=0: raise SystemExit
    u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(5)
    qname=b"".join(bytes([len(w)])+w for w in b"example.com".split(b"."))+b"\x00"
    dnsq=b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"+qname+b"\x00\x00\x01\x00\x01"
    hdr=b"\x00\x00\x00\x01"+socket.inet_aton("1.1.1.1")+struct.pack("!H",53)
    u.sendto(hdr+dnsq,(socket.inet_ntoa(resp[4:8]),struct.unpack("!H",resp[8:10])[0]))
    data,_=u.recvfrom(512); print("PASS")
except Exception: pass
PYEOF
)
        [[ "$udpcs" == "PASS" ]] && printf "\r  UDP (SOCKS5 UDP) : ${GREEN}PASS${PLAIN}\n" || printf "\r  UDP (SOCKS5 UDP) : ${RED}FAIL${PLAIN}\n"
        echo -e "  探测时间          : $(date +"%F %T")"
    fi
    echo -e "${GREEN}════════════════════════════════════════${PLAIN}"
}

# ============== 服务端/内核日志快查 (旧版缺失, 仅 status) ==============
server_logs() {
    local cur
    printf "查看哪个节点日志? (直接回车=default, 输入节点名): "
    if ! read -r ln; then return 1; fi
    ln=$(clean_input2 "${ln:-}")
    if [[ -z "$ln" ]]; then
        journalctl -u hysteria-server -n 40 --no-pager
    else
        journalctl -u "hysteria-server@$ln" -n 40 --no-pager
    fi
}

# 主菜单
show_menu() {
    # 获取服务状态
    hysteria_server_status=$(systemctl is-active hysteria-server.service)
    hysteria_server_status_text=$(if [[ "$hysteria_server_status" == "active" ]]; then echo -e "${GREEN}启动${PLAIN}"; else echo -e "${RED}未启动${PLAIN}"; fi)
    
    # 显示菜单
    echo -e "
  ${GREEN}Hysteria 2 管理脚本${PLAIN} (v2.1 服务端 + 客户端)
  ============================
  ${BLUE}[服务端]${PLAIN}
  ${GREEN}1.${PLAIN} 安装/重建 默认节点
  ${GREEN}2.${PLAIN} 多节点管理
  ${GREEN}3.${PLAIN} 卸载全部 (Hysteria2 服务)
  ${GREEN}4.${PLAIN} 更新内核
  ${GREEN}5.${PLAIN} 重启服务 (默认节点)
  ${GREEN}6.${PLAIN} 客户端查看 (服务端侧)
  ${GREEN}7.${PLAIN} 修改配置 (默认节点)
  ${GREEN}8.${PLAIN} 查询服务状态 (所有节点)
  ${GREEN}9.${PLAIN} 服务端日志 (default / 节点名)
  ----------------------
  ${BLUE}[总览 / 本机客户端]${PLAIN}
  ${GREEN}s.${PLAIN} 总状态页 (Server/Client/特性/ECH/出站 PASS|FAIL)
  ${GREEN}c.${PLAIN} 客户端面板 (内核/节点导入/启动/健康检查)
  ${GREEN}0.${PLAIN} 退出脚本
  ----------------------
  服务状态: ${hysteria_server_status_text}
  ----------------------"
    read -p "请输入选项 [1-9 / s / c / 0]: " choice || { clear;echo;echo "输入流已结束(EOF), 退出"; exit 130; }
    case "$choice" in
        0) clear;exit 0 ;;
        1) install_hysteria ;;
        2) node_menu ;;
        3) uninstall_hysteria ;;
        4) update_hysteria ;;
        5) systemctl restart hysteria-server.service ;;
        6) client_menu ;;
        7) modify_config ;;
        8) systemctl status hysteria-server.service --no-pager | head -15; node_list ;;
        9) server_logs ;;
        s|S) show_status_overview ;;
        c|C) cc_client_module ;;
        *) echo -e "${RED}无效的选项 ${choice}${PLAIN}" ;;
    esac

    echo && read -p "按回车键继续..." && echo
}

# 主程序
main() {
    show_banner
    create_shortcut
    while true; do
        show_menu
    done
}

main "$@"
