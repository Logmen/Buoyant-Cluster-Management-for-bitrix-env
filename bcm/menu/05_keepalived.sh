#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 05_keepalived.sh — VIP / Keepalived management
# Управление VIP, VRRP-приоритетами и keepalived на lb-узлах.
# Также показывает VRRP VRID web-узлов (HA Cron).
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

# ─────────────────────────────────────────────────────────────────────────────
# Вспомогательные функции
# ─────────────────────────────────────────────────────────────────────────────

# Показать текущий VIP и кто его держит
_kp_show_vip_status() {
    bcm_section_header "Статус VIP / VRRP"

    local vip
    vip=$(bcm_get_vip 2>/dev/null || echo "")

    if [[ -z "$vip" ]]; then
        bcm_warn "VIP не задан в cluster.conf ([network] vip=...)"
        return
    fi

    bcm_info "Виртуальный IP: ${vip}"
    echo

    printf "  %s │ %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Узел' 12)" "$(bcm_pad 'IP' 15)" "$(bcm_pad 'VRRP роль' 10)" \
        "$(bcm_pad 'Приоритет' 9)" "Статус keepalived"
    bcm_divider "$BCM_LINE_H1"

    for node in "${BCM_NODES_LB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        # Держит ли узел VIP?
        local has_vip role
        has_vip=$(bcm_ssh_exec_timeout "$ip" 5 \
            "ip addr show | grep -c '${vip}' 2>/dev/null || echo 0" \
            2>/dev/null | tr -d '[:space:]')
        if [[ "${has_vip:-0}" -gt 0 ]]; then
            role="MASTER"
        else
            role="BACKUP"
        fi

        # Приоритет из keepalived.conf на самом узле
        local priority
        priority=$(bcm_ssh_exec_timeout "$ip" 5 \
            "grep -m1 'priority' /etc/keepalived/keepalived.conf 2>/dev/null | awk '{print \$2}' || echo '?'" \
            2>/dev/null | tr -d '[:space:]')

        # Статус сервиса
        local svc_st
        svc_st=$(bcm_ssh_service_status "$ip" "keepalived")

        local svc_color="GREEN"
        [[ "$svc_st" != "active" ]] && svc_color="RED"

        printf "  %s │ %s │ %s │ %s │ " \
            "$(bcm_pad "$node" 12)" "$(bcm_pad "$ip" 15)" "$(bcm_pad "$role" 10)" "$(bcm_pad "${priority:-?}" 9)"
        bcm_echo_color "$svc_color" "$svc_st"
        echo
    done

    echo
    bcm_info "Текущий MASTER (держатель VIP):"
    local holder
    holder=$(bcm_get_vip_holder "$vip" 2>/dev/null || echo "неизвестно")
    if [[ -n "$holder" && "$holder" != "неизвестно" ]]; then
        bcm_ok "  VIP ${vip} → ${holder}"
    else
        bcm_warn "  VIP не определён ни на одном lb-узле!"
    fi
    echo
    bcm_any_key
}

# Показать состояние VRRP на всех lb-узлах
_kp_show_vrrp_state() {
    bcm_section_header "VRRP состояние на lb-узлах"

    for node in "${BCM_NODES_LB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        local state_output
        state_output=$(bcm_ssh_exec_timeout "$ip" 10 \
            "journalctl -u keepalived -n 20 --no-pager 2>/dev/null | \
             grep -E 'MASTER|BACKUP|Entering|Transition' | tail -5 || echo 'нет данных'" \
            2>/dev/null)

        if [[ -n "$state_output" ]]; then
            echo "$state_output" | while IFS= read -r line; do
                echo "    $line"
            done
        else
            bcm_info "    Нет данных о VRRP переходах"
        fi

        # Текущая роль через ip addr
        local vip
        vip=$(bcm_get_vip 2>/dev/null || echo "")
        if [[ -n "$vip" ]]; then
            local has_vip
            has_vip=$(bcm_ssh_exec_timeout "$ip" 5 \
                "ip addr show | grep -c '${vip}' 2>/dev/null || echo 0" \
                2>/dev/null | tr -d '[:space:]')
            if [[ "${has_vip:-0}" -gt 0 ]]; then
                bcm_ok "    → MASTER (держит VIP ${vip})"
            else
                bcm_info "    → BACKUP"
            fi
        fi
        echo
    done

    bcm_any_key
}

# Изменить приоритет на lb-узле
_kp_change_priority() {
    bcm_section_header "Изменение VRRP приоритета"

    if [[ ${#BCM_NODES_LB[@]} -eq 0 ]]; then
        bcm_warn "Нет lb-узлов в конфигурации."
        bcm_any_key; return
    fi

    # Выбор узла
    echo "  Доступные lb-узлы:"
    local i=1
    local -a node_list=()
    for node in "${BCM_NODES_LB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-?}"
        local cur_priority
        cur_priority=$(bcm_ssh_exec_timeout "$ip" 5 \
            "grep -m1 'priority' /etc/keepalived/keepalived.conf 2>/dev/null | awk '{print \$2}'" \
            2>/dev/null | tr -d '[:space:]')
        printf "    %d. %s (%s)  текущий приоритет: %s\n" \
            "$i" "$node" "$ip" "${cur_priority:-?}"
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

    local new_priority
    bcm_read_choice "Новый приоритет (1-254, 0 — отмена)" new_priority
    [[ "$new_priority" == "0" || -z "$new_priority" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    if ! [[ "$new_priority" =~ ^[0-9]+$ ]] || \
       [[ "$new_priority" -lt 1 || "$new_priority" -gt 254 ]]; then
        bcm_warn "Неверный приоритет. Допустимо: 1-254."
        bcm_any_key; return
    fi

    bcm_info "Установка приоритета ${new_priority} на ${selected_node} (${selected_ip})..."

    if ! bcm_confirm "Применить изменение?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    # Обновить keepalived.conf на удалённом узле
    local result
    result=$(bcm_ssh_exec_timeout "$selected_ip" 15 \
        "sed -i 's/^\(\s*priority\s\+\)[0-9]\+/\1${new_priority}/' \
         /etc/keepalived/keepalived.conf && \
         systemctl reload-or-restart keepalived 2>&1 && echo OK || echo FAIL" \
        2>/dev/null)

    if [[ "$result" == *"OK"* ]]; then
        bcm_ok "Приоритет обновлён, keepalived перезапущен на ${selected_node}."
        # Обновить в cluster.conf
        bcm_conf_set "layer.lb" "${selected_node}.priority" "$new_priority"
    else
        bcm_error "Не удалось обновить приоритет. Ответ: ${result}"
    fi

    bcm_any_key
}

# Принудительный failover (MASTER → BACKUP временно)
_kp_force_failover() {
    bcm_section_header "Принудительный failover VIP"

    local vip
    vip=$(bcm_get_vip 2>/dev/null || echo "")
    if [[ -z "$vip" ]]; then
        bcm_warn "VIP не задан."
        bcm_any_key; return
    fi

    local master_node
    master_node=$(bcm_get_vip_holder "$vip" 2>/dev/null || echo "")
    if [[ -z "$master_node" ]]; then
        bcm_warn "Не удалось определить текущий MASTER."
        bcm_any_key; return
    fi

    local master_ip="${BCM_NODE_IP[$master_node]:-}"
    bcm_info "Текущий MASTER: ${master_node} (${master_ip})"
    bcm_warn "Действие: понизить приоритет до 90 на ${master_node}, через 30 сек восстановить."

    if ! bcm_confirm "Выполнить failover?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    # Получить текущий приоритет
    local orig_priority
    orig_priority=$(bcm_ssh_exec_timeout "$master_ip" 5 \
        "grep -m1 'priority' /etc/keepalived/keepalived.conf 2>/dev/null | awk '{print \$2}'" \
        2>/dev/null | tr -d '[:space:]')
    orig_priority="${orig_priority:-110}"

    bcm_info "Исходный приоритет: ${orig_priority}"
    bcm_info "Понижаем до 90..."

    bcm_ssh_exec_timeout "$master_ip" 10 \
        "sed -i 's/^\(\s*priority\s\+\)[0-9]\+/\190/' /etc/keepalived/keepalived.conf && \
         systemctl reload-or-restart keepalived" 2>/dev/null || true

    bcm_ok "Приоритет понижен. Ожидаем 30 секунд..."

    local i
    for i in $(seq 30 -1 1); do
        printf "  \r  Восстановление через: %2d сек..." "$i"
        sleep 1
    done
    echo

    bcm_info "Восстанавливаем приоритет ${orig_priority}..."
    bcm_ssh_exec_timeout "$master_ip" 10 \
        "sed -i 's/^\(\s*priority\s\+\)[0-9]\+/\1${orig_priority}/' /etc/keepalived/keepalived.conf && \
         systemctl reload-or-restart keepalived" 2>/dev/null || true

    bcm_ok "Приоритет восстановлен на ${master_node}."

    local new_holder
    new_holder=$(bcm_get_vip_holder "$vip" 2>/dev/null || echo "?")
    bcm_info "Текущий держатель VIP: ${new_holder}"

    bcm_any_key
}

# Показать keepalived.conf на каждом lb-узле
_kp_show_conf() {
    bcm_section_header "keepalived.conf на lb-узлах"

    for node in "${BCM_NODES_LB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ════ ${node} (${ip}) ════"
        local conf_content
        conf_content=$(bcm_ssh_exec_timeout "$ip" 10 \
            "cat /etc/keepalived/keepalived.conf 2>/dev/null || echo '(файл не найден)'" \
            2>/dev/null)
        echo "$conf_content" | while IFS= read -r line; do
            echo "    $line"
        done
        echo
    done

    bcm_any_key
}

# Перезапустить keepalived на всех lb-узлах
_kp_restart_all() {
    bcm_section_header "Перезапуск keepalived на всех lb-узлах"

    if ! bcm_confirm "Перезапустить keepalived на ВСЕХ lb-узлах?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    for node in "${BCM_NODES_LB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_info "Перезапуск keepalived на ${node} (${ip})..."
        local result
        result=$(bcm_ssh_exec_timeout "$ip" 15 \
            "systemctl restart keepalived 2>&1 && echo OK || echo FAIL" \
            2>/dev/null)

        if [[ "$result" == *"OK"* ]]; then
            bcm_ok "  ${node}: keepalived перезапущен."
        else
            bcm_error "  ${node}: ошибка: ${result}"
        fi
    done

    bcm_any_key
}

# Показать VRRP логи (journalctl)
_kp_show_logs() {
    bcm_section_header "VRRP логи (journalctl)"

    for node in "${BCM_NODES_LB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"
        local logs
        logs=$(bcm_ssh_exec_timeout "$ip" 10 \
            "journalctl -u keepalived --no-pager -n 30 2>/dev/null || echo 'нет логов'" \
            2>/dev/null)
        echo "$logs" | while IFS= read -r line; do
            echo "    $line"
        done
        echo
    done

    bcm_any_key
}

# Показать статус VRRP VRID web-узлов (HA Cron)
_kp_show_web_vrid() {
    bcm_section_header "VRRP VRID web-узлов (HA Cron Keepalived)"

    local vrid
    vrid=$(bcm_get_web_vrid 2>/dev/null || echo "56")
    bcm_info "VRID: ${vrid}  (из cluster.conf [layer.web] keepalived_vrid)"
    echo

    printf "  %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Узел' 12)" "$(bcm_pad 'IP' 15)" "$(bcm_pad 'VRRP роль' 12)" "Статус keepalived"
    bcm_divider "$BCM_LINE_H1"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        local state
        state=$(bcm_ssh_exec_timeout "$ip" 8 \
            "ip vrrp show 2>/dev/null | grep -w ${vrid} | awk '{print \$NF}' | head -1 || \
             keepalived -v 2>/dev/null | head -1 || echo UNKNOWN" \
            2>/dev/null | tr -d '[:space:]')

        # Более надёжный способ через /var/run/keepalived
        local master_count
        master_count=$(bcm_ssh_exec_timeout "$ip" 5 \
            "grep -r 'MASTER' /var/run/keepalived/ 2>/dev/null | grep -c '${vrid}' || \
             journalctl -u keepalived -n 10 --no-pager 2>/dev/null | grep 'VRID ${vrid}' | grep -c MASTER || \
             echo 0" \
            2>/dev/null | tail -1 | tr -d '[:space:]')

        local role="BACKUP"
        [[ "${master_count:-0}" -gt 0 ]] && role="MASTER"

        local svc_st
        svc_st=$(bcm_ssh_service_status "$ip" "keepalived")
        local svc_color="GREEN"
        [[ "$svc_st" != "active" ]] && svc_color="RED"

        printf "  %s │ %s │ %s │ " "$(bcm_pad "$node" 12)" "$(bcm_pad "$ip" 15)" "$(bcm_pad "$role" 12)"
        bcm_echo_color "$svc_color" "$svc_st"
        echo
    done

    echo
    bcm_info "MASTER web-узел выполняет задания Bitrix Cron Agent."
    bcm_any_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Главное меню модуля
# ─────────────────────────────────────────────────────────────────────────────
_kp_menu() {
    while true; do
        bcm_section_header "VIP / Keepalived"

        local menu_items=(
            "1.  Статус VIP: кто держит, приоритеты VRRP"
            "2.  Состояние VRRP на всех lb-узлах (MASTER/BACKUP)"
            "3.  Изменить VRRP приоритет на узле"
            "4.  Принудительный failover (MASTER → BACKUP на 30с)"
            "5.  Показать keepalived.conf на lb-узлах"
            "6.  Перезапустить keepalived на всех lb-узлах"
            "7.  Логи VRRP (journalctl keepalived)"
            "8.  Статус VRRP VRID web-узлов (HA Cron Keepalived)"
            "9.  Редактировать haproxy.cfg (${EDITOR:-vi}, все LB)"
            "0.  Назад"
        )
        bcm_print_menu menu_items

        local choice
        bcm_read_choice "Ваш выбор" choice

        case "$choice" in
            1) _kp_show_vip_status   ;;
            2) _kp_show_vrrp_state   ;;
            3) _kp_change_priority   ;;
            4) _kp_force_failover    ;;
            5) _kp_show_conf         ;;
            6) _kp_restart_all       ;;
            7) _kp_show_logs         ;;
            8) _kp_show_web_vrid     ;;
            9) bcm_confedit_haproxy  ;;
            0) return 0              ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: ${choice}" ;;
        esac
    done
}

_kp_menu
