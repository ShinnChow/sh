#!/bin/bash
# KPANEL_WEB_CERTIFICATE_RENEWAL_PROTOCOL_VERSION=1
[ -d /home/web/certs ] && [ ! -L /home/web/certs ] || exit 1
[ ! -L /home/web/certs/.kpanel-certificate.lock ] || exit 1
exec 9>/home/web/certs/.kpanel-certificate.lock || exit 1
flock -w 30 9 || exit 1

# Remember only a pair previously observed in this host's Certbot lineage.
# Certbot's legacy delete-before-issue flow may temporarily remove that lineage.
kpanel_certificate_automatic() (
    local cert="$1" key="$2" proof="${certs_directory}${yuming}.auto-renewal"
    local pair temporary=""
    [ -f "$cert" ] && [ ! -L "$cert" ] && [ -f "$key" ] && [ ! -L "$key" ] || return 1
    [ ! -L "$proof" ] && { [ ! -e "$proof" ] || { [ -f "$proof" ] && [ "$(stat -c %u "$proof")" = 0 ] && [ "$(stat -c %a "$proof")" = 600 ]; }; } || return 1
    pair="$(sha256sum "$cert" | awk '{print $1}') $(sha256sum "$key" | awk '{print $1}')"
    [[ "$pair" =~ ^[a-f0-9]{64}\ [a-f0-9]{64}$ ]] || return 1
    if cmp -s "/etc/letsencrypt/live/$yuming/fullchain.pem" "$cert" && cmp -s "/etc/letsencrypt/live/$yuming/privkey.pem" "$key"; then
        umask 077
        trap 'rm -f -- "$temporary"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        temporary=$(mktemp "${proof}.XXXXXX") || return 1
        printf '%s\n' "$pair" > "$temporary" && chmod 600 "$temporary" && mv -f -- "$temporary" "$proof"
    else
        [ -f "$proof" ] && [ "$(wc -c < "$proof")" = 130 ] && [ "$(cat "$proof")" = "$pair" ]
    fi
)

# 定义证书存储目录
certs_directory="/home/web/certs/"
days_before_expiry=15  # 设置在证书到期前几天触发续签

# 遍历所有证书文件
for cert_file in $certs_directory*_cert.pem; do
    # 获取域名
    yuming=$(basename "$cert_file" "_cert.pem")
    # Custom material is renewed by its owner; the PEM files remain the truth.
    if [ -e "${certs_directory}${yuming}.custom" ] || [ -L "${certs_directory}${yuming}.custom" ]; then
        continue
    fi
    if ! kpanel_certificate_automatic "$cert_file" "${certs_directory}${yuming}_key.pem"; then
        continue
    fi

    # 输出正在检查的证书信息
    echo "检查证书过期日期： ${yuming}"

    # 获取证书过期日期
    expiration_date=$(openssl x509 -enddate -noout -in "${certs_directory}${yuming}_cert.pem" | cut -d "=" -f 2-)

    # 输出证书过期日期
    echo "过期日期： ${expiration_date}"

    # 将日期转换为时间戳
    expiration_timestamp=$(date -d "${expiration_date}" +%s)
    current_timestamp=$(date +%s)

    # 计算距离过期还有几天
    days_until_expiry=$(( ($expiration_timestamp - $current_timestamp) / 86400 ))

    if [ $days_until_expiry -le $days_before_expiry ]; then

        echo "证书将在${days_before_expiry}天内过期，正在进行自动续签。"

        # 1. 检查目录是否存在
        docker exec nginx [ -d /var/www/letsencrypt ] && DIR_OK=true || DIR_OK=false

        # 2. 检查配置文件是否包含关键字
        # 假设你的配置文件在容器内的 /etc/nginx/conf.d/ 目录下（这是 Nginx 容器的默认路径）
        docker exec nginx grep -q "letsencrypt" /etc/nginx/conf.d/$yuming.conf && CONF_OK=true || CONF_OK=false

        # 输出结果
        echo "--- 自动化环境检测报告 ---"
        if [ "$DIR_OK" = true ]; then echo "✅ 目录检测：/var/www/letsencrypt 存在"; else echo "❌ 目录检测：/var/www/letsencrypt 不存在"; fi
        if [ "$CONF_OK" = true ]; then echo "✅ 配置检测：$yuming.conf 已包含续签规则"; else echo "❌ 配置检测：$yuming.conf 未发现 letsencrypt 字样"; fi

        if [ "$DIR_OK" = true ] && [ "$CONF_OK" = true ]; then
            docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$yuming" -n

            docker run --rm \
              -v "/etc/letsencrypt:/etc/letsencrypt" \
              -v "/home/web/letsencrypt:/var/www/letsencrypt" \
              certbot/certbot certonly \
              --webroot \
              -w /var/www/letsencrypt \
              -d "$yuming" \
              --email your@email.com \
              --agree-tos \
              --no-eff-email \
              --key-type ecdsa \
              --force-renewal

            mkdir -p /home/web/certs/
            cp /etc/letsencrypt/live/$yuming/fullchain.pem /home/web/certs/${yuming}_cert.pem > /dev/null 2>&1
            cp /etc/letsencrypt/live/$yuming/privkey.pem /home/web/certs/${yuming}_key.pem > /dev/null 2>&1

            openssl rand -out /home/web/certs/ticket12.key 48
            openssl rand -out /home/web/certs/ticket13.key 80

            docker exec nginx nginx -t && docker exec nginx nginx -s reload

        else
            docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$yuming" -n

            docker stop nginx > /dev/null 2>&1

            docker run --rm -p 80:80 -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot certonly --standalone -d $yuming --email your@email.com --agree-tos --no-eff-email --force-renewal --key-type ecdsa

            mkdir -p /home/web/certs/
            cp /etc/letsencrypt/live/$yuming/fullchain.pem /home/web/certs/${yuming}_cert.pem > /dev/null 2>&1
            cp /etc/letsencrypt/live/$yuming/privkey.pem /home/web/certs/${yuming}_key.pem > /dev/null 2>&1

            openssl rand -out /home/web/certs/ticket12.key 48
            openssl rand -out /home/web/certs/ticket13.key 80

            docker start nginx > /dev/null 2>&1

        fi

        echo "证书已成功续签。"
    else
        # 若未满足续签条件，则输出证书仍然有效
        echo "证书仍然有效，距离过期还有 ${days_until_expiry} 天。"
    fi

    # 输出分隔线
    echo "--------------------------"
done
