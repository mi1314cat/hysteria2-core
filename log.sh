#!/bin/bash

# 配置文件路径
SERVICE_NAME="hysteria-server"
OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
LOG_FILE="/root/hy2/logfile.txt"
CLEANUP_SCRIPT="/usr/local/bin/cleanup_logs.sh"
CRON_JOB="0 1 */3 * * $CLEANUP_SCRIPT"

# 检查是否以root用户运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行此脚本"
    exit 1
fi

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

# 创建清理脚本
cat << 'EOF' > $CLEANUP_SCRIPT
#!/bin/bash

# 设置日志文件路径
LOG_FILE="/root/hy2/logfile.txt"

# 检查日志文件是否存在
if [ -f "$LOG_FILE" ]; then
    # 删除日志文件内容中超过7天的行（假设文件中的每一行代表一条日志）
    # 这里只删除日志文件本身，将根据需求修改
    find "$LOG_FILE" -type f -mtime +7 -exec rm -f {} \;

    # 输出日志（可选）
    echo "$(date): 清理完成：已删除超过7天的日志内容。" >> /var/log/cleanup_logs.log
else
    echo "日志文件未找到：$LOG_FILE" >> /var/log/cleanup_logs.log
fi
EOF

# 赋予清理脚本执行权限
chmod +x $CLEANUP_SCRIPT

# 添加 cron 任务
# 首先检查是否已存在相同的 cron 任务
(crontab -l | grep -q "$CLEANUP_SCRIPT") || (echo "$CRON_JOB" | crontab -)

# 输出结果
echo "清理脚本已创建并配置为每三天凌晨1点自动执行。"
