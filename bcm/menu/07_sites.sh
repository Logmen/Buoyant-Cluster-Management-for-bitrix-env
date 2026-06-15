#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 07_sites.sh — Управление сайтами (интеграция с bitrix-env bx-sites)
# ProxySQL: порт 6033 (не прямой MySQL)
# S3: MinIO endpoint из cluster.conf
# =============================================================================
set -euo pipefail

# ──── Пути и библиотеки ──────────────────────────────────────────────────────
BCM_BASE_DIR="${BCM_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"

source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"

# ──── Загрузить топологию ─────────────────────────────────────────────────────
if ! bcm_conf_exists; then
    bcm_error "cluster.conf не найден. Запустите install.sh."
    exit 1
fi
bcm_load_topology

# ─────────────────────────────────────────────────────────────────────────────
# Вспомогательные функции
# ─────────────────────────────────────────────────────────────────────────────

# Первый web-узел
_sites_web01_ip() {
    local node="${BCM_NODES_WEB[0]:-}"
    echo "${BCM_NODE_IP[$node]:-}"
}

_sites_web01_name() {
    echo "${BCM_NODES_WEB[0]:-}"
}

# Список сайтов через bx-sites
_st_list_sites() {
    bcm_section_header "Список сайтов (bx-sites -a list)"

    local web01_ip
    web01_ip=$(_sites_web01_ip)
    local web01_name
    web01_name=$(_sites_web01_name)

    if [[ -z "$web01_ip" ]]; then
        bcm_error "Не найден web01."
        bcm_any_key; return
    fi

    bcm_info "Запрос списка сайтов на ${web01_name} (${web01_ip}):"
    echo

    local list_output
    list_output=$(bcm_ssh_exec_timeout "$web01_ip" 30 \
        "/opt/webdir/bin/bx-sites -a list 2>/dev/null || /opt/webdir/bin/bx-sites --action=list 2>/dev/null || echo 'ERROR'" \
        2>/dev/null)

    if [[ -z "$list_output" || "$list_output" == *"ERROR"* ]]; then
        bcm_error "bx-sites недоступен или произошла ошибка при запросе списка сайтов."
        bcm_any_key; return
    fi

    # Отрисовка красивой таблицы сайтов
    printf "  %s │ %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Сайт' 20)" "$(bcm_pad 'Каталог' 30)" "$(bcm_pad 'База данных' 15)" \
        "$(bcm_pad 'Тип' 8)" "Статус"
    bcm_divider "${BCM_LINE_H1}"

    local count=0
    while IFS= read -r line; do
        [[ "$line" =~ ^bxSite:general: ]] || continue
        IFS=':' read -r -a fields <<< "$line"
        local s_name="${fields[2]:-?}"
        local s_db="${fields[3]:-?}"
        local s_type="${fields[4]:-?}"
        local s_status="${fields[5]:-?}"
        local s_root="${fields[7]:-?}"

        # Сократить путь если он слишком длинный
        if [[ ${#s_root} -gt 30 ]]; then
            s_root="...${s_root: -27}"
        fi

        printf "  %s │ %s │ %s │ %s │ %s\n" \
            "$(bcm_pad "$s_name" 20)" "$(bcm_pad "$s_root" 30)" "$(bcm_pad "$s_db" 15)" \
            "$(bcm_pad "$s_type" 8)" "$s_status"
        ((count++)) || true
    done <<< "$list_output"

    if [[ $count -eq 0 ]]; then
        # Если не распарсилось, выведем как есть
        echo "$list_output" | sed 's/^/  /'
    fi

    echo
    bcm_any_key
}

# Создать сайт через bx-sites
_st_create_site() {
    bcm_section_header "Создание нового сайта (bx-sites create)"

    local web01_ip
    web01_ip=$(_sites_web01_ip)
    local web01_name
    web01_name=$(_sites_web01_name)

    if [[ -z "$web01_ip" ]]; then
        bcm_error "Не найден web01."
        bcm_any_key; return
    fi

    # Сбор параметров
    local site_name
    bcm_read_choice "Имя сайта (напр. site1 или myshop.example.com)" site_name
    if [[ -z "$site_name" ]]; then
        bcm_warn "Имя сайта не может быть пустым."
        bcm_any_key; return
    fi

    local db_name
    bcm_read_choice "Имя базы данных (напр. ${site_name//./_}_db)" db_name
    db_name="${db_name:-${site_name//./_}_db}"

    local db_user
    bcm_read_choice "Пользователь БД (напр. ${site_name//./_}_user)" db_user
    db_user="${db_user:-${site_name//./_}_user}"

    local db_pass
    bcm_read_choice "Пароль БД" db_pass
    if [[ -z "$db_pass" ]]; then
        bcm_warn "Пароль не может быть пустым."
        bcm_any_key; return
    fi

    local proxysql_port
    proxysql_port=$(bcm_get_proxysql_port 2>/dev/null || echo "6033")
    bcm_info "БД будет настроена через ProxySQL (порт ${proxysql_port})"
    echo

    if ! bcm_confirm "Создать сайт '${site_name}'?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    bcm_info "Запускаем bx-sites create на ${web01_name}..."

    # bx-sites create workflow (интерактив через pty)
    local result
    result=$(bcm_ssh_exec_timeout "$web01_ip" 120 \
        "/opt/webdir/bin/bx-sites -a create \
         --site-name='${site_name}' \
         --db-name='${db_name}' \
         --db-user='${db_user}' \
         --db-password='${db_pass}' \
         --db-host='127.0.0.1' \
         --db-port='${proxysql_port}' \
         2>&1 | tail -20 && echo SITE_CREATED || echo SITE_FAIL" \
        2>/dev/null)

    if [[ "$result" == *"SITE_CREATED"* ]]; then
        bcm_ok "Сайт '${site_name}' создан."
        # Предложить настроить lsyncd для нового каталога
        bcm_info "Рекомендуется добавить директорию сайта в lsyncd (меню 6)."
    else
        bcm_warn "bx-sites вернул результат:"
        echo "$result" | while IFS= read -r line; do echo "  $line"; done
        bcm_info "Проверьте статус сайта через меню '1. Список сайтов'."
    fi

    bcm_any_key
}

# Настроить подключение к БД через ProxySQL
_st_configure_db() {
    bcm_section_header "Настройка подключения к БД через ProxySQL"

    local web01_ip
    web01_ip=$(_sites_web01_ip)
    local web01_name
    web01_name=$(_sites_web01_name)

    local proxysql_port
    proxysql_port=$(bcm_get_proxysql_port 2>/dev/null || echo "6033")

    bcm_info "ProxySQL порт: ${proxysql_port}"
    bcm_info "Все сайты должны использовать 127.0.0.1:${proxysql_port} вместо прямого MySQL."
    echo

    # Список сайтов
    local sites_raw
    sites_raw=$(bcm_ssh_exec_timeout "$web01_ip" 15 \
        "/opt/webdir/bin/bx-sites -a list 2>/dev/null || \
         ls /home/bitrix/ 2>/dev/null | grep -v '^bitrix$' || echo ''" \
        2>/dev/null)

    if [[ -z "$sites_raw" ]]; then
        bcm_warn "Не удалось получить список сайтов."
        bcm_any_key; return
    fi

    local site_name
    bcm_read_choice "Имя сайта для перенастройки (или 'all' для всех)" site_name

    if ! bcm_confirm "Обновить подключение к БД для '${site_name}' → ProxySQL (${proxysql_port})?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    # Обновить dbconn.php для сайтов Bitrix
    local update_script
    if [[ "$site_name" == "all" ]]; then
        update_script=$(cat <<'SCRIPT'
for conf_file in /home/*/www/bitrix/php_interface/dbconn.php \
                 /home/*/www/local/php_interface/dbconn.php \
                 /home/bitrix/www/bitrix/php_interface/dbconn.php; do
    [ -f "$conf_file" ] || continue
    echo "Updating: $conf_file"
    sed -i \
        -e "s/\\\$DBPort = '[0-9]*'/\\\$DBPort = 'PROXYSQL_PORT'/g" \
        -e "s/\\\$DBHost = '[^']*'/\\\$DBHost = '127.0.0.1'/g" \
        "$conf_file"
done
SCRIPT
)
    else
        update_script=$(cat <<SCRIPT
conf_file="/home/${site_name}/www/bitrix/php_interface/dbconn.php"
[ -f "\$conf_file" ] || conf_file="/home/bitrix/www/bitrix/php_interface/dbconn.php"
[ -f "\$conf_file" ] || { echo "dbconn.php не найден"; exit 1; }
echo "Updating: \$conf_file"
sed -i \
    -e "s/\\\\\$DBPort = '[0-9]*'/\\\\\$DBPort = '${proxysql_port}'/g" \
    -e "s/\\\\\$DBHost = '[^']*'/\\\\\$DBHost = '127.0.0.1'/g" \
    "\$conf_file"
SCRIPT
)
    fi

    # Заменить PROXYSQL_PORT на реальный порт
    update_script="${update_script//PROXYSQL_PORT/$proxysql_port}"

    local result
    result=$(echo "$update_script" | bcm_ssh_exec_timeout "$web01_ip" 30 \
        "bash -s 2>&1 && echo DB_OK || echo DB_FAIL" \
        2>/dev/null)

    if [[ "$result" == *"DB_OK"* ]]; then
        bcm_ok "Подключение к БД обновлено → ProxySQL (127.0.0.1:${proxysql_port})."
    else
        bcm_error "Ошибка обновления: ${result}"
    fi

    bcm_any_key
}

# Настроить S3 — значения и отсылка к меню 11
# ⚠️ У /opt/webdir/bin/bx-sites НЕТ действия `-a s3` (реальные: status, email,
# cron, https, create, delete, web — проверено вживую) — прежний вызов всегда
# падал в fallback. Регистрация бакета в модуле «Облачные хранилища» — меню 11.
_st_configure_s3() {
    bcm_section_header "S3 для /upload — настраивается в меню 11"

    bcm_info "Хранилище пользовательских файлов (/upload → MinIO) подключается через"
    bcm_info "модуль Bitrix «Облачные хранилища»: главное меню → 11 (статус, проверка"
    bcm_info "связи, авто-регистрация бакета, значения для админки)."
    echo
    bcm_info "Текущие параметры из cluster.conf [s3_upload]:"
    printf "    %-12s %s\n" "endpoint:" "$(bcm_conf_get s3_upload endpoint 2>/dev/null || echo '—')"
    printf "    %-12s %s\n" "bucket:"   "$(bcm_conf_get s3_upload bucket   2>/dev/null || echo '—')"
    printf "    %-12s %s\n" "region:"   "$(bcm_conf_get s3_upload region   2>/dev/null || echo '—')"
    bcm_any_key
}

# Включить HTTPS — отсылка к меню 12 (TLS терминируется на LB)
# ⚠️ Прежний путь (bx-dehydrated на web01) в кластере НЕ работает: клиентский TLS
# терминируется на HAProxy (LB), серт web-ноды клиент не видит, а HTTP-01
# challenge через VIP round-robin'ом улетает на произвольную ноду.
_st_enable_https() {
    bcm_section_header "HTTPS настраивается централизованно — меню 12"

    bcm_info "TLS терминируется на LB (HAProxy), сертификат един для кластера:"
    bcm_info "  главное меню → 12 «SSL-сертификаты»:"
    bcm_info "    • свой сертификат (fullchain + key) на все LB"
    bcm_info "    • Let's Encrypt: HTTP-01 через LB или DNS-01 Cloudflare"
    bcm_info "    • принудительный редирект 80→443"
    echo
    bcm_warn "Не используйте bx-dehydrated/.htsecure на web-нодах — за TLS-терминатором"
    bcm_warn "это даёт неработающий выпуск и цикл редиректов."
    bcm_any_key
}

# Показать DB connection сайта (проверить ProxySQL)
_st_show_db_connection() {
    bcm_section_header "Подключение к БД (проверка ProxySQL)"

    local web01_ip
    web01_ip=$(_sites_web01_ip)
    local web01_name
    web01_name=$(_sites_web01_name)

    local proxysql_port
    proxysql_port=$(bcm_get_proxysql_port 2>/dev/null || echo "6033")

    bcm_info "Проверка dbconn.php на ${web01_name}:"
    echo

    local result
    result=$(bcm_ssh_exec_timeout "$web01_ip" 15 \
        "for f in /home/*/www/bitrix/php_interface/dbconn.php \
                  /home/bitrix/www/bitrix/php_interface/dbconn.php; do
           [ -f \"\$f\" ] || continue
           echo \"=== \$f ===\"
           grep -E 'DBHost|DBPort|DBName|DBLogin' \"\$f\" 2>/dev/null | head -6
         done" \
        2>/dev/null)

    if [[ -n "$result" ]]; then
        echo "$result" | while IFS= read -r line; do
            echo "  $line"
            # Подсветить ProxySQL
            if echo "$line" | grep -q "$proxysql_port"; then
                bcm_ok "    ^ ProxySQL порт: OK"
            elif echo "$line" | grep -qE "DBPort|3306"; then
                bcm_warn "    ^ ВНИМАНИЕ: прямой MySQL (не ProxySQL)!"
            fi
        done
    else
        bcm_warn "dbconn.php не найден."
    fi

    echo
    bcm_any_key
}

# Запустить lsyncd для нового каталога сайта
_st_trigger_lsyncd() {
    bcm_section_header "Синхронизация нового каталога сайта (lsyncd)"

    local web01_ip
    web01_ip=$(_sites_web01_ip)
    local web01_name
    web01_name=$(_sites_web01_name)

    local site_path
    bcm_read_choice "Путь к новому каталогу сайта (напр. /home/bitrix/www)" site_path
    site_path="${site_path:-/home/bitrix/www}"

    bcm_info "Проверяем lsyncd на ${web01_name}..."

    local lsyncd_st
    lsyncd_st=$(bcm_ssh_service_status "$web01_ip" "lsyncd")

    if [[ "$lsyncd_st" != "active" ]]; then
        bcm_warn "lsyncd не запущен (статус: ${lsyncd_st})."
        bcm_info "Запустите lsyncd через меню 6 (Синхронизация файлов) после деплоя портала."
        bcm_any_key; return
    fi

    # Сигнал lsyncd для принудительной синхронизации
    local result
    result=$(bcm_ssh_exec_timeout "$web01_ip" 15 \
        "kill -HUP \$(cat /var/run/lsyncd.pid 2>/dev/null) 2>/dev/null && \
         echo TRIGGER_OK || echo 'Не удалось отправить HUP lsyncd'" \
        2>/dev/null)

    if [[ "$result" == *"TRIGGER_OK"* ]]; then
        bcm_ok "lsyncd получил сигнал принудительной синхронизации."
    else
        bcm_info "Результат: $result"
    fi

    bcm_any_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Главное меню модуля
# ─────────────────────────────────────────────────────────────────────────────
# ──── Перенастройка .settings.php ПЕРЕНЕСЁННОГО портала (DB+Redis+Push) ───────
# Полная перенастройка существующего .settings.php на инфраструктуру ЭТОГО
# кластера. В отличие от 7→3 (легаси sed по dbconn.php — современный bitrix-env
# реквизитов БД там не держит), правит САМ .settings.php и сразу всё:
#   • БД → ProxySQL (127.0.0.1:port)   • сессии → session-redis VIP
#   • кэш → cache-redis VIP            • push: path_to_publish + security.key
# ⚠️ MERGE, а НЕ перезапись: меняются только инфраструктурные ключи, собственные
# настройки перенесённого портала сохраняются (см. templates/portal_repoint_all.php).
_st_repoint_settings() {
    bcm_section_header "Перенастройка .settings.php перенесённого портала (DB+Redis+Push)"

    # Источник = active_node (источник lsyncd): правки .settings.php там, lsyncd
    # разносит на остальные web. push-конфиги (/etc/push-server) — на каждой ноде.
    local src src_ip
    src=$(bcm_conf_get cluster active_node 2>/dev/null || echo "")
    [[ -z "$src" ]] && src=$(_sites_web01_name)
    src_ip="${BCM_NODE_IP[$src]:-}"
    [[ -z "$src_ip" ]] && src_ip=$(_sites_web01_ip)
    [[ -z "$src_ip" ]] && { bcm_error "Не определить ноду-источник."; bcm_any_key; return; }
    if ! bcm_node_reachable "$src_ip" 5 2>/dev/null; then
        bcm_error "Источник ${src} (${src_ip}) недоступен."; bcm_any_key; return
    fi

    local docroot="/home/bitrix/www"

    # Параметры кластера из cluster.conf
    local pport proxy_host dbuser dbpass svip sport cvip cport pvip pport_redis pubpath
    pport=$(bcm_get_proxysql_port 2>/dev/null || echo "6033"); proxy_host="127.0.0.1:${pport}"
    dbuser=$(bcm_conf_get proxysql bitrix_db_user 2>/dev/null || echo "bitrix")
    dbpass=$(bcm_conf_get proxysql bitrix_db_password 2>/dev/null || echo "")
    svip=$(bcm_conf_get session redis_vip 2>/dev/null || echo ""); sport=$(bcm_conf_get session redis_port 2>/dev/null || echo "")
    cvip=$(bcm_conf_get cache redis_vip 2>/dev/null || echo ""); cport=$(bcm_conf_get cache redis_port 2>/dev/null || echo "")
    pvip=$(bcm_conf_get push redis_vip 2>/dev/null || echo ""); pport_redis=$(bcm_conf_get push redis_port 2>/dev/null || echo "")
    pubpath="http://127.0.0.1:8895/bitrix/pub/"

    # Текущее подключение (и проверка, что портал развёрнут)
    local rd curdb curhost res
    rd=$(bcm_ssh_exec "$src_ip" "BX_DOCROOT='${docroot}' BX_MODE=read php /opt/bcm/templates/db_repoint.php 2>&1" </dev/null)
    res=$(echo "$rd" | sed -n 's/^RESULT=//p' | head -1)
    curdb=$(echo "$rd" | sed -n 's/^DB_NAME=//p' | head -1)
    curhost=$(echo "$rd" | sed -n 's/^DB_HOST=//p' | head -1)
    if [[ "$res" != "OK" ]]; then
        bcm_error "На ${src} нет развёрнутого портала (.settings.php): ${res:-нет ответа}."
        bcm_info "Сначала перенесите файлы портала и его .settings.php на ${src}, затем повторите."
        bcm_any_key; return
    fi

    bcm_info "Источник (lsyncd): ${src} (${src_ip}); docroot ${docroot}"
    bcm_info "Текущее подключение БД: host=${curhost:-?} db=${curdb:-?}"
    echo
    bcm_info "Будет перенастроено (MERGE — собственные настройки портала сохраняются):"
    bcm_info "  • БД      → ProxySQL ${proxy_host} (user ${dbuser})"
    [[ -n "$svip" && -n "$sport" ]] && bcm_info "  • сессии  → redis ${svip}:${sport}" || bcm_warn "  • сессии  — пропуск ([session] не задан в cluster.conf)"
    [[ -n "$cvip" && -n "$cport" ]] && bcm_info "  • кэш     → redis ${cvip}:${cport}" || bcm_warn "  • кэш     — пропуск ([cache] не задан)"
    [[ -n "$pvip" && -n "$pport_redis" ]] && bcm_info "  • push    → redis ${pvip}:${pport_redis} + security.key + path_to_publish" || bcm_warn "  • push    — пропуск ([push] не задан)"
    echo

    # Имя целевой БД в PXC (по умолчанию — текущее из .settings.php)
    local dbname
    bcm_read_choice "Имя БД портала в PXC [${curdb}] (0 — отмена)" dbname
    [[ "${dbname:-0}" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ -z "$dbname" ]] && dbname="$curdb"
    [[ "$dbname" =~ ^[A-Za-z0-9_]+$ ]] || { bcm_error "Недопустимое имя БД."; bcm_any_key; return; }

    bcm_warn "Бэкап .settings.php (.bcm-bak-repoint) снимется автоматически перед записью."
    bcm_confirm "Перенастроить .settings.php портала на инфраструктуру кластера?" \
        || { bcm_info "Отменено."; bcm_any_key; return; }

    # single-quote-safe пароль для удалённого шелла (может содержать спецсимволы)
    local dbpass_q="'${dbpass//\'/\'\\\'\'}'"

    # 1) Правка .settings.php на источнике (merge) — пустые секции шаблон пропускает
    local out sig changed rres
    out=$(bcm_ssh_exec "$src_ip" "BX_DOCROOT='${docroot}' \
        BX_DB_HOST='${proxy_host}' BX_DB_LOGIN='${dbuser}' BX_DB_PASS=${dbpass_q} BX_DB_NAME='${dbname}' \
        BX_SESSION_HOST='${svip}' BX_SESSION_PORT='${sport}' \
        BX_CACHE_HOST='${cvip}' BX_CACHE_PORT='${cport}' \
        BX_PUSH_PUBPATH='${pubpath}' \
        php /opt/bcm/templates/portal_repoint_all.php 2>&1" </dev/null)
    rres=$(echo "$out" | sed -n 's/^RESULT=//p' | head -1)
    changed=$(echo "$out" | sed -n 's/^CHANGED=//p' | head -1)
    sig=$(echo "$out" | sed -n 's/^SIG=//p' | head -1)
    if [[ "$rres" != "OK" ]]; then
        bcm_error ".settings.php НЕ изменён (${rres:-нет ответа}). Портал не сломан."
        bcm_any_key; return
    fi
    bcm_ssh_exec "$src_ip" "chown bitrix:bitrix ${docroot}/bitrix/.settings.php 2>/dev/null || true" </dev/null
    bcm_ok "${src}: .settings.php перенастроен (секции: ${changed:-—}). Бэкап: .bcm-bak-repoint."

    # 2) push-репойнт на ВСЕХ web (security.key=signature_key + storage VIP) + рестарт
    if [[ -n "$pvip" && -n "$pport_redis" ]]; then
        local sig_q="'${sig//\'/\'\\\'\'}'"
        local n nip
        for n in "${BCM_NODES_WEB[@]}"; do
            [[ -z "$n" ]] && continue
            nip="${BCM_NODE_IP[$n]:-}"; [[ -z "$nip" ]] && continue
            if ! bcm_node_reachable "$nip" 5 2>/dev/null; then
                bcm_warn "  ${n}: недоступна — push-конфиги не обновлены."; continue
            fi
            local pr
            pr=$(bcm_ssh_exec "$nip" "php /opt/bcm/templates/push_repoint.php '${pvip}' '${pport_redis}' ${sig_q} 2>&1" </dev/null)
            bcm_ssh_exec "$nip" "systemctl restart push-server 2>/dev/null || true" </dev/null
            bcm_ok "  ${n}: push-server → ${pvip}:${pport_redis} (${pr})"
        done
    fi

    echo
    bcm_ok "Готово. .settings.php разнесётся на остальные web lsyncd'ом (источник — ${src})."
    bcm_info "Проверьте: меню 7→6 (подключение к БД через ProxySQL), 9 (push), и доступность портала."
    bcm_warn "Если меняли php-расширения/опкэш — на каждой web может потребоваться: systemctl restart httpd."
    bcm_any_key
}

_st_menu() {
    while true; do
        bcm_section_header "Управление сайтами"

        local menu_items=(
            "1.  Список сайтов (bx-sites status)"
            "2.  Создать сайт (bx-sites create)"
            "3.  Настроить подключение к БД через ProxySQL"
            "4.  S3 для /upload (→ меню 11, тут только параметры)"
            "5.  HTTPS (→ меню 12: TLS терминируется на LB)"
            "6.  Показать подключение к БД (проверка ProxySQL)"
            "7.  Запустить синхронизацию нового каталога (lsyncd)"
            "8.  Перенастроить .settings.php перенесённого портала (DB+Redis+Push)"
            "0.  Назад"
        )
        bcm_print_menu menu_items

        local choice
        bcm_read_choice "Ваш выбор" choice

        case "$choice" in
            1) _st_list_sites         ;;
            2) _st_create_site        ;;
            3) _st_configure_db       ;;
            4) _st_configure_s3       ;;
            5) _st_enable_https       ;;
            6) _st_show_db_connection ;;
            7) _st_trigger_lsyncd     ;;
            8) _st_repoint_settings   ;;
            0) return 0               ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: ${choice}" ;;
        esac
    done
}

_st_menu
