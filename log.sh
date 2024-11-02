#!/bin/bash

# 配置文件路径
SERVICE_NAME="hysteria-server"
OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
LOG_FILE="/root/hy2/logfile.txt"

# 创建日志目录（如果不存在）
mkdir -p /root/hy2

# 确保日志文件存在并设置权限
touch "$LOG_FILE"
chmod 664 "$LOG_FILE"

# 创建 override 配置文件目录
echo "Creating override configuration in $OVERRIDE_FILE..."
mkdir -p "$OVERRIDE_DIR"

# 写入日志配置到 override 文件
cat <<EOF | sudo tee "$OVERRIDE_FILE" > /dev/null
[Service]
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
EOF

# 重新加载 systemd 配置
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

# 重启服务以应用日志配置
echo "Restarting $SERVICE_NAME service..."
sudo systemctl restart "$SERVICE_NAME"

# 检查服务状态
echo "Service $SERVICE_NAME status with new logging configuration:"
sudo systemctl status "$SERVICE_NAME" --no-pager
