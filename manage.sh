#!/bin/bash

# 强制使用 bash 运行，防止 dash 兼容性问题
NGINX_CONF="/etc/nginx/nginx.conf"
DOMAINS_FILE="domains.txt"

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本"
  exit 1
fi

optimize_sysctl() {
    echo "正在优化系统内核参数 (BBR & TCP Buffers)..."
    cat <<EOF > /etc/sysctl.d/99-proxy-optimize.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
EOF
    sysctl --system >/dev/null 2>&1
}

show_menu() {
    echo "=============================="
    echo "    Nginx Stream 转发管理 (修复版)"
    echo "=============================="
    echo "1. 编辑 domains.txt (配置规则)"
    echo "2. 同步配置并重启 (含深度优化)"
    echo "3. 查看当前 Nginx 运行状态"
    echo "4. 退出"
    echo "=============================="
}

sync_config() {
    optimize_sysctl
    echo "正在生成 Nginx 配置..."
    
    [ ! -f "$DOMAINS_FILE" ] && touch "$DOMAINS_FILE"
    cp $NGINX_CONF "${NGINX_CONF}.bak"

    # 提取头部并注释 user www-data
    head_part=$(sed 's/^user www-data/# user www-data/' $NGINX_CONF | sed -n '1,/events {/p')
    events_end="}"
    
    # 使用标准变量拼接，兼容所有 Shell
    stream_content=""
    while IFS=',' read -r local_port remote_target
    do
        if [ -z "$local_port" ] || [ -z "$remote_target" ]; then continue; fi
        
        line="    server {\n"
        line="${line}        listen $local_port;\n"
        line="${line}        proxy_pass $remote_target;\n"
        line="${line}        proxy_buffer_size 16k;\n"
        line="${line}        proxy_socket_keepalive on;\n"
        line="${line}        proxy_connect_timeout 5s;\n"
        line="${line}        proxy_timeout 1h;\n"
        line="${line}    }\n"
        
        stream_content="${stream_content}${line}"
        echo "添加规则: 监听 $local_port -> $remote_target"
    done < "$DOMAINS_FILE"

    stream_block="stream {\n${stream_content}}\n"
    http_block="http {\n    include /etc/nginx/mime.types;\n    access_log off;\n    server {\n        listen 80;\n        location / {\n            return 200 'Nginx Stream Proxy Running';\n        }\n    }\n}"

    # 使用 printf 替代 echo -e，防止写入 -e 到配置文件
    printf "${head_part}\n${events_end}\n\n${stream_block}\n${http_block}\n" > $NGINX_CONF

    nginx -t
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        echo "Nginx 配置同步成功并已重启！"
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
