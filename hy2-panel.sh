#!/bin/bash

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

[[ $EUID -ne 0 ]] && echo -e "${RED}必须使用 root 运行${PLAIN}" && exit 1

SYSTEM_NAME=$(grep -i pretty_name /etc/os-release | cut -d \" -f2)
CORE_ARCH=$(arch)

show_banner() {
    clear
    cat << "EOF"
   catmi.Hysteria2 Panel
--------------------------------
EOF
    echo -e "${GREEN}System:${PLAIN} ${SYSTEM_NAME}"
    echo -e "${GREEN}Arch:${PLAIN} ${CORE_ARCH}"
    echo "--------------------------------"
}

print_info(){ echo -e "${GREEN}[Info]${PLAIN} $1"; }
print_error(){ echo -e "${RED}[Error]${PLAIN} $1"; }

# 生成端口
generate_port() {
    while :; do
        port=$((RANDOM % 10001 + 10000))
        read -p "端口(默认随机 $port): " input
        port=${input:-$port}
        ss -tuln | grep -q ":$port\b" || { echo "$port"; return 0; }
        echo "端口占用"
    done
}

# 随机伪装站
random_site() {
cat <<EOF | shuf -n 1
https://www.cloudflare.com
https://www.microsoft.com
https://www.apple.com
https://www.amazon.com
EOF
}
FAKE_SITE=$(random_site)
# 创建快捷方式
create_shortcut() {
cat > /usr/local/bin/catmihy2 << 'EOF'
#!/bin/bash
bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/main/hy2-panel.sh)
EOF
chmod +x /usr/local/bin/catmihy2
}

# 安装
install_hysteria() {

print_info "安装 Hysteria2..."
bash <(curl -fsSL https://get.hy2.sh/)

FAKE_SITE=$(random_site)

# 证书（与SNI一致）
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
-keyout /etc/hysteria/server.key \
-out /etc/hysteria/server.crt \
-subj "/CN=${FAKE_SITE#https://}" \
-days 36500

chown hysteria /etc/hysteria/server.*

AUTH_PASSWORD=$(openssl rand -base64 16)
PORT=$(generate_port)

PUBLIC_IP=$(curl -s https://api.ipify.org)

# 放行端口
ufw allow $PORT/udp 2>/dev/null
iptables -I INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null

create_server_config
create_client_config

systemctl enable --now hysteria-server.service

print_info "安装完成"
echo "IP: $PUBLIC_IP"
echo "端口: $PORT"
echo "密码: $AUTH_PASSWORD"
}

# 服务端
create_server_config() {
cat > /etc/hysteria/config.yaml <<EOF
listen: ":$PORT"

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
  alpn:
    - h3

auth:
  type: password
  password: $AUTH_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $FAKE_SITE
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520

brutal:
  enabled: true
EOF
}

# 客户端
create_client_config() {
mkdir -p /root/hy2
cat > /root/hy2/config.yaml <<EOF
- name: Hy2
  type: hysteria2
  server: $PUBLIC_IP
  port: $PORT
  password: $AUTH_PASSWORD

  sni: ${FAKE_SITE#https://}
  skip-cert-verify: false

  alpn:
    - h3

  up: "50 Mbps"
  down: "150 Mbps"

  brutal-opts:
    enabled: true
    up: "50 Mbps"
    down: "150 Mbps"
EOF
}

# 卸载
uninstall_hysteria() {
systemctl stop hysteria-server
rm -rf /etc/hysteria /root/hy2
rm -f /usr/local/bin/catmihy2
print_info "已卸载"
}

# 更新
update_hysteria() {
bash <(curl -fsSL https://get.hy2.sh/)
systemctl restart hysteria-server
print_info "已更新"
}

# 修改配置
modify_config() {

PORT=$(generate_port)
AUTH_PASSWORD=$(openssl rand -base64 16)

sed -i "s/listen:.*/listen: \":$PORT\"/" /etc/hysteria/config.yaml
sed -i "s/password:.*/password: $AUTH_PASSWORD/" /etc/hysteria/config.yaml

sed -i "s/port:.*/  port: $PORT/" /root/hy2/config.yaml
sed -i "s/password:.*/  password: $AUTH_PASSWORD/" /root/hy2/config.yaml

systemctl restart hysteria-server

print_info "已更新配置"
}

# 查看
view_client_config() {
cat /root/hy2/config.yaml
}

# 菜单
menu() {
echo "
1. 安装
2. 卸载
3. 更新
4. 重启
5. 查看配置
6. 修改配置
0. 退出
"
read -p "选择: " n

case $n in
1) install_hysteria ;;
2) uninstall_hysteria ;;
3) update_hysteria ;;
4) systemctl restart hysteria-server ;;
5) view_client_config ;;
6) modify_config ;;
0) exit ;;
*) echo "错误" ;;
esac
}

# 主循环
main(){
show_banner
create_shortcut
while true; do menu; done
}

main
