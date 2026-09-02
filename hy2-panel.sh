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
    echo -e "${GREEN}Version: ${PLAIN}1.1.0"
    echo -e "----------------------------------------"
}

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

print_error() {
    echo -e "${RED}[Error]${PLAIN} $1"
}

print_warning() {
    echo -e "${YELLOW}[Warning]${PLAIN} $1"
}


# 生成端口的函数
generate_port() {
    local protocol="$1"
    while :; do
        port=$((RANDOM % 10001 + 10000))
        read -p "请为 ${protocol} 输入监听端口(默认为随机生成): " user_input
        port=${user_input:-$port}
        ss -tuln | grep -q ":$port\b" || { echo "$port"; return $port; }
        echo "端口 $port 被占用，请输入其他端口"
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

# 生成自签证书 (CN 与伪装域名一致)
gen_selfsigned_cert() {
    local domain="$1"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=${domain}" -days 36500 && \
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
    mkdir -p "$INSTALL_DIR"

    # 安装依赖
    bash <(curl -fsSL https://get.hy2.sh/)

    # 选择伪装域名
    select_masq_domain

    # 生成自签证书 (CN = 伪装域名)
    gen_selfsigned_cert "$MASQ_DOMAIN"

    # 生成随机密码
    AUTH_PASSWORD=$(openssl rand -base64 16)

    # 提示输入监听端口号
    PORT=$(generate_port "Hysteria")

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

    # 创建服务端配置
    create_server_config

    # 创建客户端配置
    create_client_config

    # 启动服务
    systemctl enable --now hysteria-server.service

    print_info "Hysteria 2 安装完成！"
    print_info "服务器地址：${PUBLIC_IP}"
    print_info "端口：${PORT}"
    print_info "密码：${AUTH_PASSWORD}"
    print_info "伪装域名：${MASQ_DOMAIN}"
    print_info "配置文件已保存到：${INSTALL_DIR}/config.yaml"
}

# 创建服务端配置
create_server_config() {
   cat << EOF > /etc/hysteria/config.yaml
listen: ":$PORT"

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $AUTH_PASSWORD
  
masquerade:
  type: proxy
  proxy:
    url: https://${MASQ_DOMAIN}
    rewriteHost: true
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
    
    cat << EOF > "$INSTALL_DIR/config.yaml"

  - name: Hy2-Hysteria2
    server: $PUBLIC_IP
    port: $PORT
    type: hysteria2
    up: "45 Mbps"
    down: "150 Mbps"
    sni: $MASQ_DOMAIN
    password: $AUTH_PASSWORD
    skip-cert-verify: true
    alpn:
      - h3

      
**********************************************************************************************************************
   hysteria2://$AUTH_PASSWORD@$PUBLIC_IP:$PORT?sni=${MASQ_DOMAIN}&alpn=h3&insecure=1#HY2

EOF
}

# 卸载 Hysteria 2
uninstall_hysteria() {
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
        read -p "请输入选项 [0-8]: " rc
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
  ${GREEN}客户端管理${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 查看客户端配置 (Clash 格式 + 分享链接)
  ${GREEN}2.${PLAIN} 中继端口映射 (TCP/UDP Forwarding)
  ${GREEN}0.${PLAIN} 返回
  ----------------------"
        read -p "请输入选项 [0-2]: " cc
        case "$cc" in
            0) return ;;
            1) view_client_config ;;
            2) relay_menu ;;
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

    # 修改服务端密码
    if sed -i "s|^ *password: .*|  password: ${new_password}|" /etc/hysteria/config.yaml; then
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


# 主菜单
show_menu() {
    # 获取服务状态
    hysteria_server_status=$(systemctl is-active hysteria-server.service)
    hysteria_server_status_text=$(if [[ "$hysteria_server_status" == "active" ]]; then echo -e "${GREEN}启动${PLAIN}"; else echo -e "${RED}未启动${PLAIN}"; fi)
    
    # 显示菜单
    echo -e "
  ${GREEN}Hysteria 2 管理脚本${PLAIN}
  ----------------------
  ${GREEN}1.${PLAIN} 安装 Hysteria 2
  ${GREEN}2.${PLAIN} 卸载 Hysteria 2
  ${GREEN}3.${PLAIN} 更新 Hysteria 2
  ${GREEN}4.${PLAIN} 重启 Hysteria 2
  ${GREEN}5.${PLAIN} 客户端管理 (配置/分享链接/中继)
  ${GREEN}6.${PLAIN} 修改配置
  ${GREEN}7.${PLAIN} 查询服务状态
  ${GREEN}0.${PLAIN} 退出脚本
  ----------------------
  Hysteria 2 服务状态: ${hysteria_server_status_text}
  ----------------------"
  
    read -p "请输入选项 [0-7]: " choice
    
    case "${choice}" in
        0) clear;exit 0 ;;
        1) install_hysteria ;;
        2) uninstall_hysteria ;;
        3) update_hysteria ;;
        4) systemctl restart hysteria-server.service ;;
        5) client_menu ;;
        6) modify_config ;;
        7) systemctl status hysteria-server.service ;;
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
