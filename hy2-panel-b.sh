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

# =========================================================
# 带宽参数 (唯一持久化默认值源; 单位 Mbps, 数值型)
# 语义: CLIENT_BW_(UP|DOWN) = 客户端角度
#   CLIENT_BW_UP   = 客户端 → 服务端   (官方: client.up; 同时 = server.down)
#   CLIENT_BW_DOWN = 服务端 → 客户端   (官方: client.down; 同时 = server.up)
# 服务端 bandwidth 仅在用户显式开启 CLIENT_AS_SERVER_LIMIT=true 时生成
# 并按方向换算写入 (server.up=CLIENT_BW_DOWN, server.down=CLIENT_BW_UP)。
# 持久化: $INSTALL_DIR/bw.env, 面板主菜单 'b' 修改; 0 表示该方向不设置/不限速。
# ============================================================
BW_ENV_FILE="${BW_ENV_FILE:-$INSTALL_DIR/bw.env}"
CLIENT_BW_UP=${CLIENT_BW_UP:-45}
CLIENT_BW_DOWN=${CLIENT_BW_DOWN:-150}
CLIENT_AS_SERVER_LIMIT=${CLIENT_AS_SERVER_LIMIT:-false}
load_bw_env() {
    [[ -f "$BW_ENV_FILE" ]] && . "$BW_ENV_FILE"
    # 防呆: 数值非法时回落默认 (高级场景可直接手改 bw.env)
    echo "${CLIENT_BW_UP:-}" | grep -qE '^[0-9]+(\.[0-9]+)?$' || CLIENT_BW_UP=45
    echo "${CLIENT_BW_DOWN:-}" | grep -qE '^[0-9]+(\.[0-9]+)?$' || CLIENT_BW_DOWN=150
}
save_bw_env() {
    mkdir -p "$(dirname "$BW_ENV_FILE")"
    cat > "$BW_ENV_FILE" <<EOF
# 面板带宽默认值 (单位 Mbps; 0=该方向不设置). 上一轮编辑: $(date +"%F %T")
CLIENT_BW_UP=${CLIENT_BW_UP}
CLIENT_BW_DOWN=${CLIENT_BW_DOWN}
CLIENT_AS_SERVER_LIMIT=${CLIENT_AS_SERVER_LIMIT}
SRV_IGNORE_CBW_ON=${SRV_IGNORE_CBW_ON:-false}
EOF
    chmod 600 "$BW_ENV_FILE" 2>/dev/null
}

# ================================
# 带宽参数菜单 (主菜单 b)
# 语义: 这里输入的是 CLIENT 带宽 (client.up / client.down, 官方方向)
#   client.up   = 客户端→服务端 = server.down
#   client.down = 服务端→客户端 = server.up
# 只作为"新生成的配置/链接/订阅"的默认值; 已有节点需在客户端面板重导入生效。
# ============================================================
bw_menu() {
    load_bw_env
    echo ""
    echo "${GREEN}客户端带宽默认值${PLAIN} ────────────"
    echo ""
    echo "当前默认值"
    echo "  上传 : ${CLIENT_BW_UP} Mbps"
    echo "  下载 : ${CLIENT_BW_DOWN} Mbps"
    echo "  同时写入服务端限速 : ${CLIENT_AS_SERVER_LIMIT}"
    echo ""
    echo "说明 : 用于以后新增/导入节点的默认带宽; 已有节点不受影响。"
    echo "       上方数字=这台设备向服务器申报的最大带宽, 宁小勿大。"
    echo "       对应方向填了非 0 数字才会启用 Brutal; 0 = 该方向普通 BBR。"
    echo ""
    echo "${GREEN}1.${PLAIN} 修改上传带宽"
    echo "${GREEN}2.${PLAIN} 修改下载带宽"
    echo "${GREEN}3.${PLAIN} 恢复默认值 (45 / 150)"
    echo "${GREEN}4.${PLAIN} 应用到当前节点"
    echo "${GREEN}0.${PLAIN} 返回"
    echo ""
    read -p "请输入选项 [0-4]: " bwop || { echo "输入被中断, 安全退出"; exit 130; }
    case "$bwop" in
        0) return ;;
        1)
            read -p "上传 Mbps (0=不设置, 回车保留 ${CLIENT_BW_UP}): " u || return 130
            u=$(echo "${u:-}" | xargs); [[ -z "$u" ]] && u=$CLIENT_BW_UP
            echo "$u" | grep -qE '^[0-9]+(\.[0-9]+)?$' || { print_error "数字无效 (例如 100 或 45.5, 0=不设置)"; return 1; }
            CLIENT_BW_UP="$u" ;;
        2)
            read -p "下载 Mbps (0=不设置, 回车保留 ${CLIENT_BW_DOWN}): " d || return 130
            d=$(echo "${d:-}" | xargs); [[ -z "$d" ]] && d=$CLIENT_BW_DOWN
            echo "$d" | grep -qE '^[0-9]+(\.[0-9]+)?$' || { print_error "数字无效"; return 1; }
            CLIENT_BW_DOWN="$d" ;;
        3) CLIENT_BW_UP=45; CLIENT_BW_DOWN=150 ;;
        4) bw_apply_to_current; return ;;
        *) print_error "无效的选项"; return ;;
    esac
    read -p "同时写入服务端限速 (当前 ${CLIENT_AS_SERVER_LIMIT}, y/N): " sl || sl=""
    case "$(echo "${sl:-}" | xargs | tr 'A-Z' 'a-z')" in
        y|yes) CLIENT_AS_SERVER_LIMIT=true ;;
        n|no) CLIENT_AS_SERVER_LIMIT=false ;;
        *) : ;;
    esac
    if [[ "$CLIENT_AS_SERVER_LIMIT" == "true" ]]; then
        read -p "服务端忽略客户端带宽提示 (当前 ${SRV_IGNORE_CBW_ON:-false}, y/N): " icbw || icbw=""
        case "$(echo "${icbw:-}" | xargs | tr 'A-Z' 'a-z')" in
            y|yes) SRV_IGNORE_CBW_ON=true ;;
            n|no) SRV_IGNORE_CBW_ON=false ;;
            *) : ;;
        esac
    fi
    save_bw_env
    print_ok "✓ 已保存: 上传 ${CLIENT_BW_UP} / 下载 ${CLIENT_BW_DOWN} Mbps"
    print_info "生效范围: 以后新建/导入的节点; 已有节点请用『4. 应用到当前节点』或客户端→当前节点设置"
}

# 把 bw.env 默认带宽写入当前客户端节点 (current.yaml), 可选立即重启
bw_apply_to_current() {
    [[ -f "${CLIENT_DIR}/current.yaml" ]] || { print_warning "本机还没有导入任何节点, 无契约可应用"; return; }
    python3 - "${CLIENT_DIR}/current.yaml" "${CLIENT_BW_UP}" "${CLIENT_BW_DOWN}" <<'PYEOF'
import re,sys
p,u,d=sys.argv[1],sys.argv[2],sys.argv[3]
t=open(p).read()
t=re.sub(r"^bandwidth:\n(?:[ \t].*\n)+","",t,flags=re.M)
t=re.sub(r"\n\n\n","\n\n",t)
u=u if float(u)>0 else ""
d=d if float(d)>0 else ""
if u or d:
    lines="bandwidth:\n"
    if u: lines+=f"  up: {u} mbps\n"
    if d: lines+=f"  down: {d} mbps\n"
    t=t.rstrip()+"\n\n"+lines
open(p,"w").write(t)
PYEOF
    print_ok "✓ 已把默认带宽应用到当前节点 (${CLIENT_BW_UP}/${CLIENT_BW_DOWN} Mbps)"
    read -p "是否立即重启客户端使生效? (y/N): " ap || ap="n"
    case "$(echo "${ap:-n}" | xargs | tr 'A-Z' 'a-z')" in
        y) systemctl restart hysteria-client.service && print_ok "✓ 客户端已重启, 带宽已生效" ;;
        *) print_info "未重启; 带宽已写入 current.yaml, 请自行在客户端→4 重启" ;;
    esac
}

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
    echo -e "${GREEN}Version: ${PLAIN}2.1.6 (multi-node + client + status + bw-v2)"
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
    local protocol="$1" user_input port udp_used
    # 注意: 本函数 stdout 只允许出现最终端口号; 任何提示一律走 stderr (历史 bug: 提示被 command substitution 写进 listen)
    udp_used=$(ss -ulHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un; grep -h '^listen:' /etc/hysteria/*.yaml 2>/dev/null | sed 's/[^0-9-]/ /g' | tr ' -' '\n' | grep -E '^[0-9]+$' | sort -un)
    tcp_used=$(ss -tlHn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)
    while :; do
        port=$((RANDOM % 10001 + 10000))
        read -p "请为 ${protocol} 输入监听端口(默认为随机生成): " user_input
        port=$(echo "${user_input:-$port}" | xargs | tr -d '"')
        if ! echo "$port" | grep -qE '^[0-9]+$'; then
            echo "端口应为纯数字 (1-65535), 例如 45131; 你输入的是 '$port'" >&2
            continue
        fi
        if (( port < 1 || port > 65535 )); then
            echo "端口越界 (1-65535): $port" >&2
            continue
        fi
        if echo "$udp_used" | grep -qE "^${port}$"; then
            echo "UDP 端口 $port 已被其它程序占用了, 请换一个" >&2
            continue
        fi
        if echo "$tcp_used" | grep -qE "^${port}$"; then
            echo "TCP 端口 $port 已被占用 (HY2 只用 UDP, 一般可忽略; 建议另选端口避免误导)" >&2
            continue
        fi
        echo "$port"; return 0
    done
    return 1
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

# ========= 证书密钥类型检查 (chrome parrot 兼容性: RSA/ECDSA ok, Ed25519 警告) =========
cert_key_type() {
    local crt="$1" out
    command -v openssl >/dev/null 2>&1 || { echo "unknown"; return; }
    out=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl pkey -pubin -text -noout 2>/dev/null)
        if echo "$out" | grep -qi "ED25519"; then echo "ed25519"
    elif echo "$out" | grep -qiE "ASN1 OID: (prime|secp|P-)"; then echo "ecdsa"
    elif echo "$out" | grep -qE "(Private|Public)-Key: \([0-9]+ bit\)|RSA (Public|PRIVATE)"; then echo "rsa"
    else echo "unknown"
    fi
}

# ========= 带宽输入: 接受 bps/kbps/mbps/gbps (1000 进制, 官方语义), 空为未设置 =========
bw_read_field() { # $1=字段名(Up_BAND/…) $2=提示默认值
    local v
    printf "%s (如 100 mbps / 2 gbps / 500000 kbps, 直接回车=不设置): " "$1" >&2
    if ! read -r v; then return 1; fi
    v=$(echo "$v" | tr 'A-Z' 'a-z' | xargs)
    if [[ -z "$v" ]]; then echo ""; return 0; fi
    if [[ -z $(echo "$v" | tr -d ' ') ]] || ! echo "$v" | grep -qE '^[0-9]+(\.[0-9]+)? ?(bps|kbps|mbps|gbps)$'; then
        print_error "格式无效: $v (应为 数字 + bps/kbps/mbps/gbps)"; bw_read_field "$1" "$2"; return 0
    fi
    echo "$v"
}

# ========= 服务端: 拥塞控制 + bandwidth (v2.8.0 语义, 实测内核 v2.12.3) =========
# 内核支持 congestion.type: bbr|reno; brutal 不是 type —— 设置 bandwidth 后默认使用 Brutal 算法
# 输出全局: SRV_CC (default|bbr|reno), SRV_BBR_PROFILE, SRV_BW_UP, SRV_BW_DOWN, SRV_IGNORE_CBW, SRV_DISABLE_LOSSCOMP
ask_srv_congestion() {
    SRV_CONGESTION="default" SRV_BBR_PROFILE="" SRV_BW_UP="" SRV_BW_DOWN="" SRV_IGNORE_CBW=false SRV_DISABLE_LOSSCOMP=false
    local c
    echo "  限速/拥塞方式 (不熟悉就选 1 默认):" >&2
    echo "  1) 默认/自动 (有 bandwidth=Brutal, 无=BBR)" >&2
    echo "  2) BBR (可带 profile)" >&2
    echo "  3) Reno" >&2
    printf "  选择 (默认1): " >&2
    read -r c || return 1
    c=$(clean_input2 "$c")
    case "$c" in
        2) SRV_CONGESTION="bbr"
           local pf
           printf "  BBR 调优风格: 1) 标准 (默认)  2) 稳妥  3) 激进 (选号即可): " >&2
           read -r pf || pf=""
           case "$(clean_input2 "$pf")" in ""|1) SRV_BBR_PROFILE="standard";; 2) SRV_BBR_PROFILE="conservative";; 3) SRV_BBR_PROFILE="aggressive";; *) SRV_BBR_PROFILE="standard";; esac
           ;;
        3) SRV_CONGESTION="reno" ;;
        *) SRV_CONGESTION="default" ;;
    esac
    local yn
    printf "  设置服务端 bandwidth (up/down)? (默认: 否, y/N): " >&2
    read -r yn || return 0
    case "$(clean_input2 "$yn")" in y|Y)
        SRV_BW_UP=$(bw_read_field "  上传 (服务端 up, 即客户端的上传方向)") || return 0
        [[ -z "$SRV_BW_UP" ]] && { print_warning "bandwidth 需同时设置 up/down, 已跳过"; return 0; }
        SRV_BW_DOWN=$(bw_read_field "下载 (服务端 down, 注意: 与客户端上传方向相对)") || return 0
        [[ -z "$SRV_BW_DOWN" ]] && { print_warning "bandwidth 需同时设置 up/down, 已跳过"; return 0; }
        printf "  ignoreClientBandwidth (忽略客户端带宽提示)? (y/N): " >&2
        read -r yn || return 0
        case "$(clean_input2 "$yn")" in y|Y) SRV_IGNORE_CBW=true; print_info "已设置: 客户端 bandwidth 提示将被忽略 (BTW: 官方语义 server_bw.down 决定客户端 down)";;
            *) SRV_IGNORE_CBW=false;; esac
        printf "  Brutal 丢包补偿 (有丢包时略微提速硬凑设定值)? 1) 启用(默认)  2) 停用: " >&2
        read -r yn || return 0
        case "$(clean_input2 "$yn")" in 2) SRV_DISABLE_LOSSCOMP=true;; *) SRV_DISABLE_LOSSCOMP=false;; esac
        ;;
    esac
}

# ========= 客户端: bandwidth + 拥塞 + Chrome Parrot (写入 current.yaml 或导入) =========
# 输出全局: CLI_CONGESTION, CLI_BBR_PROFILE, CLI_BW_UP, CLI_BW_DOWN, CLI_DISABLE_LOSSCOMP, CHROME_PARROT_ON
ask_cli_traffic() {
    load_bw_env
    CLI_CONGESTION="default" CLI_BBR_PROFILE="" CLI_BW_UP="" CLI_BW_DOWN="" CHROME_PARROT_ON=true
    local c yn
    echo "  客户端拥塞控制 (默认/自动: 有 bandwidth=Brutal; 内核 type 仅 bbr/reno):" >&2
    echo "  1) 默认/自动  2) BBR (带 profile)  3) Reno" >&2
    printf "  选择 (默认1): " >&2
    read -r c || return 1
    case "$(clean_input2 "$c")" in
        2) CLI_CONGESTION="bbr"
           printf "  BBR 调优风格: 1) 标准 (默认)  2) 稳妥  3) 激进 (选号即可): " >&2
           read -r c || return 1
           case "$(clean_input2 "$c")" in 2) CLI_BBR_PROFILE="conservative";; 3) CLI_BBR_PROFILE="aggressive";; *) CLI_BBR_PROFILE="standard";; esac ;;
        3) CLI_CONGESTION="reno" ;;
    esac
    local yn
    printf "  设置客户端 bandwidth (up/down)? (默认: 不显式设置, 由服务端协商; y/N): " >&2
    read -r yn || return 0
    case "$(clean_input2 "$yn")" in y|Y)
        printf "  上传 (客户端 up, 默认 %s Mbps, 回车保留): " "$CLIENT_BW_UP" >&2
        CLI_BW_UP=$(bw_read_field "上传" "") || CLI_BW_UP=$CLIENT_BW_UP
        [[ -z "$CLI_BW_UP" ]] && CLI_BW_UP=$CLIENT_BW_UP
        printf "  下载 (客户端 down, 默认 %s Mbps, 回车保留): " "$CLIENT_BW_DOWN" >&2
        CLI_BW_DOWN=$(bw_read_field "下载" "") || CLI_BW_DOWN=$CLIENT_BW_DOWN
        [[ -z "$CLI_BW_DOWN" ]] && CLI_BW_DOWN=$CLIENT_BW_DOWN
        printf "  Brutal 丢包补偿 (有丢包时略微提速硬凑设定值)? 1) 启用(默认)  2) 停用: " >&2
        read -r yn || return 0
        case "$(clean_input2 "$yn")" in 2) CLI_DISABLE_LOSSCOMP=true;; *) CLI_DISABLE_LOSSCOMP=false;; esac
        ;;
    esac
}

cli_traffic_block() { # 生成 client yaml 增量块 (bandwidth/congestion/quic.disableChromeParrot)
    local up="$CLI_BW_UP" down="$CLI_BW_DOWN" lc="$CLI_DISABLE_LOSSCOMP"
    local out=""
    # 自动补单位: 若用户只填了数字 (45) → 45 mbps (官方要求 "45 mbps")
    [[ "$up" =~ ^[0-9.]+$ ]] && up="${up} mbps"
    [[ "$down" =~ ^[0-9.]+$ ]] && down="${down} mbps"
    if [[ -n "$up" || -n "$down" ]]; then
        out+="bandwidth:"
        [[ -n "$up" ]] && out+=$'\n  up: '"$up"
        [[ -n "$down" ]] && out+=$'\n  down: '"$down"
        [[ "$lc" == "true" ]] && out+=$'\n  disableLossCompensation: true'
    fi
    if [[ "$CLI_CONGESTION" != "default" ]]; then
        out+=$'\n\ncongestion:\n  type: '"$CLI_CONGESTION"
        [[ -n "$CLI_BBR_PROFILE" && "$CLI_CONGESTION" == "bbr" ]] && out+=$'\n  profile: '"$CLI_BBR_PROFILE"
    fi
    if [[ "$CHROME_PARROT_ON" != "true" ]]; then
        out+=$'\n\nquic:\n  disableChromeParrot: true'
    fi
    printf "%s" "$out"
}


# 生成服务端 bandwidth/congestion yaml 块 (依据 ask_srv_congestion 取好的全局值)
srv_cc_block() {
    local out=""
    # "同时写入服务端限速" 模式 (bw_menu 开启 CLIENT_AS_SERVER_LIMIT 且本节点未手动设服务端 bw):
    # 按官方方向换算自动生成 (server.up = client.down, server.down = client.up)
    if [[ -z "$SRV_BW_UP" && "${CLIENT_AS_SERVER_LIMIT:-false}" == "true" && "$CLIENT_BW_UP" != 0 && "$CLIENT_BW_UP" != 0.0 && "$CLIENT_BW_DOWN" != 0 && "$CLIENT_BW_DOWN" != 0.0 ]]; then
        SRV_BW_UP="${CLIENT_BW_DOWN} mbps"
        SRV_BW_DOWN="${CLIENT_BW_UP} mbps"
        SRV_IGNORE_CBW="${SRV_IGNORE_CBW_ON:-false}"
    fi
    if [[ -n "$SRV_BW_UP" ]]; then
        out="bandwidth:
  up: ${SRV_BW_UP}
  down: ${SRV_BW_DOWN}"
        [[ "$SRV_IGNORE_CBW" == "true" ]] && out+='
  ignoreClientBandwidth: true'
        [[ "$SRV_DISABLE_LOSSCOMP" == "true" ]] && out+='
  disableLossCompensation: true'
    fi
    if [[ "$SRV_CONGESTION" != "default" ]]; then
        [[ -n "$out" ]] && out+='

'
        out+="congestion:
  type: ${SRV_CONGESTION}"
        [[ "$SRV_CONGESTION" == "bbr" && -n "$SRV_BBR_PROFILE" ]] && out+='
  profile: '"${SRV_BBR_PROFILE}"
    fi
    printf "%s" "$out"
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
    if ! bash <(curl -fsSL --max-time 120 https://get.hy2.sh/); then
    print_error "内核安装失败 (网络不通或安装源异常), 已中止配置生成; 请检查网络后重试"
    return 1
  fi

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
    echo ""
    ask_srv_congestion    # 拥塞控制 / 服务端 bandwidth (v2.8.0+ 语义)

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
$(srv_cc_block
)
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
        ech_link="&ech=$(uri_encode "$ECH_CONFIG")"
        ech_note="   注意: ECH 仅官方 hysteria 客户端支持, mihomo/v2rayN 等不识别该参数"
    fi
    # bandwidth (server bandwidth.up/down ↔ 客户端 up/down 互换, v2.8.0 协商语义)
    load_bw_env
    local bw_up_cl="$CLIENT_BW_UP" bw_dn_cl="$CLIENT_BW_DOWN"
    [[ -n "$SRV_BW_UP" && -n "$SRV_BW_DOWN" ]] && {
        bw_up_cl="${SRV_BW_DOWN% *}"; bw_dn_cl="${SRV_BW_UP% *}"
    }

    cat << EOF > "$INSTALL_DIR/config.yaml"

  - name: Hy2-Hysteria2
    server: $PUBLIC_IP
    port: $PORT
    type: hysteria2
    up: "$bw_up_cl Mbps"
    down: "$bw_dn_cl Mbps"
    sni: $sni
    password: $AUTH_PASSWORD
$fp_lines
$ports_lines
$obfs_lines
    alpn:
      - h3

**********************************************************************************************************************
   hysteria2://$(uri_encode "$AUTH_PASSWORD")@$PUBLIC_IP:$PORT?$insecure&sni=${sni}&alpn=h3&$link_obfs&upmbps=$bw_up_cl&downmbps=$bw_dn_cl${PIN_PART}${ech_link}#HY2
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
    local nm="$1"
    nm=$(echo "$nm" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | cut -c1-24)
    case "$nm" in
        ""|config|default|hysteria|server)
            echo "__illegal__"
            return;;
    esac
    echo "$nm"
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
        bw_up)    awk '/^bandwidth:/{f=1;next} f&&/^  up:/{print $2, $3; exit} f&&/^[a-z]/&&!/bandwidth/{exit}' "$f" | tr -d '"' ;;
        bw_down)  awk '/^bandwidth:/{f=1;next} f&&/^  down:/{print $2, $3; exit}' "$f" ;;
        bw_ign)   awk '/^bandwidth:/{f=1} f&&/^  ignoreClientBandwidth:/{print $3; exit}' "$f" ;;
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

        local authp
    authp=$(node_get "$sf" auth 2>/dev/null | tr -d '"')
    if [[ -z "$authp" ]]; then
        print_error "节点 auth 缺失 (yaml 被手工改坏?), 拒绝导出分享链接 — 请先恢复配置"
        return 1
    fi
# 带宽 (mihomo up/down + 链接 upmbps/downmbps): 方向取“客户端 up / down" (服务器 up → 客户客户端 down 的对偶)
    load_bw_env
    local bw_up_note bw_dn_note bw_lines_mihomo
    if node_get "$sf" bw_ign 2>/dev/null | grep -q true; then
        bw_up_note="ignoreClientBandwidth=true 生效时, 链接带宽仅参考 (服务端忽略 client 提示)"
    fi
    local srv_bw_up srv_bw_down
    srv_bw_up=$(node_get "$sf" bw_up 2>/dev/null | tr -d '":')
    srv_bw_down=$(node_get "$sf" bw_down 2>/dev/null | tr -d '":')
    if [[ -n "$srv_bw_up" && -n "$srv_bw_down" ]]; then
        bw_up_cl="${srv_bw_down% *}"    # server.down → client.up   (官方方向对偶)
        bw_dn_cl="${srv_bw_up% *}"      # server.up   → client.down
    else
        load_bw_env
        CLIENT_BW_UP="${CLIENT_BW_UP:-0}"; CLIENT_BW_DOWN="${CLIENT_BW_DOWN:-0}"
        if [[ "$CLIENT_BW_UP" != "0" && "$CLIENT_BW_UP" != "0.0" ]]; then bw_up_cl="$CLIENT_BW_UP"; else bw_up_cl=""; fi
        if [[ "$CLIENT_BW_DOWN" != "0" && "$CLIENT_BW_DOWN" != "0.0" ]]; then bw_dn_cl="$CLIENT_BW_DOWN"; else bw_dn_cl=""; fi
    fi
    if [[ -n "$bw_up_cl" && -n "$bw_dn_cl" ]]; then
        bw_lines_mihomo=$(printf '    up: "%s Mbps"\n    down: "%s Mbps"' "$bw_up_cl" "$bw_dn_cl")
    else
        bw_lines_mihomo=""
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
${bw_lines_mihomo}
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
    # 带宽: bw_up_cl/bw_dn_cl 已在上方解析 (server bw 存在→方向对偶; 否则取面板默认 CLIENT_BW_UP/DOWN)
    if [[ "$(node_get "$sf" bw_ign 2>/dev/null)" == "true" ]]; then
        print_info "该节点 ignoreClientBandwidth=true: 服务端忽略客户端带宽提示, 分享链接里 upmbps/downmbps 只是参考值"
    fi
    [[ -n "$bw_up_note" ]] && print_info "$bw_up_note"
    local link_bw=""
    [[ -n "$bw_up_cl" && -n "$bw_dn_cl" ]] && link_bw="&upmbps=$bw_up_cl&downmbps=$bw_dn_cl"
    link="${link}${link_bw}"
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
    # Chrome Parrot 兼容性: 证书密钥类型检查 (仅警告, 不自动改证书)
    local ktype; ktype=$(cert_key_type "$ncert")
    [[ "$ktype" == "ed25519" ]] && print_warning "证书为 Ed25519: 实测 v2.12.3 时开启 Chrome Parrot 会握手失败 (CRYPTO_ERROR 0x128); 关闭 Chrome Parrot 后可正常连接 — 请在客户端同步关闭 Chrome Parrot"
    nauth=$(openssl rand -base64 16)
    nport=$(generate_port "Hysteria")

    # 端口跳跃 / obfs / ECH (复用现有交互函数)
    HOP_RANGE=""
    ask_port_hopping || return 1
    OBFS_PASSWORD=""
    ask_obfs
    ECH_ENABLED=false; ECH_PUBLIC_NAME="$MASQ_DOMAIN"
    ask_ech

    # —— 拥塞控制 / bandwidth / chrome parrot (v2.8.0+ 语义, 内核实测 v2.12.3) ——
    echo ""
    ask_srv_congestion
    if [[ "$ECH_ENABLED" == "true" || "$SRV_CONGESTION" != "default" || -n "$SRV_BW_UP" ]]; then :; fi
    if [[ -n "$SRV_BW_UP" && "$SRV_CONGESTION" == "bbr" ]]; then
        print_info "注意: 服务端同时设置 bandwidth 与 congestion: BBR (bandwidth 将仅作为客户端提示对端协商参照, 服务端发送被 congestion 接管)"
    fi

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
$(printf "\n%s\n" "$(srv_cc_block
)")
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
    read -r runyn || runyn="n"
    local PRECHECK_FAILED=false
    if ! validate_node_cfg "$(node_file "$name")"; then
        PRECHECK_FAILED=true
        print_error "✗ 配置未通过预检, 已阻止启动 (上面列出的原因); 文件仍保留在 ${NODES_OUT_DIR}/"
    elif [[ "$(clean_input2 "${runyn:-n}")" =~ ^[Yy] ]]; then
        systemctl enable --now "hysteria-server@${name}.service" >/dev/null 2>&1
        sleep 2
        if systemctl is-active --quiet "hysteria-server@${name}.service"; then
            print_ok "节点 $name 已启动, 服务端口: $(node_get "$(node_file "$name")" listen)"
        else
            print_error "启动失败 —— 常见原因: 端口被占用 / 证书文件没权限。用『菜单9 服务端日志』看最后一行: journalctl -u hysteria-server@${name}.service -n 20"
        fi
    else
        print_info "暂不启动 (之后可在 多节点管理 3 里启动)"
    fi
    echo
    if [[ "${PRECHECK_FAILED:-false}" == "true" ]]; then
        print_info "修正问题后可在『多节点管理 3.节点 启停』里再次启动"
    else
        echo "  客户端配置: ${NODES_OUT_DIR}/${name}/client.yaml"
        echo "  分享链接  : ${NODES_OUT_DIR}/${name}/share.txt"
    fi
}
# (配置/链接路径在 validate 失败时已单独提示错误; 不静默覆盖)

node_list() {
    scan_nodes
    ((${#NODE_NAMES[@]} == 0)) && { print_warning "未发现节点 (请先执行 '1 服务端→1 安装' 或 '→2 多节点管理→2 新增节点')"; return; }
    local n uf st i=1 num
    echo "节点列表"
    echo "----------------------"
    for n in "${NODE_NAMES[@]}"; do
        uf=$(node_file "$n")
        if [[ "$n" == "default" ]]; then
            st=$(systemctl is-active hysteria-server.service 2>/dev/null || echo inactive)
        else
            st=$(systemctl is-active "hysteria-server@${n}.service" 2>/dev/null || echo inactive)
        fi
        num=$(printf "%02d" "$i")
        local ob="无"
        [[ -n "$(node_get "$uf" obfs_pw 2>/dev/null)" ]] && ob="Salamander"
        echo -e "  ${GREEN}${num})${PLAIN} $(printf '%-14s' "$n") ${BLUE}$(printf '%-27s' "$(node_get "$uf" listen 2>/dev/null)")${PLAIN} $( [[ $st == active ]] && echo -e "${GREEN}● 运行中${PLAIN}" || echo -e "${RED}○ 停止${PLAIN}" )  混淆: $(printf '%-10s' "$ob") 伪装: $(node_get "$uf" masq 2>/dev/null)"
        ((i++))
    done
}

node_pick() {
    scan_nodes
    ((${#NODE_NAMES[@]} == 0)) && { print_warning "无节点"; return 1; }
    local n c num
    echo "节点列表" >&2
    echo "----------------------" >&2
    local i=1 uf st ob
    for n in "${NODE_NAMES[@]}"; do
        uf=$(node_file "$n")
        if [[ "$n" == "default" ]]; then
            st=$(systemctl is-active hysteria-server.service 2>/dev/null || echo inactive)
        else
            st=$(systemctl is-active "hysteria-server@${n}.service" 2>/dev/null || echo inactive)
        fi
        num=$(printf "%02d" "$i")
        ob="无"; [[ -n "$(node_get "$uf" obfs_pw 2>/dev/null)" ]] && ob="Salamander"
        echo -e "  ${GREEN}${num})${PLAIN} $(printf '%-14s' "$n") ${BLUE}$(printf '%-24s' "$(node_get "$uf" listen 2>/dev/null)")${PLAIN} $( [[ $st == active ]] && echo -e "${GREEN}● 运行中${PLAIN}" || echo -e "${RED}○ 停止${PLAIN}" )  混淆: $ob" >&2
        ((i++))
    done
    printf "选择节点 (1-%d): " "${#NODE_NAMES[@]}" >&2
    if ! read -r c; then
        print_error "输入流被中断, 已安全退出"; exit 130
    fi
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=${#NODE_NAMES[@]} )); then
        echo "${NODE_NAMES[$((c-1))]}"
        return 0
    fi
    print_error "无效的选项"; return 1
}


# 查看某节点的客户端配置 + 分享链接 (单独节点视图)
node_show_client() {
    local n; n=$(node_pick) || { print_warning "无节点"; return; }
    ensure_node_dirs
    local d="${NODES_OUT_DIR}/${n}"
    if [[ -f "${d}/client.yaml" ]]; then
        echo "==================== 节点 $n 客户端配置 (client.yaml) ===================="
        cat "${d}/client.yaml"
    else
        print_warning "$n 尚未导出过; 先执行菜单 5 一键导出"
    fi
    if [[ -f "${d}/share.txt" ]]; then
        echo ""
        echo "分享链接:"
        cat "${d}/share.txt"
    fi
}

node_menu() {
    while true; do
        echo -e "
  ${GREEN}多节点管理${PLAIN} (默认节点 default 也算其中之一)
  ----------------------
  1. 列出节点 / 状态
  2. 新增节点
  3. 节点 启动/停止/重启/状态
  4. 删除节点
  5. 导出全部客户端配置
  6. 查看某节点的客户端配置 + 分享链接
  7. 修改节点配置
  0. 返回
  ----------------------"
        read -p "请输入选项 [0-7]: " nc || { echo "输入流已结束(EOF), 退出"; exit 130; }
        case "$nc" in
            0) return ;;
            1) node_list ;;
            2) node_add ;;
            6) node_show_client ;;
            7) server_edit_config ;;
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
                            print_error "✗ 启动被拦截, 原因见上方红字; 修好后重试"
                        fi;;
                    2) systemctl stop "${un}" && print_ok "已停止";;
                    3)
                        if validate_node_cfg "$uf"; then
                            systemctl restart "${un}" && print_ok "已重启"
                        else
                            print_error "✗ 重启被拦截, 原因见上方红字; 修好后重试"
                        fi;;
                    4) systemctl status "${un}" --no-pager | head -12 ;;
                    5) validate_node_cfg "$uf" && print_ok "配置验证通过" ;;
                esac ;;
            4)
                local n=$(node_pick) || continue
                [[ "$n" == "default" ]] && { print_error "默认节点请用主菜单 2 (卸载)"; continue; }
                printf "确认删除节点 %s? 输入大写 DEL 确认: " "$n"
                read -r dc || dc=""
                if [[ "$dc" == "DEL" ]]; then
                    mkdir -p /tmp/hy2-node-del-bak
                    tar -czf "/tmp/hy2-node-del-bak/node-${n}-$(date +%m%d%H%M).tar.gz" -C /etc/hysteria "${n}.yaml" 2>/dev/null && print_info "已把该节点配置备份到 /tmp/hy2-node-del-bak/ (防止误删后找不回)"
                    systemctl stop "hysteria-server@${n}.service" 2>/dev/null
                    systemctl disable "hysteria-server@${n}.service" 2>/dev/null
                    rm -f /etc/hysteria/${n}.yaml /etc/hysteria/hy2-${n}.yaml /etc/hysteria/server-${n}.crt /etc/hysteria/server-${n}.key /etc/hysteria/ech-${n}.pem
                    rm -rf "${NODES_OUT_DIR:?}/${n}"
                    systemctl daemon-reload 2>/dev/null
                    print_ok "节点 $n 已删除 (配置已备份到 /tmp/hy2-node-del-bak/)"
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
    sp="${sp:-0}"; ep="${ep:-0}"
    if [[ -n "$clean" ]]; then
        (( sp >= 1 && sp <= 65535 && ep >= 1 && ep <= 65535 && sp <= ep )) || { echo "listen 端口越界 (应为 1-65535 或 起点-终点): ${listen:0:60}"; errs=$((errs+1)); }
    fi

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
# 带宽 (服务端分享链接有值可直接用; 支持单方向 Brutal)
up = get("upmbps"); down = get("downmbps")
bw_lines = []
if up:
    bw_lines.append(f"  up: {up} mbps")
if down:
    bw_lines.append(f"  down: {down} mbps")
if bw_lines:
    lines.append("")
    lines.append("bandwidth:\n" + "\n".join(bw_lines))
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
    if [[ "$name" == "__illegal__" || -z "$name" ]]; then
        print_error "✗ 节点名称无效: 不能是 config / default / hysteria / server, 也不能为空"
        return 1
    fi
    local fp="${CLIENT_NODE_DIR}/${name}.yaml"
    if [[ ! -d "$fp" ]]; then :; fi
    case "${im:-1}" in
        1)
            printf "粘贴链接: "
            read -r uri
            [[ "$uri" == hysteria2://* || "$uri" == *hysteria2://* ]] || { print_error "✗ 不是 hysteria2 链接 —— 复制时可能丢了开头, 正确样例: hysteria2://密码@1.2.3.4:36712?insecure=1&sni=..."; return 1; }
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
            # —— 高级客户端流量设置 (bandwidth/congestion/Chrome Parrot), 空回车=保持链接默认 (parrot on) ——
            local atvb=""
            printf "进阶: 拥塞/带宽/ChromeParrot? (默认: 否, y/N): " >&2
            if ! read -r adv || [[ "$adv" == "" ]]; then adv=""; fi
            adv=$(clean_input2 "$adv")
            case "$adv" in y|Y)
                ask_cli_traffic || return 1
                echo "" >&2
                echo "  Chrome 握手伪装 (Chrome Parrot; 默认开, 让 QUIC 握手包看起来像 Google Chrome):" >&2
                echo "  1) 启用 (默认)  2) 停用" >&2
                printf "  选择 (默认1): " >&2
                read -r adv || adv=""
                case "$(clean_input2 "$adv")" in 2) CHROME_PARROT_ON=false;; *) CHROME_PARROT_ON=true;; esac
                atvb=$'\n'"$(cli_traffic_block)"
                ;;
            esac
            cat > "${CLIENT_NODE_DIR}/${name}.yaml" <<EOF
# [${name}] (来自 hysteria2 链接导入, "$(date +"%F %T")")
${gen}${atvb}
socks5:
  listen: ${s5:-127.0.0.1:10808}
http:
  listen: ${hp:-127.0.0.1:8080}
EOF
            if [[ -n "$atvb" ]]; then
                python3 - "${CLIENT_NODE_DIR}/${name}.yaml" <<'PYEOF'
import re,sys
path=sys.argv[1]
t=open(path).read()
import re
t=re.sub(r"\nbandwidth:\n(?:[ \t].*\n)+","",t,count=1) if t.count("bandwidth:")>1 else t
open(path,"w").write(t)
PYEOF
                sed -i "/^bandwidth:/{x;/./d;}" /dev/null 2>/dev/null
                python3 - "${CLIENT_NODE_DIR}/${name}.yaml" <<'PYEOF'
import re,sys
path=sys.argv[1]
t=open(path).read()
t=t.replace("\n\n\n","\n\n")
open(path,"w").write(t)
PYEOF
            fi
            print_ok "节点 $name 已导入 -> ${CLIENT_NODE_DIR}/${name}.yaml"
            # 若本机还没有"当前节点", 引导一步到位: 询问是否立刻切换到这个节点
            if [[ ! -f "${CLIENT_DIR}/current.yaml" ]]; then
                printf "本机还没有在用的节点, 是否把 %s 设为当前节点并重启客户端? (Y/n): " "$name"
                read -r sc || sc=""
                case "$(echo "${sc:-y}" | xargs | tr 'A-Z' 'a-z')" in
                    n|no) print_info "已保留; 之后请在『节点管理→3.切换当前节点』自行切换" ;;
                    *)
                        cp "${CLIENT_NODE_DIR}/${name}.yaml" "${CLIENT_DIR}/current.yaml"
                        systemctl restart hysteria-client.service
                        if systemctl is-active --quiet hysteria-client.service; then
                            print_ok "✓ 当前节点已设为 $name, 客户端已重启"
                        else
                            print_error "✗ 客户端重启失败; 请先在『5.诊断→1.健康检查』里看原因"
                        fi
                        ;;
                esac
            fi
            ;;
        2)
            read -p "yaml 文件路径: " yp
            [[ -f "$yp" ]] || { print_error "文件不存在: $yp"; return 1; }
            cp "$yp" "${CLIENT_NODE_DIR}/${name}.yaml"
            print_ok "节点 $name 已从文件导入";;
    esac
}

# ---- 当前节点 拥塞/带宽/Chrome Parrot 调整 (就地编辑 current.yaml 与对应 nodes/<名>.yaml) ----
cc_traffic_tune() {
    [[ -f "${CLIENT_DIR}/current.yaml" ]] || { print_error "尚未设置当前节点 (菜单 4)"; return 1; }
    echo "当前节点流量设置摘要:"
    grep -E "^\s*(bandwidth|  up:|  down:|congestion|  type:|  profile:|disableChromeParrot|quic:)" "${CLIENT_DIR}/current.yaml" 2>/dev/null | head -10
    local cur="${CLIENT_DIR}/current.yaml"
    local matched=""
    if [[ -f "$cur" ]]; then
        local ch y cf
        ch=$(md5sum "$cur" 2>/dev/null | awk '{print $1}')
        for cf in "${CLIENT_DIR}"/nodes/*.yaml; do
            [[ -f "$cf" ]] || break
            y=$(md5sum "$cf" 2>/dev/null | awk '{print $1}')
            [[ "$y" == "$ch" ]] && { NODE_MATCH="$cf"; break; }
            NODE_MATCH=""
        done
    fi
    ask_cli_traffic || return 1
    echo "" >&2
    echo "  Chrome 握手伪装 (Chrome Parrot; 默认开):" >&2
    echo "  1) 启用 (默认)  2) 停用" >&2
    printf "  选择 (默认1): " >&2
    read -r adj || adj=""
    case "$(clean_input2 "$adj")" in 2) CHROME_PARROT_ON=false;; *) CHROME_PARROT_ON=true;; esac
    # python 就地替换: 删除旧 bandwidth/congestion/quic 顶层块, 追加新块
    python3 - "${cur}" "$(cli_traffic_block)" <<'PYEOF'
import re,sys
path=sys.argv[1]; add=sys.argv[2] if len(sys.argv)>2 else ""
t=open(path).read()
# remove old top-level blocks
t=re.sub(r"\nbandwidth:\n(?:[ \t].*\n)+","",t)
t=re.sub(r"\ncongestion:\n(?:[ \t].*\n)+","",t)
t=re.sub(r"\nquic:\n(?:[ \t].*\n)+","",t)
t=t.rstrip("\n")
if add:
    if add.startswith("\n"): pass
    else: add="\n"+add
    t=t+add.replace("\n\n","\n",1)+"\n"
t=re.sub(r"\n{3,}","\n\n",t)
open(path,"w").write(t)
PYEOF
    # 同步 nodes/<名>.yaml (若 current 与某节点文件一致)
    if [[ -n "${NODE_MATCH:-}" ]]; then
        cp "$cur" "$NODE_MATCH"
        print_info "已同步到节点文件: $NODE_MATCH"
    fi
    print_ok "流量设置已写入 current.yaml (重启客户端后生效)"
}

client_node_pick() {
    ensure_client_dirs
    local y f c num
    local -a CL=()
    shopt -s nullglob
    CL=()
    for y in "${CLIENT_NODE_DIR}"/*.yaml; do
        CL+=("$(basename "$y" .yaml)")
    done
    shopt -u nullglob
    ((${#CL[@]} == 0)) && { print_warning "暂无节点, 请先导入 (菜单 3)"; return 1; }
    local i=1
    echo "节点列表" >&2
    echo "----------------------" >&2
    for f in "${CL[@]}"; do
        num=$(printf "%02d" "$i")
        local srv
        srv=$(awk '/^server:/{print $2; exit}' "${CLIENT_NODE_DIR}/${f}.yaml")
        echo -e "  ${GREEN}${num})${PLAIN} $(printf '%-16s' "$f") ${BLUE}${srv}${PLAIN}" >&2
        ((i++))
    done
    printf "选择节点 (1-%d): " "${#CL[@]}" >&2
    if ! read -r c; then
        print_error "输入流被中断, 已安全退出"; exit 130
    fi
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=${#CL[@]} )); then
        echo "${CL[$((c-1))]}"
        return 0
    fi
    print_error "无效的选项"; return 1
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

# 客户端节点列表 (nodes/*.yaml)
client_node_list() {
    ensure_client_dirs
    local i=1 f name num
    echo "节点列表"
    echo "----------------------"
    local has=0
    for f in "${CLIENT_NODE_DIR}"/*.yaml; do
        [[ -f "$f" ]] || { echo "  (空 — 还没有任何节点)"; return; }
        name="${f##*/}"; name="${name%.yaml}"
        num=$(printf "%02d" "$i")
        local srv bwup bwdn obfs sni
        srv=$(awk '/^server:/{print $2; exit}' "$f")
        bwup=$(awk '/^bandwidth:/{f=1;next} f&&/^  up:/{print $2; exit}' "$f")
        bwdn=$(awk '/^bandwidth:/{f=1;next} f&&/^  down:/{print $2; exit}' "$f")
        obfs=$(awk '/^obfs:/{f=1;next} f&&/^  type:/{print $2; exit}' "$f")
        sni=$(awk '/^tls:/{f=1;next} f&&/^  sni:/{print $2; exit}' "$f")
        local obs="无"
        [[ "$obfs" == "salamander" ]] && obs="Salamander"
        printf "  ${GREEN}%s${PLAIN}) %-16s ${BLUE}%-26s${PLAIN} 上/下: ${YELLOW}%-9s${PLAIN} 混淆: ${CYAN}%-9s${PLAIN} 伪装: %s\n" \
            "$num" "$name" "${srv:-?}" "${bwup:-自动}/${bwdn:-自动}" "$obs" "${sni:-?}"
        has=1; ((i++))
    done
    [[ -f "${CLIENT_DIR}/current.yaml" ]] && {
        local cur
        cur=$(awk '/^server:/{print $2; exit}' "${CLIENT_DIR}/current.yaml")
        echo "  当前节点出口 : ${cur:-?}"
    }
}

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
    while true; do        # 当前节点名称: 与 nodes/*.yaml 内容比对得出 (basename current.yaml 恒为字面量, 无信息量)
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
  t. 当前节点 拥塞/带宽/Chrome Parrot 调整 (v2.12.3)
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
            t|T) cc_traffic_tune ;;
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
    if [[ -x "$CLIENT_BIN" ]]; then
        echo "  内核路径 : $CLIENT_BIN"
        local kv; kv=$("$CLIENT_BIN" version 2>/dev/null | grep -a "^Version" | head -1 | tr -d "\t")
        echo "  内核版本 : ${kv#Version:}"
    else
        print_warning "客户端内核未安装 (请使用 1.安装 / 更新内核)"
    fi
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
    echo -e "${RED}!!  危险: 即将彻底卸载 Hysteria 2 并删除
!!  会删除: /etc/hysteria (所有自签证书/节点配置) 和程序本体
!!  不会删除: 你自己的 nginx / CF Origin CA 等外部证书 (只引用过路径)${PLAIN}"
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${PLAIN}"
    printf "确认要继续? (y/N): "
    local confirm
    read -r confirm
    confirm=$(echo "$confirm" | xargs | tr '[:upper:]' '[:lower:]')
    confirm="${confirm:-n}"
    case "$confirm" in
        y|yes) : ;;
        *) print_warning "已取消 (未删除任何东西)"; return 1 ;;
    esac
    mkdir -p /tmp/hysteria-uninstall-bak
    tar -czf /tmp/hysteria-uninstall-bak/hysteria-$(date +%m%d%H%M).tar.gz /etc/hysteria "$INSTALL_DIR" 2>/dev/null
    print_info "卸载前已自动备份到 /tmp/hysteria-uninstall-bak/"
    print_info "开始卸载 Hysteria 2..."
    print_info "正在停止所有 hysteria-server@* 节点实例..."
    local un
    while IFS= read -r un; do
        [[ -n "$un" ]] || continue
        systemctl stop "$un" 2>/dev/null
        systemctl disable "$un" 2>/dev/null
        print_info "  已停止并禁用: $un"
    done < <(systemctl list-units "hysteria-server@*" --type=service --all --no-legend 2>/dev/null | awk '{print $1}')
    systemctl stop hysteria-server.service 2>/dev/null
    systemctl disable hysteria-server.service 2>/dev/null
    systemctl stop hysteria-client.service 2>/dev/null
    systemctl disable hysteria-client.service 2>/dev/null
    systemctl stop $RELAY_SERVICE 2>/dev/null
    systemctl disable $RELAY_SERVICE 2>/dev/null
    rm -f /etc/systemd/system/$RELAY_SERVICE
    systemctl daemon-reload
    rm -rf /etc/hysteria
    # 避免面板脚本自杀导致 VPS 断连后无法恢复: 保留自己与节点导出目录
    rm -rf "${INSTALL_DIR:?}/nodes" "${INSTALL_DIR:?}/out"
    rm -f /etc/systemd/system/${RELAY_SERVICE}.service 2>/dev/null
    systemctl daemon-reload
    print_info "Hysteria 2 服务已卸载完成 (面板脚本与卸载备份保留在原处; /tmp/hysteria-uninstall-bak/ 可用于恢复)"
}

# 更新 Hysteria 2
update_hysteria() {
    print_info "开始更新 Hysteria 2 内核..."
    if ! bash <(curl -fsSL --max-time 120 https://get.hy2.sh/); then
        print_error "内核下载/安装失败 (网络问题?) —— 现有服务未动, 稍后再试"
        return 1
    fi
    print_info "内核已更新, 正在重启所有节点实例..."
    local un
    while IFS= read -r un; do
        [[ -n "$un" ]] || continue
        systemctl restart "$un" 2>/dev/null
        print_info "  已重启: $un"
    done < <(systemctl list-units "hysteria-server@*" --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -a "^hysteria-")
    systemctl restart hysteria-client.service 2>/dev/null
    systemctl restart hysteria-server.service && print_info "  已重启: hysteria-server.service (default)"
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
    echo ""
    echo "  1) 从本机服务端节点导入 (自动填 地址+认证+SNI)"
    echo "  2) 手动输入"
    read -p "选择 (默认1): " rs_mode || rs_mode="1"
    if [[ "${rs_mode:-1}" == "1" ]]; then
        local rn; rn=$(node_pick) || { print_warning "无节点"; return; }
        local rnf="/etc/hysteria/${rn}.yaml"
        [[ "$rn" == "default" ]] && rnf="/etc/hysteria/config.yaml"
        new_addr="127.0.0.1:$(node_get "$rnf" listen 2>/dev/null | head -n1 | sed 's/^[^0-9]*//;s/-.*$//' | tr -d '\"')"
        new_auth=$(node_get "$rnf" auth 2>/dev/null | head -n1 | tr -d '\"')
        new_sni=$(node_get "$rnf" masq 2>/dev/null | head -n1 | tr -d '\"')
        printf "已就绪: 地址=%s 认证=%s SNI=%s (回车往下)\n" "$new_addr" "$new_auth" "$new_sni"
    else
    echo "(直接回车保持不变)"
    read -p "服务端地址 (IP:端口, 如 1.2.3.4:16680): " new_addr
    read -p "认证密码: " new_auth
    read -p "SNI 域名 (伪装域名, 可空): " new_sni
    new_addr=${new_addr:-$RS_ADDR}
    new_auth=${new_auth:-$RS_AUTH}
    new_sni=${new_sni:-$RS_SNI}
    fi
    if [ -z "$new_addr" ] || [ -z "$new_auth" ]; then
        print_error "地址和认证密码不能都为空"
        return
    fi
    cat > "$RELAY_SERVER_CONF" << EOF
RS_ADDR=$new_addr
RS_AUTH=$new_auth
RS_SNI=$new_sni
EOF
    print_info "中继服务端已保存: $RELAY_SERVER_CONF (目标节点: ${rn:-手动输入})"
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
    # 已运行 => restart 加载最新配置 (enable --now 只会 no-op, 之前漏管道恰恰因为这句)
    systemctl restart "$RELAY_SERVICE" 2>/dev/null || systemctl enable --now $RELAY_SERVICE >/dev/null 2>&1
    systemctl enable $RELAY_SERVICE >/dev/null 2>&1
    if systemctl is-active --quiet $RELAY_SERVICE; then
        print_info "中继客户端已运行 (已加载最新配置)"
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


# =========================================================
# v2.3 信息架构重构: 一级菜单 = 服务端 / 客户端 / 状态与诊断 / 系统与内核
# =========================================================
# 服务端
server_menu() {
    while true; do
        echo -e "
  ${GREEN}服务端${PLAIN} (这台机器开放的 HY2 入口)
  ----------------------
  ${GREEN}1.${PLAIN} 多节点管理  (列表 / 新增 / 启停 / 删除 / 导出 / 修改)
  ${GREEN}2.${PLAIN} 服务端日志
  ${GREEN}3.${PLAIN} 服务管理
  ${GREEN}4.${PLAIN} 查看客户端配置 (Clash / 分享链接)
  ${GREEN}5.${PLAIN} 分流管理 (ACL / 出站)
  ${GREEN}0.${PLAIN} 返回
  ----------------------
  (整机初始化 / 重装 默认节点 在 4.系统与内核 → 2)"
        read -p "请输入选项 [0-5]: " sm || { echo "输入被中断, 安全退出"; exit 130; }
        case "$sm" in
            0) return ;;
            1) node_menu ;;
            2) server_logs ;;
            3) server_ctl_menu ;;
            4) client_menu ;;
            5) shunt_menu ;;
            *) print_error "无效的选项" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

# 服务管理 (范围明示)
server_ctl_menu() {
    echo -e "
  ${GREEN}服务管理${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 默认节点 启动 / 停止 / 重启
  ${GREEN}2.${PLAIN} 指定节点 启动 / 停止 / 重启
  ${GREEN}3.${PLAIN} 重启全部节点
  ${GREEN}0.${PLAIN} 返回"
    read -p "请输入选项 [0-3]: " sm2 || { echo "输入被中断, 安全退出"; exit 130; }
    case "$sm2" in
        1)
            echo "  1) 启动  2) 停止  3) 重启"
            read -p "选择: " op2 || op2=""
            case "$op2" in
                1) systemctl start hysteria-server.service && print_ok "✓ 默认节点已启动" ;;
                2) systemctl stop hysteria-server.service && print_ok "✓ 默认节点已停止" ;;
                3) systemctl restart hysteria-server.service && print_ok "✓ 默认节点已重启" ;;
            esac ;;
        2)
            local sn; sn=$(node_pick) || { print_warning "无节点"; return; }
            local un="hysteria-server@${sn}.service"
            [[ "$sn" == "default" ]] && un="hysteria-server.service"
            echo "  1) 启动  2) 停止  3) 重启"
            read -p "选择: " op3 || op3=""
            case "$op3" in
                1) systemctl start "${un}" && print_ok "✓ ${sn} 已启动" ;;
                2) systemctl stop "${un}" && print_ok "✓ ${sn} 已停止" ;;
                3) systemctl restart "${un}" && print_ok "✓ ${sn} 已重启" ;;
            esac ;;
        3)
            local un
            while IFS= read -r un; do
                [[ "$un" =~ ^hysteria- ]] || continue
                systemctl restart "$un" 2>/dev/null && print_info "  已重启: $un"
            done < <(systemctl list-units "hysteria-server*" --type=service --no-legend 2>/dev/null | awk '{print $1}')
            print_ok "✓ 全部节点已重启" ;;
    esac
}

# 修改节点配置 → default 走 modify_config; 其它节点如实说明
server_edit_config() {
    local sn; sn=$(node_pick) || { print_warning "无节点"; return; }
    if [[ "$sn" == "default" ]]; then
        modify_config
    else
        print_warning "『修改配置』目前只支持默认节点 (default)。"
        print_info "节点 ${sn}: 可手工编辑 /etc/hysteria/${sn}.yaml, 然后在 1.服务端→2.多节点管理→3.节点→5 配置验证; 分享链接用 2→5 重新导出。"
    fi
}

# 状态与诊断
diag_menu() {
    while true; do
        echo -e "
  ${GREEN}状态与诊断${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 总状态
  ${GREEN}2.${PLAIN} 服务端状态 (节点列表)
  ${GREEN}3.${PLAIN} 客户端状态
  ${GREEN}4.${PLAIN} 网络健康检查
  ${GREEN}5.${PLAIN} 系统服务检查
  ${GREEN}0.${PLAIN} 返回
  ----------------------"
        read -p "请输入选项 [0-5]: " dm || { echo "输入被中断, 安全退出"; exit 130; }
        case "$dm" in
            0) return ;;
            1) show_status_overview ;;
            2) node_list ;;
            3) client_status ;;
            4)
                if command -v hysteria >/dev/null 2>&1; then client_health; else print_warning "本机未安装客户端内核, 无法做隧道健康检查"; fi ;;
            5)
                systemctl --failed --no-legend 2>/dev/null | head -10
                systemctl --failed --no-legend 2>/dev/null | wc -l | xargs -I{} echo "  失败的 systemd 服务数: {}" ;;
            *) print_error "无效的选项" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

# ========= 服务端分流 (ACL + Outbounds) =========
# 语义: 每个节点一份 server.yaml → 分流本来就是"按节点"的粒度
# 出站类型: direct / socks5 / http (官方协议; 无 HY2-native 出站, 想链 HY2 时用 socks5 接下游 HY2 client)
shunt_menu() {
    local sn; sn=$(node_pick) || { print_warning "无节点"; return; }
    SHUNT_NODE="$sn"
    local nf="/etc/hysteria/${sn}.yaml"
    [[ "$sn" == "default" ]] && nf="/etc/hysteria/config.yaml"
    while true; do
        echo -e "
  ${GREEN}分流管理${PLAIN} (节点: $sn)
  说明: 每个节点一份独立配置, 规则/出站只作用于这个节点; 修改需重启生效
  ----------------------
  ${GREEN}1.${PLAIN} 查看当前分流 (出站 + 规则)
  ${GREEN}2.${PLAIN} 添加 socks5 出站
  ${GREEN}3.${PLAIN} 添加 http 出站
  ${GREEN}4.${PLAIN} 添加分流规则
  ${GREEN}5.${PLAIN} 删除分流规则
  ${GREEN}6.${PLAIN} 清空此节点分流 (回到 direct 直连)
  ${GREEN}0.${PLAIN} 返回
  ----------------------"
        read -p "请输入选项 [0-6]: " so || { echo "输入被中断, 安全退出"; exit 130; }
        case "$so" in
            0) return ;;
            1) shunt_show "$nf" ;;
            2) shunt_add_outbound "$nf" socks5 ;;
            3) shunt_add_outbound "$nf" http ;;
            4) shunt_add_rule "$nf" ;;
            5) shunt_del_rule "$nf" ;;
            6) shunt_clear "$nf" "$sn" ;;
            *) print_error "无效的选项" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

shunt_show() {
    local nf="$1"
    python3 - "$nf" <<'PYEOF'
import sys
t=open(sys.argv[1]).read()
m=re.search(r"^outbounds:\n(?:[\t ].*\n)+", t, flags=re.M)
if not m:
    print("出站: 无显式定义 (默认 direct 直连)")
else:
    print("出站列表:")
    for ln in m.group(0).splitlines():
        s=ln.strip()
        if s.startswith(("name:","type:","addr:","url:","username:")):
            print("   ", s)
print()
m=re.search(r"^acl:\n(?:[\t ].*\n)+", t, flags=re.M)
if not m:
    print("规则: (无, 全部走默认出口=direct)")
else:
    i=0
    for ln in m.group(0).splitlines():
        s=ln.strip()
        if s.startswith("- "):
            i+=1
            print(f"  [{i}] {s[2:]}")
PYEOF
}

shunt_add_outbound() {
    # $1=yaml  $2=type(socks5/http)
    local nf="$1" typ="$2" name addr usr pwd url
    if [[ "$typ" == "socks5" ]]; then
        print_info "预设 socks01: 127.0.0.1:33934 用户 DfD42wmG (直接回车即用此预设)"
    fi
    printf "出口名称: "
    read -r name || return 130
    name=$(echo "$name" | xargs)
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { print_error "名称只能用字母数字_-"; return; }
    if [[ "$typ" == "socks5" ]]; then
        printf "SOCKS 服务地址 (回车=默认 127.0.0.1:33934): "
        read -r addr || return 130
        addr=$(echo "${addr:-127.0.0.1:33934}" | xargs)
        printf "用户名: "
        read -r usr || return 130
        printf "密码: "
        read -r pwd || return 130
    else
        printf "HTTP 代理 URL (例: http://user:pass@1.2.3.4:8080): "
        read -r url || return 130
        url=$(echo "$url" | xargs)
    fi
    python3 - "$nf" "$name" "$typ" "$addr" "$usr" "$pwd" "$url" <<'PYEOF'
import re, sys
p,name,typ = sys.argv[1:4]
addr,usr,pwd,url = sys.argv[4:8]
t=open(p).read()
lines=[]
lines.append(f"  - name: {name}")
lines.append(f"    type: {typ}")
lines.append(f"    {typ}:")
if typ=="socks5":
    lines.append(f"      addr: {addr}")
    if usr: lines.append(f"      username: {usr}")
    if pwd: lines.append(f"      password: {pwd}")
else:
    lines.append(f"      url: {url}")
block="\n".join(lines)+"\n"
m=re.search(r"^outbounds:\n(?:[\t ].*\n)+", t, flags=re.M)
if m:
    t=t[:m.end()] + block + t[m.end():]
else:
    t=t.rstrip()+"\n\noutbounds:\n"+block
open(p,"w").write(t)
PYEOF
    print_ok "✓ 已写入出站 $name ($typ)"
    print_info "⚠ 没有分流到该出口的请求统一走第一个 outbounds 列表项作为默认;"
    print_info "  若只想分流部分站点而剩余直连, 请在规则里加一行 direct(all) 且放在其它规则之后"
    shunt_apply "$nf"
}

shunt_add_rule() {
    local nf="$1" rule sr1
    echo "  1) reject(geoip:cn)        拒绝中国 IP"
    echo "  2) direct(geoip:cn)        中国 IP 直连"
    echo "  3) 自由填写 (例: socks01(suffix:example.com))"
    read -p "选择: " sr1 || return 130
    case "$sr1" in
        1) rule='reject(geoip:cn)' ;;
        2) rule='direct(geoip:cn)' ;;
        3) read -r -p "规则: " rule || return 130 ;;
        *) print_error "无效"; return ;;
    esac
    rule=$(echo "$rule" | xargs)
    sane=$(printf "%s" "$rule" | tr -d '()?:/' )
    python3 -c "import re,sys; sys.exit(0 if re.fullmatch(r'[A-Za-z0-9_-]+\\([^)]*\\)', '$rule') else 1)" || { print_error "规则格式不对, 应形如 出口(地址)"; return; }
    python3 - "$nf" "$rule" <<'PYEOF'
import re, sys
p, rule = sys.argv[1:3]
t=open(p).read()
m=re.search(r"^(acl:\n(?:(?!  inline:).*\n)*  inline:\n)((?:[\t ]+.*\n)*)", t, flags=re.M|re.S)
if m:
    t=t[:m.end(2)] + f"    - {rule}\n" + t[m.end(2):]
else:
    t=t.rstrip()+"\n\nacl:\n  inline:\n"+f"    - {rule}\n"
open(p,"w").write(t)
PYEOF
    shunt_apply "$nf"
}

shunt_del_rule() {
    local nf="$1" dn
    read -p "要删除的规则编号: " dn || return 130
    [[ "$dn" =~ ^[0-9]+$ ]] || { print_error "编号必须是数字"; return; }
    python3 - "$nf" "$dn" <<'PYEOF'
import re, sys
p, n = sys.argv[1:3]
n=int(n)
t=open(p).read()
m=re.search(r"^acl:\n(?:[\t ].*\n)+", t, flags=re.M)
rows=m.group(0).splitlines(keepends=True)
i=0; kept=[]
for ln in rows:
    if ln.lstrip().startswith("- "):
        i+=1
        if i==n: continue
    kept.append(ln)
t=t.replace(m.group(0), "".join(kept))
open(p,"w").write(t)
PYEOF
    shunt_apply "$nf"
}

shunt_apply() {
    local nf="$1" sn="${2:-$SHUNT_NODE}"
    local un="hysteria-server@${sn}.service"; [[ "$sn" == "default" ]] && un="hysteria-server.service"
    if validate_node_cfg "$nf"; then
        systemctl restart "$un" && print_ok "✓ 已重启, 分流生效 (节点 $sn)"
    else
        print_error "✗ 配置验证失败, 未重启"
    fi
}

shunt_clear() {
    local nf="$1" sn="$2"
    python3 - "$nf" <<'PYEOF'
import re, sys
p=sys.argv[1]
t=open(p).read()
t=re.sub(r"^acl:\n(?:[\t ].*\n)+","",t,flags=re.M)
t=re.sub(r"^outbounds:\n(?:[\t ].*\n)+","",t,flags=re.M)
t=re.sub(r"\n\n\n","\n\n",t)
open(p,"w").write(t.rstrip()+"\n")
PYEOF
    print_ok "✓ 已将节点 $sn 回到纯 direct 直连 (删了 acl + outbounds)"
    shunt_apply "$nf"
}

# (sys_kernel_menu 在此之下)

sys_kernel_version() {
    if command -v hysteria >/dev/null 2>&1; then
        echo "  内核路径 : $(command -v hysteria)"
        local kv; kv=$(hysteria version 2>/dev/null | grep -a "^Version" | head -1 | tr -d "\t")
        echo "  内核版本 : ${kv#Version:}  (主机底层)"
    else
        print_warning "未安装内核; 可在 3.整机初始化 安装"
    fi
}

sys_kernel_menu() {
    echo -e "
  ${GREEN}系统与内核${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 内核安装 / 升级 (同时会重启全部节点)
  ${GREEN}2.${PLAIN} 核查内核版本
  ${GREEN}3.${PLAIN} 整机初始化 / 重装 (装内核 + 默认节点, 覆盖式)
  ${GREEN}4.${PLAIN} 卸载全部 (危险)
  ${GREEN}0.${PLAIN} 返回
  (客户端内核在 2.客户端 → 7.内核管理)"
    read -p "请输入选项 [0-4]: " km || { echo "输入被中断, 安全退出"; exit 130; }
    case "$km" in
        1) update_hysteria ;;
        2) sys_kernel_version ;;
        3) install_hysteria ;;
        4) uninstall_hysteria ;;
    esac
}

# 客户端 (统一功能中心)
client_dashboard() {
    while true; do
        load_bw_env
        local cct="● 未运行"
        systemctl is-active --quiet hysteria-client.service 2>/dev/null && cct="${GREEN}● 运行中${PLAIN}"
        echo -e "
  ${GREEN}客户端${PLAIN} (本机作为 HY2 客户端)
  ----------------------
  状态: ${cct}
  ----------------------
  ${GREEN}1.${PLAIN} 节点管理
  ${GREEN}2.${PLAIN} 当前节点设置
  ${GREEN}3.${PLAIN} 代理设置
  ${GREEN}4.${PLAIN} 客户端服务
  ${GREEN}5.${PLAIN} 诊断
  ${GREEN}6.${PLAIN} 日志
  ${GREEN}7.${PLAIN} 内核管理
  ${GREEN}8.${PLAIN} 带宽默认值
  ${GREEN}9.${PLAIN} 中继管理
  ${GREEN}0.${PLAIN} 返回
  ----------------------"
        read -p "请输入选项 [0-9]: " cd || { echo "输入被中断, 安全退出"; exit 130; }
        case "$cd" in
            0) return ;;
            1) cli_node_menu ;;
            2) cli_node_settings ;;
            3) client_ports_edit ;;
            4) client_ctl_menu ;;
            5) cli_diag_menu ;;
            6) client_do_logs ;;
            7) cli_kernel_menu ;;
            8) bw_menu ;;
            9) relay_menu ;;
            *) print_error "无效的选项" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

# 客户端 节点管理
cli_node_menu() {
    while true; do
        echo -e "
  ${GREEN}节点管理 (客户端)${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 添加 / 导入节点
  ${GREEN}2.${PLAIN} 节点列表
  ${GREEN}3.${PLAIN} 切换当前节点
  ${GREEN}4.${PLAIN} 当前节点信息
  ${GREEN}5.${PLAIN} 删除节点
  ${GREEN}0.${PLAIN} 返回
  ----------------------"
        read -p "请输入选项 [0-5]: " cn1 || { echo "输入被中断, 安全退出"; exit 130; }
        case "$cn1" in
            0) return ;;
            1) client_node_import_menu ;;
            2) client_node_list ;;
            3) client_node_switch ;;
            4) client_show_current ;;
            5) client_node_delete ;;
            *) print_error "无效的选项" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

# 客户端 当前节点设置 (正式入口, 替代隐藏的 t)
cli_node_settings() {
    while true; do
        load_bw_env
        local cur="${CLIENT_DIR}/current.yaml"
        if [[ ! -f "$cur" ]]; then
            print_warning "还没有导入任何节点。请先在『1. 节点管理』里添加节点。"
            return
        fi
        local b d cg parrot
        bwval() { awk -v k="$2" '/^bandwidth:/{f=1} f&&/^  '"$2"':/{ if ($3=="") print $2; else print $2" "$3; exit }' "$1" 2>/dev/null; }
        b=$(bwval "$cur" up)
        d=$(bwval "$cur" down)
        cg=$(awk '/^congestion:/{f=1;next} f&&/^  type:/{print $2; exit}' "$cur" 2>/dev/null)
        [[ -z "$cg" ]] && cg="未设置 (自动)"
        if grep -q "disableChromeParrot: true" "$cur" 2>/dev/null; then
            parrot="已停用"
        else
            parrot="已启用 (默认)"
        fi
        echo -e "
  ${GREEN}当前节点设置${PLAIN}
  ----------------------
  上传带宽: ${b:-未设置 (自动)}
  下载带宽: ${d:-未设置 (自动)}
  拥塞控制: ${cg}
  Chrome Parrot 握手伪装: ${parrot}
  ----------------------
  ${GREEN}1.${PLAIN} 拥塞控制 / 带宽设置
  ${GREEN}2.${PLAIN} Chrome Parrot
  ${GREEN}0.${PLAIN} 返回
  ----------------------
  说明: 修改后需要重启客户端服务才能生效。"
        read -p "请输入选项 [0-2]: " cv || { echo "输入被中断, 安全退出"; exit 130; }
        case "$cv" in
            0) return ;;
            1) cc_traffic_tune ;;
            2) cli_parrot_toggle ;;
            *) print_error "无效的选项" ;;
        esac
        echo && read -p "按回车键继续..." && echo
    done
}

# 客户端 诊断
cli_diag_menu() {
    echo -e "
  ${GREEN}诊断${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 健康检查 (进程 / 监听 / HTTPS / UDP / IPv4 / IPv6)
  ${GREEN}2.${PLAIN} 测试拨号
  ${GREEN}3.${PLAIN} 总状态页
  ${GREEN}0.${PLAIN} 返回"
    read -p "请输入选项 [0-3]: " cdm || { echo "输入被中断, 安全退出"; exit 130; }
    case "$cdm" in
        1) client_health ;;
        2) client_do_proxy_probe ;;
        3) show_status_overview ;;
    esac
}

# 客户端 内核管理
cli_kernel_menu() {
    echo -e "
  ${GREEN}内核管理 (客户端)${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 安装 / 更新内核
  ${GREEN}2.${PLAIN} 查看版本
  ${GREEN}0.${PLAIN} 返回"
    read -p "请输入选项 [0-2]: " ckm || { echo "输入被中断, 安全退出"; exit 130; }
    case "$ckm" in
        1) client_kernel_install ;;
        2) client_kernel_version ;;
    esac
}

# Chrome Parrot 单项开关 (当前节点)
cli_parrot_toggle() {
    local cur="${CLIENT_DIR}/current.yaml"
    [[ -f "$cur" ]] || { print_warning "还没有任何节点"; return; }
    echo "  1) 启用 (握手伪装成 Chrome, 默认)"
    echo "  2) 停用 (QUIC 使用标准客户端指纹)"
    printf "选择 (默认1): "
    local sel; read -r sel || sel=""
    sel=$(echo "${sel:-1}" | xargs)
    python3 - "$cur" "$sel" <<'PYEOF'
import re,sys
p,sel=sys.argv[1],sys.argv[2]
t=open(p).read()
t=re.sub(r"^quic:\n(?:[ \t].*\n)+","",t,flags=re.M)
t=re.sub(r"\n\n\n","\n\n",t)
val = "false" if sel=="2" else "true"
t=t.rstrip()+"\n\nquic:\n  disableChromeParrot: "+val+"\n"
open(p,"w").write(t)
PYEOF
    if [[ "$sel" == "2" ]]; then
        print_ok "✓ Chrome Parrot 已停用 (写入 current.yaml)"
    else
        print_ok "✓ Chrome Parrot 已恢复启用 (默认)"
    fi
    print_info "重启客户端 (客户端→4.客户端服务) 后生效"
}

# 客户端 节点删除
client_node_delete() {
    local n; n=$(client_node_pick) || { print_warning "没有可删除的节点"; return; }
    printf "删除已导入的客户端节点 %s? 输入 DEL 确认: " "$n"
    local dc; read -r dc || dc=""
    if [[ "$dc" != "DEL" ]]; then print_info "已取消"; return; fi
    rm -f "${CLIENT_NODE_DIR}/${n}.yaml"
    print_ok "✓ 已删除 ${n}.yaml (如它正是当前使用的节点, 请重新导入或切换其它节点)"
}

# (旧 client_menu 保留: 服务端→6 复用)


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
    local sst="● 停止" cct="● 未启动"
    systemctl is-active --quiet hysteria-server.service 2>/dev/null && sst="${GREEN}● 运行中${PLAIN}" || sst="${RED}● 停止${PLAIN}"
    systemctl is-active --quiet hysteria-client.service 2>/dev/null && cct="${GREEN}● 运行中${PLAIN}" || cct="${RED}● 未启动${PLAIN}"
    # 服务端节点特性
    scan_nodes quiet 2>/dev/null
    echo -e "${GREEN}══════════ HY2 总状态 ══════════${PLAIN}"
    echo -e "  ${BLUE}[服务端]${PLAIN} (本机开放的入口) $sst"
    if (( ${#NODE_NAMES[@]} > 0 )); then
        for n in "${NODE_NAMES[@]}"; do
            local st="● 停止"
            if [[ "$n" == "default" ]]; then
                systemctl is-active --quiet hysteria-server.service 2>/dev/null && st="${GREEN}● 运行中${PLAIN}"
            else
                systemctl is-active --quiet "hysteria-server@$n.service" 2>/dev/null && st="${GREEN}● 运行中${PLAIN}"
            fi
            local uf; uf=$(node_file "$n")
            local lsn ob ex
            lsn=$(node_get "$uf" listen | tr -d '"')
            [[ -n "$(node_get "$uf" obfs_pw)" ]] && ob="Salamander" || ob="无"
            grep -q '^ech:' "$uf" 2>/dev/null && ex="${GREEN}ECH开${PLAIN}" || ex="ECH关"
            echo -e "   $st $(printf '%-12s' "$n") 端口 $(printf '%-12s' "$lsn") 伪装: $(printf '%-16s' "$(node_get "$uf" masq 2>/dev/null)") 混淆: $(printf '%-3s' "$ob") $ex"
        done
    fi
    echo
    echo -e "  ${BLUE}[客户端]${PLAIN} (本机出网隧道) $cct"
    local cn="(未导入)" y cf ch found=""
    if [[ -f "$CLIENT_DIR/current.yaml" ]]; then
        ch=$(md5sum "$CLIENT_DIR/current.yaml" 2>/dev/null | awk '{print $1}')
        cn="(手动编辑/未匹配)"
        for cf in "${CLIENT_DIR}"/nodes/*.yaml; do
            [[ -f "$cf" ]] || break
            y=$(md5sum "$cf" 2>/dev/null | awk '{print $1}')
            if [[ "$y" == "$ch" ]]; then cn="${cf##*/}"; cn="${cn%.yaml}"; found=1; break; fi
        done
    fi
    # 客户端 → 服务端入口映射 (读 current.yaml 的 server)
    local csr sym=""; csr=$(awk '/^server:/{print $2; exit}' "$CLIENT_DIR/current.yaml" 2>/dev/null)
    local sp hm
    sp=$(awk '/^socks5:/{f=1} f&&/^  listen:/{print $2; exit}' "$CLIENT_DIR/current.yaml" 2>/dev/null)
    hp=$(awk '/^http:/{f=1} f&&/^  listen:/{print $2; exit}' "$CLIENT_DIR/current.yaml" 2>/dev/null)
    echo -e "  当前节点 : $cn"
    if [[ -n "$csr" ]]; then
        sym=""
        for n in "${NODE_NAMES[@]:-}"; do
            [[ -z "$n" ]] && continue
            local nls=$(node_get "$(node_file "$n")" listen 2>/dev/null | tr -d '"' | sed 's/^[^0-9]*//; s/-.*//')
            [[ -n "$nls" && "$csr" == *":$nls" ]] && { sym="$n"; break; }
        done
        if [[ -n "$sym" ]]; then
            echo -e "  ${GREEN}→ 出网入口 $csr = 本机服务端节点 '$sym'${PLAIN}"
        elif ((${#NODE_NAMES[@]:-0} > 0)); then
            echo -e "  ${GREEN}→ 出网入口 $csr (来自第三方服务器, 不在本机节点表里)${PLAIN}"
        else
            echo -e "  ${GREEN}→ 出网入口 $csr (这是一台纯客户端机器)${PLAIN}"
        fi
    fi
    echo -e "  HY2 版本  : ${hyv}"
    [[ -n "$sp" ]] && echo -e "  SOCKS5           : $sp"
    [[ -n "$hp" ]] && echo -e "  HTTP Proxy       : $hp"
    echo
    # 真实出站探测 (Quick 数秒, 不拖慢菜单)
    if [[ -n "$sp" ]]; then
        local s5="socks5h://${sp}" eip4 eip6
        printf "  IPv4 (隧道 v4)   : 检测中"
        eip4=$(curl -4 -sx "$s5" --max-time 10 https://api.ipify.org 2>/dev/null)
        [[ -n "$eip4" ]] && printf "\r  IPv4 隧道   : ${GREEN}✓ 通了${PLAIN} (出口 $eip4)\n" || printf "\r  IPv4 隧道   : ${RED}✗ 不通${PLAIN} (看看节点是否被墙/账号对不对)\n"
        printf "  IPv6 (隧道 v6)   : 检测中"
        eip6=$(curl -sx "$s5" --max-time 10 https://api6.ipify.org 2>/dev/null)
        [[ -n "$eip6" && "$eip6" == *:* ]] && printf "\r  IPv6 隧道   : ${GREEN}✓ 通了${PLAIN} (出口 $eip6)\n" || printf "\r  IPv6 隧道   : ${RED}✗ 不通${PLAIN} (本机没有 IPv6 可忽略)\n"
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
        [[ "$udpcs" == "PASS" ]] && printf "\r  UDP 通道    : ${GREEN}✓ 通了${PLAIN}\n" || printf "\r  UDP 通道    : ${RED}✗ 不通${PLAIN}\n"
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
    hysteria_server_status=$(systemctl is-active hysteria-server.service 2>/dev/null)
    hysteria_server_status_text=$(if [[ "$hysteria_server_status" == "active" ]]; then echo -e "${GREEN}● 运行中${PLAIN}"; else echo -e "${RED}● 未运行${PLAIN}"; fi)
    local cct="● 未运行"
    systemctl is-active --quiet hysteria-client.service 2>/dev/null && cct="${GREEN}● 运行中${PLAIN}"

    # 显示菜单
    echo -e "
  ${GREEN}Hysteria 2 管理面板${PLAIN}
  ============================
  ${GREEN}1.${PLAIN} 服务端        (多节点 / 分流 / 日志)
  ${GREEN}2.${PLAIN} 客户端        (节点 / 当前节点设置 / 中继)
  ${GREEN}3.${PLAIN} 状态与诊断
  ${GREEN}4.${PLAIN} 系统与内核    (内核更新 / 整机初始化)
  ${GREEN}0.${PLAIN} 退出
  ----------------------
  服务端状态: ${hysteria_server_status_text}
  本机客户端状态: ${cct}
  ----------------------
  (快捷兼容: s=总状态c=客户端面板 b=带宽默认值)"
    read -p "请输入选项 [1-4 / 0]: " choice || { clear;echo;echo "输入流被中断, 已安全退出"; exit 130; }
    case "$choice" in
        0) clear;exit 0 ;;
        1) server_menu ;;
        2) client_dashboard ;;
        3) diag_menu ;;
        4) sys_kernel_menu ;;
        s|S) show_status_overview ;;
        c|C) client_dashboard ;;
        b|B) bw_menu ;;
        *) echo -e "${RED}无效的选项 ${choice}${PLAIN}" ;;
    esac

    echo && read -p "按回车键继续..." && echo
}

# 主程序
main() {
    # 并发保护: 同一时刻只允许一个面板
    local lockf="${HY2_PANEL_LOCK:-/tmp/hy2-panel.lock}"
    exec 9>"$lockf"
    if ! flock -n 9 2>/dev/null; then
        echo "另一个 hy2 管理面板正在运行 ($lockf), 请先关闭它再操作。"; exit 1
    fi
    load_bw_env
    show_banner
    create_shortcut
    while true; do
        show_menu
    done
}

main "$@"
