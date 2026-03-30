#!/bin/bash

NGINX_CONF="/etc/nginx/nginx.conf"
DOMAINS_FILE="domains.txt"

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
    echo "   Nginx Stream 转发管理 (抗探测版)"
    echo "=============================="
    echo "1. 编辑 domains.txt"
    echo "2. 同步配置并重启 (含抗探测)"
    echo "3. 查看 Nginx 状态"
    echo "4. 退出"
    echo "=============================="
}

sync_config() {
    optimize_sysctl
    echo "正在生成 Nginx 配置..."

    [ ! -f "$DOMAINS_FILE" ] && touch "$DOMAINS_FILE"
    cp $NGINX_CONF "${NGINX_CONF}.bak"

    # ===== 全局优化 =====
    # 在这里加上 load_module
    head_part="load_module /usr/lib/nginx/modules/ngx_stream_module.so;
worker_processes auto;

events {
    worker_connections 10240;
    multi_accept on;
}"

    # ===== stream 内容（真实网站 fallback）=====
    stream_content=""

    while IFS=',' read -r local_port remote_target
    do
        if [ -z "$local_port" ] || [ -z "$remote_target" ]; then
            continue
        fi

        # ===== upstream =====
        upstream="    upstream backend_$local_port {\n"
        upstream="${upstream}        server $remote_target max_fails=1 fail_timeout=2s;\n"
        upstream="${upstream}        server 1.1.1.1:443 backup;\n"
        upstream="${upstream}        server 8.8.8.8:443 backup;\n"
        upstream="${upstream}    }\n"

        # ===== server =====
        line="    server {\n"
        line="${line}        listen $local_port reuseport;\n"
        line="${line}        proxy_pass backend_$local_port;\n"

        line="${line}        proxy_buffer_size 16k;\n"
        line="${line}        proxy_socket_keepalive on;\n"
        line="${line}        so_keepalive on;\n"
        line="${line}        proxy_half_close on;\n"
        line="${line}        tcp_nodelay on;\n"

        # 🔥 关键：快速失败 → fallback
        line="${line}        proxy_connect_timeout 2s;\n"
        line="${line}        proxy_timeout 3m;\n"

        line="${line}        limit_conn addr 20;\n"
        line="${line}    }\n"

        stream_content="${stream_content}${upstream}${line}"

        echo "添加规则(抗探测): $local_port -> $remote_target"
    done < "$DOMAINS_FILE"

    # ===== stream 块 =====
    stream_block="stream {
    limit_conn_zone \$binary_remote_addr zone=addr:10m;

${stream_content}
}
"

    # ===== http 伪装 =====
    http_block="http {
    include /etc/nginx/mime.types;
    access_log off;

    server {
        listen 80;
        location / {
            return 200 '';
        }
    }
}
"

    # ===== 写入配置 =====
    printf "${head_part}\n\n${stream_block}\n${http_block}\n" > $NGINX_CONF

    nginx -t
    if [ $? -eq 0 ]; then
        systemctl restart nginx
        echo "✅ Nginx 已应用抗探测配置并重启成功！"
    else
        echo "❌ 配置错误，正在回滚..."
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
