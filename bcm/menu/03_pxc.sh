#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 03_pxc.sh — Управление Percona XtraDB Cluster (Galera)
# Статус кластера, Bootstrap, Join, смена Writer, авто-failover, резервное копирование.
#
# Все данные — только из cluster.conf через функции bcm_config.sh / bcm_runtime.sh
# Никаких хардкодных IP, версий, имён узлов.
# =============================================================================
set -euo pipefail

# ──── Пути и библиотеки ──────────────────────────────────────────────────────
BCM_BASE_DIR="${BCM_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"

source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"
source "${BCM_LIB_DIR}/bcm_confedit.sh"

# ──── Загрузить топологию ─────────────────────────────────────────────────────
if ! bcm_conf_exists; then
    bcm_error "cluster.conf не найден. Запустите install.sh."
    exit 1
fi
bcm_load_topology

# =============================================================================
# Вспомогательные функции
# =============================================================================

# Получить wsrep-переменную с PXC-узла
# _pxc_wsrep_var <ip> <variable_name>
_pxc_wsrep_var() {
    local ip="$1"
    local var="$2"
    bcm_ssh_exec_timeout "$ip" 12 \
        "mysql -N -e \"SHOW STATUS LIKE '${var}'\" 2>/dev/null | awk '{print \$2}'" \
        2>/dev/null | tr -d '[:space:]'
}

# Проверить, готов ли узел (wsrep_ready=ON && wsrep_cluster_status=Primary)
# Возвращает 0 если готов
_pxc_node_ready() {
    local ip="$1"
    local ready
    ready=$(_pxc_wsrep_var "$ip" "wsrep_ready")
    local status
    status=$(_pxc_wsrep_var "$ip" "wsrep_cluster_status")
    [[ "$ready" == "ON" && "$status" == "Primary" ]]
}

# Получить размер кластера с узла
_pxc_cluster_size() {
    local ip="$1"
    _pxc_wsrep_var "$ip" "wsrep_cluster_size"
}

# =============================================================================
# 1. Показать статус кластера
# =============================================================================
_pxc_show_status() {
    bcm_section_header "Статус Percona XtraDB Cluster (Galera)"

    if [[ ${#BCM_NODES_PXC[@]} -eq 0 ]]; then
        bcm_warn "PXC-узлы не заданы в cluster.conf."
        bcm_any_key; return
    fi

    # Фактический writer — из runtime ProxySQL (HG10), откат на конфиг.
    local writer writer_src="ProxySQL HG10"
    writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || echo "")
    [[ -z "$writer" ]] && { writer=$(bcm_get_pxc_writer 2>/dev/null || echo ""); writer_src="cluster.conf — ProxySQL недоступен"; }
    bcm_info "Текущий WRITER (${writer_src}): ${writer:-не задан}"
    echo

    # bcm_pad (по символам), а не printf %-Ns (по байтам): кириллические заголовки
    # и значения иначе уже своих колонок → разделители не совпадают с данными.
    printf "  %s │ %s │ %s │ %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Узел' 14)" "$(bcm_pad 'IP' 15)" "$(bcm_pad 'WRITER' 8)" \
        "$(bcm_pad 'Готов' 7)" "$(bcm_pad 'Р-р кл.' 9)" "$(bcm_pad 'Статус Galera' 18)" \
        "Локальный статус"
    bcm_divider "${BCM_LINE_H1}"

    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        local is_writer=" "
        [[ "$node" == "$writer" ]] && is_writer="★"

        # Проверка SSH
        if ! bcm_ssh_reachable "$ip" 4 2>/dev/null; then
            printf "  "
            bcm_echo_color "RED" "$(bcm_pad "$node" 14)"
            printf " │ %s │ %s │ " "$(bcm_pad "$ip" 15)" "$(bcm_pad "$is_writer" 8)"
            bcm_echo_color "RED_BOLD" "$(bcm_pad "НЕДОСТ" 7)"
            printf " │ %s │ %s │ %s\n" "$(bcm_pad '—' 9)" "$(bcm_pad '—' 18)" "SSH недоступен"
            continue
        fi

        local wsrep_cluster_status wsrep_ready wsrep_cluster_size wsrep_local_state
        wsrep_cluster_status=$(_pxc_wsrep_var "$ip" "wsrep_cluster_status")
        wsrep_ready=$(_pxc_wsrep_var         "$ip" "wsrep_ready")
        wsrep_cluster_size=$(_pxc_wsrep_var  "$ip" "wsrep_cluster_size")
        wsrep_local_state=$(_pxc_wsrep_var   "$ip" "wsrep_local_state_comment")

        # Цвет строки
        local node_color="WHITE"
        if [[ "$wsrep_ready" != "ON" || "$wsrep_cluster_status" != "Primary" ]]; then
            node_color="RED"
        fi

        local ready_color="GREEN"
        [[ "$wsrep_ready" != "ON" ]] && ready_color="RED"

        printf "  "
        bcm_echo_color "$node_color" "$(bcm_pad "$node" 14)"
        printf " │ %s │ %s │ " "$(bcm_pad "$ip" 15)" "$(bcm_pad "$is_writer" 8)"
        bcm_echo_color "$ready_color" "$(bcm_pad "${wsrep_ready:-?}" 7)"
        printf " │ %s │ %s │ %s\n" \
            "$(bcm_pad "${wsrep_cluster_size:-?}" 9)" \
            "$(bcm_pad "${wsrep_cluster_status:-?}" 18)" \
            "${wsrep_local_state:-?}"
    done

    echo
    bcm_info "★ = текущий WRITER (ProxySQL HG10)"
    bcm_any_key
}

# =============================================================================
# 2. Bootstrap Galera (опасная операция!)
# =============================================================================
_pxc_bootstrap() {
    bcm_section_header "Bootstrap Galera кластера"

    bcm_warn "╔══════════════════════════════════════════════════════════════╗"
    bcm_warn "║  ОПАСНАЯ ОПЕРАЦИЯ! Bootstrap запускает новый кластер с      ║"
    bcm_warn "║  нуля. Используйте ТОЛЬКО если ВСЕ узлы остановлены        ║"
    bcm_warn "║  и нет ни одного работающего участника Galera.              ║"
    bcm_warn "║  Запуск Bootstrap при работающем кластере приведёт к        ║"
    bcm_warn "║  РАСЩЕПЛЕНИЮ (split-brain) и потере данных!                ║"
    bcm_warn "╚══════════════════════════════════════════════════════════════╝"
    echo

    if [[ ${#BCM_NODES_PXC[@]} -eq 0 ]]; then
        bcm_error "Нет PXC-узлов в конфигурации."
        bcm_any_key; return
    fi

    # Проверяем — вдруг кластер уже работает
    bcm_info "Проверяем работающие узлы..."
    local running_count=0
    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if bcm_ssh_reachable "$ip" 4 2>/dev/null; then
            local mysqld_st
            mysqld_st=$(bcm_ssh_service_status "$ip" "mysqld")
            if [[ "$mysqld_st" == "active" ]]; then
                bcm_warn "  Узел ${node} (${ip}): mysqld АКТИВЕН!"
                ((running_count++)) || true
            else
                bcm_info "  Узел ${node} (${ip}): mysqld остановлен — ОК"
            fi
        else
            bcm_info "  Узел ${node} (${ip}): SSH недоступен (считаем остановленным)"
        fi
    done

    if [[ $running_count -gt 0 ]]; then
        bcm_error "Обнаружено ${running_count} узлов с работающим mysqld!"
        bcm_warn "Остановите все PXC-узлы перед Bootstrap."
        bcm_any_key; return
    fi

    echo
    bcm_info "  Опрашиваем состояние grastate.dat на узлах..."

    local -a node_list=()
    local -a node_details=()

    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-?}"
        node_list+=("$node")

        local info=""
        if bcm_ssh_reachable "$ip" 3 2>/dev/null; then
            info=$(bcm_ssh_exec_timeout "$ip" 5 \
                "awk '/seqno:/{seq=\$2} /safe_to_bootstrap:/{safe=\$2} END {printf \"safe:%s,seq:%s\", safe, seq}' /var/lib/mysql/grastate.dat 2>/dev/null || echo 'error'")
        else
            info="unreachable"
        fi
        node_details+=("$info")
    done
    echo

    echo "  Выберите узел для Bootstrap (узел с самыми актуальными данными):"

    local recommended_idx=-1
    local max_seq=-2
    local best_safe=0

    # 1. Поиск safe_to_bootstrap: 1
    for (( idx=0; idx<${#node_list[@]}; idx++ )); do
        local det="${node_details[$idx]}"
        if [[ "$det" == *"safe:1"* ]]; then
            recommended_idx=$idx
            best_safe=1
            break
        fi
    done

    # 2. Если safe:1 не найден, ищем с максимальным seqno
    if [[ $recommended_idx -eq -1 ]]; then
        for (( idx=0; idx<${#node_list[@]}; idx++ )); do
            local det="${node_details[$idx]}"
            if [[ "$det" == *"seq:"* ]]; then
                local seq
                seq=$(echo "$det" | sed -n 's/.*seq:\([0-9-]\+\).*/\1/p')
                if [[ -n "$seq" && "$seq" =~ ^-?[0-9]+$ ]]; then
                    if (( seq > max_seq )); then
                        max_seq=$seq
                        recommended_idx=$idx
                    fi
                fi
            fi
        done
    fi

    # Вывод списка с подсветкой
    for (( idx=0; idx<${#node_list[@]}; idx++ )); do
        local node="${node_list[$idx]}"
        local ip="${BCM_NODE_IP[$node]:-?}"
        local det="${node_details[$idx]}"
        local status_str=""
        local suffix=""

        if [[ "$det" == "unreachable" ]]; then
            status_str="[SSH недоступен]"
        elif [[ "$det" == "error" ]]; then
            status_str="[ошибка чтения grastate.dat]"
        else
            local safe="?"
            local seq="?"
            [[ "$det" == *"safe:"* ]] && safe=$(echo "$det" | sed -n 's/.*safe:\([^,]*\).*/\1/p')
            [[ "$det" == *"seq:"* ]] && seq=$(echo "$det" | sed -n 's/.*seq:\([^,]*\).*/\1/p')
            status_str="[safe_to_bootstrap: ${safe}, seqno: ${seq}]"
        fi

        if [[ $idx -eq $recommended_idx ]]; then
            if [[ $best_safe -eq 1 ]]; then
                suffix=" <-- РЕКОМЕНДУЕТСЯ (безопасный запуск)"
            else
                local seq_val="?"
                [[ "$det" == *"seq:"* ]] && seq_val=$(echo "$det" | sed -n 's/.*seq:\([^,]*\).*/\1/p')
                suffix=" <-- НАИБОЛЕЕ АКТУАЛЬНЫЙ (seqno: ${seq_val})"
            fi
            printf "    %d. %s (%s)  %s" "$((idx+1))" "$node" "$ip" "$status_str"
            bcm_echo_color "GREEN_BOLD" "$suffix"
            echo
        else
            printf "    %d. %s (%s)  %s\n" "$((idx+1))" "$node" "$ip" "$status_str"
        fi
    done
    echo

    local node_idx
    bcm_read_choice "Введите номер узла (0 — отмена)" node_idx
    [[ "$node_idx" == "0" || -z "$node_idx" ]] && { bcm_info "Отменено."; bcm_any_key; return; }

    if ! [[ "$node_idx" =~ ^[0-9]+$ ]] || \
       [[ "$node_idx" -lt 1 || "$node_idx" -gt "${#node_list[@]}" ]]; then
        bcm_error "Неверный выбор."
        bcm_any_key; return
    fi

    local bootstrap_node="${node_list[$((node_idx-1))]}"
    local bootstrap_ip="${BCM_NODE_IP[$bootstrap_node]:-}"

    echo
    bcm_warn "ПОДТВЕРЖДЕНИЕ: Bootstrap будет запущен на узле '${bootstrap_node}' (${bootstrap_ip})"
    bcm_warn "Введите слово BOOTSTRAP для подтверждения:"
    local confirm_word
    bcm_read_choice "Подтверждение" confirm_word
    if [[ "$confirm_word" != "BOOTSTRAP" ]]; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    bcm_info "Запускаем Bootstrap на ${bootstrap_node} (${bootstrap_ip})..."

    local result
    result=$(bcm_ssh_exec_timeout "$bootstrap_ip" 60 \
        "systemctl stop mysql 2>/dev/null; \
         systemctl stop mysqld 2>/dev/null; \
         [ -f /var/lib/mysql/grastate.dat ] && sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /var/lib/mysql/grastate.dat || true; \
         systemctl start mysql@bootstrap 2>&1 && \
         echo BOOTSTRAP_OK || echo BOOTSTRAP_FAIL" \
        2>/dev/null)

    if [[ "$result" == *"BOOTSTRAP_OK"* ]]; then
        bcm_ok "Bootstrap завершён. Узел ${bootstrap_node} поднят как Galera PRIMARY."
        bcm_info "Теперь подключите остальные узлы через меню '3. Подключить узел к кластеру'."
        bcm_log_info "PXC Bootstrap выполнен на ${bootstrap_node} (${bootstrap_ip})"
    else
        bcm_error "Bootstrap завершился ошибкой."
        echo "$result" | while IFS= read -r line; do echo "    $line"; done
        bcm_info "Проверьте journalctl -u mysqld на ${bootstrap_node}."
    fi

    bcm_any_key
}

# =============================================================================
# 3. Подключить узел к кластеру (Join)
# =============================================================================
_pxc_join_node() {
    bcm_section_header "Подключение узла к Galera кластеру (Join)"

    if [[ ${#BCM_NODES_PXC[@]} -eq 0 ]]; then
        bcm_error "Нет PXC-узлов в конфигурации."
        bcm_any_key; return
    fi

    # Показать список узлов с их статусами
    echo "  Доступные PXC-узлы:"
    local i=1
    local -a offline_nodes=()
    local -a offline_ips=()
    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-?}"
        local state="работает"
        if bcm_ssh_reachable "$ip" 3 2>/dev/null; then
            local mysqld_st
            mysqld_st=$(bcm_ssh_service_status "$ip" "mysqld")
            if [[ "$mysqld_st" != "active" ]]; then
                state="mysqld остановлен"
                offline_nodes+=("$node")
                offline_ips+=("$ip")
                printf "    %d. %-14s (%s)  [%s]\n" "$i" "$node" "$ip" "$state"
                ((i++)) || true
            else
                printf "    %-2s %-14s (%s)  [%s]\n" "—" "$node" "$ip" "$state"
            fi
        else
            state="SSH недоступен"
            printf "    %-2s %-14s (%s)  [%s]\n" "—" "$node" "$ip" "$state"
        fi
    done

    if [[ ${#offline_nodes[@]} -eq 0 ]]; then
        bcm_warn "Все узлы уже активны — нечего подключать."
        bcm_any_key; return
    fi

    echo
    bcm_read_choice "Введите номер узла для подключения (0 — отмена)" node_idx

    [[ "${node_idx:-0}" == "0" || -z "${node_idx:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    if ! [[ "${node_idx}" =~ ^[0-9]+$ ]] || \
       [[ "${node_idx}" -lt 1 || "${node_idx}" -gt "${#offline_nodes[@]}" ]]; then
        bcm_error "Неверный выбор."
        bcm_any_key; return
    fi

    local join_node="${offline_nodes[$((node_idx-1))]}"
    local join_ip="${offline_ips[$((node_idx-1))]}"

    # Найти donor — первый доступный Primary-узел
    local donor_ip=""
    local donor_node=""
    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" || "$node" == "$join_node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if bcm_ssh_reachable "$ip" 3 2>/dev/null && _pxc_node_ready "$ip" 2>/dev/null; then
            donor_ip="$ip"
            donor_node="$node"
            break
        fi
    done

    if [[ -z "$donor_ip" ]]; then
        bcm_error "Не найден работающий Primary-узел для Donor."
        bcm_warn "Убедитесь, что хотя бы один узел кластера запущен."
        bcm_any_key; return
    fi

    bcm_info "Donor-узел: ${donor_node} (${donor_ip})"
    bcm_info "Подключаем: ${join_node} (${join_ip})"

    if ! bcm_confirm "Запустить mysqld на ${join_node} для Join?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    # ⚠️⚠️ Юнит PXC-ноды для JOIN — `mysql.service` (НЕ `mysqld.service`, его на PXC
    # НЕТ — ловили вживую: `systemctl start mysqld` → «Unit mysqld.service not found»).
    # Bootstrap отдельным инстансом `mysql@bootstrap`; рядовой узел джойнится плейн
    # `mysql.service` (читает wsrep_cluster_address и подтягивается IST/SST). Фолбэк на
    # `mysqld` — на случай не-PXC сборки (как в menu/01). ⚠️ Код возврата берём от
    # САМОГО `systemctl start`, а НЕ от пайпа: прежнее `start … | tail && echo JOIN_OK`
    # отдавало статус `tail` (всегда 0) → JOIN_OK печатался даже при провале старта.
    local result
    result=$(bcm_ssh_exec_timeout "$join_ip" 120 \
        "if systemctl start mysql 2>/dev/null || systemctl start mysqld 2>/dev/null; then echo JOIN_OK; else echo JOIN_FAIL; journalctl -u mysql --no-pager -n 10 2>/dev/null | tail -10; fi" \
        2>/dev/null)

    if [[ "$result" == *"JOIN_OK"* ]]; then
        bcm_ok "СУБД запущена на ${join_node}. SST/IST синхронизация запущена."
        bcm_info "Проверьте статус через меню '1. Статус кластера' (дождитесь Synced)."
        bcm_log_info "PXC Join: ${join_node} (${join_ip}), donor: ${donor_node}"
    else
        bcm_error "Ошибка запуска СУБД на ${join_node}:"
        echo "$result" | while IFS= read -r line; do echo "    $line"; done
    fi

    bcm_any_key
}

# =============================================================================
# Построить SQL ProxySQL для назначения writer'а = ${target_ip}.
#
# ⚠️⚠️ ВЕС САМ ПО СЕБЕ НЕ МЕНЯЕТ WRITER'А (проверено вживую, ProxySQL 2.6.6 + PXC 8.4,
# июнь 2026). С mysql_galera_hostgroups galera-checker выбирает активным writer'ом
# (HG_WRITE ONLINE) ноду по весу ТОЛЬКО СРЕДИ нод, сконфигурированных в
# writer_hostgroup (HG_WRITE) в самой таблице mysql_servers. Нода, осевшая в
# reader_hostgroup (HG_READ) — а install-сид и SAVE после раскладки checker'а кладут
# не-writer'ов именно туда — для checker'а «выделенный reader» и НЕ повышается в
# writer'ы НИКАКИМ весом (db02 weight=1000 в HG20 → writer'ом оставался db03; ловили
# вживую, это и был баг меню «Сменить Writer»). Прежний код делал только
# `UPDATE … SET weight` → на живом кластере молча НЕ срабатывал.
#
# Детерминированный и самоисцеляющий приём: ПЕРЕСОБРАТЬ набор серверов — все PXC-ноды
# в HG_WRITE (target вес 1000, остальные 100), checker сам разложит их по
# backup_writer/reader (writer_is_also_reader=2). Удаляем строки PXC-хостов ПО
# hostname (по всем HG разом, без констант HG11/HG30), затем вставляем канон.
# Проверено вживую: db02 стал стабильным writer'ом (все ноды в HG10), failover-пул
# (HG11) заполнен. ⚠️ Это НЕ прежний «битый» DELETE FROM …WHERE hostgroup_id=HG_WRITE
# + INSERT…SELECT FROM HG_READ (тот пустил HG_WRITE при target уже в HG_WRITE) —
# здесь полная пересборка из cluster.conf, поэтому идемпотентна и без гонки с checker'ом.
# =============================================================================
_pxc_build_writer_sql() {
    local target_ip="$1" hg_write="$2"
    local del_list="" values=""
    local node ip
    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        local w=100
        [[ "$ip" == "$target_ip" ]] && w=1000
        del_list="${del_list:+${del_list},}'${ip}'"
        values="${values:+${values},}(${hg_write},'${ip}',3306,${w},200)"
    done
    printf 'DELETE FROM mysql_servers WHERE hostname IN (%s); INSERT INTO mysql_servers(hostgroup_id,hostname,port,weight,max_connections) VALUES %s; LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;' \
        "$del_list" "$values"
}

# =============================================================================
# 4. Сменить Writer (обновить cluster.conf + ProxySQL HG10 на web-узлах)
# =============================================================================
_pxc_change_writer() {
    bcm_section_header "Смена WRITER-узла PXC"

    if [[ ${#BCM_NODES_PXC[@]} -eq 0 ]]; then
        bcm_error "Нет PXC-узлов в конфигурации."
        bcm_any_key; return
    fi

    # Фактический writer (runtime ProxySQL), откат на конфиг.
    local current_writer
    current_writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || echo "")
    [[ -z "$current_writer" ]] && current_writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")
    bcm_info "Текущий WRITER: ${current_writer:-не задан}"
    echo

    # Показать готовые узлы
    echo "  Доступные PXC-узлы (только готовые, wsrep_ready=ON):"
    local i=1
    local -a ready_nodes=()
    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if bcm_ssh_reachable "$ip" 3 2>/dev/null && _pxc_node_ready "$ip" 2>/dev/null; then
            local marker=" "
            [[ "$node" == "$current_writer" ]] && marker="★"
            local cluster_size
            cluster_size=$(_pxc_cluster_size "$ip")
            printf "    %d. %s%-14s (%s)  cluster_size=%s\n" \
                "$i" "$marker" "$node" "$ip" "${cluster_size:-?}"
            ready_nodes+=("$node")
            ((i++))
        else
            printf "    —  %-14s (%s)  [недоступен или не Primary]\n" "$node" "$ip"
        fi
    done

    if [[ ${#ready_nodes[@]} -eq 0 ]]; then
        bcm_error "Нет доступных Primary-узлов для назначения Writer."
        bcm_any_key; return
    fi

    echo
    local node_idx
    bcm_read_choice "Введите номер нового Writer (0 — отмена)" node_idx
    [[ "${node_idx:-0}" == "0" || -z "${node_idx:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }

    if ! [[ "${node_idx}" =~ ^[0-9]+$ ]] || \
       [[ "${node_idx}" -lt 1 || "${node_idx}" -gt "${#ready_nodes[@]}" ]]; then
        bcm_error "Неверный выбор."
        bcm_any_key; return
    fi

    local new_writer="${ready_nodes[$((node_idx-1))]}"
    local new_writer_ip="${BCM_NODE_IP[$new_writer]:-}"

    if [[ "$new_writer" == "$current_writer" ]]; then
        bcm_warn "${new_writer} уже является текущим Writer."
        bcm_any_key; return
    fi

    echo
    bcm_info "Новый Writer: ${new_writer} (${new_writer_ip})"
    if ! bcm_confirm "Обновить Writer в cluster.conf и ProxySQL на всех web-узлах?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    # 1. Обновить cluster.conf
    bcm_info "Обновляем cluster.conf: writer = ${new_writer}..."
    bcm_conf_set "layer.pxc" "writer" "$new_writer"
    BCM_CONF_LOADED=0
    bcm_load_topology
    bcm_ok "cluster.conf обновлён."

    # 2. Обновить ProxySQL HG10 на всех web-узлах
    local hg_write
    hg_write=$(bcm_get_proxysql_hg_write 2>/dev/null || echo "10")
    local hg_read
    hg_read=$(bcm_get_proxysql_hg_read 2>/dev/null || echo "20")
    local proxysql_admin_port proxysql_admin_user proxysql_admin_pass
    proxysql_admin_port=$(bcm_get_proxysql_admin_port 2>/dev/null || echo "6032")
    proxysql_admin_user=$(bcm_get_proxysql_admin_user 2>/dev/null || echo "admin")
    proxysql_admin_pass=$(bcm_get_proxysql_admin_pass 2>/dev/null || echo "admin")
    # Пароль в одинарных кавычках (с экранированием самих ') для инлайна в -p'...'.
    local aps_q="'${proxysql_admin_pass//\'/\'\\\'\'}'"

    bcm_info "Обновляем ProxySQL HG${hg_write} на web-узлах..."

    local web_errors=0
    for web_node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$web_node" ]] && continue
        local web_ip="${BCM_NODE_IP[$web_node]:-}"
        [[ -z "$web_ip" ]] && continue

        if ! bcm_ssh_reachable "$web_ip" 4 2>/dev/null; then
            bcm_warn "  ${web_node}: SSH недоступен — пропускаем."
            web_errors=$((web_errors+1))
            continue
        fi

        # Пересобрать набор серверов: все PXC в HG_WRITE, target вес 1000 (см.
        # _pxc_build_writer_sql — вес сам по себе writer'а НЕ двигает, нужна
        # HG_WRITE-принадлежность). galera-checker сам разложит остальных в
        # backup_writer/reader.
        local writer_sql
        writer_sql=$(_pxc_build_writer_sql "$new_writer_ip" "$hg_write")
        local proxysql_update_script
        proxysql_update_script=$(cat <<PROXYSQL_SCRIPT
# ProxySQL принимает пароль только как -p<pass>. ⚠️ Инлайним -p${aps_q} ПРЯМО в команду:
# через переменную (MYSQL_ADMIN="...-p'pass'"; \$MYSQL_ADMIN) кавычки остаются литеральными
# при ре-экспансии → пароль='pass' → Access denied (ловили вживую на rolling-тесте).
mysql --default-auth=mysql_native_password -h127.0.0.1 -P${proxysql_admin_port} -u${proxysql_admin_user} -p${aps_q} -e "${writer_sql}" 2>/dev/null && echo PROXYSQL_OK || echo PROXYSQL_FAIL
PROXYSQL_SCRIPT
)
        local result
        result=$(echo "$proxysql_update_script" | bcm_ssh_exec_timeout "$web_ip" 20 \
            "bash -s" 2>/dev/null)

        if [[ "$result" == *"PROXYSQL_OK"* ]]; then
            bcm_ok "  ${web_node}: ProxySQL обновлён → writer=${new_writer} (${new_writer_ip})"
        else
            bcm_error "  ${web_node}: ошибка обновления ProxySQL"
            web_errors=$((web_errors+1))
        fi
    done

    echo
    if [[ $web_errors -gt 0 ]]; then
        bcm_warn "Обновлено с ошибками (${web_errors} web-узлов не обновлены)."
        bcm_info "Повторите операцию для недоступных узлов позже."
    else
        bcm_ok "Writer успешно изменён: ${current_writer:-?} → ${new_writer}"
    fi

    bcm_log_info "PXC Writer изменён: ${current_writer:-none} → ${new_writer} (${new_writer_ip})"
    bcm_any_key
}

# =============================================================================
# 5. Авто-failover: проверить Writer, выбрать альтернативу
# =============================================================================
_pxc_auto_failover() {
    bcm_section_header "Авто-failover PXC Writer"

    local current_writer
    current_writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")

    if [[ -z "$current_writer" ]]; then
        bcm_error "Writer не задан в cluster.conf. Задайте через 'Сменить Writer'."
        bcm_any_key; return
    fi

    local writer_ip="${BCM_NODE_IP[$current_writer]:-}"
    if [[ -z "$writer_ip" ]]; then
        bcm_error "IP текущего Writer '${current_writer}' не найден в cluster.conf."
        bcm_any_key; return
    fi

    bcm_info "Проверяем текущий Writer: ${current_writer} (${writer_ip})..."
    echo

    # Проверить доступность текущего writer
    local writer_ok=0
    if bcm_ssh_reachable "$writer_ip" 5 2>/dev/null; then
        if _pxc_node_ready "$writer_ip" 2>/dev/null; then
            writer_ok=1
            bcm_ok "Writer ${current_writer} работает нормально (wsrep_ready=ON, Primary)."
        else
            bcm_warn "Writer ${current_writer} доступен по SSH, но Galera не в состоянии Primary!"
        fi
    else
        bcm_warn "Writer ${current_writer} НЕДОСТУПЕН по SSH!"
    fi

    if [[ $writer_ok -eq 1 ]]; then
        bcm_info "Failover не требуется."
        bcm_any_key; return
    fi

    # Найти альтернативный узел
    bcm_info "Ищем альтернативный Primary-узел..."
    local new_writer=""
    local new_writer_ip=""
    local best_cluster_size=0

    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" || "$node" == "$current_writer" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        if ! bcm_ssh_reachable "$ip" 4 2>/dev/null; then
            bcm_info "  ${node} (${ip}): SSH недоступен"
            continue
        fi

        if ! _pxc_node_ready "$ip" 2>/dev/null; then
            local st
            st=$(_pxc_wsrep_var "$ip" "wsrep_cluster_status")
            bcm_info "  ${node} (${ip}): wsrep_ready=OFF или ${st:-?}"
            continue
        fi

        local cluster_size
        cluster_size=$(_pxc_cluster_size "$ip")
        cluster_size="${cluster_size:-0}"

        bcm_info "  ${node} (${ip}): wsrep_ready=ON, cluster_size=${cluster_size}"

        # Выбираем узел с наибольшим cluster_size
        if [[ "$cluster_size" -ge 2 && "$cluster_size" -gt "$best_cluster_size" ]]; then
            best_cluster_size="$cluster_size"
            new_writer="$node"
            new_writer_ip="$ip"
        fi
    done

    if [[ -z "$new_writer" ]]; then
        bcm_error "Не найдено доступного Primary-узла с cluster_size >= 2."
        bcm_warn "Кластер не имеет кворума. Ручное вмешательство необходимо."
        bcm_any_key; return
    fi

    echo
    bcm_warn "Writer ${current_writer} недоступен!"
    bcm_info "Предлагаемый новый Writer: ${new_writer} (${new_writer_ip}), cluster_size=${best_cluster_size}"
    echo

    if ! bcm_confirm "Выполнить failover: назначить ${new_writer} новым Writer?"; then
        bcm_info "Отменено. Failover не выполнен."
        bcm_any_key; return
    fi

    # Обновить cluster.conf
    bcm_info "Обновляем cluster.conf: writer = ${new_writer}..."
    bcm_conf_set "layer.pxc" "writer" "$new_writer"
    BCM_CONF_LOADED=0
    bcm_load_topology
    bcm_ok "cluster.conf обновлён."

    # Обновить ProxySQL на web-узлах
    local hg_write
    hg_write=$(bcm_get_proxysql_hg_write 2>/dev/null || echo "10")
    local hg_read
    hg_read=$(bcm_get_proxysql_hg_read 2>/dev/null || echo "20")
    local proxysql_admin_port proxysql_admin_user proxysql_admin_pass
    proxysql_admin_port=$(bcm_get_proxysql_admin_port 2>/dev/null || echo "6032")
    proxysql_admin_user=$(bcm_get_proxysql_admin_user 2>/dev/null || echo "admin")
    proxysql_admin_pass=$(bcm_get_proxysql_admin_pass 2>/dev/null || echo "admin")
    # Пароль в одинарных кавычках (с экранированием самих ') для инлайна в -p'...'.
    local aps_q="'${proxysql_admin_pass//\'/\'\\\'\'}'"

    bcm_info "Обновляем ProxySQL HG${hg_write} на web-узлах..."

    for web_node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$web_node" ]] && continue
        local web_ip="${BCM_NODE_IP[$web_node]:-}"
        [[ -z "$web_ip" ]] && continue

        if ! bcm_ssh_reachable "$web_ip" 4 2>/dev/null; then
            bcm_warn "  ${web_node}: SSH недоступен — пропускаем."
            continue
        fi

        # Пересобрать набор серверов: все PXC в HG_WRITE, новый writer вес 1000
        # (см. _pxc_build_writer_sql — вес сам по себе writer'а НЕ двигает).
        local writer_sql
        writer_sql=$(_pxc_build_writer_sql "$new_writer_ip" "$hg_write")
        local proxysql_failover_script
        proxysql_failover_script=$(cat <<PROXYSQL_SCRIPT
# ProxySQL принимает пароль только как -p<pass>. ⚠️ Инлайним -p${aps_q} ПРЯМО в команду
# (не через переменную — иначе кавычки литеральны при ре-экспансии → Access denied).
mysql --default-auth=mysql_native_password -h127.0.0.1 -P${proxysql_admin_port} -u${proxysql_admin_user} -p${aps_q} -e "${writer_sql}" 2>/dev/null && echo OK || echo FAIL
PROXYSQL_SCRIPT
)
        local result
        result=$(echo "$proxysql_failover_script" | bcm_ssh_exec_timeout "$web_ip" 20 \
            "bash -s" 2>/dev/null)

        if [[ "$result" == *"OK"* ]]; then
            bcm_ok "  ${web_node}: ProxySQL → writer=${new_writer}"
        else
            bcm_error "  ${web_node}: ошибка обновления ProxySQL"
        fi
    done

    echo
    bcm_ok "Авто-failover завершён: ${current_writer} → ${new_writer} (${new_writer_ip})"
    bcm_log_info "PXC AUTO-FAILOVER: ${current_writer} → ${new_writer} (${new_writer_ip})"
    bcm_any_key
}

# =============================================================================
# 6. Резервное копирование с xtrabackup
# =============================================================================
_pxc_backup() {
    bcm_section_header "Резервное копирование PXC (xtrabackup)"

    if [[ ${#BCM_NODES_PXC[@]} -eq 0 ]]; then
        bcm_error "Нет PXC-узлов в конфигурации."
        bcm_any_key; return
    fi

    local current_writer
    current_writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")

    # Выбор узла для бэкапа (рекомендуется не-writer)
    echo "  Доступные PXC-узлы:"
    local i=1
    local -a avail_nodes=()
    local -a avail_ips=()
    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-?}"
        local marker=" "
        [[ "$node" == "$current_writer" ]] && marker="★"
        local state="недоступен"
        if bcm_ssh_reachable "$ip" 3 2>/dev/null; then
            state=$(bcm_ssh_service_status "$ip" "mysqld")
        fi
        printf "    %d. %s%-14s (%s)  mysqld: %s\n" "$i" "$marker" "$node" "$ip" "$state"
        avail_nodes+=("$node")
        avail_ips+=("$ip")
        ((i++))
    done

    echo
    bcm_info "★ = текущий Writer. Рекомендуется делать бэкап с НЕ-Writer узла."
    echo

    local node_idx
    bcm_read_choice "Выберите узел для бэкапа (0 — отмена)" node_idx
    [[ "${node_idx:-0}" == "0" || -z "${node_idx:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }

    if ! [[ "${node_idx}" =~ ^[0-9]+$ ]] || \
       [[ "${node_idx}" -lt 1 || "${node_idx}" -gt "${#avail_nodes[@]}" ]]; then
        bcm_error "Неверный выбор."
        bcm_any_key; return
    fi

    local backup_node="${avail_nodes[$((node_idx-1))]}"
    local backup_ip="${avail_ips[$((node_idx-1))]}"

    # Директория для бэкапа
    local default_backup_dir="/var/backup/mysql/$(date +%Y%m%d_%H%M%S)"
    local backup_dir
    bcm_read_choice "Директория бэкапа на ${backup_node} [${default_backup_dir}]" backup_dir
    backup_dir="${backup_dir:-$default_backup_dir}"

    echo
    bcm_info "Узел:    ${backup_node} (${backup_ip})"
    bcm_info "Каталог: ${backup_dir}"

    if ! bcm_confirm "Запустить xtrabackup?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    bcm_info "Запускаем xtrabackup на ${backup_node}..."
    bcm_info "(Это может занять несколько минут в зависимости от размера БД)"
    echo

    local result
    result=$(bcm_ssh_exec_timeout "$backup_ip" 600 \
        "mkdir -p '${backup_dir}' && \
         xtrabackup --backup \
           --target-dir='${backup_dir}' \
           --datadir=/var/lib/mysql \
           2>&1 | tail -20 && \
         xtrabackup --prepare \
           --target-dir='${backup_dir}' \
           2>&1 | tail -10 && \
         du -sh '${backup_dir}' && \
         echo BACKUP_OK || echo BACKUP_FAIL" \
        2>/dev/null)

    echo "$result" | while IFS= read -r line; do echo "  $line"; done

    if [[ "$result" == *"BACKUP_OK"* ]]; then
        local backup_size
        backup_size=$(echo "$result" | grep -E '^[0-9]' | head -1 | awk '{print $1}')
        bcm_ok "Резервная копия создана: ${backup_dir} (${backup_size:-?})"
        bcm_log_info "PXC Backup: ${backup_node} (${backup_ip}) → ${backup_dir}"
    else
        bcm_error "Бэкап завершился ошибкой. Проверьте логи."
    fi

    bcm_any_key
}

# =============================================================================
# 7. Показать wsrep-переменные (расширенный статус)
# =============================================================================
_pxc_show_wsrep() {
    bcm_section_header "Расширенный WSREP статус (SHOW STATUS LIKE 'wsrep%')"

    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ════ ${node} (${ip}) ════"

        if ! bcm_ssh_reachable "$ip" 4 2>/dev/null; then
            bcm_echo_color "RED" "  SSH недоступен"
            echo
            continue
        fi

        local wsrep_output
        wsrep_output=$(bcm_get_galera_status "$ip" 2>/dev/null)

        if [[ -n "$wsrep_output" ]]; then
            echo "$wsrep_output" | while IFS=$'\t' read -r varname value; do
                printf "  %-40s = " "$varname"
                case "$varname" in
                    wsrep_ready)
                        [[ "$value" == "ON" ]] && bcm_echo_color "GREEN_BOLD" "$value" || bcm_echo_color "RED_BOLD" "$value"
                        ;;
                    wsrep_cluster_status)
                        [[ "$value" == "Primary" ]] && bcm_echo_color "GREEN" "$value" || bcm_echo_color "RED" "$value"
                        ;;
                    wsrep_local_state_comment)
                        [[ "$value" == "Synced" ]] && bcm_echo_color "GREEN" "$value" || bcm_echo_color "YELLOW" "$value"
                        ;;
                    *)
                        echo "$value"
                        ;;
                esac
                echo
            done
        else
            bcm_warn "  Нет данных — mysqld остановлен или нет прав."
        fi
        echo
    done

    bcm_any_key
}

# =============================================================================
# 8. Корректная остановка всего кластера БД
# =============================================================================
_pxc_stop_cluster() {
    bcm_section_header "Корректная остановка Galera кластера"

    bcm_warn "╔══════════════════════════════════════════════════════════════╗"
    bcm_warn "║  ВНИМАНИЕ! Эта операция корректно останавливает базы данных   ║"
    bcm_warn "║  на всех узлах кластера. Сначала останавливаются READER-узлы,║"
    bcm_warn "║  а WRITER-узел останавливается ПОСЛЕДНИМ, чтобы сохранить   ║"
    bcm_warn "║  актуальную позицию (safe_to_bootstrap) для следующего старта.║"
    bcm_warn "╚══════════════════════════════════════════════════════════════╝"
    echo

    if [[ ${#BCM_NODES_PXC[@]} -eq 0 ]]; then
        bcm_error "Нет PXC-узлов в конфигурации."
        bcm_any_key; return
    fi

    local writer
    writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")
    if [[ -z "$writer" ]]; then
        bcm_warn "Не удалось автоматически определить WRITER-узел из cluster.conf."
        writer="${BCM_NODES_PXC[0]}"
        bcm_info "В качестве условного WRITER будет использован: ${writer}"
    else
        bcm_info "Текущий WRITER (останавливается ПОСЛЕДНИМ): ${writer}"
    fi

    # Сформируем списки узлов
    local -a readers=()
    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        if [[ "$node" != "$writer" ]]; then
            readers+=("$node")
        fi
    done

    echo "  План остановки:"
    if [[ ${#readers[@]} -gt 0 ]]; then
        echo "    1. Остановить READER-узлы: ${readers[*]}"
    fi
    echo "    2. Остановить WRITER-узел: ${writer}"
    echo

    if ! bcm_confirm "Вы действительно хотите остановить все базы данных в кластере?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    # 1. Остановить ридеры
    for node in "${readers[@]}"; do
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_info "Останавливаем службу mysql на READER-узле: ${node} (${ip})..."
        if bcm_ssh_reachable "$ip" 3 2>/dev/null; then
            local res
            res=$(bcm_ssh_exec_timeout "$ip" 30 "systemctl stop mysql.service mysql@bootstrap.service 2>&1")
            bcm_ok "  Узел ${node}: остановлен. ${res:-}"
        else
            bcm_warn "  Узел ${node}: недоступен по SSH (пропускаем)."
        fi
    done

    # 2. Остановить райтер
    local writer_ip="${BCM_NODE_IP[$writer]:-}"
    if [[ -n "$writer_ip" ]]; then
        bcm_info "Останавливаем службу mysql на WRITER-узле: ${writer} (${writer_ip}) (ПОСЛЕДНИЙ)..."
        if bcm_ssh_reachable "$writer_ip" 3 2>/dev/null; then
            local res
            res=$(bcm_ssh_exec_timeout "$writer_ip" 30 "systemctl stop mysql.service mysql@bootstrap.service 2>&1")
            bcm_ok "  Узел ${writer}: остановлен. ${res:-}"
        else
            bcm_warn "  Узел ${writer}: недоступен по SSH (пропускаем)."
        fi
    fi

    bcm_info "Все запланированные узлы обработаны."
    bcm_any_key
}

# =============================================================================
# Импорт mysqldump в PXC (на writer, реплицируется Galera) — «без заморочек»
# =============================================================================
# Дамп лежит НА ЭТОЙ (мозг/web) ноде. Стримится по SSH на writer-узел и заливается
# в его ЛОКАЛЬНЫЙ mysql через root-сокет (без пароля, полные права; то же делает
# install.sh::configure_portal_db). Galera синхронно реплицирует на все PXC-ноды.
# «Заморочки» берёт на себя: определяет runtime-writer, проверяет Synced, создаёт
# БД utf8mb4, gzip-стрим по сети, авто-распознаёт .gz, сессионно гасит FK/UNIQUE-
# проверки (чтобы дамп зашёл без правок), опц. прогресс через pv.
_pxc_import_dump() {
    bcm_section_header "Импорт mysqldump в PXC (на writer)"

    # 1) writer: runtime (ProxySQL HG10) → откат на конфиг
    local writer writer_ip
    writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || echo "")
    [[ -z "$writer" ]] && writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")
    [[ -z "$writer" ]] && { bcm_error "Не удалось определить writer-узел."; bcm_any_key; return; }
    writer_ip="${BCM_NODE_IP[$writer]:-}"
    [[ -z "$writer_ip" ]] && { bcm_error "Нет IP для writer '${writer}' в cluster.conf."; bcm_any_key; return; }
    if ! bcm_node_reachable "$writer_ip" 5 2>/dev/null; then
        bcm_error "Writer ${writer} (${writer_ip}) недоступен по SSH."; bcm_any_key; return
    fi
    # Гейт: писать можно только в Synced-кластер (иначе данные не реплицируются/затрутся)
    local st; st=$(_pxc_wsrep_var "$writer_ip" "wsrep_local_state_comment")
    [[ "$st" == "Synced" ]] || { bcm_error "Writer ${writer} не Synced (состояние: ${st:-?}) — импорт отменён."; bcm_any_key; return; }

    bcm_info "Импорт пойдёт на WRITER ${writer} (${writer_ip}) → Galera реплицирует на все PXC-ноды."
    bcm_info "Дамп должен лежать НА ЭТОЙ ноде. Лучший формат — дамп ОДНОЙ БД (mysqldump <db>, без --databases)."
    echo

    # 2) файл дампа (локально на мозг-ноде)
    local file
    bcm_read_choice "Путь к файлу дампа (.sql или .sql.gz) (0 — отмена)" file
    [[ "${file:-0}" == "0" || -z "${file:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ -f "$file" && -r "$file" ]] || { bcm_error "Файл не найден/нечитаем: ${file}"; bcm_any_key; return; }

    # 3) целевая БД (имя — только [A-Za-z0-9_], безопасно для бэктиков/кавычек)
    local db
    bcm_read_choice "Имя целевой БД (0 — отмена)" db
    [[ "${db:-0}" == "0" || -z "${db:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || { bcm_error "Недопустимое имя БД (разрешены буквы, цифры, _)."; bcm_any_key; return; }

    # 4) gzip? (по содержимому, не по расширению)
    local gz=0
    gzip -t "$file" >/dev/null 2>&1 && gz=1

    # 5) существующая БД → предложить DROP/CREATE или импорт поверх
    local drop=0 exists tbls
    exists=$(bcm_ssh_exec "$writer_ip" "mysql -N -e \"SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${db}'\"" </dev/null 2>/dev/null | tr -d '[:space:]')
    if [[ "$exists" == "1" ]]; then
        tbls=$(bcm_ssh_exec "$writer_ip" "mysql -N -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}'\"" </dev/null 2>/dev/null | tr -d '[:space:]')
        bcm_warn "БД '${db}' уже существует на кластере (${tbls:-?} таблиц)."
        if bcm_confirm "ПЕРЕСОЗДАТЬ БД (DROP + CREATE — удалит ТЕКУЩИЕ данные) перед импортом?"; then
            drop=1
        else
            bcm_confirm "Импортировать ПОВЕРХ существующей (одноимённые объекты из дампа перезапишут текущие)?" \
                || { bcm_info "Отменено."; bcm_any_key; return; }
        fi
    else
        bcm_info "БД '${db}' будет создана (utf8mb4)."
    fi

    # 6) подтверждение
    local sz; sz=$(du -h "$file" 2>/dev/null | awk '{print $1}')
    [[ $gz -eq 1 ]] && bcm_info "Формат файла: gzip (распаковка на лету на writer)." || bcm_info "Формат файла: обычный SQL (сжимается для передачи по сети)."
    bcm_warn "⚠ Импорт пишет в Galera синхронно — на время большой заливки возможен flow-control (кратковременные тормоза кластера)."
    bcm_confirm "Импортировать '${file}' (${sz:-?}) → БД '${db}' на ${writer}?" \
        || { bcm_info "Отменено."; bcm_any_key; return; }

    # 7) (пере)создать БД на writer (root-сокет, без пароля)
    if [[ $drop -eq 1 ]]; then
        bcm_info "DROP DATABASE ${db}..."
        bcm_ssh_exec "$writer_ip" "mysql -e 'DROP DATABASE IF EXISTS \`${db}\`'" </dev/null 2>/dev/null || true
    fi
    if ! bcm_ssh_exec_verbose "$writer_ip" "mysql -e 'CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'" </dev/null 2>&1; then
        bcm_error "Не удалось создать БД '${db}' на ${writer}."; bcm_any_key; return
    fi

    # 8) стрим импорта. Поток в ОДНУ сессию mysql: сначала SET (гасим FK/UNIQUE —
    #    дамп зайдёт без правок и в любом порядке таблиц), затем сам дамп.
    #    gz-файл шлём как есть (gunzip на writer); несжатый — gzip'уем для сети.
    #    Локальный SET-префикс инжектится на writer перед gunzip'ом.
    local remote_cmd="{ echo 'SET SESSION foreign_key_checks=0; SET SESSION unique_checks=0;'; gunzip -c; } | mysql --default-character-set=utf8mb4 '${db}'"
    bcm_info "Импорт начат. НЕ прерывайте — большой дамп может идти несколько минут..."
    local rc=0
    if [[ $gz -eq 1 ]]; then
        if command -v pv >/dev/null 2>&1; then
            pv "$file" | bcm_ssh_exec_verbose "$writer_ip" "$remote_cmd" || rc=$?
        else
            bcm_ssh_exec_verbose "$writer_ip" "$remote_cmd" < "$file" || rc=$?
        fi
    else
        if command -v pv >/dev/null 2>&1; then
            pv "$file" | gzip -c | bcm_ssh_exec_verbose "$writer_ip" "$remote_cmd" || rc=$?
        else
            gzip -c "$file" | bcm_ssh_exec_verbose "$writer_ip" "$remote_cmd" || rc=$?
        fi
    fi

    # 9) итог + верификация
    local newtbls
    newtbls=$(bcm_ssh_exec "$writer_ip" "mysql -N -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}'\"" </dev/null 2>/dev/null | tr -d '[:space:]')
    if [[ $rc -eq 0 ]]; then
        bcm_ok "Импорт завершён: БД '${db}' на ${writer} — таблиц: ${newtbls:-?}. Реплицировано Galera на все PXC."
        bcm_info "Если это БД портала — убедитесь, что .settings.php указывает на ProxySQL (127.0.0.1:6033) и БД '${db}' (см. install.sh::configure_portal_db)."
    else
        bcm_error "Импорт завершился с ошибкой (rc=${rc}) — дамп мог залиться ЧАСТИЧНО (таблиц сейчас: ${newtbls:-?})."
        bcm_error "Проверьте вывод выше; при необходимости пересоздайте БД (DROP) и повторите импорт."
    fi
    bcm_any_key
}

# =============================================================================
# Меню модуля
# =============================================================================
_pxc_print_menu() {
    local -a items=(
        "1.  Статус кластера (wsrep_cluster_status, wsrep_ready, cluster_size)"
        "2.  Расширенный WSREP статус (все wsrep переменные)"
        "3.  Bootstrap Galera  ⚠ ОПАСНО — только при полной остановке!"
        "4.  Подключить узел к кластеру (Join)"
        "5.  Сменить Writer (cluster.conf + ProxySQL HG10)"
        "6.  Авто-failover Writer (проверить и при необходимости сменить)"
        "7.  Резервное копирование (xtrabackup)"
        "8.  Остановить базы данных на всех узлах (корректный шатдаун)"
        "9.  Редактировать общие настройки MySQL (drop-in, все PXC)"
        "10. Импорт mysqldump в PXC (на writer, реплицируется Galera)"
        "0.  Назад"
    )
    bcm_print_menu items
}

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
        bcm_color "WHITE" "  ═══ Percona XtraDB Cluster (Galera) ═══"
        echo

        _pxc_print_menu

        local choice
        bcm_read_choice "Введите ваш выбор" choice

        case "$choice" in
            1) _pxc_show_status   ;;
            2) _pxc_show_wsrep    ;;
            3) _pxc_bootstrap     ;;
            4) _pxc_join_node     ;;
            5) _pxc_change_writer ;;
            6) _pxc_auto_failover ;;
            7) _pxc_backup        ;;
            8) _pxc_stop_cluster  ;;
            9) bcm_confedit_mysql ;;
            10) _pxc_import_dump  ;;
            0) break              ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: '${choice}'. Введите число от 0 до 10." ;;
        esac
    done
}

main "$@"
