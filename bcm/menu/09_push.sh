#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 09_push.sh — Управление bx-push-server (Bitrix RTC/Push)
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
# Константы (названия сервисов, пути конфига)
# ─────────────────────────────────────────────────────────────────────────────
PUSH_CONF_FILE="/etc/sysconfig/push-server-multi"
PUSH_SERVICE_PATTERNS=(
    "bx-push-server"
    "push-server-multi"
    "push-server"
)

# Определить актуальное имя сервиса push на узле
_push_service_name() {
    local ip="$1"
    local result
    for svc in "${PUSH_SERVICE_PATTERNS[@]}"; do
        result=$(bcm_ssh_exec_timeout "$ip" 5 \
            "systemctl is-active '${svc}' 2>/dev/null || echo inactive" \
            2>/dev/null | tr -d '[:space:]')
        # Если не failed (т.е. active или inactive — сервис существует)
        if bcm_ssh_exec_timeout "$ip" 5 \
           "systemctl list-units --full --all '${svc}*' 2>/dev/null | grep -q '${svc}'" \
           2>/dev/null; then
            echo "$svc"
            return 0
        fi
    done
    echo "bx-push-server"  # fallback
}

# ─────────────────────────────────────────────────────────────────────────────
# Вспомогательные функции
# ─────────────────────────────────────────────────────────────────────────────

# Показать статус push-server на всех web-узлах
_push_show_status() {
    bcm_section_header "Статус bx-push-server на web-узлах"

    printf "  %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Узел' 12)" "$(bcm_pad 'IP' 15)" "$(bcm_pad 'Статус' 15)" "Клиентов"
    bcm_divider "$BCM_LINE_H1"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        local push_status clients
        push_status=$(bcm_check_push_status "$ip")

        # Количество подключённых клиентов: установленные соединения на sub-портах
        # push-server-multi (8010-8015) и pub-портах (9010-9011).
        # grep -c сам печатает «0» при отсутствии совпадений (и выходит rc=1) —
        # `|| echo '?'` дописывал бы «?» к нулю («0?»). Берём число как есть.
        clients=$(bcm_ssh_exec_timeout "$ip" 8 \
            "ss -tn state established 2>/dev/null | grep -cE ':(801[0-9]|901[0-9])\\b'" \
            2>/dev/null | tr -d '[:space:]')
        [[ "$clients" =~ ^[0-9]+$ ]] || clients="?"

        local color="GREEN"
        [[ "$push_status" != "active" ]] && color="RED"

        printf "  %s │ %s │ " "$(bcm_pad "$node" 12)" "$(bcm_pad "$ip" 15)"
        bcm_echo_color "$color" "$(bcm_pad "$push_status" 15)"
        printf " │ %s клиентов\n" "${clients:-?}"
    done

    echo
    bcm_any_key
}

# Запустить/остановить/перезапустить push-server
_push_service_action() {
    local action="$1"
    local action_ru
    case "$action" in
        start)   action_ru="запуск"     ;;
        stop)    action_ru="остановка"  ;;
        restart) action_ru="перезапуск" ;;
        *)       action_ru="$action"    ;;
    esac

    bcm_section_header "bx-push-server: ${action_ru}"

    if ! bcm_confirm "${action_ru^} bx-push-server на ВСЕХ web-узлах?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        local svc_name
        svc_name=$(_push_service_name "$ip")

        bcm_info "${action_ru^} ${svc_name} на ${node} (${ip})..."
        local result
        result=$(bcm_ssh_exec_timeout "$ip" 30 \
            "systemctl ${action} '${svc_name}' 2>&1 && echo SVC_OK || echo SVC_FAIL" \
            2>/dev/null)

        if [[ "$result" == *"SVC_OK"* ]]; then
            bcm_ok "  ${node}: ${svc_name} — ${action_ru}."
        else
            bcm_error "  ${node}: ошибка: ${result}"
        fi
    done

    bcm_any_key
}

# Показать конфигурацию push-server
_push_show_config() {
    bcm_section_header "Конфигурация bx-push-server (${PUSH_CONF_FILE})"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        local conf_content
        conf_content=$(bcm_ssh_exec_timeout "$ip" 10 \
            "cat '${PUSH_CONF_FILE}' 2>/dev/null || \
             cat /etc/push-server/push-server.conf 2>/dev/null || \
             echo '(конфиг не найден)'" \
            2>/dev/null)

        echo "$conf_content" | while IFS= read -r line; do
            echo "    $line"
        done
        echo
    done

    bcm_any_key
}

# Показать логи push-server
_push_show_logs() {
    bcm_section_header "Логи bx-push-server (journalctl, последние 50 строк)"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        local log_output
        log_output=$(bcm_ssh_exec_timeout "$ip" 10 \
            "journalctl -u 'push-server*' --no-pager -n 50 2>/dev/null || \
             journalctl -u 'bx-push-server*' --no-pager -n 50 2>/dev/null || \
             tail -50 /var/log/push-server/error.log 2>/dev/null || \
             echo '(логи недоступны)'" \
            2>/dev/null)

        echo "$log_output" | while IFS= read -r line; do
            echo "    $line"
        done
        echo
    done

    bcm_any_key
}

# Показать количество подключённых клиентов
_push_show_clients() {
    bcm_section_header "Количество подключённых клиентов"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        # Пробуем разные способы получить статистику
        local stats
        stats=$(bcm_ssh_exec_timeout "$ip" 10 \
            "# Соединения на sub-портах (8010-8015) и pub-портах (9010-9011)
             sub_conns=\$(ss -tn state established 2>/dev/null | grep -cE ':801[0-9]\\b' 2>/dev/null || echo 0)
             pub_conns=\$(ss -tn state established 2>/dev/null | grep -cE ':901[0-9]\\b' 2>/dev/null || echo 0)
             echo \"ESTABLISHED на sub-портах (8010-8015): \${sub_conns}\"
             echo \"ESTABLISHED на pub-портах (9010-9011): \${pub_conns}\"

             # Статус службы push
             systemctl status push-server 2>/dev/null | grep -E 'Active|Tasks|Memory' | head -5 || true" \
            2>/dev/null)

        if [[ -n "$stats" ]]; then
            echo "$stats" | while IFS= read -r line; do echo "    $line"; done
        else
            bcm_info "    Нет данных (push-server может быть остановлен)."
        fi
        echo
    done

    bcm_any_key
}

# Настроить параметры push-server (интерактивно)
_push_configure() {
    bcm_section_header "Настройка bx-push-server"

    local web01_ip="${BCM_NODE_IP[${BCM_NODES_WEB[0]:-}]:-}"
    if [[ -z "$web01_ip" ]]; then
        bcm_error "Не найден web01."
        bcm_any_key; return
    fi

    # Показать текущие значения
    bcm_info "Текущая конфигурация (${PUSH_CONF_FILE}):"
    local current_conf
    current_conf=$(bcm_ssh_exec_timeout "$web01_ip" 10 \
        "cat '${PUSH_CONF_FILE}' 2>/dev/null || echo '(не найден)'" \
        2>/dev/null)
    echo "$current_conf" | while IFS= read -r line; do echo "  $line"; done
    echo

    bcm_warn "Топология портов push-server-multi задаётся ключами BASE_SUB (8010-8015)"
    bcm_warn "и BASE_PUB (9010-9011); их смена требует регенерации JSON-конфигов через"
    bcm_warn "bitrix-env (menu.sh → 6). Здесь правится только /etc/sysconfig/push-server-multi."
    echo

    # Интерактивный ввод параметров (реальные значения bitrix-env по умолчанию)
    local ws_port sub_port pub_port security_key

    bcm_read_choice "WS_PORT (WebSocket порт, по умолчанию 1337)" ws_port
    ws_port="${ws_port:-1337}"

    bcm_read_choice "BASE_SUB (база sub-портов, по умолчанию 801)" sub_port
    sub_port="${sub_port:-801}"

    bcm_read_choice "BASE_PUB (база pub-портов, по умолчанию 901)" pub_port
    pub_port="${pub_port:-901}"

    bcm_read_choice "SECURITY_KEY (ключ безопасности, оставьте пустым для сохранения текущего)" security_key

    echo
    bcm_info "Параметры:"
    bcm_info "  WS_PORT  = ${ws_port}"
    bcm_info "  SUB_PORT = ${sub_port}"
    bcm_info "  PUB_PORT = ${pub_port}"
    [[ -n "$security_key" ]] && bcm_info "  SECURITY_KEY = [обновлён]"

    if ! bcm_confirm "Применить на всех web-узлах?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_info "Обновление конфига на ${node} (${ip})..."

        local update_cmd
        update_cmd="mkdir -p \$(dirname '${PUSH_CONF_FILE}')
# Обновить или добавить параметры
for key_val in 'WS_PORT=${ws_port}' 'BASE_SUB=${sub_port}' 'BASE_PUB=${pub_port}'; do
    key=\${key_val%%=*}
    val=\${key_val#*=}
    if grep -q \"^\${key}=\" '${PUSH_CONF_FILE}' 2>/dev/null; then
        sed -i \"s|^\${key}=.*|\${key}=\${val}|\" '${PUSH_CONF_FILE}'
    else
        echo \"\${key}=\${val}\" >> '${PUSH_CONF_FILE}'
    fi
done"

        if [[ -n "$security_key" ]]; then
            update_cmd+="
if grep -q '^SECURITY_KEY=' '${PUSH_CONF_FILE}' 2>/dev/null; then
    sed -i \"s|^SECURITY_KEY=.*|SECURITY_KEY=${security_key}|\" '${PUSH_CONF_FILE}'
else
    echo 'SECURITY_KEY=${security_key}' >> '${PUSH_CONF_FILE}'
fi"
        fi

        local svc_name
        svc_name=$(_push_service_name "$ip")
        update_cmd+="
systemctl restart '${svc_name}' 2>&1 && echo CONF_OK || echo CONF_FAIL"

        local result
        result=$(echo "$update_cmd" | bcm_ssh_exec_timeout "$ip" 30 \
            "bash -s 2>&1" \
            2>/dev/null)

        if [[ "$result" == *"CONF_OK"* ]]; then
            bcm_ok "  ${node}: конфиг обновлён, push-server перезапущен."
        else
            bcm_error "  ${node}: ошибка: ${result}"
        fi
    done

    bcm_any_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Главное меню модуля
# ─────────────────────────────────────────────────────────────────────────────
_push_menu() {
    while true; do
        bcm_section_header "Push/RTC сервис (bx-push-server)"

        local menu_items=(
            "1.  Статус bx-push-server на всех web-узлах"
            "2.  Запустить bx-push-server"
            "3.  Остановить bx-push-server"
            "4.  Перезапустить bx-push-server"
            "5.  Показать конфигурацию (${PUSH_CONF_FILE})"
            "6.  Показать логи (journalctl)"
            "7.  Количество подключённых клиентов"
            "8.  Настроить push (WS_PORT, SUB_PORT, PUB_PORT)"
            "0.  Назад"
        )
        bcm_print_menu menu_items

        local choice
        bcm_read_choice "Ваш выбор" choice

        case "$choice" in
            1) _push_show_status              ;;
            2) _push_service_action "start"   ;;
            3) _push_service_action "stop"    ;;
            4) _push_service_action "restart" ;;
            5) _push_show_config              ;;
            6) _push_show_logs                ;;
            7) _push_show_clients             ;;
            8) _push_configure                ;;
            0) return 0                       ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: ${choice}" ;;
        esac
    done
}

_push_menu
