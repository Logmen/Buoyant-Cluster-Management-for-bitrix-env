#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 01_cluster_nodes.sh — Управление узлами кластера
# Список, добавление, удаление узлов. Перезагрузка топологии. Просмотр конфига.
#
# Все данные — только из cluster.conf через функции bcm_config.sh / bcm_runtime.sh
# Никаких хардкодных IP, версий, имён.
# =============================================================================
set -euo pipefail

# ──── Загрузка библиотек ─────────────────────────────────────────────────────
source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"
source "${BCM_LIB_DIR}/bcm_cluster_mode.sh"
source "${BCM_LIB_DIR}/bcm_os_update.sh"

# ──── Вспомогательные функции ────────────────────────────────────────────────


# Таблица всех узлов с Live-статусом (SSH-пинг)
_cn_show_node_table() {
    bcm_section_header "Узлы кластера — текущий статус"

    # bcm_pad (по символам), а не printf %-Ns (по байтам): кириллические заголовки
    # и значения (ОБСЛУЖ) иначе уже своих колонок → разделители не совпадают.
    printf "  %s │ %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Имя узла' 14)" "$(bcm_pad 'IP-адрес' 15)" "$(bcm_pad 'Слой' 5)" \
        "$(bcm_pad 'Статус' 7)" "SSH"
    bcm_divider "${BCM_LINE_H1}"

    # Фактический writer PXC — из runtime ProxySQL (galera-checker мог сменить его
    # после failover/рестарта), откат на [layer.pxc] writer. Один опрос на таблицу.
    local pxc_writer
    pxc_writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || echo "")
    [[ -z "$pxc_writer" ]] && pxc_writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")

    local found=0
    for layer in lb web pxc s3; do
        local nodes_str
        nodes_str=$(bcm_get_nodes "$layer" 2>/dev/null) || continue
        [[ -z "$nodes_str" ]] && continue

        local node_arr
        read -ra node_arr <<< "$nodes_str"
        for node in "${node_arr[@]}"; do
            [[ -z "$node" ]] && continue
            local ip
            ip=$(bcm_get_node_ip "$layer" "$node" 2>/dev/null) || ip="?"
            found=1

            local is_maint=0
            if bcm_node_in_maintenance "$node"; then
                is_maint=1
            fi

            # SSH ping
            local ssh_ok="—"
            local node_color="WHITE"
            if bcm_ssh_reachable "$ip" 4 2>/dev/null; then
                ssh_ok="$(bcm_echo_color GREEN_BOLD " ✓ ОК")"
                [[ $is_maint -eq 1 ]] && node_color="GRAY" || node_color="WHITE"
            else
                ssh_ok="$(bcm_echo_color RED_BOLD " ✗ нет")"
                [[ $is_maint -eq 1 ]] && node_color="GRAY" || node_color="RED"
            fi

            printf "  "
            bcm_echo_color "$node_color" "$(bcm_pad "$node" 14)"
            printf " │ %s │ %s │ " "$(bcm_pad "$ip" 15)" "$(bcm_pad "$layer" 5)"

            # Role/writer marker
            local marker="—"
            local marker_color="WHITE"
            if [[ $is_maint -eq 1 ]]; then
                marker="ОБСЛУЖ"
                marker_color="YELLOW"
            else
                case "$layer" in
                    pxc)
                        [[ "$pxc_writer" == "$node" ]] && marker="WRITER" || marker="reader"
                        ;;
                    lb)
                        marker="lb"
                        ;;
                    web)
                        marker="web"
                        ;;
                    s3)
                        marker="s3"
                        ;;
                esac
            fi
            bcm_echo_color "$marker_color" "$(bcm_pad "$marker" 7)"
            printf " │ %s\n" "$ssh_ok"
        done

        # Разделитель между слоями
        bcm_table_layer_sep
    done

    if [[ $found -eq 0 ]]; then
        bcm_warn "Узлы не найдены в cluster.conf. Конфиг пуст или не загружен."
    fi

    # VIP строка
    local vip
    vip=$(bcm_get_vip 2>/dev/null || echo "")
    if [[ -n "$vip" ]]; then
        printf "  "
        bcm_echo_color CYAN "$(bcm_pad "VIP (float)" 14)"
        printf " │ %s │ %s │ %s │ %s\n" "$(bcm_pad "$vip" 15)" "$(bcm_pad '—' 5)" "$(bcm_pad '—' 7)" "—"
        echo
    fi
}

# ──── Добавить узел ───────────────────────────────────────────────────────────
_cn_add_node() {
    bcm_section_header "Добавление узла в кластер"

    # Выбор слоя
    echo "  Доступные слои:"
    echo "    1. lb   — балансировщик нагрузки (HAProxy + Keepalived)"
    echo "    2. web  — веб-узел (bitrix-env + ProxySQL)"
    echo "    3. pxc  — узел базы данных (Percona XtraDB Cluster)"
    echo "    4. s3   — хранилище объектов (MinIO)"
    echo

    local layer_choice
    bcm_read_choice "Выберите слой [1-4] (0 — отмена)" layer_choice
    [[ "$layer_choice" == "0" || -z "$layer_choice" ]] && { bcm_info "Отменено."; bcm_any_key; return; }

    local layer
    case "$layer_choice" in
        1) layer="lb"  ;;
        2) layer="web" ;;
        3) layer="pxc" ;;
        4) layer="s3"  ;;
        *)
            bcm_error "Неверный выбор слоя."
            bcm_any_key
            return
            ;;
    esac

    # Имя узла
    local node_name
    bcm_read_choice "Имя нового узла (латиница, без пробелов)" node_name
    if [[ -z "$node_name" ]]; then
        bcm_error "Имя узла не может быть пустым."
        bcm_any_key
        return
    fi
    if ! bcm_valid_hostname "$node_name"; then
        bcm_error "Имя узла содержит недопустимые символы: ${node_name}"
        bcm_any_key
        return
    fi

    # Проверка дубликата
    local existing_layer="${BCM_NODE_LAYER[$node_name]:-}"
    if [[ -n "$existing_layer" ]]; then
        bcm_error "Узел '${node_name}' уже существует в слое '${existing_layer}'."
        bcm_any_key
        return
    fi

    # IP-адрес
    local node_ip
    bcm_read_choice "IP-адрес нового узла" node_ip
    if ! bcm_valid_ip "$node_ip"; then
        bcm_error "Некорректный IP-адрес: ${node_ip}"
        bcm_any_key
        return
    fi

    # Проверка дубликата по IP
    for known_node in "${!BCM_NODE_IP[@]}"; do
        if [[ "${BCM_NODE_IP[$known_node]}" == "$node_ip" ]]; then
            bcm_error "IP ${node_ip} уже используется узлом '${known_node}'."
            bcm_any_key
            return
        fi
    done

    # Итоговое подтверждение
    echo
    bcm_info "Будет добавлено:"
    bcm_info "  Слой:  ${layer}"
    bcm_info "  Узел:  ${node_name}"
    bcm_info "  IP:    ${node_ip}"
    echo

    if ! bcm_confirm "Добавить узел в cluster.conf и скопировать SSH-ключ?"; then
        bcm_info "Отменено."
        bcm_any_key
        return
    fi

    # Запись в конфиг
    bcm_info "Запись в cluster.conf..."
    bcm_conf_add_node "$layer" "$node_name" "$node_ip"
    BCM_CONF_LOADED=0
    bcm_load_topology
    bcm_ok "Узел '${node_name}' добавлен в слой '${layer}'."

    # Копирование SSH-ключа
    local pub_key="${BCM_SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}.pub"
    if [[ -f "$pub_key" ]]; then
        bcm_info "Попытка скопировать SSH-ключ на ${node_ip} (потребуется пароль root)..."
        echo
        bcm_warn "Введите пароль root удалённого узла (или Ctrl+C для пропуска):"
        local ssh_pass
        read -r -s ssh_pass
        echo

        if [[ -n "$ssh_pass" ]]; then
            if bcm_copy_key_to_node "$node_ip" "$ssh_pass" "$pub_key"; then
                bcm_ok "SSH-ключ успешно скопирован на ${node_ip}."
            else
                bcm_error "Не удалось скопировать SSH-ключ. Проверьте пароль и доступность узла."
                bcm_info "Скопируйте вручную: ssh-copy-id -i ${pub_key} root@${node_ip}"
            fi
        else
            bcm_warn "Пароль не введён. Скопируйте ключ вручную:"
            bcm_info "  ssh-copy-id -i ${pub_key} root@${node_ip}"
        fi
    else
        bcm_warn "Публичный ключ не найден: ${pub_key}"
        bcm_info "Создайте ключ: ssh-keygen -t ed25519 -f ${BCM_SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}"
    fi

    bcm_log_info "Добавлен узел ${node_name} (${node_ip}) в слой ${layer}"
    bcm_any_key
}

# ──── Удалить узел ────────────────────────────────────────────────────────────
_cn_remove_node() {
    bcm_section_header "Удаление узла из кластера"

    # Собираем список всех узлов
    local all_nodes=()
    local all_layers=()
    local all_ips=()
    local idx=0

    for layer in lb web pxc s3; do
        local nodes_str
        nodes_str=$(bcm_get_nodes "$layer" 2>/dev/null) || continue
        [[ -z "$nodes_str" ]] && continue
        local node_arr
        read -ra node_arr <<< "$nodes_str"
        for node in "${node_arr[@]}"; do
            [[ -z "$node" ]] && continue
            idx=$((idx + 1))
            local ip
            ip=$(bcm_get_node_ip "$layer" "$node" 2>/dev/null) || ip="?"
            all_nodes+=("$node")
            all_layers+=("$layer")
            all_ips+=("$ip")
            printf "  %2d. %-14s %-15s [%s]\n" "$idx" "$node" "$ip" "$layer"
        done
    done

    if [[ $idx -eq 0 ]]; then
        bcm_warn "Нет узлов для удаления."
        bcm_any_key
        return
    fi

    echo
    local sel
    bcm_read_choice "Введите номер узла для удаления (0 — отмена)" sel

    [[ "$sel" == "0" || -z "$sel" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 || "$sel" -gt "$idx" ]]; then
        bcm_error "Неверный номер: ${sel}"
        bcm_any_key
        return
    fi

    local target_idx=$(( sel - 1 ))
    local target_node="${all_nodes[$target_idx]}"
    local target_layer="${all_layers[$target_idx]}"
    local target_ip="${all_ips[$target_idx]}"

    # ── Валидация минимума слоя (инварианты install.sh) ──────────────────────
    # lb/web/s3 >= 2, pxc >= 3 и НЕЧЁТНОЕ. Проверяем ОСТАТОК после удаления, а не
    # текущее число (прежняя проверка `pxc_count -le 2` пропускала 3→2). На
    # минимальной конфигурации удаление любого узла увело бы слой ниже минимума.
    local layer_count remaining min_count
    layer_count=$(bcm_get_nodes "$target_layer" | tr ',' ' ' | wc -w)
    remaining=$(( layer_count - 1 ))
    case "$target_layer" in
        pxc) min_count=3 ;;
        *)   min_count=2 ;;
    esac
    if [[ "$remaining" -lt "$min_count" ]]; then
        bcm_error "Нельзя удалить '${target_node}': в слое '${target_layer}' останется ${remaining}, минимум — ${min_count}."
        bcm_info "Конфигурация минимальна. Сначала добавьте узел в слой '${target_layer}'."
        bcm_any_key
        return
    fi
    if [[ "$target_layer" == "pxc" && $(( remaining % 2 )) -eq 0 ]]; then
        bcm_error "Нельзя удалить PXC-узел: останется ЧЁТНОЕ число (${remaining}) — Galera теряет кворум-устойчивость."
        bcm_info "PXC-кластер должен быть нечётным (3, 5, 7…). Удаляйте PXC-узлы по два."
        bcm_any_key
        return
    fi

    # ── Валидация: удаляемый узел — текущий PXC writer? ──────────────────────
    if [[ "$target_layer" == "pxc" ]]; then
        # Фактический writer (runtime ProxySQL), откат на конфиг.
        local current_writer
        current_writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || echo "")
        [[ -z "$current_writer" ]] && current_writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")
        if [[ "$current_writer" == "$target_node" ]]; then
            bcm_error "Узел '${target_node}' является текущим WRITER'ом PXC."
            bcm_info "Сначала смените writer (меню 03 → Сменить writer) и повторите."
            bcm_any_key
            return
        fi
    fi

    echo
    bcm_warn "ВНИМАНИЕ! Узел будет удалён из cluster.conf:"
    bcm_info "  Узел:  ${target_node}"
    bcm_info "  IP:    ${target_ip}"
    bcm_info "  Слой:  ${target_layer}"
    echo

    if ! bcm_confirm "Подтвердите удаление узла '${target_node}'"; then
        bcm_info "Отменено."
        bcm_any_key
        return
    fi

    bcm_conf_remove_node "$target_layer" "$target_node"

    # Удалить также IP-ключ узла из конфига
    local tmpfile
    tmpfile=$(mktemp)
    grep -v "^${target_node}\.ip[[:space:]]*=" "${BCM_CONF_FILE}" > "$tmpfile" || true
    cp "$tmpfile" "${BCM_CONF_FILE}"
    rm -f "$tmpfile"

    BCM_CONF_LOADED=0
    bcm_load_topology

    bcm_ok "Узел '${target_node}' удалён из cluster.conf."
    bcm_log_info "Удалён узел ${target_node} (${target_ip}) из слоя ${target_layer}"
    bcm_any_key
}

# ──── Перезагрузить топологию ─────────────────────────────────────────────────
_cn_reload_topology() {
    bcm_section_header "Перезагрузка топологии из cluster.conf"
    BCM_CONF_LOADED=0
    bcm_clear_cache
    if bcm_load_topology; then
        bcm_ok "Топология успешно перезагружена."
        echo
        local total=0
        for layer in lb web pxc s3; do
            local nodes_str
            nodes_str=$(bcm_get_nodes "$layer" 2>/dev/null) || continue
            [[ -z "$nodes_str" ]] && continue
            local cnt
            cnt=$(echo "$nodes_str" | tr ',' ' ' | wc -w)
            bcm_info "  Слой ${layer}: ${cnt} узел(ов)"
            ((total += cnt))
        done
        echo
        bcm_info "Итого: ${total} узел(ов) в кластере."
    else
        bcm_error "Не удалось загрузить топологию. Проверьте ${BCM_CONF_FILE}."
    fi
    bcm_any_key
}

# ──── Просмотр cluster.conf ───────────────────────────────────────────────────
_cn_view_conf() {
    bcm_section_header "Содержимое cluster.conf"
    bcm_info "Файл: ${BCM_CONF_FILE}"
    echo

    if [[ ! -f "${BCM_CONF_FILE}" ]]; then
        bcm_error "Файл не найден: ${BCM_CONF_FILE}"
        bcm_any_key
        return
    fi

    # Простая подсветка: секции — голубым, ключи — белым, комментарии — серым
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            bcm_echo_color "DIM" "  ${line}"
            echo
        elif [[ "$line" =~ ^\[.+\]$ ]]; then
            echo
            bcm_echo_color "CYAN_BOLD" "  ${line}"
            echo
        elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_.]+[[:space:]]*= ]]; then
            local key val
            key="${line%%=*}"
            val="${line#*=}"
            printf "  "
            bcm_echo_color "WHITE" "$(printf '%-28s' "$key")"
            printf "= "
            bcm_echo_color "YELLOW" "${val}"
            echo
        else
            echo "  ${line}"
        fi
    done < "${BCM_CONF_FILE}"

    echo
    bcm_any_key
}

# ──── Режим обслуживания (ввод/вывод узлов) ──────────────────────────────────
_cn_toggle_maintenance() {
    bcm_section_header "Управление режимом обслуживания узлов кластера"

    # Собираем список всех узлов
    local all_nodes=()
    local all_layers=()
    local all_ips=()
    local idx=0

    for layer in lb web pxc s3; do
        local nodes_str
        nodes_str=$(bcm_get_nodes "$layer" 2>/dev/null) || continue
        [[ -z "$nodes_str" ]] && continue
        local node_arr
        read -ra node_arr <<< "$nodes_str"
        for node in "${node_arr[@]}"; do
            [[ -z "$node" ]] && continue
            idx=$((idx + 1))
            local ip
            ip=$(bcm_get_node_ip "$layer" "$node" 2>/dev/null) || ip="?"
            all_nodes+=("$node")
            all_layers+=("$layer")
            all_ips+=("$ip")
            
            local status_text="АКТИВЕН"
            local status_color="GREEN_BOLD"
            if bcm_node_in_maintenance "$node"; then
                status_text="ОБСЛУЖИВАНИЕ"
                status_color="YELLOW_BOLD"
            fi
            
            printf "  %2d. %-14s %-15s [%s] — " "$idx" "$node" "$ip" "$layer"
            bcm_echo_color "$status_color" "$status_text"
            echo
        done
    done

    if [[ $idx -eq 0 ]]; then
        bcm_warn "Нет узлов для управления."
        bcm_any_key
        return
    fi

    echo
    local sel
    bcm_read_choice "Введите номер узла для изменения режима (0 — отмена)" sel

    [[ "$sel" == "0" || -z "$sel" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 || "$sel" -gt "$idx" ]]; then
        bcm_error "Неверный номер: ${sel}"
        bcm_any_key
        return
    fi

    local target_idx=$(( sel - 1 ))
    local target_node="${all_nodes[$target_idx]}"
    local target_layer="${all_layers[$target_idx]}"
    local target_ip="${all_ips[$target_idx]}"

    local is_maint=0
    if bcm_node_in_maintenance "$target_node"; then
        is_maint=1
    fi

    if [[ $is_maint -eq 0 ]]; then
        # Вывод в обслуживание (Активен -> Обслуживание)
        
        # Проверка PXC Writer (фактический — runtime ProxySQL, откат на конфиг)
        if [[ "$target_layer" == "pxc" ]]; then
            local current_writer
            current_writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || echo "")
            [[ -z "$current_writer" ]] && current_writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")
            if [[ "$current_writer" == "$target_node" ]]; then
                bcm_error "Узел '${target_node}' является активным WRITER'ом PXC!"
                bcm_warn "Нельзя вывести WRITER в обслуживание. Сначала смените writer (меню 03 -> Сменить writer) или выполните failover."
                bcm_any_key
                return
            fi
        fi

        echo
        bcm_warn "ВНИМАНИЕ! Узел '${target_node}' будет выведен из кластера в режим обслуживания."
        bcm_info "Все службы слоя '${target_layer}' на узле будут ОСТАНОВЛЕНЫ."
        echo

        if ! bcm_confirm "Продолжить вывод в обслуживание?"; then
            bcm_info "Отменено."
            bcm_any_key
            return
        fi

        bcm_info "Выполняется остановка служб на ${target_node} (${target_ip})..."

        # Проверка SSH перед остановкой
        local ssh_reachable=0
        if bcm_node_reachable "$target_ip" 3 2>/dev/null; then
            ssh_reachable=1
        fi

        if [[ $ssh_reachable -eq 1 ]]; then
            # Остановка служб по слоям
            local stop_cmd=""
            case "$target_layer" in
                lb)
                    stop_cmd="systemctl stop keepalived 2>/dev/null; systemctl stop haproxy 2>/dev/null"
                    ;;
                web)
                    stop_cmd="systemctl stop keepalived 2>/dev/null; systemctl stop bx-push-server push-server 2>/dev/null; systemctl stop nginx 2>/dev/null; systemctl stop httpd 2>/dev/null; systemctl stop proxysql 2>/dev/null; systemctl stop lsyncd 2>/dev/null; systemctl stop crond cron 2>/dev/null"
                    ;;
                pxc)
                    stop_cmd="systemctl stop mysql 2>/dev/null; systemctl stop mysqld 2>/dev/null; systemctl stop mysql@bootstrap 2>/dev/null"
                    ;;
                s3)
                    stop_cmd="systemctl stop minio 2>/dev/null"
                    ;;
            esac
            
            bcm_info "Команда остановки: ${stop_cmd}"
            local stop_res
            stop_res=$(bcm_ssh_exec_timeout "$target_ip" 30 "$stop_cmd" 2>&1 || echo "FAIL")
            bcm_ok "Службы остановлены на удалённом узле."
        else
            bcm_warn "Узел недоступен по SSH. Не удалось остановить службы удалённо."
            bcm_info "Флаг обслуживания всё равно будет выставлен в конфигурации."
        fi

        # Запись в конфиг
        bcm_conf_set "layer.${target_layer}" "${target_node}.maintenance" "1"
        
        # Синхронизация конфига
        bcm_info "Синхронизация конфигурации на другие узлы..."
        bcm_conf_sync
        
        bcm_ok "Узел '${target_node}' успешно переведён в режим обслуживания."
        bcm_log_info "Узел ${target_node} переведён в режим обслуживания (layer: ${target_layer})"
    else
        # Возврат из обслуживания (Обслуживание -> Активен)
        echo
        bcm_info "Узел '${target_node}' будет возвращён в работу."
        bcm_info "Все службы слоя '${target_layer}' на узле будут ЗАПУЩЕНЫ."
        echo

        if ! bcm_confirm "Продолжить ввод в работу?"; then
            bcm_info "Отменено."
            bcm_any_key
            return
        fi

        bcm_info "Проверка доступности узла ${target_node} (${target_ip})..."
        local ssh_reachable=0
        if bcm_node_reachable "$target_ip" 4 2>/dev/null; then
            ssh_reachable=1
        fi

        if [[ $ssh_reachable -eq 1 ]]; then
            bcm_info "Запуск служб на ${target_node}..."
            local start_cmd=""
            case "$target_layer" in
                lb)
                    start_cmd="systemctl start haproxy 2>/dev/null && systemctl start keepalived 2>/dev/null"
                    ;;
                web)
                    start_cmd="systemctl start crond cron 2>/dev/null; systemctl start proxysql 2>/dev/null; systemctl start httpd 2>/dev/null; systemctl start nginx 2>/dev/null; systemctl start bx-push-server push-server 2>/dev/null; systemctl start keepalived 2>/dev/null; systemctl start lsyncd 2>/dev/null"
                    ;;
                pxc)
                    start_cmd="systemctl start mysql 2>/dev/null || systemctl start mysqld 2>/dev/null"
                    ;;
                s3)
                    start_cmd="systemctl start minio 2>/dev/null"
                    ;;
            esac
            
            bcm_info "Команда запуска: ${start_cmd}"
            local start_res
            start_res=$(bcm_ssh_exec_timeout "$target_ip" 45 "$start_cmd" 2>&1 || echo "FAIL")
            bcm_ok "Службы запущены на удалённом узле."
        else
            bcm_warn "Узел недоступен по SSH. Не удалось запустить службы удалённо."
            if ! bcm_confirm "Узел недоступен. Всё равно сбросить флаг обслуживания в конфиге?"; then
                bcm_info "Отменено."
                bcm_any_key
                return
            fi
        fi

        # Сброс в конфиге
        bcm_conf_set "layer.${target_layer}" "${target_node}.maintenance" "0"
        
        # Синхронизация конфига
        bcm_info "Синхронизация конфигурации на другие узлы..."
        bcm_conf_sync
        
        bcm_ok "Узел '${target_node}' возвращён в работу."
        bcm_log_info "Узел ${target_node} возвращён из обслуживания в работу (layer: ${target_layer})"
    fi

    # Сбросить локальный кэш
    BCM_CONF_LOADED=0
    bcm_load_topology
    bcm_any_key
}

# ──── Меню ────────────────────────────────────────────────────────────────────
_cn_print_menu() {
    local -a items=(
        "1.  Список узлов кластера (live-статус)"
        "2.  Добавить узел"
        "3.  Удалить узел"
        "4.  Перезагрузить топологию"
        "5.  Просмотр cluster.conf"
        "6.  Режим обслуживания (ввод/вывод узлов)"
        "7.  Режим единой ноды (single-active: вкл/выкл)"
        "8.  Обновление пакетов ОС (HA-rolling)"
        "0.  Назад"
    )
    bcm_print_menu items
}

# ──── Режим единой ноды (single-active) ──────────────────────────────────────
_cn_single_node_mode() {
    bcm_section_header "Режим единой ноды (single-active)"

    local mode active
    mode=$(bcm_get_cluster_mode)
    active=$(bcm_get_active_node)

    bcm_info "Текущий режим: ${mode}$( [[ "$mode" == "single" ]] && echo " (активная нода: ${active})" )"
    echo
    bcm_color "DIM" "  Режим закрепляет весь HTTP на одной web-ноде (остальные → drain в"
    bcm_color "DIM" "  HAProxy) и направляет чтения БД на writer. Остальные ноды остаются"
    bcm_color "DIM" "  тёплыми (службы и lsyncd работают). Удобно для первичной заливки или"
    bcm_color "DIM" "  переноса портала, чтобы трафик/БД не «гуляли» между нодами."
    echo

    # Список web-нод
    local web_str
    web_str=$(bcm_get_nodes "web" 2>/dev/null) || web_str=""
    local -a web_arr
    read -ra web_arr <<< "$web_str"
    if [[ ${#web_arr[@]} -eq 0 ]]; then
        bcm_error "Web-ноды не найдены в cluster.conf."
        bcm_any_key; return
    fi

    if [[ "$mode" == "single" ]]; then
        bcm_color "WHITE" "  1. Выключить режим (вернуть HA / балансировку)"
        bcm_color "WHITE" "  2. Сменить активную ноду"
        bcm_color "WHITE" "  0. Отмена"
        echo
        local ch
        bcm_read_choice "Выбор" ch
        case "$ch" in
            1)
                if bcm_confirm "Вернуть кластер в HA-режим (round-robin + чтения с реплик)?"; then
                    if bcm_cluster_unpin; then
                        bcm_ok "Режим единой ноды выключен. HA восстановлен."
                    else
                        bcm_error "Не удалось полностью вернуть HA-режим (см. сообщения выше)."
                    fi
                else
                    bcm_info "Отменено."
                fi
                ;;
            2) _cn_pick_and_pin web_arr ;;
            *) bcm_info "Отменено." ;;
        esac
    else
        if bcm_confirm "Включить режим единой ноды?"; then
            _cn_pick_and_pin web_arr
        else
            bcm_info "Отменено."
        fi
    fi
    bcm_any_key
}

# Выбрать активную web-ноду и закрепить на ней
_cn_pick_and_pin() {
    local -n _web=$1
    echo
    bcm_color "WHITE" "  Выберите активную web-ноду:"
    local i
    for i in "${!_web[@]}"; do
        local n="${_web[$i]}"
        local hint=""
        [[ $i -eq 0 ]] && hint="  (источник lsyncd, рекомендуется)"
        printf "    %d. %s%s\n" "$((i+1))" "$n" "$hint"
    done
    echo
    local sel
    bcm_read_choice "Номер ноды (Enter — 1, 0 — отмена)" sel
    [[ "$sel" == "0" ]] && { bcm_info "Отменено."; return; }
    sel="${sel:-1}"
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#_web[@]} )); then
        bcm_warn "Неверный номер."
        return
    fi
    local active="${_web[$((sel-1))]}"
    if bcm_cluster_pin "$active"; then
        bcm_ok "Режим единой ноды включён. Активная нода: ${active}."
        bcm_info "Весь HTTP идёт на ${active}, чтения БД — на writer."
        bcm_info "Не забудьте выключить режим после переноса (меню 1 → 7 → 1)."
    else
        bcm_error "Не удалось включить режим."
    fi
}

# ──── Главная функция ─────────────────────────────────────────────────────────
main() {
    # Убедимся, что топология загружена
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
        bcm_color "WHITE" "  ═══ Управление узлами кластера ═══"
        echo
 
        _cn_print_menu
 
        local choice
        bcm_read_choice "Введите ваш выбор" choice
 
        case "$choice" in
            1) _cn_show_node_table; bcm_any_key ;;
            2) _cn_add_node ;;
            3) _cn_remove_node ;;
            4) _cn_reload_topology ;;
            5) _cn_view_conf ;;
            6) _cn_toggle_maintenance ;;
            7) _cn_single_node_mode ;;
            8) bcm_osupdate_rolling ;;
            0) break ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: '${choice}'. Введите число от 0 до 8." ;;
        esac
    done
}

main "$@"
