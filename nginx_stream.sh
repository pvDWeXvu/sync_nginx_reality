#!/bin/bash

NGINX_CONF="/etc/nginx/nginx.conf"
DOMAINS_FILE="domains.txt"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本"
  exit
fi

# 检查 domains 文件
if [ ! -f "$DOMAINS_FILE" ]; then
    echo "创建默认 domains.txt..."
    cat > $DOMAINS_FILE <<EOF
# 本地端口,目标IP:端口
10000,1.1.1.1:10000
EOF
fi

show_menu() {
    echo "=============================="
    echo "   Nginx Stream 转发管理脚本"
    echo "=============================="
    echo "1. 编辑 domains.txt (配置转发规则)"
    echo "2. 同步配置并重启 Nginx"
    echo "3. 查看当前 Nginx 运行状态"
    echo "4. 查看端口监听情况"
    echo "5. 退出"
    echo "=============================="
}

sync_config() {

    echo "正在生成 Nginx 配置..."

    # 备份
    cp $NGINX_CONF "${NGINX_CONF}.bak"

    # 提取 nginx.conf 头部
    head_part=$(sed 's/^user www-data/# user www-data/' $NGINX_CONF | sed -n '1,/events {/p')
    events_end="}"

    stream_block="stream {\n"

    while IFS=',' read -r local_port remote_target
    do

        # 跳过注释
        [[ "$local_port" =~ ^#.*$ ]] && continue

        if [ -n "$local_port" ] && [ -n "$remote_target" ]; then

            stream_block+="    server {\n"
            stream_block+="        listen $local_port;\n"
            stream_block+="        listen $local_port udp;\n"
            stream_block+="        proxy_pass $remote_target;\n"
            stream_block+="        proxy_timeout 1h;\n"
            stream_block+="    }\n"

            echo "添加规则: $local_port (TCP+UDP) -> $remote_target"

        fi

    done < "$DOMAINS_FILE"

    stream_block+="}\n"

    http_block="http {
        include /etc/nginx/mime.types;
        default_type application/octet-stream;

        server {
            listen 80;
            location / {
                return 200 'Nginx Stream Proxy Running';
            }
        }
    }"

    echo -e "$head_part" > $NGINX_CONF
    echo -e "$events_end" >> $NGINX_CONF
    echo -e "\n$stream_block" >> $NGINX_CONF
    echo -e "\n$http_block" >> $NGINX_CONF

    nginx -t

    if [ $? -eq 0 ]; then
        systemctl restart nginx
        echo "Nginx 配置同步成功并已重启"
    else
        echo "配置错误，恢复备份"
        mv "${NGINX_CONF}.bak" $NGINX_CONF
    fi
}

while true
do

show_menu

read -p "请输入选项 [1-5]: " choice

case $choice in

1)
nano $DOMAINS_FILE
;;

2)
sync_config
;;

3)
systemctl status nginx | grep -E "Active|Main PID"
;;

4)
echo "TCP监听："
ss -lntp | grep nginx
echo ""
echo "UDP监听："
ss -lunp | grep nginx
;;

5)
exit 0
;;

*)
echo "无效选项"
;;

esac

done
