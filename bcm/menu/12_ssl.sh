#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 12_ssl.sh — SSL-сертификаты кластера (HTTPS)
#
# TLS терминируется ТОЛЬКО на HAProxy (LB-слой): один pem лежит в
# /etc/haproxy/certs/ на ОБОИХ LB, web-нодам публичный сертификат не нужен
# (Apache видит HTTPS=on по X-Forwarded-Proto, nginx подставляет порт в Host).
# Вся LB-сторона — bin/lib/ssl_certs.sh (раскатан на LB), меню оркеструет по SSH.
#
# Let's Encrypt: HTTP-01 через acme_backend HAProxy (challenge с VIP:80 доезжает
# до acme.sh --standalone на любом LB). Продление — systemd-timer bcm-cert-renew
# на обоих LB (реально продлевает только держатель VIP).
#
# ⚠️ Принудительный HTTPS включать ЗДЕСЬ (редирект на HAProxy), а НЕ в админке
# Bitrix и НЕ через .htsecure: nginx-редирект .htsecure не видит X-Forwarded-Proto
# → бесконечный цикл редиректов за TLS-терминатором.
# =============================================================================
set -euo pipefail

BCM_BASE_DIR="${BCM_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"

source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"

if ! bcm_conf_exists; then
    bcm_error "cluster.conf не найден. Запустите install.sh."
    exit 1
fi
bcm_load_topology

SSL_LIB="/opt/bcm/bin/lib/ssl_certs.sh"
SSL_ENV="/etc/bitrix-cluster/ssl-renew.env"

# ──── Параметры из конфига ───────────────────────────────────────────────────
_ssl_domain()  { bcm_conf_get ssl domain 2>/dev/null || bcm_conf_get network portal_domain 2>/dev/null || echo ""; }
_ssl_email()   { bcm_conf_get ssl le_email 2>/dev/null || echo ""; }
_ssl_acme_ca() { bcm_conf_get ssl acme_ca 2>/dev/null || echo "letsencrypt"; }

# ──── LB-ноды: держатель VIP последним (reload бесшовный, но так безопаснее) ──
# Выводит по строке: "<node> <ip>"
_ssl_lb_ordered() {
    local vip holder_line="" node ip
    vip=$(bcm_get_vip 2>/dev/null || echo "")
    for node in "${BCM_NODES_LB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if [[ -n "$vip" ]] && bcm_ssh_exec_timeout "$ip" 8 "ip -4 addr | grep -q 'inet ${vip}/'" 2>/dev/null; then
            holder_line="${node} ${ip}"
        else
            echo "${node} ${ip}"
        fi
    done
    [[ -n "$holder_line" ]] && echo "$holder_line"
}

# Держатель VIP (или первый доступный LB) — на нём выпускаем/продлеваем
_ssl_issue_node() {
    _ssl_lb_ordered | tail -1
}

# ──── Раскатать ssl-renew.env на все LB (идемпотентно, из cluster.conf) ───────
# _ssl_push_env [method] [cf_token]
# method: http | dns_cf (пусто → из conf). cf_token: пусто → сохранить прежний
# токен с ноды (не перезатирать). env уходит через stdin (cat >), а НЕ в argv —
# токен не светится в ps.
_ssl_push_env() {
    local method="${1:-}" cf_token="${2:-}"
    local domain email vip lb_ips="" web_ips="" node ip
    domain=$(_ssl_domain); email=$(_ssl_email); vip=$(bcm_get_vip 2>/dev/null || echo "")
    [[ -z "$method" ]] && method=$(bcm_conf_get ssl acme_method 2>/dev/null || echo http)
    for node in "${BCM_NODES_LB[@]}"; do
        lb_ips="${lb_ips}${BCM_NODE_IP[$node]:-} "
    done
    lb_ips="${lb_ips% }"
    for node in "${BCM_NODES_WEB[@]}"; do
        web_ips="${web_ips}${BCM_NODE_IP[$node]:-} "
    done
    web_ips="${web_ips% }"

    for node in "${BCM_NODES_LB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_node_reachable "$ip" 5 2>/dev/null || { bcm_warn "  ${node} (${ip}) недоступен — env не обновлён."; continue; }

        local node_token="$cf_token"
        if [[ -z "$node_token" ]]; then
            node_token=$(bcm_ssh_exec_timeout "$ip" 8 \
                "sed -n 's/^CF_Token=\"\\(.*\\)\"/\\1/p' ${SSL_ENV} 2>/dev/null" 2>/dev/null) || node_token=""
        fi

        printf '%s\n' \
            "# Сгенерировано BCM (меню SSL) — параметры ssl_certs.sh" \
            "SELF_NODE=\"${node}\"" \
            "SELF_IP=\"${ip}\"" \
            "LB_PEERS=\"${lb_ips}\"" \
            "WEB_PEERS=\"${web_ips}\"" \
            "DOMAIN=\"${domain}\"" \
            "LE_EMAIL=\"${email}\"" \
            "VIP=\"${vip}\"" \
            "ACME_CA=\"$(_ssl_acme_ca)\"" \
            "ACME_METHOD=\"${method}\"" \
            "CF_Token=\"${node_token}\"" \
            | bcm_ssh_exec "$ip" "mkdir -p /etc/bitrix-cluster && cat > ${SSL_ENV} && chmod 600 ${SSL_ENV}" 2>/dev/null \
            && bcm_info "  ${node}: ${SSL_ENV} обновлён (метод: ${method})." \
            || bcm_warn "  ${node}: не удалось записать env."
    done
}

# ──── Убедиться, что таймер продления стоит на LB (для старых установок) ──────
_ssl_ensure_timer() {
    local node ip
    # ⚠️ mapfile ДО цикла (ssh в теле съел бы stdin живого process substitution →
    # таймер встал бы только на первый LB). См. _ssl_toggle_https.
    local -a _lb_lines=(); mapfile -t _lb_lines < <(_ssl_lb_ordered)
    local _l
    for _l in "${_lb_lines[@]}"; do
        read -r node ip <<< "$_l"
        [[ -z "${ip:-}" ]] && continue
        bcm_ssh_exec "$ip" "test -f /etc/systemd/system/bcm-cert-renew.timer" 2>/dev/null && continue
        bcm_info "  ${node}: ставлю таймер продления bcm-cert-renew..."
        bcm_ssh_exec "$ip" "cat > /etc/systemd/system/bcm-cert-renew.service <<'EOF'
[Unit]
Description=BCM: renew cluster SSL certificate (Let's Encrypt)
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SSL_LIB} --renew
EOF
cat > /etc/systemd/system/bcm-cert-renew.timer <<'EOF'
[Unit]
Description=BCM: daily SSL certificate renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload && systemctl enable --now bcm-cert-renew.timer" 2>/dev/null \
            || bcm_warn "  ${node}: не удалось поставить таймер."
    done
}

# ──── 1. Статус сертификатов ─────────────────────────────────────────────────
_ssl_show_status() {
    bcm_section_header "SSL: статус сертификатов на LB-нодах"
    bcm_info "Домен: $(_ssl_domain || true)  |  режим: $(bcm_conf_get ssl mode 2>/dev/null || echo none)  |  force_https: $(bcm_conf_get ssl force_https 2>/dev/null || echo 0)"
    echo
    local node ip
    for node in "${BCM_NODES_LB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_color "WHITE" "  ── ${node} (${ip}) ──"
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "    недоступен"
            continue
        fi
        local line
        while IFS='|' read -r f subj end flag; do
            [[ -z "$f" ]] && continue
            if [[ "$f" == \(* ]]; then echo "    $f"; continue; fi
            printf "    %-44s %s\n" "${f##*/}: ${subj}" "до ${end} [${flag}]"
        done < <(bcm_ssh_exec_timeout "$ip" 15 "${SSL_LIB} --status" 2>/dev/null)
        # Редирект и таймер
        local redir timer
        redir=$(bcm_ssh_exec_timeout "$ip" 8 \
            "grep -q '^[[:space:]]*http-request redirect scheme https.*bcm:force_https' /etc/haproxy/haproxy.cfg && echo ВКЛ || echo выкл" 2>/dev/null) || redir="?"
        timer=$(bcm_ssh_exec_timeout "$ip" 8 \
            "systemctl is-enabled bcm-cert-renew.timer 2>/dev/null || echo нет" 2>/dev/null) || timer="?"
        bcm_info "    редирект HTTPS: ${redir:-?}  |  таймер продления: ${timer:-?}"
        echo
    done
    bcm_any_key
}

# ──── 2. Установить свой (купленный) сертификат ──────────────────────────────
_ssl_install_custom() {
    bcm_section_header "Установка своего сертификата (fullchain + key) на все LB"
    bcm_info "Файлы должны лежать на ЭТОЙ ноде (скопируйте заранее, например в /root/)."
    echo

    local fc key domain
    bcm_read_choice "Путь к fullchain (серт + промежуточные, PEM)" fc
    [[ -s "${fc:-}" ]] || { bcm_error "Файл не найден: ${fc:-}"; bcm_any_key; return; }
    bcm_read_choice "Путь к приватному ключу (PEM)" key
    [[ -s "${key:-}" ]] || { bcm_error "Файл не найден: ${key:-}"; bcm_any_key; return; }
    bcm_read_choice "Домен (имя pem-файла) [$(_ssl_domain)]" domain
    domain="${domain:-$(_ssl_domain)}"
    [[ -z "$domain" ]] && { bcm_error "Домен не задан."; bcm_any_key; return; }

    # Локальная валидация пары до раската
    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$fc" -noout -pubkey 2>/dev/null) \
        || { bcm_error "Не удалось прочитать сертификат из ${fc}."; bcm_any_key; return; }
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null) \
        || { bcm_error "Не удалось прочитать ключ из ${key}."; bcm_any_key; return; }
    [[ "$cert_pub" == "$key_pub" ]] \
        || { bcm_error "Ключ НЕ соответствует сертификату — раскат отменён."; bcm_any_key; return; }
    openssl x509 -in "$fc" -noout -checkend 0 >/dev/null 2>&1 \
        || { bcm_error "Сертификат уже истёк."; bcm_any_key; return; }
    bcm_ok "Пара валидна: $(openssl x509 -in "$fc" -noout -enddate 2>/dev/null)"

    bcm_confirm "Раскатать ${domain}.pem на все LB и перечитать HAProxy?" || { bcm_info "Отменено."; bcm_any_key; return; }

    local pem
    pem=$(mktemp /tmp/bcm-ssl.XXXXXX)
    cat "$fc" "$key" > "$pem"; chmod 600 "$pem"

    local node ip ok_all=1
    # ⚠️ mapfile ДО цикла (ssh в теле съел бы stdin живого process substitution →
    # серт лёг бы только на первый LB). См. _ssl_toggle_https.
    local -a _lb_lines=(); mapfile -t _lb_lines < <(_ssl_lb_ordered)
    local _l
    for _l in "${_lb_lines[@]}"; do
        read -r node ip <<< "$_l"
        [[ -z "${ip:-}" ]] && continue
        bcm_info "  ${node} (${ip}): установка..."
        if bcm_ssh_copy_file "$pem" "$ip" "/tmp/bcm-ssl-deploy.pem" && \
           bcm_ssh_exec_timeout "$ip" 30 "${SSL_LIB} --install-pem /tmp/bcm-ssl-deploy.pem '${domain}'; rc=\$?; rm -f /tmp/bcm-ssl-deploy.pem; exit \$rc" 2>/dev/null; then
            bcm_ok "  ${node}: установлен, haproxy перечитан."
        else
            bcm_error "  ${node}: ошибка установки (см. /var/log/bcm/ssl-renew.log на ноде)."
            ok_all=0
        fi
    done

    # И на web-ноды (локальный nginx :443): self-check'и Bitrix ходят на
    # ssl://домен:443 → 127.0.0.1 (hosts-фикс) — без реального серта падают.
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_node_reachable "$ip" 5 2>/dev/null || { bcm_warn "  ${node}: недоступен — серт не доставлен."; ok_all=0; continue; }
        if bcm_ssh_copy_file "$pem" "$ip" "/tmp/bcm-ssl-web.pem" && \
           bcm_ssh_exec_timeout "$ip" 30 "
               [ -f /etc/nginx/ssl/cert.pem ] && cp -n /etc/nginx/ssl/cert.pem /etc/nginx/ssl/cert.pem.bcm-bak
               cp /tmp/bcm-ssl-web.pem /etc/nginx/ssl/cert.pem && chmod 600 /etc/nginx/ssl/cert.pem
               if nginx -t 2>/dev/null; then systemctl reload nginx; else
                   cp /etc/nginx/ssl/cert.pem.bcm-bak /etc/nginx/ssl/cert.pem 2>/dev/null; systemctl reload nginx; exit 1
               fi
               rm -f /tmp/bcm-ssl-web.pem" 2>/dev/null; then
            bcm_ok "  ${node}: серт в локальном nginx обновлён."
        else
            bcm_error "  ${node}: ошибка установки серта в nginx."
            ok_all=0
        fi
    done
    rm -f "$pem"

    if [[ $ok_all -eq 1 ]]; then
        bcm_conf_set ssl domain "$domain"
        bcm_conf_set ssl mode "custom"
        bcm_conf_sync 2>/dev/null || true
        bcm_ok "Готово. Проверьте: пункт «Проверка HTTPS через VIP»."
    fi
    bcm_any_key
}

# ──── 3. Выпустить сертификат Let's Encrypt ──────────────────────────────────
_ssl_issue_le() {
    bcm_section_header "Let's Encrypt: выпуск сертификата"

    # Метод валидации
    local cur_method method m
    cur_method=$(bcm_conf_get ssl acme_method 2>/dev/null || echo http)
    bcm_info "Метод валидации:"
    bcm_info "  1 — HTTP-01 через LB (нужен публичный :80 на VIP)"
    bcm_info "  2 — DNS-01 Cloudflare (нужен API-токен Zone.DNS:Edit; :80 не нужен; можно wildcard)"
    bcm_read_choice "Выбор [тек.: ${cur_method}] (0 — отмена)" m
    [[ "$m" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    case "${m:-}" in
        2|dns|dns_cf) method="dns_cf" ;;
        1|http)       method="http" ;;
        "")           method="$cur_method" ;;
        *) bcm_warn "Неверный выбор."; bcm_any_key; return ;;
    esac

    local domain email
    if [[ "$method" == "dns_cf" ]]; then
        bcm_read_choice "Домен (можно *.домен) [$(_ssl_domain)]" domain
    else
        bcm_read_choice "Домен [$(_ssl_domain)]" domain
    fi
    domain="${domain:-$(_ssl_domain)}"
    [[ -z "$domain" ]] && { bcm_error "Домен не задан."; bcm_any_key; return; }
    if [[ "$method" == "http" && "$domain" == \** ]]; then
        bcm_error "Wildcard-сертификат возможен только через DNS-01 (Cloudflare)."
        bcm_any_key; return
    fi
    bcm_read_choice "E-mail для учётки Let's Encrypt [$(_ssl_email)]" email
    email="${email:-$(_ssl_email)}"
    [[ -z "$email" ]] && { bcm_error "E-mail обязателен."; bcm_any_key; return; }

    # Токен Cloudflare — скрытый ввод; пусто = оставить уже сохранённый на LB
    # (в ssl-renew.env или в account.conf acme.sh после первого выпуска).
    local cf_token=""
    if [[ "$method" == "dns_cf" ]]; then
        bcm_info "API-токен Cloudflare: Zone.DNS:Edit (+ Zone.Zone:Read) на зону домена."
        read -rsp "  CF API Token (пусто — использовать сохранённый): " cf_token
        echo
    fi

    local vip
    vip=$(bcm_get_vip 2>/dev/null || echo "?")
    if [[ "$method" == "dns_cf" ]]; then
        bcm_warn "Требования: зона домена обслуживается Cloudflare; у LB есть выход в интернет (API CF + LE)."
    else
        bcm_warn "Требования: DNS ${domain} → ${vip} (публично) и :80 кластера доступен из интернета."
    fi
    bcm_confirm "Запустить выпуск для ${domain} (${method})?" || { bcm_info "Отменено."; bcm_any_key; return; }

    bcm_conf_set ssl domain "$domain"
    bcm_conf_set ssl le_email "$email"
    bcm_conf_set ssl mode "letsencrypt"
    bcm_conf_set ssl acme_method "$method"
    bcm_conf_sync 2>/dev/null || true

    bcm_info "Обновляю ssl-renew.env на LB..."
    _ssl_push_env "$method" "$cf_token"
    _ssl_ensure_timer

    local issue_node="" issue_ip=""
    read -r issue_node issue_ip < <(_ssl_issue_node) || true
    [[ -z "${issue_ip:-}" ]] && { bcm_error "Нет доступных LB-нод."; bcm_any_key; return; }

    bcm_info "Выпуск на ${issue_node} (${issue_ip}) — до 5 минут..."
    echo
    if bcm_ssh_exec_verbose "$issue_ip" "timeout 300 ${SSL_LIB} --issue" 2>&1 | tail -25; then
        bcm_ok "Выпуск завершён: серт раскатан на все LB (см. статус)."
    else
        bcm_error "Выпуск не удался. Лог: ${issue_node}:/var/log/bcm/ssl-renew.log"
        if [[ "$method" == "dns_cf" ]]; then
            bcm_info "Частые причины: токен без прав Zone.DNS:Edit; зона не в Cloudflare; нет интернета с LB."
        else
            bcm_info "Частые причины: DNS не указывает на VIP; :80 закрыт; нет интернета с LB."
        fi
    fi
    bcm_any_key
}

# ──── 4. Продлить принудительно ──────────────────────────────────────────────
_ssl_renew_now() {
    bcm_section_header "Let's Encrypt: принудительное продление"
    local issue_node="" issue_ip=""
    read -r issue_node issue_ip < <(_ssl_issue_node) || true
    [[ -z "${issue_ip:-}" ]] && { bcm_error "Нет доступных LB-нод."; bcm_any_key; return; }
    bcm_confirm "Продлить сейчас на ${issue_node}? (LE rate-limit: не злоупотреблять)" || { bcm_any_key; return; }
    bcm_ssh_exec_verbose "$issue_ip" "timeout 240 ${SSL_LIB} --renew --force" 2>&1 | tail -15 \
        && bcm_ok "Продление выполнено." \
        || bcm_error "Продление не удалось (лог на ${issue_node})."
    bcm_any_key
}

# ──── 5. Принудительный HTTPS (редирект 80 → 443 на HAProxy) ─────────────────
_ssl_toggle_https() {
    bcm_section_header "Принудительный HTTPS (redirect на HAProxy)"
    local cur
    cur=$(bcm_conf_get ssl force_https 2>/dev/null || echo 0)
    bcm_info "Текущее состояние (по cluster.conf): $( [[ "$cur" == "1" ]] && echo ВКЛЮЧЁН || echo выключен )"
    bcm_warn "Не включайте редирект в админке Bitrix/.htsecure — за TLS-терминатором это даёт цикл."
    echo

    local action sed_cmd new_val
    if [[ "$cur" == "1" ]]; then
        bcm_confirm "ВЫКЛЮЧИТЬ редирект http→https?" || { bcm_any_key; return; }
        sed_cmd='s|^\([[:space:]]*\)\(http-request redirect scheme https[^#]*# bcm:force_https\)$|\1# \2|'
        new_val=0
    else
        bcm_confirm "ВКЛЮЧИТЬ редирект http→https? (нужен установленный сертификат!)" || { bcm_any_key; return; }
        sed_cmd='s|^\([[:space:]]*\)# \(http-request redirect scheme https[^#]*# bcm:force_https\)$|\1\2|'
        new_val=1
    fi

    local node ip ok_all=1
    # ⚠️ mapfile ДО цикла, не «живой» process substitution: ssh в теле (без -n)
    # съедал бы остаток stdin (строки остальных LB) → применялось бы только к
    # первой ноде (ловили вживую: force_https лёг лишь на один LB). -n/`</dev/null`
    # в bcm_ssh_* нельзя — они приёмники stdin (echo … | bcm_ssh_exec_timeout).
    local -a _lb_lines=(); mapfile -t _lb_lines < <(_ssl_lb_ordered)
    local _l
    for _l in "${_lb_lines[@]}"; do
        read -r node ip <<< "$_l"
        [[ -z "${ip:-}" ]] && continue
        if bcm_ssh_exec_timeout "$ip" 20 \
            "sed -i '${sed_cmd}' /etc/haproxy/haproxy.cfg && haproxy -c -f /etc/haproxy/haproxy.cfg -q && systemctl reload haproxy" 2>/dev/null; then
            bcm_ok "  ${node}: применено."
        else
            bcm_error "  ${node}: ошибка (конфиг без маркера bcm:force_https? пересоздайте конфиг HAProxy)."
            ok_all=0
        fi
    done

    [[ $ok_all -eq 1 ]] && { bcm_conf_set ssl force_https "$new_val"; bcm_conf_sync 2>/dev/null || true; }
    bcm_any_key
}

# ──── 6. Проверка HTTPS через VIP ────────────────────────────────────────────
_ssl_check_https() {
    bcm_section_header "Проверка HTTPS через VIP"
    local vip domain
    vip=$(bcm_get_vip 2>/dev/null || echo "")
    domain=$(_ssl_domain)
    [[ -z "$vip" ]] && { bcm_error "VIP не задан."; bcm_any_key; return; }

    local -a sni_args=() host_args=()
    if [[ -n "$domain" ]]; then
        sni_args=(-servername "$domain")
        host_args=(-H "Host: ${domain}")
    fi

    bcm_info "Какой сертификат отдаёт VIP (SNI: ${domain:-—}):"
    echo | openssl s_client -connect "${vip}:443" "${sni_args[@]}" 2>/dev/null \
        | openssl x509 -noout -subject -issuer -enddate 2>/dev/null \
        | sed 's/^/    /' || bcm_warn "    не удалось получить сертификат с ${vip}:443"
    echo
    bcm_info "HTTP-код ответа https://${domain:-$vip}/ (через VIP, без проверки серта):"
    local code
    if [[ -n "$domain" ]]; then
        code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "${domain}:443:${vip}" \
            "https://${domain}/" 2>/dev/null || echo 000)
    else
        code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${vip}/" 2>/dev/null || echo 000)
    fi
    bcm_info "    HTTP ${code}"
    echo
    bcm_info "Редирект 80→443 (если включён force_https):"
    code=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "${host_args[@]}" \
        "http://${vip}/" 2>/dev/null || echo 000)
    bcm_info "    ${code}"
    bcm_any_key
}

# ──── Меню ───────────────────────────────────────────────────────────────────
_ssl_menu() {
    while true; do
        bcm_section_header "SSL-сертификаты кластера (TLS терминируется на LB/HAProxy)"
        local menu_items=(
            "1.  Статус сертификатов (все LB)"
            "2.  Установить свой сертификат (fullchain + key)"
            "3.  Выпустить сертификат Let's Encrypt (HTTP-01 / DNS-01 Cloudflare)"
            "4.  Продлить Let's Encrypt принудительно"
            "5.  Включить/выключить принудительный HTTPS (redirect)"
            "6.  Проверка HTTPS через VIP"
            "0.  Назад"
        )
        bcm_print_menu menu_items

        local choice
        bcm_read_choice "Введите ваш выбор" choice
        case "$choice" in
            1) _ssl_show_status ;;
            2) _ssl_install_custom ;;
            3) _ssl_issue_le ;;
            4) _ssl_renew_now ;;
            5) _ssl_toggle_https ;;
            6) _ssl_check_https ;;
            0) return 0 ;;
            *) bcm_warn "Неверный выбор." ;;
        esac
    done
}

_ssl_menu
