#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 08_webservers.sh — Управление веб-серверами (Nginx + Apache/httpd)
# bitrix-env использует Apache mod_php (PHP-FPM отсутствует).
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

# Показать статус nginx и httpd на всех web-узлах
_ws_show_status() {
    bcm_section_header "Статус web-серверов на всех web-узлах"

    printf "  %s │ %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Узел' 12)" "$(bcm_pad 'IP' 15)" "$(bcm_pad 'nginx' 12)" \
        "$(bcm_pad 'httpd' 12)" "Версии"
    bcm_divider "$BCM_LINE_H1"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        local nginx_st httpd_st nginx_ver
        nginx_st=$(bcm_ssh_service_status "$ip" "nginx")
        httpd_st=$(bcm_ssh_service_status "$ip" "httpd")
        nginx_ver=$(bcm_get_nginx_version "$ip")

        local nginx_color="GREEN"
        local httpd_color="GREEN"
        [[ "$nginx_st" != "active" ]] && nginx_color="RED"
        [[ "$httpd_st" != "active" ]] && httpd_color="RED"

        printf "  %s │ %s │ " "$(bcm_pad "$node" 12)" "$(bcm_pad "$ip" 15)"
        bcm_echo_color "$nginx_color" "$(bcm_pad "$nginx_st" 12)"
        printf " │ "
        bcm_echo_color "$httpd_color" "$(bcm_pad "$httpd_st" 12)"
        printf " │ %s\n" "${nginx_ver:-nginx:?}"
    done

    echo
    bcm_any_key
}

# Перезапустить сервис на всех web-узлах
_ws_restart_service() {
    local service="$1"
    local service_ru="$2"

    bcm_section_header "Перезапуск ${service_ru} на всех web-узлах"

    if ! bcm_confirm "Перезапустить ${service_ru} на ВСЕХ web-узлах?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_info "Перезапуск ${service_ru} на ${node} (${ip})..."
        local result
        result=$(bcm_ssh_exec_timeout "$ip" 30 \
            "systemctl restart ${service} 2>&1 && echo SVC_OK || echo SVC_FAIL" \
            2>/dev/null)

        if [[ "$result" == *"SVC_OK"* ]]; then
            bcm_ok "  ${node}: ${service_ru} перезапущен."
        else
            bcm_error "  ${node}: ошибка: ${result}"
        fi
    done

    bcm_any_key
}

# Перезагрузить конфигурацию nginx (nginx -s reload)
_ws_reload_nginx() {
    bcm_section_header "Перезагрузка конфигурации nginx (nginx -s reload)"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_info "nginx -s reload на ${node} (${ip})..."
        local result
        result=$(bcm_ssh_exec_timeout "$ip" 15 \
            "nginx -t 2>&1 && nginx -s reload 2>&1 && echo RELOAD_OK || echo RELOAD_FAIL" \
            2>/dev/null)

        if [[ "$result" == *"RELOAD_OK"* ]]; then
            bcm_ok "  ${node}: nginx перезагружен."
        else
            bcm_error "  ${node}: ошибка:"
            echo "$result" | while IFS= read -r line; do echo "    $line"; done
        fi
    done

    bcm_any_key
}

# Показать nginx error log
_ws_show_nginx_log() {
    bcm_section_header "Nginx error.log (tail -100)"

    local log_paths=(
        "/var/log/nginx/error.log"
        "/var/log/nginx/bitrix_error.log"
        "/home/bitrix/logs/nginx/error.log"
    )

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        local log_output=""
        for log_path in "${log_paths[@]}"; do
            log_output=$(bcm_ssh_exec_timeout "$ip" 10 \
                "[ -f '${log_path}' ] && tail -100 '${log_path}' 2>/dev/null || true" \
                2>/dev/null)
            if [[ -n "$log_output" ]]; then
                bcm_info "  Лог: ${log_path}"
                echo "$log_output" | while IFS= read -r line; do echo "  $line"; done
                break
            fi
        done

        if [[ -z "$log_output" ]]; then
            bcm_info "  Nginx error log пуст или не найден."
        fi
        echo
    done

    bcm_any_key
}

# Показать httpd error log
_ws_show_httpd_log() {
    bcm_section_header "Apache httpd error.log (tail -100)"

    local log_paths=(
        "/var/log/httpd/error_log"
        "/var/log/apache2/error.log"
        "/home/bitrix/logs/apache/error_log"
    )

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        local log_output=""
        for log_path in "${log_paths[@]}"; do
            log_output=$(bcm_ssh_exec_timeout "$ip" 10 \
                "[ -f '${log_path}' ] && tail -100 '${log_path}' 2>/dev/null || true" \
                2>/dev/null)
            if [[ -n "$log_output" ]]; then
                bcm_info "  Лог: ${log_path}"
                echo "$log_output" | while IFS= read -r line; do echo "  $line"; done
                break
            fi
        done

        if [[ -z "$log_output" ]]; then
            bcm_info "  Apache error log пуст или не найден."
        fi
        echo
    done

    bcm_any_key
}

# Проверить конфигурацию nginx (nginx -t)
_ws_test_nginx_config() {
    bcm_section_header "Проверка конфигурации nginx (nginx -t)"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        local result
        result=$(bcm_ssh_exec_timeout "$ip" 15 \
            "nginx -t 2>&1; echo exit_code:\$?" \
            2>/dev/null)

        local exit_code
        exit_code=$(echo "$result" | grep 'exit_code:' | cut -d: -f2 | tr -d '[:space:]')

        echo "$result" | grep -v 'exit_code:' | while IFS= read -r line; do
            echo "  $line"
        done

        if [[ "${exit_code:-1}" == "0" ]]; then
            bcm_ok "  ${node}: конфигурация nginx корректна."
        else
            bcm_error "  ${node}: ошибка в конфигурации nginx!"
        fi
        echo
    done

    bcm_any_key
}

# Показать текущие соединения (порты 80, 443)
_ws_show_connections() {
    bcm_section_header "Текущие соединения (ss -tuln, порты 80 и 443)"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        local conns
        conns=$(bcm_ssh_exec_timeout "$ip" 10 \
            "ss -tuln 2>/dev/null | grep -E ':80\b|:443\b' || echo '(нет активных соединений на 80/443)'" \
            2>/dev/null)
        echo "$conns" | while IFS= read -r line; do
            echo "  $line"
        done

        # Счётчик ESTABLISHED
        local established
        established=$(bcm_ssh_exec_timeout "$ip" 10 \
            "ss -tun 2>/dev/null | grep -cE ':80\b|:443\b' || echo 0" \
            2>/dev/null | tr -d '[:space:]')
        bcm_info "  ESTABLISHED соединений на 80/443: ${established:-0}"
        echo
    done

    bcm_any_key
}

# Показать PHP info
_ws_show_php_info() {
    bcm_section_header "PHP информация (mod_php)"

    local web01_node="${BCM_NODES_WEB[0]:-}"
    local web01_ip="${BCM_NODE_IP[$web01_node]:-}"

    if [[ -z "$web01_ip" ]]; then
        bcm_error "Не найден web01."
        bcm_any_key; return
    fi

    bcm_info "PHP версия на ${web01_node} (${web01_ip}):"
    local php_ver
    php_ver=$(bcm_ssh_exec_timeout "$web01_ip" 10 \
        "php -v 2>/dev/null | head -3 || echo 'PHP не найден'" \
        2>/dev/null)
    echo "$php_ver" | while IFS= read -r line; do echo "  $line"; done
    echo

    bcm_info "Включённые PHP модули:"
    local php_modules
    php_modules=$(bcm_ssh_exec_timeout "$web01_ip" 10 \
        "php -m 2>/dev/null || echo 'нет данных'" \
        2>/dev/null)
    echo "$php_modules" | while IFS= read -r line; do echo "  $line"; done
    echo

    bcm_info "Конфигурация Apache mod_php (LoadModule):"
    local mod_status
    mod_status=$(bcm_ssh_exec_timeout "$web01_ip" 10 \
        "httpd -M 2>/dev/null | grep -i php || apachectl -M 2>/dev/null | grep -i php || echo 'нет данных'" \
        2>/dev/null)
    echo "$mod_status" | while IFS= read -r line; do echo "  $line"; done
    echo

    bcm_any_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Главное меню модуля
# ─────────────────────────────────────────────────────────────────────────────
_ws_menu() {
    while true; do
        bcm_section_header "Веб-серверы (Nginx + Apache/httpd)"

        local menu_items=(
            "1.  Статус nginx и httpd на всех web-узлах"
            "2.  Перезапустить nginx на всех web-узлах"
            "3.  Перезапустить httpd на всех web-узлах"
            "4.  Перезагрузить конфигурацию nginx (nginx -s reload)"
            "5.  Nginx error.log (tail -100)"
            "6.  Apache httpd error.log (tail -100)"
            "7.  Проверить конфигурацию nginx (nginx -t)"
            "8.  Текущие соединения (ss -tuln, порты 80/443)"
            "9.  PHP info (версия, модули, mod_php)"
            "0.  Назад"
        )
        bcm_print_menu menu_items

        local choice
        bcm_read_choice "Ваш выбор" choice

        case "$choice" in
            1) _ws_show_status                    ;;
            2) _ws_restart_service "nginx" "Nginx" ;;
            3) _ws_restart_service "httpd" "Apache (httpd)" ;;
            4) _ws_reload_nginx                   ;;
            5) _ws_show_nginx_log                 ;;
            6) _ws_show_httpd_log                 ;;
            7) _ws_test_nginx_config              ;;
            8) _ws_show_connections               ;;
            9) _ws_show_php_info                  ;;
            0) return 0                           ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: ${choice}" ;;
        esac
    done
}

_ws_menu
