#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 10_cron.sh — Управление HA Cron (Keepalived VRID на web-узлах)
# Bitrix Agent/Cron выполняется только на MASTER web-узле (держателе VRID).
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

# Получить VRID для web Keepalived
_cron_get_vrid() {
    bcm_get_web_vrid 2>/dev/null || echo "56"
}

# Определить текущий MASTER web-узел (держатель VRID)
_cron_get_master_node() {
    bcm_get_cron_vrrp_holder "force"
}

# Показать, какой web-узел держит VRID (MASTER Cron)
_cron_show_master() {
    bcm_section_header "HA Cron: VRRP VRID держатель"

    local vrid
    vrid=$(_cron_get_vrid)
    bcm_info "Keepalived VRID для HA Cron: ${vrid}"
    echo

    printf "  %s │ %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Узел' 12)" "$(bcm_pad 'IP' 15)" "$(bcm_pad 'Роль Cron' 12)" \
        "$(bcm_pad 'keepalived' 12)" "Приоритет"
    bcm_divider "$BCM_LINE_H1"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        local svc_st priority cron_role
        svc_st=$(bcm_ssh_service_status "$ip" "keepalived")
        priority=$(bcm_ssh_exec_timeout "$ip" 5 \
            "grep -A5 'virtual_router_id ${vrid}' /etc/keepalived/keepalived.conf 2>/dev/null | \
             grep -m1 'priority' | awk '{print \$2}' || echo '?'" \
            2>/dev/null | tr -d '[:space:]')

        # Определить роль на основе bcm_get_cron_vrrp_holder
        local holder
        holder=$(bcm_get_cron_vrrp_holder 2>/dev/null || echo "")
        if [[ "$holder" == "$node" ]]; then
            cron_role="MASTER"
        else
            cron_role="BACKUP"
        fi

        local svc_color="GREEN"
        [[ "$svc_st" != "active" ]] && svc_color="RED"
        local role_color="GRAY"
        [[ "$cron_role" == "MASTER" ]] && role_color="GREEN_BOLD"

        printf "  %s │ %s │ " "$(bcm_pad "$node" 12)" "$(bcm_pad "$ip" 15)"
        bcm_echo_color "$role_color" "$(bcm_pad "$cron_role" 12)"
        printf " │ "
        bcm_echo_color "$svc_color" "$(bcm_pad "$svc_st" 12)"
        printf " │ %s\n" "${priority:-?}"
    done

    echo
    local master
    master=$(_cron_get_master_node)
    if [[ -n "$master" ]]; then
        bcm_ok "MASTER Cron узел: ${master}"
    else
        bcm_warn "Не удалось определить MASTER Cron узел (возможно keepalived не запущен)."
    fi
    echo

    bcm_any_key
}

# Показать cron-задания на всех web-узлах
_cron_show_crontab() {
    bcm_section_header "Cron-задания (crontab -l на всех web-узлах)"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        local cron_output
        cron_output=$(bcm_ssh_exec_timeout "$ip" 10 \
            "crontab -l 2>/dev/null || echo '(cron пуст)'
             echo '--- /etc/cron.d/ ---'
             ls /etc/cron.d/ 2>/dev/null | head -10 || echo '(пусто)'
             echo '--- bitrix cron ---'
             crontab -l -u bitrix 2>/dev/null | head -20 || echo '(нет пользователя bitrix)'" \
            2>/dev/null)

        echo "$cron_output" | while IFS= read -r line; do
            echo "  $line"
        done
        echo
    done

    bcm_any_key
}

# Принудительно переключить MASTER Cron на конкретный web-узел
_cron_force_master() {
    bcm_section_header "Принудительное переключение MASTER Cron"

    local vrid
    vrid=$(_cron_get_vrid)

    if [[ ${#BCM_NODES_WEB[@]} -lt 2 ]]; then
        bcm_warn "Для переключения нужно минимум 2 web-узла."
        bcm_any_key; return
    fi

    echo "  Доступные web-узлы:"
    local i=1
    local -a node_list=()
    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-?}"
        local cur_priority
        cur_priority=$(bcm_ssh_exec_timeout "$ip" 5 \
            "grep -A5 'virtual_router_id ${vrid}' /etc/keepalived/keepalived.conf 2>/dev/null | \
             grep -m1 'priority' | awk '{print \$2}' || echo '?'" \
            2>/dev/null | tr -d '[:space:]')
        printf "    %d. %s (%s)  текущий приоритет: %s\n" \
            "$i" "$node" "$ip" "${cur_priority:-?}"
        node_list+=("$node")
        ((i++))
    done
    echo

    local node_idx
    bcm_read_choice "Выберите целевой узел MASTER Cron (1-$((i-1)), 0 — отмена)" node_idx
    [[ "$node_idx" == "0" || -z "$node_idx" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    if ! [[ "$node_idx" =~ ^[0-9]+$ ]] || \
       [[ "$node_idx" -lt 1 || "$node_idx" -gt "${#node_list[@]}" ]]; then
        bcm_warn "Неверный выбор."
        bcm_any_key; return
    fi

    local target_node="${node_list[$((node_idx-1))]}"
    local target_ip="${BCM_NODE_IP[$target_node]:-}"

    bcm_info "Целевой MASTER Cron: ${target_node} (${target_ip})"

    if ! bcm_confirm "Установить ${target_node} как MASTER Cron (VRID ${vrid})?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    # Установить высокий приоритет на целевом узле, низкий на остальных
    local high_priority=110
    local low_priority=90

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        local new_prio
        if [[ "$node" == "$target_node" ]]; then
            new_prio=$high_priority
        else
            new_prio=$low_priority
        fi

        bcm_info "Установка приоритета ${new_prio} на ${node} (VRID ${vrid})..."

        local result
        result=$(bcm_ssh_exec_timeout "$ip" 15 \
            "# Обновить приоритет для нашего VRID в keepalived.conf
             # Ищем блок с virtual_router_id и обновляем priority после него
             python3 -c \"
import re, sys
with open('/etc/keepalived/keepalived.conf', 'r') as f:
    content = f.read()
# Найти блок vrrp_instance с нашим VRID и заменить priority
pattern = r'(virtual_router_id\s+${vrid}\b.*?priority\s+)\d+'
replacement = r'\g<1>${new_prio}'
new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)
with open('/etc/keepalived/keepalived.conf', 'w') as f:
    f.write(new_content)
print('OK')
\" 2>/dev/null || \
             sed -i '/virtual_router_id ${vrid}/,/^}/{s/priority[[:space:]]*[0-9]*/priority ${new_prio}/}' \
                 /etc/keepalived/keepalived.conf 2>/dev/null && echo 'OK'
             systemctl reload-or-restart keepalived 2>&1 && echo PRIO_OK || echo PRIO_FAIL" \
            2>/dev/null)

        if [[ "$result" == *"PRIO_OK"* ]]; then
            bcm_ok "  ${node}: приоритет ${new_prio}, keepalived перезапущен."
        else
            bcm_error "  ${node}: ошибка: ${result}"
        fi
    done

    bcm_info "Ожидание VRRP-выборов (5 сек)..."
    sleep 5

    local new_master
    new_master=$(_cron_get_master_node)
    if [[ -n "$new_master" ]]; then
        bcm_ok "Новый MASTER Cron: ${new_master}"
    else
        bcm_info "Не удалось подтвердить MASTER автоматически. Проверьте вручную."
    fi

    bcm_any_key
}

# Показать статус Bitrix Agent
_cron_show_bitrix_agent() {
    bcm_section_header "Bitrix Agent статус"

    local master_node
    master_node=$(_cron_get_master_node)
    local master_ip=""
    if [[ -n "$master_node" ]]; then
        master_ip="${BCM_NODE_IP[$master_node]:-}"
        bcm_info "Выполнение Agent на: ${master_node} (${master_ip})"
    else
        bcm_warn "MASTER Cron узел не определён. Проверяем все web-узлы."
    fi

    echo

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        # Проверить bitrix_agent или cron
        local agent_output
        agent_output=$(bcm_ssh_exec_timeout "$ip" 15 \
            "# Статус Bitrix Agent через crontab
             echo '=== crontab bitrix пользователя ==='
             crontab -l -u bitrix 2>/dev/null | grep -v '^#' | grep -v '^$' | head -10 || echo '(нет задач)'

             # Запущенные процессы агента
             echo '=== Процессы php agent ==='
             ps aux 2>/dev/null | grep -E 'bitrix.*agent|cron_events' | grep -v grep | head -5 || echo '(нет процессов)'

             # Проверка cron.php
             echo '=== Последний запуск cron.php ==='
             find /home/*/www/bitrix/ /home/bitrix/www/bitrix/ -name 'cron_events.php' 2>/dev/null | head -2" \
            2>/dev/null)

        echo "$agent_output" | while IFS= read -r line; do echo "  $line"; done
        echo
    done

    bcm_any_key
}

# Включить/отключить cron на конкретном web-узле
_cron_toggle() {
    local action="$1"
    local action_ru
    [[ "$action" == "enable" ]] && action_ru="включение" || action_ru="отключение"

    bcm_section_header "Cron: ${action_ru} на web-узле"

    echo "  Доступные web-узлы:"
    local i=1
    local -a node_list=()
    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-?}"
        printf "    %d. %s (%s)\n" "$i" "$node" "$ip"
        node_list+=("$node")
        ((i++))
    done
    echo

    local node_idx
    bcm_read_choice "Выберите узел (1-$((i-1)), 0 — отмена)" node_idx
    [[ "$node_idx" == "0" || -z "$node_idx" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    if ! [[ "$node_idx" =~ ^[0-9]+$ ]] || \
       [[ "$node_idx" -lt 1 || "$node_idx" -gt "${#node_list[@]}" ]]; then
        bcm_warn "Неверный выбор."
        bcm_any_key; return
    fi

    local selected_node="${node_list[$((node_idx-1))]}"
    local selected_ip="${BCM_NODE_IP[$selected_node]:-}"

    if ! bcm_confirm "${action_ru^} cron на ${selected_node}?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    local systemd_action
    [[ "$action" == "enable" ]] && systemd_action="start" || systemd_action="stop"

    local result
    result=$(bcm_ssh_exec_timeout "$selected_ip" 15 \
        "systemctl ${systemd_action} crond 2>&1 || \
         systemctl ${systemd_action} cron 2>&1 && echo CRON_OK || echo CRON_FAIL" \
        2>/dev/null)

    if [[ "$result" == *"CRON_OK"* ]]; then
        bcm_ok "Cron ${action_ru} на ${selected_node}."
    else
        bcm_error "Ошибка: ${result}"
    fi

    bcm_any_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Управляемые cron-задания BCM (добавление/удаление через меню)
#
# Два класса, два файла в /etc/cron.d на ОБЕИХ web-нодах:
#   bcm-portal-master — «только на master»: на BACKUP файл ПЕРЕМЕЩЁН в
#                       /etc/bitrix-cluster/bcm-portal-master.disabled —
#                       ⚠️ именно вынос из /etc/cron.d: cronie (RHEL) исполняет
#                       и файлы с точкой (Debian-правило тут не работает,
#                       ловили вживую). Переключает cron_notify.sh.
#   bcm-local         — «на каждой ноде»: активен всегда и везде.
# Канонический источник содержимого — первая доступная web-нода; меню всегда
# раскатывает файл на все web-ноды (идемпотентно).
# ─────────────────────────────────────────────────────────────────────────────
BCM_CRON_MASTER="/etc/cron.d/bcm-portal-master"
BCM_CRON_MASTER_OFF="/etc/bitrix-cluster/bcm-portal-master.disabled"
BCM_CRON_LOCAL="/etc/cron.d/bcm-local"
BCM_CRON_HEADER="# Сгенерировано BCM (меню 10 — фоновые задания). Правки руками не делать."

# Первая доступная web-нода: "node ip"
_cron_first_web() {
    local node ip
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_node_reachable "$ip" 5 2>/dev/null && { echo "$node $ip"; return 0; }
    done
    return 1
}

# Содержимое управляемого файла (active или .disabled) с канонической ноды
# _cron_managed_get <master|local>
_cron_managed_get() {
    local class="$1" file
    [[ "$class" == "master" ]] && file="$BCM_CRON_MASTER" || file="$BCM_CRON_LOCAL"
    local node ip
    read -r node ip < <(_cron_first_web) || return 1
    local off="$BCM_CRON_MASTER_OFF"
    bcm_ssh_exec_timeout "$ip" 10 \
        "cat '${file}' 2>/dev/null || cat '${off}' 2>/dev/null" 2>/dev/null \
        | grep -v '^# Сгенерировано BCM' || true
}

# Раскатать содержимое на все web-ноды.
# master-класс: пишем как .disabled и дёргаем `cron_notify.sh assert` — нода сама
# включит файл, если она MASTER (роль-логика остаётся в одном месте).
# _cron_managed_push <master|local> <content>
_cron_managed_push() {
    local class="$1" content="$2" node ip ok=1
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "  ${node}: недоступен — файл НЕ обновлён (раскатайте позже повторным сохранением)."
            ok=0; continue
        fi
        if [[ "$class" == "master" ]]; then
            printf '%s\n%s\n' "$BCM_CRON_HEADER" "$content" \
                | bcm_ssh_exec "$ip" "rm -f '${BCM_CRON_MASTER}'; cat > '${BCM_CRON_MASTER_OFF}' && chmod 644 '${BCM_CRON_MASTER_OFF}'; /opt/bcm/bin/lib/cron_notify.sh assert >/dev/null 2>&1; ls '${BCM_CRON_MASTER}' 2>/dev/null || ls '${BCM_CRON_MASTER_OFF}'" >/dev/null 2>&1 \
                && bcm_ok "  ${node}: обновлено." || { bcm_error "  ${node}: ошибка записи."; ok=0; }
        else
            printf '%s\n%s\n' "$BCM_CRON_HEADER" "$content" \
                | bcm_ssh_exec "$ip" "cat > '${BCM_CRON_LOCAL}' && chmod 644 '${BCM_CRON_LOCAL}'" >/dev/null 2>&1 \
                && bcm_ok "  ${node}: обновлено." || { bcm_error "  ${node}: ошибка записи."; ok=0; }
        fi
    done
    return $((1 - ok))
}

# ──── Список заданий BCM ─────────────────────────────────────────────────────
_cron_managed_list() {
    bcm_section_header "Задания BCM (управляемые через меню)"
    local node ip
    bcm_color "WHITE" "  ── Только на master (bcm-portal-master) ──"
    _cron_managed_get master | grep -v '^[[:space:]]*$' | nl -w4 -s'. ' | sed 's/^/  /' \
        || echo "    (пусто)"
    echo
    bcm_color "WHITE" "  ── На каждой ноде (bcm-local) ──"
    _cron_managed_get local | grep -v '^[[:space:]]*$' | nl -w4 -s'. ' | sed 's/^/  /' \
        || echo "    (пусто)"
    echo
    bcm_color "WHITE" "  ── Фактическое состояние файлов по нодам ──"
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        local st
        st=$(bcm_ssh_exec_timeout "$ip" 8 \
            "[ -f '${BCM_CRON_MASTER}' ] && echo 'master-задания: АКТИВНЫ' || { [ -f '${BCM_CRON_MASTER_OFF}' ] && echo 'master-задания: выключены (BACKUP)' || echo 'master-задания: нет файла'; }" 2>/dev/null) || st="?"
        printf "    %-8s %s\n" "$node" "$st"
    done
    bcm_any_key
}

# ──── Добавить задание ───────────────────────────────────────────────────────
_cron_managed_add() {
    bcm_section_header "Добавить cron-задание BCM"
    bcm_info "Класс задания:"
    bcm_info "  1 — только на master (портал/БД: рассылки, импорты — НЕ задублируется)"
    bcm_info "  2 — на каждой web-ноде (локальное: чистка tmp и т.п.)"
    local cls class
    bcm_read_choice "Класс [1], 0 — отмена" cls
    [[ "$cls" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    case "${cls:-1}" in
        1) class="master" ;;
        2) class="local"  ;;
        *) bcm_warn "Неверный выбор."; bcm_any_key; return ;;
    esac

    local sched user cmd
    bcm_read_choice "Расписание (5 полей, напр. '*/5 * * * *')" sched
    # Базовая валидация: ровно 5 полей из допустимых символов cron
    local f_cnt
    f_cnt=$(echo "$sched" | awk '{print NF}')
    if [[ "$f_cnt" -ne 5 ]] || ! [[ "$sched" =~ ^[0-9\*/,\ \	-]+$ ]]; then
        bcm_error "Расписание должно быть 5 полей из цифр и * / , - (имена дней/месяцев не поддерживаются)."
        bcm_any_key; return
    fi
    bcm_read_choice "Пользователь [bitrix]" user
    user="${user:-bitrix}"
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { bcm_error "Некорректное имя пользователя."; bcm_any_key; return; }
    if ! id "$user" >/dev/null 2>&1; then
        bcm_warn "Пользователя '${user}' нет на этой ноде — проверьте, что он есть на web-нодах."
    fi
    bcm_read_choice "Команда (одной строкой)" cmd
    [[ -z "$cmd" ]] && { bcm_error "Команда пуста."; bcm_any_key; return; }
    if [[ "$cmd" == *$'\n'* || "$cmd" == *'%'* ]]; then
        bcm_error "Команда не должна содержать перевод строки и символ % (спецсимвол cron)."
        bcm_any_key; return
    fi

    local line="${sched} ${user} ${cmd}"
    echo
    bcm_info "Будет добавлено (${class}): ${line}"
    bcm_confirm "Сохранить и раскатать на web-ноды?" || { bcm_info "Отменено."; bcm_any_key; return; }

    local content
    content=$(_cron_managed_get "$class" | grep -v '^[[:space:]]*$' || true)
    content="${content:+$content$'\n'}${line}"
    _cron_managed_push "$class" "$content" && bcm_ok "Задание добавлено." || bcm_warn "Добавлено не на все ноды."
    bcm_any_key
}

# ──── Удалить задание ────────────────────────────────────────────────────────
_cron_managed_del() {
    bcm_section_header "Удалить cron-задание BCM"
    local cls class
    bcm_read_choice "Класс: 1 — master-only, 2 — на каждой ноде [1], 0 — отмена" cls
    [[ "$cls" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    case "${cls:-1}" in
        1) class="master" ;;
        2) class="local"  ;;
        *) bcm_warn "Неверный выбор."; bcm_any_key; return ;;
    esac

    local content
    content=$(_cron_managed_get "$class" | grep -v '^[[:space:]]*$' || true)
    [[ -z "$content" ]] && { bcm_info "Заданий класса '${class}' нет."; bcm_any_key; return; }

    echo "$content" | nl -w4 -s'. ' | sed 's/^/  /'
    echo
    local num total
    total=$(echo "$content" | grep -c .)
    bcm_read_choice "Номер задания для удаления (1-${total}, 0 — отмена)" num
    [[ "$num" == "0" || -z "$num" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [[ "$num" -lt 1 || "$num" -gt "$total" ]]; then
        bcm_warn "Неверный номер."; bcm_any_key; return
    fi
    bcm_info "Удаляю: $(echo "$content" | sed -n "${num}p")"
    bcm_confirm "Подтвердить удаление?" || { bcm_info "Отменено."; bcm_any_key; return; }

    local new_content
    new_content=$(echo "$content" | sed "${num}d")
    _cron_managed_push "$class" "$new_content" && bcm_ok "Задание удалено." || bcm_warn "Удалено не на всех нодах."
    bcm_any_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Главное меню модуля
# ─────────────────────────────────────────────────────────────────────────────
_cron_menu() {
    while true; do
        local vrid
        vrid=$(_cron_get_vrid)
        bcm_section_header "Фоновые задания HA Cron (VRID: ${vrid})"

        local menu_items=(
            "1.  Показать текущий MASTER Cron (держатель VRID ${vrid})"
            "2.  Cron-задания на всех web-узлах (crontab -l)"
            "3.  Принудительно переключить MASTER Cron на узел"
            "4.  Статус Bitrix Agent (процессы, cron_events.php)"
            "5.  Включить cron на конкретном web-узле"
            "6.  Отключить cron на конкретном web-узле"
            "7.  Задания BCM: список (master-only и локальные)"
            "8.  Задания BCM: добавить"
            "9.  Задания BCM: удалить"
            "0.  Назад"
        )
        bcm_print_menu menu_items

        local choice
        bcm_read_choice "Ваш выбор" choice

        case "$choice" in
            1) _cron_show_master           ;;
            2) _cron_show_crontab          ;;
            3) _cron_force_master          ;;
            4) _cron_show_bitrix_agent     ;;
            5) _cron_toggle "enable"       ;;
            6) _cron_toggle "disable"      ;;
            7) _cron_managed_list          ;;
            8) _cron_managed_add           ;;
            9) _cron_managed_del           ;;
            0) return 0                    ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: ${choice}" ;;
        esac
    done
}

_cron_menu
