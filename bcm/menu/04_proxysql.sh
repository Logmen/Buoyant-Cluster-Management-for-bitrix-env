#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 04_proxysql.sh — Управление ProxySQL
#
# ProxySQL встроен в web-узлы (порт 6033 — proxy, 6032 — admin).
# Не является отдельным типом нод.
#
# Функционал:
#   - Статус mysql_servers (HG10 write, HG20 read) на каждой web-ноде
#   - Показ правил маршрутизации (mysql_query_rules)
#   - Перестройка HG10/HG20 из cluster.conf
#   - Добавить/удалить реплику из HG20 (read)
#   - Статистика stats_mysql_connection_pool
#   - Перезапуск ProxySQL на всех web-нодах
#   - Синхронизация конфига между web-нодами
#
# Все данные — из cluster.conf через bcm_config.sh / bcm_runtime.sh
# =============================================================================
set -euo pipefail

# ──── Загрузка библиотек ─────────────────────────────────────────────────────
source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"

# ──── Вспомогательные переменные (из cluster.conf) ───────────────────────────
_psql_get_admin_port() { bcm_get_proxysql_admin_port 2>/dev/null || echo "6032"; }
_psql_get_admin_user() { bcm_get_proxysql_admin_user 2>/dev/null || echo "admin"; }
_psql_get_admin_pass() { bcm_get_proxysql_admin_pass 2>/dev/null || echo "admin"; }
_psql_get_hg_write()   { bcm_get_proxysql_hg_write   2>/dev/null || echo "10"; }
_psql_get_hg_read()    { bcm_get_proxysql_hg_read    2>/dev/null || echo "20"; }
_psql_get_proxy_port() { bcm_get_proxysql_port        2>/dev/null || echo "6033"; }

# Выполнить SQL в ProxySQL admin на конкретной web-ноде
_psql_admin_query() {
    local web_ip="$1"
    local sql="$2"
    local admin_port admin_user admin_pass
    admin_port=$(_psql_get_admin_port)
    admin_user=$(_psql_get_admin_user)
    admin_pass=$(_psql_get_admin_pass)

    # ProxySQL принимает пароль только как -p<pass> (не MYSQL_PWD/defaults-file).
    bcm_ssh_exec "$web_ip" \
        "mysql --default-auth=mysql_native_password -h127.0.0.1 -P${admin_port} -u${admin_user} -p'${admin_pass}' \
         --table -e \"${sql}\" 2>/dev/null" 2>/dev/null
}

# Выполнить SQL в ProxySQL admin на web-ноде и вернуть raw вывод
_psql_admin_raw() {
    local web_ip="$1"
    local sql="$2"
    local admin_port admin_user admin_pass
    admin_port=$(_psql_get_admin_port)
    admin_user=$(_psql_get_admin_user)
    admin_pass=$(_psql_get_admin_pass)

    # ProxySQL принимает пароль только как -p<pass> (не MYSQL_PWD/defaults-file).
    bcm_ssh_exec "$web_ip" \
        "mysql --default-auth=mysql_native_password -h127.0.0.1 -P${admin_port} -u${admin_user} -p'${admin_pass}' \
         -N -e \"${sql}\" 2>/dev/null" 2>/dev/null
}

# Получить список web-нод (массив)
_psql_get_web_nodes() {
    local -n _out_nodes=$1
    local web_str
    web_str=$(bcm_get_nodes "web" 2>/dev/null) || { _out_nodes=(); return 1; }
    [[ -z "$web_str" ]] && { _out_nodes=(); return 1; }
    read -ra _out_nodes <<< "$web_str"
}

# ──── Показать статус mysql_servers ──────────────────────────────────────────
_psql_show_status() {
    bcm_section_header "Статус ProxySQL — mysql_servers"

    local -a web_nodes
    if ! _psql_get_web_nodes web_nodes || [[ ${#web_nodes[@]} -eq 0 ]]; then
        bcm_warn "Web-узлы не найдены в cluster.conf."
        bcm_any_key
        return
    fi

    local hg_write hg_read proxy_port
    hg_write=$(_psql_get_hg_write)
    hg_read=$(_psql_get_hg_read)
    proxy_port=$(_psql_get_proxy_port)

    bcm_info "HG Write: ${hg_write}  |  HG Read: ${hg_read}  |  Proxy port: ${proxy_port}"
    echo

    for web_node in "${web_nodes[@]}"; do
        [[ -z "$web_node" ]] && continue
        local web_ip
        web_ip=$(bcm_get_node_ip "web" "$web_node" 2>/dev/null) || continue

        bcm_color "WHITE" "  ── ${web_node} (${web_ip}) ──"

        if ! bcm_ssh_reachable "$web_ip" 5 2>/dev/null; then
            bcm_echo_color "RED_BOLD" "  Узел недоступен"
            echo
            continue
        fi

        # Проверить, что ProxySQL запущен
        local psql_active
        psql_active=$(bcm_ssh_service_status "$web_ip" "proxysql" 2>/dev/null || echo "unknown")
        if [[ "$psql_active" != "active" ]]; then
            bcm_echo_color "YELLOW_BOLD" "  ProxySQL не активен (статус: ${psql_active})"
            echo
            continue
        fi

        echo "  mysql_servers:"
        local result
        result=$(_psql_admin_query "$web_ip" \
            "SELECT hostgroup_id AS HG, hostname, port, status, weight, max_connections
             FROM mysql_servers
             ORDER BY hostgroup_id, hostname;" 2>/dev/null)
        if [[ -n "$result" ]]; then
            echo "$result" | sed 's/^/  /'
        else
            bcm_warn "  Таблица mysql_servers пуста или ProxySQL admin недоступен."
        fi
        echo

        # Runtime vs disk
        local runtime_hash disk_hash
        runtime_hash=$(_psql_admin_raw "$web_ip" \
            "SELECT checksum FROM stats_mysql_global WHERE variable_name='ProxySQL_Uptime' LIMIT 1;" 2>/dev/null || echo "")
        echo "  ProxySQL uptime:"
        _psql_admin_query "$web_ip" \
            "SELECT variable_name, variable_value FROM stats_mysql_global
             WHERE variable_name IN ('ProxySQL_Uptime','Questions','Client_Connections_connected','Client_Connections_created')
             ORDER BY variable_name;" 2>/dev/null | sed 's/^/  /'
        echo
    done

    bcm_any_key
}

# ──── Показать правила маршрутизации ─────────────────────────────────────────
_psql_show_query_rules() {
    bcm_section_header "Правила маршрутизации ProxySQL (mysql_query_rules)"

    local -a web_nodes
    if ! _psql_get_web_nodes web_nodes || [[ ${#web_nodes[@]} -eq 0 ]]; then
        bcm_warn "Web-узлы не найдены."; bcm_any_key; return
    fi

    # Берём первую доступную web-ноду
    local web_ip=""
    local web_node_name=""
    for wn in "${web_nodes[@]}"; do
        [[ -z "$wn" ]] && continue
        local wip
        wip=$(bcm_get_node_ip "web" "$wn" 2>/dev/null) || continue
        if bcm_ssh_reachable "$wip" 5 2>/dev/null; then
            web_ip="$wip"
            web_node_name="$wn"
            break
        fi
    done

    if [[ -z "$web_ip" ]]; then
        bcm_error "Ни одна web-нода недоступна."
        bcm_any_key
        return
    fi

    bcm_info "Данные с ${web_node_name} (${web_ip}):"
    echo

    _psql_admin_query "$web_ip" \
        "SELECT rule_id, active, match_digest, destination_hostgroup, apply
         FROM mysql_query_rules
         ORDER BY rule_id;" 2>/dev/null | sed 's/^/  /'
    echo

    bcm_any_key
}

# ──── Перестроить HG10/HG20 из cluster.conf ───────────────────────────────────
_psql_reconfigure() {
    bcm_section_header "Перестройка ProxySQL HG (из cluster.conf)"

    local hg_write hg_read admin_port admin_user admin_pass
    hg_write=$(_psql_get_hg_write)
    hg_read=$(_psql_get_hg_read)
    admin_port=$(_psql_get_admin_port)
    admin_user=$(_psql_get_admin_user)
    admin_pass=$(_psql_get_admin_pass)

    # Текущий writer
    local writer
    writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")
    if [[ -z "$writer" ]]; then
        bcm_error "Writer не задан в cluster.conf. Установите writer в меню PXC."
        bcm_any_key
        return
    fi

    local writer_ip
    writer_ip=$(bcm_get_node_ip "pxc" "$writer" 2>/dev/null) || {
        bcm_error "IP для writer '${writer}' не найден."
        bcm_any_key
        return
    }

    # Все PXC-узлы
    local pxc_str
    pxc_str=$(bcm_get_nodes "pxc" 2>/dev/null) || { bcm_error "PXC-узлы не найдены."; bcm_any_key; return; }
    local pxc_arr
    read -ra pxc_arr <<< "$pxc_str"

    bcm_info "Writer (HG${hg_write}): ${writer} (${writer_ip})"
    echo "  Узлы PXC (HG${hg_read} — read):"
    for pxc_node in "${pxc_arr[@]}"; do
        [[ -z "$pxc_node" ]] && continue
        local pip
        pip=$(bcm_get_node_ip "pxc" "$pxc_node" 2>/dev/null) || pip="?"
        local role_label="reader"
        [[ "$pxc_node" == "$writer" ]] && role_label="writer"
        printf "  %-14s %-16s [%s]\n" "$pxc_node" "$pip" "$role_label"
    done
    echo

    local -a web_nodes
    if ! _psql_get_web_nodes web_nodes || [[ ${#web_nodes[@]} -eq 0 ]]; then
        bcm_error "Web-узлы не найдены."; bcm_any_key; return
    fi

    if ! bcm_confirm "Перестроить mysql_servers на всех web-нодах (очистить и заполнить заново)?"; then
        bcm_info "Отменено."
        bcm_any_key
        return
    fi

    for web_node in "${web_nodes[@]}"; do
        [[ -z "$web_node" ]] && continue
        local web_ip
        web_ip=$(bcm_get_node_ip "web" "$web_node" 2>/dev/null) || continue

        if ! bcm_ssh_reachable "$web_ip" 5 2>/dev/null; then
            bcm_warn "  ${web_node} недоступен — пропущен."
            continue
        fi

        bcm_info "  Обновление ${web_node} (${web_ip})..."

        # Строим SQL: DELETE + INSERT для каждого PXC-узла
        local sql_block=""
        sql_block+="DELETE FROM mysql_servers WHERE hostgroup_id IN (${hg_write},${hg_read});"

        # Writer → HG write
        sql_block+="INSERT INTO mysql_servers(hostgroup_id,hostname,port,weight,max_connections)
            VALUES(${hg_write},'${writer_ip}',3306,1000,1000);"

        # Все PXC-узлы → HG read
        for pxc_node in "${pxc_arr[@]}"; do
            [[ -z "$pxc_node" ]] && continue
            local pip
            pip=$(bcm_get_node_ip "pxc" "$pxc_node" 2>/dev/null) || continue
            local read_weight=100
            # Writer тоже в HG read (с меньшим весом)
            [[ "$pxc_node" == "$writer" ]] && read_weight=50
            sql_block+="INSERT IGNORE INTO mysql_servers(hostgroup_id,hostname,port,weight,max_connections)
                VALUES(${hg_read},'${pip}',3306,${read_weight},1000);"
        done

        sql_block+="LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;"

        local result
        result=$(bcm_ssh_exec "$web_ip" \
            "mysql --default-auth=mysql_native_password -h127.0.0.1 -P${admin_port} -u${admin_user} -p'${admin_pass}' \
             -e \"${sql_block}\" 2>&1" 2>/dev/null)

        if [[ $? -eq 0 ]]; then
            bcm_ok "  ${web_node}: конфигурация применена."
        else
            bcm_warn "  ${web_node}: ошибка: ${result:0:100}"
        fi
    done

    echo
    bcm_log_info "ProxySQL HG${hg_write}/${hg_read} перестроены из cluster.conf (writer=${writer})"
    bcm_any_key
}

# ──── Добавить/удалить реплику из HG read ─────────────────────────────────────
_psql_manage_read_replica() {
    bcm_section_header "Управление репликами в HG read"

    local hg_read admin_port admin_user
    hg_read=$(_psql_get_hg_read)
    admin_port=$(_psql_get_admin_port)
    admin_user=$(_psql_get_admin_user)

    # Берём первую доступную web-ноду для запроса данных
    local -a web_nodes
    _psql_get_web_nodes web_nodes || true
    local ref_ip=""
    for wn in "${web_nodes[@]}"; do
        [[ -z "$wn" ]] && continue
        local wip
        wip=$(bcm_get_node_ip "web" "$wn" 2>/dev/null) || continue
        bcm_ssh_reachable "$wip" 5 2>/dev/null && { ref_ip="$wip"; break; }
    done

    if [[ -z "$ref_ip" ]]; then
        bcm_error "Ни одна web-нода недоступна."
        bcm_any_key
        return
    fi

    # Текущие серверы в HG read
    bcm_info "Текущие серверы в HG${hg_read} (read):"
    _psql_admin_query "$ref_ip" \
        "SELECT hostname, port, status, weight FROM mysql_servers
         WHERE hostgroup_id=${hg_read} ORDER BY hostname;" 2>/dev/null | sed 's/^/  /'
    echo

    echo "  Действия:"
    echo "    1. Добавить сервер в HG${hg_read}"
    echo "    2. Удалить сервер из HG${hg_read}"
    echo "    0. Назад"
    echo

    local action
    bcm_read_choice "Выберите действие" action

    case "$action" in
        1)
            local new_host new_port new_weight
            bcm_read_choice "IP-адрес нового сервера" new_host
            if ! bcm_valid_ip "$new_host"; then
                bcm_error "Некорректный IP: ${new_host}"
                bcm_any_key
                return
            fi
            bcm_read_choice "Порт (Enter = 3306)" new_port
            [[ -z "$new_port" ]] && new_port="3306"
            bcm_read_choice "Вес (Enter = 100)" new_weight
            [[ -z "$new_weight" || ! "$new_weight" =~ ^[0-9]+$ ]] && new_weight="100"

            echo
            if ! bcm_confirm "Добавить ${new_host}:${new_port} (вес ${new_weight}) в HG${hg_read} на всех web-нодах?"; then
                bcm_info "Отменено."
                bcm_any_key
                return
            fi

            for web_node in "${web_nodes[@]}"; do
                [[ -z "$web_node" ]] && continue
                local web_ip
                web_ip=$(bcm_get_node_ip "web" "$web_node" 2>/dev/null) || continue
                if ! bcm_ssh_reachable "$web_ip" 5 2>/dev/null; then
                    bcm_warn "  ${web_node}: недоступен — пропущен."
                    continue
                fi
                local r
                r=$(_psql_admin_raw "$web_ip" \
                    "INSERT IGNORE INTO mysql_servers(hostgroup_id,hostname,port,weight)
                     VALUES(${hg_read},'${new_host}',${new_port},${new_weight});
                     LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;" 2>/dev/null)
                bcm_ok "  ${web_node}: ${new_host}:${new_port} добавлен в HG${hg_read}."
            done
            bcm_log_info "ProxySQL HG${hg_read}: добавлен ${new_host}:${new_port} (weight=${new_weight})"
            ;;
        2)
            local del_host
            bcm_read_choice "IP-адрес сервера для удаления из HG${hg_read}" del_host
            if [[ -z "$del_host" ]]; then
                bcm_error "IP не может быть пустым."
                bcm_any_key
                return
            fi

            echo
            if ! bcm_confirm "Удалить ${del_host} из HG${hg_read} на всех web-нодах?"; then
                bcm_info "Отменено."
                bcm_any_key
                return
            fi

            for web_node in "${web_nodes[@]}"; do
                [[ -z "$web_node" ]] && continue
                local web_ip
                web_ip=$(bcm_get_node_ip "web" "$web_node" 2>/dev/null) || continue
                if ! bcm_ssh_reachable "$web_ip" 5 2>/dev/null; then
                    bcm_warn "  ${web_node}: недоступен — пропущен."
                    continue
                fi
                _psql_admin_raw "$web_ip" \
                    "DELETE FROM mysql_servers WHERE hostgroup_id=${hg_read} AND hostname='${del_host}';
                     LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;" 2>/dev/null
                bcm_ok "  ${web_node}: ${del_host} удалён из HG${hg_read}."
            done
            bcm_log_info "ProxySQL HG${hg_read}: удалён ${del_host}"
            ;;
        0|"")
            return
            ;;
        *)
            bcm_warn "Неверный выбор."
            ;;
    esac

    bcm_any_key
}

# ──── Статистика пула соединений ─────────────────────────────────────────────
_psql_show_stats() {
    bcm_section_header "Статистика ProxySQL — Connection Pool"

    local -a web_nodes
    if ! _psql_get_web_nodes web_nodes || [[ ${#web_nodes[@]} -eq 0 ]]; then
        bcm_warn "Web-узлы не найдены."; bcm_any_key; return
    fi

    for web_node in "${web_nodes[@]}"; do
        [[ -z "$web_node" ]] && continue
        local web_ip
        web_ip=$(bcm_get_node_ip "web" "$web_node" 2>/dev/null) || continue

        bcm_color "WHITE" "  ── ${web_node} (${web_ip}) ──"

        if ! bcm_ssh_reachable "$web_ip" 5 2>/dev/null; then
            bcm_echo_color "RED_BOLD" "  Узел недоступен"
            echo
            continue
        fi

        echo "  stats_mysql_connection_pool:"
        _psql_admin_query "$web_ip" \
            "SELECT hostgroup, srv_host, srv_port, status,
                    ConnUsed, ConnFree, ConnOK, ConnERR,
                    Queries, Bytes_data_sent, Bytes_data_recv
             FROM stats_mysql_connection_pool
             ORDER BY hostgroup, srv_host;" 2>/dev/null | sed 's/^/  /'
        echo

        echo "  stats_mysql_global (ключевые):"
        _psql_admin_query "$web_ip" \
            "SELECT variable_name, variable_value
             FROM stats_mysql_global
             WHERE variable_name IN (
                 'Client_Connections_connected',
                 'Client_Connections_created',
                 'Client_Connections_aborted',
                 'Questions',
                 'Slow_queries',
                 'MySQL_Monitor_connect_check_OK_total',
                 'MySQL_Monitor_connect_check_ERR_total'
             ) ORDER BY variable_name;" 2>/dev/null | sed 's/^/  /'
        echo
    done

    bcm_any_key
}

# ──── Перезапуск ProxySQL на всех web-нодах ──────────────────────────────────
_psql_restart_all() {
    bcm_section_header "Перезапуск ProxySQL на всех web-нодах"

    local -a web_nodes
    if ! _psql_get_web_nodes web_nodes || [[ ${#web_nodes[@]} -eq 0 ]]; then
        bcm_warn "Web-узлы не найдены."; bcm_any_key; return
    fi

    bcm_warn "ProxySQL будет перезапущен на всех web-нодах."
    bcm_warn "Кратковременный разрыв соединений с БД возможен!"
    echo

    if ! bcm_confirm "Перезапустить ProxySQL на всех web-нодах?"; then
        bcm_info "Отменено."
        bcm_any_key
        return
    fi

    for web_node in "${web_nodes[@]}"; do
        [[ -z "$web_node" ]] && continue
        local web_ip
        web_ip=$(bcm_get_node_ip "web" "$web_node" 2>/dev/null) || continue

        if ! bcm_ssh_reachable "$web_ip" 5 2>/dev/null; then
            bcm_warn "  ${web_node} недоступен — пропущен."
            continue
        fi

        bcm_info "  Перезапуск ProxySQL на ${web_node} (${web_ip})..."
        local restart_result
        restart_result=$(bcm_ssh_exec "$web_ip" \
            "systemctl restart proxysql 2>&1" 2>/dev/null)
        local rc=$?

        sleep 2

        local new_status
        new_status=$(bcm_ssh_service_status "$web_ip" "proxysql" 2>/dev/null || echo "unknown")

        if [[ $rc -eq 0 && "$new_status" == "active" ]]; then
            bcm_ok "  ${web_node}: ProxySQL перезапущен — active."
        else
            bcm_error "  ${web_node}: ошибка перезапуска (статус: ${new_status}). ${restart_result:0:80}"
        fi
    done

    bcm_log_info "ProxySQL перезапущен на всех web-нодах"
    bcm_any_key
}

# ──── Синхронизация конфига между web-нодами ─────────────────────────────────
_psql_sync_config() {
    bcm_section_header "Синхронизация конфигурации ProxySQL между web-нодами"

    local -a web_nodes
    if ! _psql_get_web_nodes web_nodes || [[ ${#web_nodes[@]} -eq 0 ]]; then
        bcm_warn "Web-узлы не найдены."; bcm_any_key; return
    fi

    if [[ ${#web_nodes[@]} -lt 2 ]]; then
        bcm_warn "Для синхронизации нужно минимум 2 web-ноды. Найдена: ${#web_nodes[@]}."
        bcm_any_key
        return
    fi

    # Выбираем источник (master) конфига
    bcm_info "Web-ноды:"
    local idx=0
    for wn in "${web_nodes[@]}"; do
        [[ -z "$wn" ]] && continue
        ((idx++))
        local wip
        wip=$(bcm_get_node_ip "web" "$wn" 2>/dev/null) || wip="?"
        local reachable_str="✓"
        bcm_ssh_reachable "$wip" 4 2>/dev/null || reachable_str="✗ недоступен"
        printf "  %2d. %-14s %s [%s]\n" "$idx" "$wn" "$wip" "$reachable_str"
    done
    echo

    local sel
    bcm_read_choice "Выберите ИСТОЧНИК конфига (номер узла, 0 — отмена)" sel
    [[ "$sel" == "0" || -z "$sel" ]] && return

    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 || "$sel" -gt "${#web_nodes[@]}" ]]; then
        bcm_error "Неверный выбор."
        bcm_any_key
        return
    fi

    local source_node="${web_nodes[$(( sel - 1 ))]}"
    local source_ip
    source_ip=$(bcm_get_node_ip "web" "$source_node" 2>/dev/null) || {
        bcm_error "IP источника не найден."
        bcm_any_key
        return
    }

    if ! bcm_ssh_reachable "$source_ip" 5 2>/dev/null; then
        bcm_error "Источник ${source_node} недоступен."
        bcm_any_key
        return
    fi

    echo
    bcm_info "Источник: ${source_node} (${source_ip})"
    bcm_info "Целевые ноды:"

    local -a target_nodes=()
    for wn in "${web_nodes[@]}"; do
        [[ -z "$wn" || "$wn" == "$source_node" ]] && continue
        local wip
        wip=$(bcm_get_node_ip "web" "$wn" 2>/dev/null) || continue
        target_nodes+=("$wn")
        echo "    → ${wn} (${wip})"
    done
    echo

    if ! bcm_confirm "Синхронизировать конфиг ProxySQL с ${source_node} на указанные узлы?"; then
        bcm_info "Отменено."
        bcm_any_key
        return
    fi

    local admin_port admin_user
    admin_port=$(_psql_get_admin_port)
    admin_user=$(_psql_get_admin_user)

    # Экспортируем данные из источника
    bcm_info "Экспорт mysql_servers с ${source_node}..."
    local servers_data
    servers_data=$(_psql_admin_raw "$source_ip" \
        "SELECT hostgroup_id, hostname, port, weight, max_connections, status
         FROM mysql_servers ORDER BY hostgroup_id, hostname;" 2>/dev/null)

    bcm_info "Экспорт mysql_users с ${source_node}..."
    local users_data
    users_data=$(_psql_admin_raw "$source_ip" \
        "SELECT username, password, default_hostgroup, active, max_connections
         FROM mysql_users ORDER BY username;" 2>/dev/null)

    bcm_info "Экспорт mysql_query_rules с ${source_node}..."
    local rules_data
    rules_data=$(_psql_admin_raw "$source_ip" \
        "SELECT rule_id, active, match_digest, destination_hostgroup, apply
         FROM mysql_query_rules ORDER BY rule_id;" 2>/dev/null)

    # Применяем на целевых нодах
    for target_node in "${target_nodes[@]}"; do
        [[ -z "$target_node" ]] && continue
        local target_ip
        target_ip=$(bcm_get_node_ip "web" "$target_node" 2>/dev/null) || continue

        if ! bcm_ssh_reachable "$target_ip" 5 2>/dev/null; then
            bcm_warn "  ${target_node}: недоступен — пропущен."
            continue
        fi

        bcm_info "  Синхронизация ${target_node} (${target_ip})..."

        # Передаём через ProxySQL admin команды LOAD FROM MEMORY / proxysql_servers
        # Наиболее надёжный способ: скопировать sqlite файл БД через scp или
        # использовать команду PROXYSQL CLUSTER (если настроен)

        # Проверяем: есть ли ProxySQL Cluster
        local cluster_check
        cluster_check=$(_psql_admin_raw "$source_ip" \
            "SELECT COUNT(*) FROM proxysql_servers;" 2>/dev/null | tr -d '[:space:]')

        if [[ "$cluster_check" =~ ^[1-9] ]]; then
            # ProxySQL Cluster настроен — используем встроенную синхронизацию
            bcm_info "    Используется ProxySQL Cluster (proxysql_servers)..."
            _psql_admin_raw "$target_ip" \
                "LOAD MYSQL SERVERS FROM CONFIG;
                 LOAD MYSQL USERS FROM CONFIG;
                 LOAD MYSQL QUERY RULES FROM CONFIG;
                 LOAD MYSQL SERVERS TO RUNTIME;
                 LOAD MYSQL USERS TO RUNTIME;
                 LOAD MYSQL QUERY RULES TO RUNTIME;" 2>/dev/null || true
            bcm_ok "    ${target_node}: команды LOAD применены."
        else
            # Ручная синхронизация: копируем sqlite файл proxysql.db
            bcm_info "    Копирование proxysql.db (${source_node} → ${target_node})..."

            local db_path="/var/lib/proxysql/proxysql.db"
            local tmp_db="/tmp/proxysql_sync_$$.db"

            # Сохранить конфиг источника на диск
            _psql_admin_raw "$source_ip" \
                "SAVE MYSQL SERVERS TO DISK;
                 SAVE MYSQL USERS TO DISK;
                 SAVE MYSQL QUERY RULES TO DISK;" 2>/dev/null

            # Скопировать через промежуточный tmpfile (source → local tmp → target)
            local local_tmp
            local_tmp=$(mktemp /tmp/proxysql_bcm_sync.XXXX.db)
            if bcm_ssh_fetch_file "$source_ip" "$db_path" "$local_tmp" 2>/dev/null; then
                if bcm_ssh_copy_file "$local_tmp" "$target_ip" "$db_path" 2>/dev/null; then
                    rm -f "$local_tmp"
                    # Перезапуск ProxySQL на target для применения DB
                    bcm_ssh_exec "$target_ip" \
                        "systemctl restart proxysql 2>/dev/null" 2>/dev/null
                    sleep 3
                    local new_status
                    new_status=$(bcm_ssh_service_status "$target_ip" "proxysql" 2>/dev/null || echo "unknown")
                    if [[ "$new_status" == "active" ]]; then
                        bcm_ok "    ${target_node}: proxysql.db скопирован, ProxySQL перезапущен."
                    else
                        bcm_warn "    ${target_node}: ProxySQL не запустился после копирования (${new_status})."
                    fi
                else
                    rm -f "$local_tmp"
                    bcm_warn "    ${target_node}: ошибка копирования файла."
                fi
            else
                rm -f "$local_tmp"
                bcm_warn "    ${source_node}: не удалось получить ${db_path}."
            fi
        fi
    done

    echo
    bcm_log_info "ProxySQL конфиг синхронизирован с ${source_node} на: ${target_nodes[*]:-none}"
    bcm_any_key
}

# ──── Меню ────────────────────────────────────────────────────────────────────
_psql_print_menu() {
    local hg_write hg_read proxy_port
    hg_write=$(_psql_get_hg_write)
    hg_read=$(_psql_get_hg_read)
    proxy_port=$(_psql_get_proxy_port)

    local -a items=(
        "1.  Статус mysql_servers (HG${hg_write} write, HG${hg_read} read)"
        "2.  Правила маршрутизации (mysql_query_rules)"
        "3.  Перестроить HG${hg_write}/HG${hg_read} из cluster.conf"
        "4.  Управление репликами HG${hg_read} (add/remove)"
        "5.  Статистика connection pool"
        "6.  Перезапустить ProxySQL на всех web-нодах"
        "7.  Синхронизировать конфиг между web-нодами"
        "0.  Назад"
    )
    bcm_print_menu items
}

# ──── Главная функция ─────────────────────────────────────────────────────────
main() {
    if ! bcm_load_topology; then
        bcm_error "Не удалось загрузить топологию. Проверьте ${BCM_CONF_FILE}."
        bcm_any_key
        exit 1
    fi

    local app_ver benv_ver current_role current_node
    app_ver=$(bcm_get_app_version)
    benv_ver=$(bcm_get_local_benv_version)
    current_role=$(bcm_get_current_role)
    current_node=$(bcm_get_current_node_name)

    while true; do
        bcm_print_header "$app_ver" "$benv_ver" "$current_role" "$current_node"
        bcm_color "WHITE" "  ═══ Управление ProxySQL ═══"
        echo

        # Краткий статус ProxySQL
        local hg_write hg_read proxy_port admin_port
        hg_write=$(_psql_get_hg_write)
        hg_read=$(_psql_get_hg_read)
        proxy_port=$(_psql_get_proxy_port)
        admin_port=$(_psql_get_admin_port)

        bcm_info "HG Write: ${hg_write}  |  HG Read: ${hg_read}  |  Proxy: :${proxy_port}  |  Admin: :${admin_port}"

        # Writer — фактический из runtime ProxySQL (HG10), откат на конфиг.
        local writer writer_src="runtime HG${hg_write}"
        writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || echo "")
        [[ -z "$writer" ]] && { writer=$(bcm_get_pxc_writer 2>/dev/null || echo "не задан"); writer_src="cluster.conf"; }
        bcm_info "Writer (${writer_src}): ${writer}"
        echo

        _psql_print_menu

        local choice
        bcm_read_choice "Введите ваш выбор" choice

        case "$choice" in
            1) _psql_show_status ;;
            2) _psql_show_query_rules ;;
            3) _psql_reconfigure ;;
            4) _psql_manage_read_replica ;;
            5) _psql_show_stats ;;
            6) _psql_restart_all ;;
            7) _psql_sync_config ;;
            0) break ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: '${choice}'. Введите число от 0 до 7." ;;
        esac

        # Сброс кэша
        bcm_clear_cache
        BCM_CONF_LOADED=0
        bcm_load_topology 2>/dev/null || true
    done
}

main "$@"
