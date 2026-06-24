#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_runtime.sh — Опрос версий и статусов компонентов кластера в рантайме
# ВСЕ версии получаются командами на живых узлах. Никаких константных версий.
# =============================================================================

# Зависимости: bcm_ssh.sh, bcm_config.sh

# ──── Кэш текущего сеанса (переменные в памяти, не persist) ──────────────────
declare -gA BCM_CACHE_VERSION=()
declare -gA BCM_CACHE_STATUS=()
declare -gA BCM_CACHE_VIPCRON=()

# ──── HAProxy: получить версию ────────────────────────────────────────────────
# Вывод: "HAProxy 2.8.14" или пустая строка при ошибке
bcm_get_haproxy_version() {
    local ip="$1"
    local cache_key="haproxy_ver_${ip}"
    [[ -n "${BCM_CACHE_VERSION[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_VERSION[$cache_key]}" && return

    local raw
    raw=$(bcm_ssh_exec_timeout "$ip" 8 \
        "haproxy -v 2>&1 | head -1" 2>/dev/null)
    # Парсим: "HAProxy version 2.8.14-1ubuntu1, released 2024/04/04"
    local ver=""
    if [[ "$raw" =~ HAProxy[[:space:]]version[[:space:]]([0-9][^,[:space:]]+) ]]; then
        ver="HAProxy ${BASH_REMATCH[1]}"
    elif [[ -n "$raw" ]]; then
        ver="${raw:0:30}"
    fi

    BCM_CACHE_VERSION[$cache_key]="$ver"
    echo "$ver"
}

# ──── bitrix-env: получить версию ────────────────────────────────────────────
# Вывод: "BITRIX_VA_VER=9.0.10" или пустая строка
bcm_get_benv_version() {
    local ip="$1"
    local cache_key="benv_ver_${ip}"
    [[ -n "${BCM_CACHE_VERSION[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_VERSION[$cache_key]}" && return

    local ver=""
    # Источник 1: переменная окружения
    local env_ver
    env_ver=$(bcm_ssh_exec_timeout "$ip" 8 \
        "source /etc/profile 2>/dev/null; echo \"\$BITRIX_VA_VER\"" 2>/dev/null | tr -d '[:space:]')

    if [[ -n "$env_ver" ]]; then
        ver="BITRIX_VA_VER=${env_ver}"
    else
        # Источник 2: rpm пакет
        local rpm_ver
        rpm_ver=$(bcm_ssh_exec_timeout "$ip" 8 \
            "rpm -q bitrix-env --queryformat '%{VERSION}-%{RELEASE}' 2>/dev/null | sed 's/\.el[0-9]*//g'" 2>/dev/null | tr -d '[:space:]')
        [[ -n "$rpm_ver" ]] && ver="BITRIX_VA_VER=${rpm_ver}"
    fi

    BCM_CACHE_VERSION[$cache_key]="$ver"
    echo "$ver"
}

# ──── MinIO: получить версию ──────────────────────────────────────────────────
# Вывод: "minio RELEASE.2025-09-07..." или пустая строка
bcm_get_minio_version() {
    local ip="$1"
    local cache_key="minio_ver_${ip}"
    [[ -n "${BCM_CACHE_VERSION[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_VERSION[$cache_key]}" && return

    local raw
    raw=$(bcm_ssh_exec_timeout "$ip" 8 \
        "minio --version 2>&1 | head -1" 2>/dev/null)
    # Парсим: "minio version RELEASE.2025-09-07T..."
    local ver=""
    if [[ "$raw" =~ RELEASE\.([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        ver="minio RELEASE.${BASH_REMATCH[1]}"
    elif [[ -n "$raw" ]]; then
        ver="${raw:0:30}"
    fi

    BCM_CACHE_VERSION[$cache_key]="$ver"
    echo "$ver"
}

# ──── PXC/MySQL: получить версию ─────────────────────────────────────────────
# Вывод: "8.4.7-27.1" или пустая строка
bcm_get_pxc_version() {
    local ip="$1"
    local cache_key="pxc_ver_${ip}"
    [[ -n "${BCM_CACHE_VERSION[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_VERSION[$cache_key]}" && return

    local raw
    raw=$(bcm_ssh_exec_timeout "$ip" 8 \
        "mysql -N -e 'SELECT @@version;' 2>/dev/null || mysqld --version 2>&1 | head -1" 2>/dev/null)
    # Парсим: "8.4.7-27.1-PXC" или "8.0.45-36" (standalone Percona)
    local ver=""
    if [[ "$raw" =~ ^([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*) ]]; then
        ver="${BASH_REMATCH[1]}"
        # Убрать суффикс типа "-PXC" для унификации
        ver="${ver%%-PXC*}"
    fi

    BCM_CACHE_VERSION[$cache_key]="$ver"
    echo "$ver"
}

# ──── Nginx: версия (на web-нодах) ───────────────────────────────────────────
bcm_get_nginx_version() {
    local ip="$1"
    local cache_key="nginx_ver_${ip}"
    [[ -n "${BCM_CACHE_VERSION[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_VERSION[$cache_key]}" && return

    local raw
    raw=$(bcm_ssh_exec_timeout "$ip" 8 \
        "nginx -v 2>&1 | head -1" 2>/dev/null)
    local ver=""
    if [[ "$raw" =~ nginx/([0-9][^[:space:]]+) ]]; then
        ver="nginx/${BASH_REMATCH[1]}"
    fi

    BCM_CACHE_VERSION[$cache_key]="$ver"
    echo "$ver"
}

# ──── Health-check: lb-узел ───────────────────────────────────────────────────
# ok | fail
bcm_check_lb_health() {
    local ip="$1"
    local cache_key="health_lb_${ip}"
    [[ -n "${BCM_CACHE_STATUS[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_STATUS[$cache_key]}" && return

    local status="fail"

    if ! bcm_ssh_reachable "$ip" 5; then
        BCM_CACHE_STATUS[$cache_key]="fail"
        echo "fail"
        return
    fi

    # HAProxy должен работать
    local haproxy_active
    haproxy_active=$(bcm_ssh_service_status "$ip" "haproxy")

    # Keepalived должен работать
    local keepalived_active
    keepalived_active=$(bcm_ssh_service_status "$ip" "keepalived")

    if [[ "$haproxy_active" == "active" && "$keepalived_active" == "active" ]]; then
        status="ok"
    fi

    BCM_CACHE_STATUS[$cache_key]="$status"
    echo "$status"
}

# ──── Health-check: web-узел ──────────────────────────────────────────────────
bcm_check_web_health() {
    local ip="$1"
    local cache_key="health_web_${ip}"
    [[ -n "${BCM_CACHE_STATUS[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_STATUS[$cache_key]}" && return

    local status="fail"

    if ! bcm_ssh_reachable "$ip" 5; then
        BCM_CACHE_STATUS[$cache_key]="fail"
        echo "fail"
        return
    fi

    # Nginx + httpd должны работать
    local nginx_st httpd_st
    nginx_st=$(bcm_ssh_service_status "$ip" "nginx")
    httpd_st=$(bcm_ssh_service_status "$ip" "httpd")

    if [[ "$nginx_st" == "active" && "$httpd_st" == "active" ]]; then
        status="ok"
    fi

    BCM_CACHE_STATUS[$cache_key]="$status"
    echo "$status"
}

# ──── Health-check: PXC-узел ─────────────────────────────────────────────────
bcm_check_pxc_health() {
    local ip="$1"
    local cache_key="health_pxc_${ip}"
    [[ -n "${BCM_CACHE_STATUS[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_STATUS[$cache_key]}" && return

    local status="fail"

    if ! bcm_ssh_reachable "$ip" 5; then
        BCM_CACHE_STATUS[$cache_key]="fail"
        echo "fail"
        return
    fi

    # Galera: wsrep_cluster_status=Primary AND wsrep_ready=ON
    local wsrep_status wsrep_ready
    wsrep_status=$(bcm_ssh_exec_timeout "$ip" 10 \
        "mysql -N -e \"SHOW STATUS LIKE 'wsrep_cluster_status'\" 2>/dev/null | awk '{print \$2}'" 2>/dev/null | tr -d '[:space:]')
    wsrep_ready=$(bcm_ssh_exec_timeout "$ip" 10 \
        "mysql -N -e \"SHOW STATUS LIKE 'wsrep_ready'\" 2>/dev/null | awk '{print \$2}'" 2>/dev/null | tr -d '[:space:]')

    if [[ "$wsrep_status" == "Primary" && "$wsrep_ready" == "ON" ]]; then
        status="ok"
    elif [[ -z "$wsrep_status" ]]; then
        # Не PXC — проверяем просто MySQL
        local mysql_st
        mysql_st=$(bcm_ssh_service_status "$ip" "mysqld")
        [[ "$mysql_st" == "active" ]] && status="warn"   # MySQL работает, но не в кластере
    fi

    BCM_CACHE_STATUS[$cache_key]="$status"
    echo "$status"
}

# ──── Health-check: s3-узел ───────────────────────────────────────────────────
bcm_check_s3_health() {
    local ip="$1"
    local s3_port
    s3_port=$(bcm_get_s3_port 2>/dev/null || echo "9000")
    local cache_key="health_s3_${ip}"
    [[ -n "${BCM_CACHE_STATUS[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_STATUS[$cache_key]}" && return

    local status="fail"

    if ! bcm_ssh_reachable "$ip" 5; then
        BCM_CACHE_STATUS[$cache_key]="fail"
        echo "fail"
        return
    fi

    # MinIO health endpoint. MinIO слушает HTTPS (см. install.sh::configure_s3_tls) —
    # http теперь вернул бы 400. CA серта доверен на ноде → https://localhost (SAN
    # включает localhost) проходит без -k; --fail откатывает на http для до-TLS кластеров.
    local health
    health=$(bcm_ssh_exec_timeout "$ip" 8 \
        "curl -sf https://localhost:${s3_port}/minio/health/live >/dev/null 2>&1 && echo ok || \
         { curl -sf http://localhost:${s3_port}/minio/health/live >/dev/null 2>&1 && echo ok || echo fail; }" 2>/dev/null | tr -d '[:space:]')

    [[ "$health" == "ok" ]] && status="ok"

    BCM_CACHE_STATUS[$cache_key]="$status"
    echo "$status"
}

# ──── VIP: определить, кто держит плавающий адрес ────────────────────────────
# Возвращает имя lb-узла или пустую строку
bcm_get_vip_holder() {
    local vip="$1"
    local cache_key="vip_holder_${vip}"
    [[ -n "${BCM_CACHE_VIPCRON[$cache_key]+x}" ]] && \
        echo "${BCM_CACHE_VIPCRON[$cache_key]}" && return

    local holder=""
    local nodes
    nodes=$(bcm_get_nodes "lb") || { echo ""; return; }

    for node in $nodes; do
        local ip
        ip=$(bcm_get_node_ip "lb" "$node") || continue
        if ! bcm_ssh_reachable "$ip" 3; then
            continue
        fi
        local has_vip
        has_vip=$(bcm_ssh_exec_timeout "$ip" 5 \
            "ip addr show | grep -c '${vip}' 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')
        if [[ "${has_vip:-0}" -gt 0 ]]; then
            holder="$node"
            break
        fi
    done

    BCM_CACHE_VIPCRON[$cache_key]="$holder"
    echo "$holder"
}

# ──── VRRP роль lb-узла (MASTER/BACKUP) ──────────────────────────────────────
# Определяется фактом: держит ли узел VIP
bcm_get_lb_vrrp_role() {
    local node="$1"
    local vip
    vip=$(bcm_get_vip 2>/dev/null) || { echo "BACKUP"; return; }

    local vip_holder
    vip_holder=$(bcm_get_vip_holder "$vip")

    if [[ "$vip_holder" == "$node" ]]; then
        echo "MASTER"
    else
        echo "BACKUP"
    fi
}

# ──── HA Cron: кто держит Keepalived VRID для веб-нод ────────────────────────
bcm_get_cron_vrrp_holder() {
    local force_refresh=0
    if [[ "${1:-}" == "--force" || "${1:-}" == "force" ]]; then
        force_refresh=1
    fi

    local vrid
    vrid=$(bcm_get_web_vrid 2>/dev/null || echo "56")
    local cache_key="cron_vrid_${vrid}"
    if [[ $force_refresh -eq 0 ]]; then
        [[ -n "${BCM_CACHE_VIPCRON[$cache_key]+x}" ]] && \
            echo "${BCM_CACHE_VIPCRON[$cache_key]}" && return
    fi

    local holder=""
    local nodes
    nodes=$(bcm_get_nodes "web") || { echo ""; return; }

    for node in $nodes; do
        local ip
        ip=$(bcm_get_node_ip "web" "$node") || continue
        if ! bcm_ssh_reachable "$ip" 3; then continue; fi
        local state
        state=$(bcm_ssh_exec_timeout "$ip" 5 \
            "ip addr show dev lo 2>/dev/null | grep -q '127.0.0.254' && echo 1 || echo 0" 2>/dev/null | head -1 | tr -d '[:space:]')
        if [[ "${state:-0}" -eq 1 ]]; then
            holder="$node"
            break
        fi
    done

    BCM_CACHE_VIPCRON[$cache_key]="$holder"
    echo "$holder"
}

# ──── Версия BCM (читается из файла) ─────────────────────────────────────────
bcm_get_app_version() {
    local ver_file="${BCM_BASE_DIR:-/opt/bcm}/VERSION"
    if [[ -f "$ver_file" ]]; then
        tr -d '[:space:]' < "$ver_file"
    else
        echo "1.0.0"
    fi
}

# ──── Версия bitrix-env на локальном узле ─────────────────────────────────────
bcm_get_local_benv_version() {
    local ver=""
    # Источник 1: переменная окружения
    if [[ -n "${BITRIX_VA_VER:-}" ]]; then
        ver="$BITRIX_VA_VER"
    else
        # Источник 2: /etc/profile
        ver=$(grep 'BITRIX_VA_VER=' /etc/profile 2>/dev/null | tail -1 | \
            sed "s/.*BITRIX_VA_VER=['\"]\\?\\([^'\"[:space:]]*\\)['\"]\\?.*/\\1/")
    fi

    if [[ -z "$ver" ]]; then
        # Источник 3: rpm
        ver=$(rpm -q bitrix-env \
            --queryformat '%{VERSION}.%{RELEASE}' 2>/dev/null | \
            sed 's/\.el[0-9]*$//')
    fi

    echo "${ver:-unknown}"
}

# ──── Галера WSREP статус на узле ────────────────────────────────────────────
# Возвращает ассоциативный массив через stdout: "key=value" строки
bcm_get_galera_status() {
    local ip="$1"
    bcm_ssh_exec_timeout "$ip" 10 \
        "mysql -N -e \"SHOW STATUS LIKE 'wsrep%'\" 2>/dev/null | \
         grep -E 'wsrep_cluster_status|wsrep_ready|wsrep_cluster_size|wsrep_local_state_comment|wsrep_incoming_addresses'" 2>/dev/null
}

# ──── ProxySQL: статус на web-узле ───────────────────────────────────────────
bcm_get_proxysql_status() {
    local ip="$1"
    local admin_port admin_user admin_pass
    admin_port=$(bcm_get_proxysql_admin_port 2>/dev/null || echo "6032")
    admin_user=$(bcm_get_proxysql_admin_user 2>/dev/null || echo "admin")
    admin_pass=$(bcm_get_proxysql_admin_pass 2>/dev/null || echo "admin")

    # ProxySQL принимает пароль ТОЛЬКО как -p<pass> (MYSQL_PWD/defaults-file
    # отвергаются клиентом MySQL 8 при коннекте к ProxySQL). --default-auth нужен
    # для совместимости с native. Команда не логируется (bcm_ssh_exec_timeout).
    bcm_ssh_exec_timeout "$ip" 10 \
        "mysql --default-auth=mysql_native_password -h127.0.0.1 -P${admin_port} -u${admin_user} -p'${admin_pass}' \
         -e 'SELECT hostgroup_id,hostname,status,weight FROM mysql_servers ORDER BY hostgroup_id;' \
         2>/dev/null" 2>/dev/null
}

# ──── PXC: фактический writer по runtime ProxySQL (не из конфига) ─────────────
# Возвращает ИМЯ pxc-ноды, которую ProxySQL держит в HG_WRITE со статусом ONLINE.
# galera-checker может сменить writer после failover/рестарта писателя — тогда
# [layer.pxc] writer в конфиге устаревает. Опрашивается через ProxySQL admin на
# первой живой web-ноде. Пусто → вызывающий откатывается на конфиг.
bcm_get_pxc_runtime_writer() {
    local node web_ip=""
    for node in "${BCM_NODES_WEB[@]}"; do
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if bcm_node_reachable "$ip" 3 2>/dev/null; then web_ip="$ip"; break; fi
    done
    [[ -z "$web_ip" ]] && return 1

    local admin_port admin_user admin_pass hg_write
    admin_port=$(bcm_get_proxysql_admin_port 2>/dev/null || echo "6032")
    admin_user=$(bcm_get_proxysql_admin_user 2>/dev/null || echo "admin")
    admin_pass=$(bcm_get_proxysql_admin_pass 2>/dev/null || echo "admin")
    hg_write=$(bcm_get_proxysql_hg_write 2>/dev/null || echo "10")

    # Пароль ТОЛЬКО как -p<pass> (см. гочу про ProxySQL CLI); команда не логируется.
    local writer_ip
    writer_ip=$(bcm_ssh_exec_timeout "$web_ip" 10 \
        "mysql --default-auth=mysql_native_password -h127.0.0.1 -P${admin_port} -u${admin_user} -p'${admin_pass}' \
         -N -e \"SELECT hostname FROM runtime_mysql_servers WHERE hostgroup_id=${hg_write} AND status='ONLINE' ORDER BY weight DESC LIMIT 1;\" \
         2>/dev/null" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$writer_ip" ]] && return 1

    # IP → имя ноды (если не нашли — вернём IP, чтобы хоть что-то показать)
    for node in "${BCM_NODES_PXC[@]}"; do
        [[ "${BCM_NODE_IP[$node]:-}" == "$writer_ip" ]] && { echo "$node"; return 0; }
    done
    echo "$writer_ip"
    return 0
}

# ──── lsyncd статус ───────────────────────────────────────────────────────────
bcm_check_lsyncd_status() {
    local ip="$1"
    bcm_ssh_service_status "$ip" "lsyncd"
}

# ──── bx-push-server статус ───────────────────────────────────────────────────
bcm_check_push_status() {
    local ip="$1" st
    # bitrix-env 9: umbrella-юнит называется push-server (НЕ bx-push-server).
    # ⚠️ Прежний `is-active 'bx-push-server*' | head -1 || ...` всегда возвращал пусто:
    # глоб без совпадений → пустой вывод, но pipe-код = код head(0) → fallback не
    # срабатывал, колонка «Статус» пустела (ловили вживую).
    st=$(bcm_ssh_exec_timeout "$ip" 8 \
        "systemctl is-active push-server 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]')
    echo "${st:-unknown}"
}

# ──── Очистить кэш (для принудительного обновления) ──────────────────────────
bcm_clear_cache() {
    BCM_CACHE_VERSION=()
    BCM_CACHE_STATUS=()
    BCM_CACHE_VIPCRON=()
}

