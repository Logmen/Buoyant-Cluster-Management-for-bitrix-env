#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 06_lsyncd.sh — Управление синхронизацией файлов (lsyncd)
# ВАЖНО: синхронизация запускается только ПОСЛЕ деплоя портала на web01.
# Синхронизация: web01 → web02 (и другие web-узлы).
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

# Источник синхронизации = активная нода (single-active), иначе первый web-узел.
# lsyncd — строго мастер-слейв: код пишется на источнике, разъезжается на остальные.
_lsyncd_source_node() {
    local active
    active=$(bcm_get_active_node 2>/dev/null || echo "")
    if [[ -n "$active" && -n "${BCM_NODE_IP[$active]:-}" ]]; then
        echo "$active"
    else
        echo "${BCM_NODES_WEB[0]:-}"
    fi
}

_lsyncd_source_ip() {
    local src_node
    src_node=$(_lsyncd_source_node)
    echo "${BCM_NODE_IP[$src_node]:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Вспомогательные функции
# ─────────────────────────────────────────────────────────────────────────────

_warn_portal_required() {
    echo
    bcm_color "YELLOW_BOLD" "  ╔══════════════════════════════════════════════════════════════╗"
    bcm_color "YELLOW_BOLD" "  ║  ⚠  ВНИМАНИЕ:                                                ║"
    bcm_color "YELLOW_BOLD" "  ║  Синхронизация запускается только после деплоя портала       ║"
    bcm_color "YELLOW_BOLD" "  ║  на web01. До этого lsyncd должен быть остановлен!            ║"
    bcm_color "YELLOW_BOLD" "  ╚══════════════════════════════════════════════════════════════╝"
    echo
}

# Показать статус lsyncd на всех web-узлах
_ls_show_status() {
    bcm_section_header "Статус lsyncd на web-узлах"
    _warn_portal_required

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        bcm_color "WHITE" "  ── ${node} (${ip}) ──"

        local svc_st
        svc_st=$(bcm_ssh_service_status "$ip" "lsyncd")

        local svc_color="GREEN"
        case "$svc_st" in
            active)   svc_color="GREEN"  ;;
            inactive) svc_color="YELLOW" ;;
            failed)   svc_color="RED"    ;;
            *)        svc_color="GRAY"   ;;
        esac

        printf "  Статус: "
        bcm_echo_color "$svc_color" "$svc_st"
        echo

        local detail
        detail=$(bcm_ssh_exec_timeout "$ip" 10 \
            "systemctl status lsyncd --no-pager -l 2>/dev/null | head -10 || echo 'нет данных'" \
            2>/dev/null)
        echo "$detail" | while IFS= read -r line; do
            echo "    $line"
        done
        echo
    done

    bcm_any_key
}

# Начальная (однократная) синхронизация rsync
_ls_initial_sync() {
    bcm_section_header "Начальная синхронизация (rsync, однократно)"
    _warn_portal_required

    local src_node
    src_node=$(_lsyncd_source_node)
    local src_ip
    src_ip=$(_lsyncd_source_ip)

    if [[ -z "$src_node" || -z "$src_ip" ]]; then
        bcm_error "Не удалось определить web01 из конфигурации."
        bcm_any_key; return
    fi

    bcm_info "Источник: ${src_node} (${src_ip})"
    echo

    # Спросить путь к сайту
    local site_path
    bcm_read_choice "Путь к директории сайта (напр. /home/bitrix/www)" site_path
    site_path="${site_path:-/home/bitrix/www}"

    # Убедиться, что путь существует на источнике
    local path_exists
    path_exists=$(bcm_ssh_exec_timeout "$src_ip" 5 \
        "[ -d '${site_path}' ] && echo yes || echo no" \
        2>/dev/null | tr -d '[:space:]')

    if [[ "$path_exists" != "yes" ]]; then
        bcm_error "Путь '${site_path}' не найден на ${src_node}."
        bcm_any_key; return
    fi

    # Sanity-гейт источника: дерево деградировало (есть bitrix/modules, но нет
    # ядра) → пуш с --delete затёр бы приёмники. Не даём начать сверку с битого
    # источника (тот же предохранитель, что в lsyncd_role.sh::promote).
    local src_degraded
    src_degraded=$(bcm_ssh_exec_timeout "$src_ip" 5 \
        "if [ -d '${site_path}/bitrix/modules' ] && [ ! -f '${site_path}/bitrix/modules/main/include/prolog_before.php' ]; then echo yes; else echo no; fi" \
        2>/dev/null | tr -d '[:space:]')
    if [[ "$src_degraded" == "yes" ]]; then
        bcm_error "Источник ${src_node} деградирован: есть bitrix/modules, но нет ядра (modules/main/include/prolog_before.php)."
        bcm_error "Начальная синхронизация ОТМЕНЕНА — иначе --delete затёр бы код на остальных web. Восстановите дерево на источнике."
        bcm_any_key; return
    fi

    # Синхронизировать на остальные web-узлы
    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        [[ "$node" == "$src_node" ]] && continue  # пропустить источник
        local dst_ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$dst_ip" ]] && continue

        bcm_info "Синхронизация ${src_node} → ${node} (${dst_ip}): ${site_path}"

        if ! bcm_confirm "Выполнить rsync на ${node}?"; then
            bcm_info "Пропущено."
            continue
        fi

        # rsync выполняется с src-узла на dst через SSH-ключ кластера
        local ssh_key="${BCM_SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}"
        local result
        # Только код: исключаем /upload (в S3), локальные кэш/tmp и временный
        # churn обновлятора (/bitrix/updates). --delete уважает excludes.
        # Это КОНТРОЛИРУЕМАЯ операторская реконсиляция (с подтверждением и sanity-
        # проверкой источника выше) — здесь --max-delete НЕ ставим намеренно:
        # легитимная сверка может удалить много устаревших файлов на target.
        result=$(bcm_ssh_exec_timeout "$src_ip" 300 \
            "rsync -avz --delete \
             --exclude=/upload/ --exclude=/bitrix/cache/ --exclude=/bitrix/managed_cache/ \
             --exclude=/bitrix/stack_cache/ --exclude=/bitrix/html_pages/ \
             --exclude=/bitrix/tmp/ --exclude=/bitrix/updates/ --exclude=/bitrix/backup/ \
             --exclude='*.tmp' --exclude=.git/ \
             -e 'ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -i ${ssh_key}' \
             '${site_path}/' \
             'root@${dst_ip}:${site_path}/' 2>&1 | tail -5 && echo RSYNC_OK || echo RSYNC_FAIL" \
            2>/dev/null)

        if [[ "$result" == *"RSYNC_OK"* ]]; then
            bcm_ok "Синхронизация на ${node} завершена."
        else
            bcm_error "Ошибка синхронизации на ${node}. Вывод:"
            echo "$result" | while IFS= read -r line; do echo "    $line"; done
        fi
    done

    bcm_any_key
}

# Настроить lsyncd (сгенерировать конфиг)
_ls_configure() {
    bcm_section_header "Настройка lsyncd (генерация конфига)"
    _warn_portal_required

    local src_node
    src_node=$(_lsyncd_source_node)
    local src_ip
    src_ip=$(_lsyncd_source_ip)

    if [[ -z "$src_node" || -z "$src_ip" ]]; then
        bcm_error "Не найден web01 в конфигурации."
        bcm_any_key; return
    fi

    local site_path
    bcm_read_choice "Путь к директории сайта для lsyncd (напр. /home/bitrix/www)" site_path
    site_path="${site_path:-/home/bitrix/www}"

    local ssh_key="${BCM_SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}"

    # Собрать целевые узлы (все web кроме src_node)
    local -a dst_nodes=()
    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        [[ "$node" == "$src_node" ]] && continue
        local dst_ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$dst_ip" ]] || dst_nodes+=("$dst_ip")
    done

    if [[ ${#dst_nodes[@]} -eq 0 ]]; then
        bcm_warn "Нет дополнительных web-узлов для синхронизации (нужно минимум 2)."
        bcm_any_key; return
    fi

    # Сгенерировать конфиг lsyncd
    local lsyncd_conf
    lsyncd_conf=$(cat <<LSYNCD_CONF
-- /etc/lsyncd/lsyncd.conf
-- Сгенерировано BCM install.sh / 06_lsyncd.sh
-- НЕ редактировать вручную.

settings {
    logfile    = "/var/log/lsyncd/lsyncd.log",
    statusFile = "/var/run/lsyncd.status",
    statusInterval = 10,
}

LSYNCD_CONF
)

    for dst_ip in "${dst_nodes[@]}"; do
        lsyncd_conf+=$(cat <<LSYNCD_SYNC

sync {
    default.rsync,
    source = "${site_path}/",
    target = "root@${dst_ip}:${site_path}/",
    rsync = {
        archive  = true,
        compress = true,
        rsh      = "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -i ${ssh_key}",
        -- Синкаем только КОД. Исключаем общие/локальные мутабельные данные:
        --   /upload — пользовательские файлы (хранятся в S3/MinIO, общие для нод);
        --   кэш и tmp — локальные на каждой ноде, синкать нельзя;
        --   /bitrix/updates — временный churn обновлятора Bitrix (не синкать).
        -- rsync --delete уважает excludes (не удаляет исключённое на target).
        -- --max-delete=1000 — предохранитель: один проход не сносит >1000 файлов
        -- (обрезанное дерево/churn под --delete не уничтожит приёмник; rc=25).
        _extra = {
            "--max-delete=1000",
            "--exclude=/upload/",
            "--exclude=/bitrix/cache/",
            "--exclude=/bitrix/managed_cache/",
            "--exclude=/bitrix/stack_cache/",
            "--exclude=/bitrix/html_pages/",
            "--exclude=/bitrix/tmp/",
            "--exclude=/bitrix/updates/",
            "--exclude=/bitrix/backup/",
            "--exclude=*.tmp",
            "--exclude=.git/",
        },
    },
    delete = true,
    delay  = 5,
}
LSYNCD_SYNC
)
    done

    bcm_info "Конфигурация lsyncd будет записана на ${src_node} в /etc/lsyncd/lsyncd.conf:"
    echo
    echo "$lsyncd_conf" | while IFS= read -r line; do echo "    $line"; done
    echo

    if ! bcm_confirm "Записать конфиг на ${src_node} и перезапустить lsyncd?"; then
        bcm_info "Отменено."
        bcm_any_key; return
    fi

    # Записать конфиг на src_node.
    # ВАЖНО: дистрибутивный unit запускает `lsyncd -nodaemon $LSYNCD_OPTIONS`, где
    # $LSYNCD_OPTIONS берётся из /etc/sysconfig/lsyncd и по умолчанию указывает на
    # /etc/lsyncd.conf (пример дистрибутива: /var/www/html → localhost). Поэтому
    # одновременно прописываем /etc/sysconfig/lsyncd на наш конфиг — иначе
    # `systemctl start lsyncd` поднимет дефолтный пример и синхронизация «молча»
    # не работает.
    local result
    result=$(echo "$lsyncd_conf" | bcm_ssh_exec_timeout "$src_ip" 20 \
        "mkdir -p /etc/lsyncd /var/log/lsyncd && \
         cat > /etc/lsyncd/lsyncd.conf && \
         printf 'LSYNCD_OPTIONS=\"/etc/lsyncd/lsyncd.conf\"\n' > /etc/sysconfig/lsyncd && \
         echo CONF_OK" \
        2>/dev/null)

    if [[ "$result" == *"CONF_OK"* ]]; then
        bcm_ok "Конфиг записан на ${src_node}."
    else
        bcm_error "Не удалось записать конфиг на ${src_node}."
        bcm_any_key; return
    fi

    bcm_any_key
}

# Запустить/остановить/перезапустить lsyncd
_ls_service_action() {
    local action="$1"
    local action_ru
    case "$action" in
        start)   action_ru="запуск"       ;;
        stop)    action_ru="остановка"    ;;
        restart) action_ru="перезапуск"   ;;
        *)       action_ru="$action"      ;;
    esac

    bcm_section_header "lsyncd: ${action_ru}"

    if [[ "$action" == "start" || "$action" == "restart" ]]; then
        _warn_portal_required
        if ! bcm_confirm "Убедитесь, что портал задеплоен на web01. Продолжить?"; then
            bcm_info "Отменено."
            bcm_any_key; return
        fi
    fi

    # Действие только на web01 (источнике)
    local src_node
    src_node=$(_lsyncd_source_node)
    local src_ip
    src_ip=$(_lsyncd_source_ip)

    if [[ -z "$src_ip" ]]; then
        bcm_error "Не найден web01."
        bcm_any_key; return
    fi

    bcm_info "systemctl ${action} lsyncd на ${src_node} (${src_ip})..."
    local result
    result=$(bcm_ssh_exec_timeout "$src_ip" 20 \
        "systemctl ${action} lsyncd 2>&1 && echo SVC_OK || echo SVC_FAIL" \
        2>/dev/null)

    if [[ "$result" == *"SVC_OK"* ]]; then
        bcm_ok "lsyncd ${action_ru} на ${src_node}."
    else
        bcm_error "Ошибка ${action_ru} lsyncd: ${result}"
    fi

    bcm_any_key
}

# Показать лог lsyncd
_ls_show_log() {
    bcm_section_header "Лог lsyncd (tail -50)"

    local src_node
    src_node=$(_lsyncd_source_node)
    local src_ip
    src_ip=$(_lsyncd_source_ip)

    if [[ -z "$src_ip" ]]; then
        bcm_error "Не найден web01."
        bcm_any_key; return
    fi

    bcm_info "Лог с ${src_node} (${src_ip}):"
    echo

    local log_output
    log_output=$(bcm_ssh_exec_timeout "$src_ip" 10 \
        "tail -50 /var/log/lsyncd/lsyncd.log 2>/dev/null || echo '(лог пуст или не найден)'" \
        2>/dev/null)
    echo "$log_output" | while IFS= read -r line; do
        echo "  $line"
    done

    bcm_any_key
}

# Проверить статус синхронизации (сравнить количество файлов)
_ls_check_sync() {
    bcm_section_header "Проверка синхронизации (счётчик файлов)"

    local src_node
    src_node=$(_lsyncd_source_node)
    local src_ip
    src_ip=$(_lsyncd_source_ip)

    if [[ -z "$src_ip" ]]; then
        bcm_error "Не найден web01."
        bcm_any_key; return
    fi

    local site_path
    bcm_read_choice "Путь для проверки (напр. /home/bitrix/www)" site_path
    site_path="${site_path:-/home/bitrix/www}"

    # Количество файлов на источнике
    local src_count
    bcm_info "Считаем файлы на ${src_node} (${src_ip})..."
    src_count=$(bcm_ssh_exec_timeout "$src_ip" 30 \
        "find '${site_path}' -type f 2>/dev/null | wc -l" \
        2>/dev/null | tr -d '[:space:]')

    bcm_color "WHITE" "  ${src_node}: ${src_count:-?} файлов"
    echo

    printf "  %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Узел' 12)" "$(bcm_pad 'IP' 15)" "$(bcm_pad 'Файлов' 12)" "Состояние"
    bcm_divider "$BCM_LINE_H1"

    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        [[ "$node" == "$src_node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue

        local dst_count
        dst_count=$(bcm_ssh_exec_timeout "$ip" 30 \
            "find '${site_path}' -type f 2>/dev/null | wc -l" \
            2>/dev/null | tr -d '[:space:]')

        local sync_status="OK"
        local color="GREEN"
        if [[ -z "$dst_count" ]]; then
            sync_status="НЕДОСТУПЕН"
            color="RED"
        elif [[ "$dst_count" != "$src_count" ]]; then
            sync_status="РАСХОЖДЕНИЕ (${dst_count} vs ${src_count})"
            color="YELLOW"
        fi

        printf "  %s │ %s │ %s │ " "$(bcm_pad "$node" 12)" "$(bcm_pad "$ip" 15)" "$(bcm_pad "${dst_count:-?}" 12)"
        bcm_echo_color "$color" "$sync_status"
        echo
    done

    echo
    bcm_any_key
}

# Роли источника (авто-failover за master web-VRRP) + ручной override promote.
# Источник lsyncd выбирается автоматически (cron_notify.sh → lsyncd_role.sh при
# смене роли keepalived). Здесь можно посмотреть текущие роли и при необходимости
# принудительно назначить источник (например, для контролируемого failback).
_ls_roles() {
    bcm_section_header "Роль источника lsyncd (авто-failover за master web-VRRP)"

    local active
    active=$(bcm_get_active_node 2>/dev/null || echo "")
    bcm_info "active_node в cluster.conf: ${active:-—}"
    echo
    printf "  %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Узел' 12)" "$(bcm_pad 'IP' 15)" "$(bcm_pad 'lsyncd' 10)" "Роль"
    bcm_divider "${BCM_LINE_H1}"

    local -a wn=()
    for node in "${BCM_NODES_WEB[@]}"; do
        [[ -z "$node" ]] && continue
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        wn+=("$node")
        local st role color
        st=$(bcm_ssh_service_status "$ip" "lsyncd")
        if [[ "$st" == "active" ]]; then role="ИСТОЧНИК"; color="GREEN"; else role="приёмник"; color="GRAY"; fi
        printf "  %s │ %s │ %s │ " "$(bcm_pad "$node" 12)" "$(bcm_pad "$ip" 15)" "$(bcm_pad "$st" 10)"
        bcm_echo_color "$color" "$role"
        echo
    done
    echo
    bcm_info "Источник следует за master web-VRRP автоматически. Ручное назначение ниже —"
    bcm_info "это override (до следующего события keepalived); promote делает catch-up без потерь."

    local i=1 node
    for node in "${wn[@]}"; do printf "    %d. %s\n" "$i" "$node"; i=$((i+1)); done
    echo "    0. Отмена"

    local ch
    bcm_read_choice "Назначить источником узел (0 — отмена)" ch
    [[ "$ch" == "0" || -z "$ch" ]] && { bcm_any_key; return; }
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || [[ "$ch" -lt 1 || "$ch" -gt "${#wn[@]}" ]]; then
        bcm_error "Неверный выбор."; bcm_any_key; return
    fi

    local target="${wn[$((ch-1))]}"
    if ! bcm_confirm "Назначить ${target} источником lsyncd (promote с catch-up, остальные → приёмники)?"; then
        bcm_info "Отменено."; bcm_any_key; return
    fi

    for node in "${wn[@]}"; do
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if [[ "$node" == "$target" ]]; then
            bcm_info "promote ${node} (возможен SST/догон, ждём)..."
            bcm_ssh_exec_timeout "$ip" 900 "/opt/bcm/bin/lib/lsyncd_role.sh promote" >/dev/null 2>&1 \
                && bcm_ok "${node}: назначен источником." \
                || bcm_warn "${node}: promote завершился с ошибкой (см. /var/log/bcm/lsyncd-role.log)."
        else
            bcm_ssh_exec_timeout "$ip" 60 "/opt/bcm/bin/lib/lsyncd_role.sh demote" >/dev/null 2>&1 || true
        fi
    done

    bcm_any_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Главное меню модуля
# ─────────────────────────────────────────────────────────────────────────────
_ls_menu() {
    while true; do
        bcm_section_header "Синхронизация файлов (lsyncd)"
        _warn_portal_required

        local menu_items=(
            "1.  Статус lsyncd на всех web-узлах"
            "2.  Начальная синхронизация (rsync, однократно)"
            "3.  Настроить lsyncd (сгенерировать конфиг)"
            "4.  Запустить lsyncd"
            "5.  Остановить lsyncd"
            "6.  Перезапустить lsyncd"
            "7.  Показать лог lsyncd"
            "8.  Проверить синхронизацию (счётчик файлов)"
            "9.  Роли источника (авто-failover) / назначить источник"
            "0.  Назад"
        )
        bcm_print_menu menu_items

        local choice
        bcm_read_choice "Ваш выбор" choice

        case "$choice" in
            1) _ls_show_status              ;;
            2) _ls_initial_sync             ;;
            3) _ls_configure                ;;
            4) _ls_service_action "start"   ;;
            5) _ls_service_action "stop"    ;;
            6) _ls_service_action "restart" ;;
            7) _ls_show_log                 ;;
            8) _ls_check_sync               ;;
            9) _ls_roles                    ;;
            0) return 0                     ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: ${choice}" ;;
        esac
    done
}

_ls_menu
