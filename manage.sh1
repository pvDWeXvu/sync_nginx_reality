#!/bin/bash

NGINX_CONF="/etc/nginx/nginx.conf"
DOMAINS_FILE="domains.txt"

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本"
  exit
fi

# 菜单功能
show_menu() {
    echo "=============================="
    echo "   Nginx Stream 转发管理脚本"
    echo "=============================="
    echo "1. 编辑 domains.txt (配置转发规则)"
    echo "2. 同步配置并重启 Nginx"
    echo "3. 查看当前 Nginx 运行状态"
    echo "4. 退出"
    echo "=============================="
}

sync_config() {
    echo "正在生成 Nginx 配置..."
    
    # 备份原配置
    cp $NGINX_CONF "${NGINX_CONF}.bak"

    # 提取 Nginx 头部加载模块和全局设置（保留到 events 结束）
    # 自动注释 user www-data
    head_part=$(sed 's/^user www-data/# user www-data/' $NGINX_CONF | sed -n '1,/events {/p')
    # 提取 events 块的闭合括号
    events_end="}"
    
    # 构建新的 stream 块
    stream_block="stream {\n"
    while IFS=',' read -r local_port remote_target
    do
        if [ -n "$local_port" ] && [ -n "$remote_target" ]; then
            stream_block+="    server {\n"
            stream_block+="        listen $local_port;\n"
            stream_block+="        proxy_pass $remote_target;\n"
            stream_block+="        proxy_connect_timeout 5s;\n"
            stream_block+="        proxy_timeout 1h;\n"
            stream_block+="    }\n"
            echo "添加规则: 监听 $local_port -> 转发至 $remote_target"
        fi
    done < "$DOMAINS_FILE"
    stream_block+="}\n"

    # 构建基础 http 块 (保持极简运行)
    http_block="http {\n    include /etc/nginx/mime.types;\n    server {\n        listen 80;\n        location / {\n            return 200 'Nginx Stream Proxy Running';\n        }\n    }\n}"

    # 写入文件
    echo -e "$head_part" > $NGINX_CONF
    echo -e "$events_end" >> $NGINX_CONF
    echo -e "\n$stream_block" >> $NGINX_CONF
    echo -e "\n$http_block" >> $NGINX_CONF

    # 检查并重启
    nginx -t
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        echo "Nginx 配置同步成功并已重启！"
    else
        echo "配置错误，已还原备份。"
        mv "${NGINX_CONF}.bak" $NGINX_CONF
    fi
}

while true; do
    show_menu
    read -p "请输入选项 [1-4]: " choice
    case $choice in
        1)
            nano $DOMAINS_FILE
            ;;
        2)
            sync_config
            ;;
        3)
            systemctl status nginx | grep -E "Active|Main PID"
            netstat -tulpn | grep nginx
            ;;
        4)
            exit 0
            ;;
        *)
            echo "无效选项"
            ;;
    esac
done
