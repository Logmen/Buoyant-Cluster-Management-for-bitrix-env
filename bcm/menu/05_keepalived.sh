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

# Принудительный переезд ОДНОГО VRRP-инстанса.
#
# ⚠️ Механизм зависит от инстанса, единого нет:
#   • без nopreempt (LB-VIP, VI_<web_vrid> крона/lsyncd) — понижаем priority ЭТОГО
#     инстанса, пир перехватывает по preempt, потом возвращаем исходное значение;
#   • с nopreempt (сессии, push, кэш, transformer) — понижение приоритета НЕ работает
#     по определению: резервная нода не отбирает VIP у живого MASTER'а. Единственный
#     путь — увести инстанс в FAULT, чтобы держатель сам отдал VIP. Для этого health-
#     check'и понимают маркер /run/bcm-vrrp-fault-*, который здесь ставится и снимается.
#     Сервисы при этом НЕ трогаются.
# ⚠️ Правится ТОЛЬКО блок выбранного инстанса: на web-нодах их пять, и общий
# `sed 's/priority .../'` по файлу обнулил бы приоритеты сразу всем.
_kp_force_failover() {
    bcm_section_header "Принудительный переезд VIP (по одному инстансу)"

    # Таблица инстансов: метка|VRID|VIP|слой|маркер FAULT (пусто — механизм priority)
    local -a rows=()
    local v
    v=$(bcm_get_vip 2>/dev/null || echo "")
    [[ -n "$v" ]] && rows+=("VIP портала (HAProxy)|-|${v}|lb|")
    v=$(bcm_get_web_vrid 2>/dev/null || echo "")
    [[ -n "$v" ]] && rows+=("Cron/lsyncd (VI_${v})|${v}|127.0.0.254|web|")
    local sec
    for sec in session push cache; do
        local svip sport svrid
        svip=$(bcm_conf_get "$sec" redis_vip 2>/dev/null || echo "")
        sport=$(bcm_conf_get "$sec" redis_port 2>/dev/null || echo "")
        svrid=$(bcm_conf_get "$sec" keepalived_vrid 2>/dev/null || echo "")
        [[ -n "$svip" && -n "$sport" ]] && rows+=("Redis ${sec} (:${sport})|${svrid}|${svip}|web|/run/bcm-vrrp-fault-${sport}")
    done
    local tvip tvrid
    tvip=$(bcm_conf_get transformer vip 2>/dev/null || echo "")
    tvrid=$(bcm_conf_get transformer vrid 2>/dev/null || echo "")
    [[ -n "$tvip" ]] && rows+=("Transformer|${tvrid}|${tvip}|web|/run/bcm-vrrp-fault-transformer")

    if [[ ${#rows[@]} -eq 0 ]]; then
        bcm_warn "Ни одного VIP не задано в cluster.conf."; bcm_any_key; return
    fi

    # Текущие держатели
    echo "  Инстансы и держатели:"
    local -a holders=()
    local i=0 row label vrid vip layer marker holder
    for row in "${rows[@]}"; do
        IFS='|' read -r label vrid vip layer marker <<< "$row"
        holder=$(_kp_holder_of "$vip" "$layer")
        holders+=("$holder")
        i=$((i+1))
        printf "    %d. %-26s VIP %-15s держит: %s\n" "$i" "$label" "$vip" "${holder:-—}"
    done
    echo "    0. Назад"
    echo

    local idx
    bcm_read_choice "Какой инстанс переместить (1-${i}, 0 — отмена)" idx
    [[ "$idx" == "0" || -z "$idx" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 && "$idx" -le "$i" ]] || { bcm_error "Неверный выбор."; bcm_any_key; return; }

    IFS='|' read -r label vrid vip layer marker <<< "${rows[$((idx-1))]}"
    holder="${holders[$((idx-1))]}"
    [[ -z "$holder" ]] && { bcm_error "Держатель не определён — переезжать не от кого."; bcm_any_key; return; }
    local hip="${BCM_NODE_IP[$holder]:-}"
    [[ -z "$hip" ]] && { bcm_error "Не найден IP узла ${holder}."; bcm_any_key; return; }

    bcm_info "${label}: держит ${holder} (${hip})"
    if [[ -n "$marker" ]]; then
        bcm_warn "Инстанс с nopreempt → уводим в FAULT маркером ${marker}. Сервисы не трогаем."
        bcm_warn "VIP уедет к пиру и ОСТАНЕТСЯ там: nopreempt не вернёт его автоматически."
    else
        bcm_warn "Инстанс без nopreempt → временно понижаем его priority, затем возвращаем."
    fi
    bcm_confirm "Выполнить переезд?" || { bcm_info "Отменено."; bcm_any_key; return; }

    if [[ -n "$marker" ]]; then
        bcm_ssh_exec_timeout "$hip" 10 "touch '${marker}'" </dev/null 2>/dev/null
        bcm_ok "Маркер выставлен, ждём переезда..."
        _kp_wait_holder_change "$vip" "$layer" "$holder" 25
        bcm_ssh_exec_timeout "$hip" 10 "rm -f '${marker}'" </dev/null 2>/dev/null
        bcm_info "Маркер снят — инстанс на ${holder} снова здоров (останется BACKUP)."
    else
        local orig
        orig=$(bcm_ssh_exec_timeout "$hip" 8 \
            "awk '/^vrrp_instance/{n=\$2} n!=\"\" && /^[[:space:]]*priority/ && (\"${vrid}\"==\"-\" || n ~ /_${vrid}\$|^VI_${vrid}\$/){print \$2; exit}' /etc/keepalived/keepalived.conf" 2>/dev/null | tr -d '[:space:]')
        orig="${orig:-110}"
        bcm_info "Исходный priority: ${orig} → 90"
        _kp_set_priority "$hip" "$vrid" 90
        _kp_wait_holder_change "$vip" "$layer" "$holder" 25
        bcm_info "Возвращаем priority ${orig}..."
        _kp_set_priority "$hip" "$vrid" "$orig"
    fi

    # ⚠️ Ждём, пока держатель устоится, а не проверяем один раз: у preempt-инстанса
    # после возврата приоритета VIP переезжает обратно, и несколько секунд его не
    # держит НИКТО. Одиночная проверка попадала в это окно и пугала оператора
    # сообщением «держатель не определяется», хотя всё шло штатно.
    local now="" t
    for ((t = 0; t < 25; t++)); do
        now=$(_kp_holder_of "$vip" "$layer")
        [[ -n "$now" ]] && break
        sleep 1
    done

    if [[ -z "$now" ]]; then
        bcm_warn "${label}: за 25с держатель не определился — проверьте keepalived на обеих нодах."
    elif [[ -n "$marker" ]]; then
        # nopreempt: VIP закрепляется за новым узлом, обратно сам не вернётся.
        if [[ "$now" != "$holder" ]]; then
            bcm_ok "${label}: VIP перешёл ${holder} → ${now} и останется там (nopreempt)."
        else
            bcm_warn "${label}: VIP остался на ${holder}. Проверьте health-check и keepalived на пире."
        fi
    else
        # preempt: понижение приоритета — временное, возврат на исходный узел штатен.
        if [[ "$now" == "$holder" ]]; then
            bcm_ok "${label}: переезд проверен; приоритет возвращён, VIP снова на ${holder} — так и задумано для preempt-инстанса."
        else
            bcm_ok "${label}: VIP сейчас на ${now} (был ${holder}); с восстановленным приоритетом вернётся на ${holder}."
        fi
    fi
    bcm_any_key
}

# Кто держит адрес: для lb-VIP — штатный хелпер, для web-инстансов ищем адрес на узле
# (у крона это маркерный 127.0.0.254 на lo).
_kp_holder_of() {
    local vip="$1" layer="$2" node ip
    if [[ "$layer" == "lb" ]]; then
        bcm_get_vip_holder "$vip" 2>/dev/null || echo ""
        return
    fi
    for node in $(bcm_get_nodes "$layer" 2>/dev/null); do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        if [[ "$(bcm_ssh_exec_timeout "$ip" 5 "ip -4 addr 2>/dev/null | grep -q 'inet ${vip}[/ ]' && echo YES" </dev/null 2>/dev/null | tr -d '[:space:]')" == "YES" ]]; then
            echo "$node"; return
        fi
    done
    echo ""
}

# priority ТОЛЬКО у блока нужного инстанса (vrid='-' → единственный инстанс на узле).
_kp_set_priority() {
    local ip="$1" vrid="$2" val="$3"
    bcm_ssh_exec_timeout "$ip" 15 "
        awk -v vrid='${vrid}' -v val='${val}' '
            /^vrrp_instance/ { inb = (vrid == \"-\" || \$2 ~ (\"_\" vrid \"\$\")) }
            inb && /^[[:space:]]*priority[[:space:]]/ { sub(/[0-9]+[[:space:]]*\$/, val) }
            /^}/ { inb = 0 }
            { print }
        ' /etc/keepalived/keepalived.conf > /tmp/bcm-kp.new && mv /tmp/bcm-kp.new /etc/keepalived/keepalived.conf
        systemctl reload keepalived 2>/dev/null || systemctl restart keepalived" </dev/null 2>/dev/null
}

# Ждать смены держателя (или таймаут).
_kp_wait_holder_change() {
    local vip="$1" layer="$2" was="$3" secs="${4:-25}" i now
    for ((i=0; i<secs; i++)); do
        sleep 1
        now=$(_kp_holder_of "$vip" "$layer")
        [[ -n "$now" && "$now" != "$was" ]] && { bcm_ok "  VIP уехал на ${now} (за ${i}с)."; return 0; }
    done
    bcm_warn "  За ${secs}с держатель не сменился."
    return 1
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

    # ⚠️ Роль VI_<vrid> определяется НАЛИЧИЕМ маркерного адреса 127.0.0.254/32 на lo:
    # у этого инстанса нет «настоящего» VIP, адрес на loopback и есть признак MASTER
    # (см. keepalived_web.conf.tmpl). Тем же способом работает bcm_get_cron_vrrp_holder,
    # поэтому спрашиваем его — один опрос на экран вместо двух на ноду.
    # Прежние способы не работали и экран ВСЕГДА показывал BACKUP на ОБЕИХ нодах при
    # живом HA-Cron (ловили вживую): команды `ip vrrp show` в iproute2 не существует,
    # keepalived не пишет состояние в /var/run/keepalived, а grep по последним 10
    # строкам journalctl не находит давний переход в MASTER.
    local cron_holder
    cron_holder=$(bcm_get_cron_vrrp_holder --force 2>/dev/null || echo "")

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        local role="BACKUP"
        [[ "$node" == "$cron_holder" ]] && role="MASTER"

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
            "4.  Принудительный переезд VIP (по одному инстансу)"
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
