#!/bin/bash

NGINX_CONF="/etc/nginx/nginx.conf"
DOMAINS_FILE="domains.txt"

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本"
  exit 1
fi

optimize_sysctl() {
    echo "正在优化系统内核参数 (针对 Hy2 高速 UDP 优化)..."
    cat <<EOF > /etc/sysctl.d/99-proxy-optimize.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
# 增加 UDP 接收缓冲区，防止 Hy2 高速传输时丢包
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
    sysctl --system >/dev/null 2>&1
}

show_menu() {
    echo "=============================="
    echo "    Nginx Stream 转发 (Hy2 优化版)"
    echo "=============================="
    echo "1. 编辑 domains.txt (配置规则)"
    echo "2. 同步配置并重启 (含 UDP 优化)"
    echo "3. 查看当前 Nginx 运行状态"
    echo "4. 退出"
    echo "=============================="
}

sync_config() {
    optimize_sysctl
    echo "正在生成 Nginx 配置..."
    
    [ ! -f "$DOMAINS_FILE" ] && touch "$DOMAINS_FILE"
    cp $NGINX_CONF "${NGINX_CONF}.bak"

    head_part=$(sed 's/^user www-data/# user www-data/' $NGINX_CONF | sed -n '1,/events {/p')
    events_end="}"
    
    stream_content=""
    while IFS=',' read -r local_port remote_target
    do
        if [ -z "$local_port" ] || [ -z "$remote_target" ]; then continue; fi
        
        # 核心配置：同时兼容 TCP (Reality) 和 UDP (Hysteria2)
        line="    server {\n"
        line="${line}        listen $local_port;\n"
        line="${line}        listen $local_port udp;\n"
        line="${line}        proxy_pass $remote_target;\n"
        
        # TCP 优化 (对 Reality 生效)
        line="${line}        proxy_buffer_size 16k;\n"
        line="${line}        proxy_socket_keepalive on;\n"
        
        # UDP 优化 (对 Hysteria2 生效)
        line="${line}        proxy_responses 1;          # 关键：允许 UDP 回包\n"
        line="${line}        proxy_timeout 120s;         # 适中的 UDP 会话保持时间\n"
        
        line="${line}        proxy_connect_timeout 5s;\n"
        line="${line}    }\n"
        
        stream_content="${stream_content}${line}"
        echo "添加规则: 监听 $local_port (TCP+UDP) -> $remote_target"
    done < "$DOMAINS_FILE"

    stream_block="stream {\n${stream_content}}\n"
    http_block="http {\n    include /etc/nginx/mime.types;\n    access_log off;\n    server {\n        listen 80;\n        location / {\n            return 200 'Proxy Server Running';\n        }\n    }\n}"

    printf "${head_part}\n${events_end}\n\n${stream_block}\n${http_block}\n" > $NGINX_CONF

    nginx -t
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        echo "Nginx 配置同步成功并已重启！"
        echo "提示：请确保防火墙已放行上述端口的 TCP 和 UDP 协议。"
    else
        echo "配置错误，已从备份还原。"
        cp "${NGINX_CONF}.bak" $NGINX_CONF
    fi
}

while true; do
    show_menu
    read -p "请输入选项 [1-4]: " choice
    case $choice in
        1) nano $DOMAINS_FILE ;;
        2) sync_config ;;
        3) 
            systemctl status nginx | grep -E "Active|Main PID"
            echo "------------------------------"
            netstat -tulpn | grep nginx
            ;;
        4) exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
