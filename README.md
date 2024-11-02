# hysteria2-core一键脚本


## hysteria2 带面板脚本
```bash
bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/hy2-panel.sh)
```
## hysteria2 快速脚本
```bash
bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/fast-hy2.sh)
```
### 添加日志
#### hysteria2日志
```bash
bash <(curl -fsSL https://github.com/mi1314cat/hysteria2-core/raw/refs/heads/main/log.sh)
```
# hysteria2服务管理
## 编辑配置文件
```
nano /etc/hysteria/config.yaml
```
## 服务管理
### 设置开机自启， 并立即启动服务

```
systemctl enable --now hysteria-server.service
```
### 重启服务， 通常在修改配置文件后执行
```
systemctl restart hysteria-server.service
```
### 查询服务状态
```
systemctl status hysteria-server.service
```
查询服务端日志
```
journalctl --no-pager -e -u hysteria-server.service
```



