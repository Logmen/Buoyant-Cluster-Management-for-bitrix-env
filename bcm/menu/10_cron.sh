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

        # ⚠️ Задание агентов bitrix-env лежит в /etc/crontab, а НЕ в crontab
        # пользователя bitrix — прежняя проверка смотрела не туда и панель всегда
        # была пустой, из чего можно было заключить, что агенты не работают.
        # На BACKUP-ноде строка закомментирована маркером #bcm-ha-backup# (это и есть
        # механизм HA Cron), поэтому показываем ещё и роль, и фактические тики.
        local agent_output
        agent_output=$(bcm_ssh_exec_timeout "$ip" 20 \
            "echo '=== роль ноды ==='
             cat /run/bcm-ha-cron.role 2>/dev/null || echo '(роль не назначена — notify keepalived не отрабатывал)'

             echo '=== агенты Bitrix в /etc/crontab ==='
             line=\$(grep -n 'cron_events\.php' /etc/crontab 2>/dev/null | head -1)
             if [ -z \"\$line\" ]; then
                 echo '(строки нет — bitrix-env её не создавал)'
             elif echo \"\$line\" | grep -q '#bcm-ha-backup#'; then
                 echo 'отключена маркером #bcm-ha-backup# (штатно для BACKUP)'
             else
                 echo 'активна (агенты выполняются на этой ноде)'
             fi

             echo '=== тиков cron_events за последний час ==='
             since=\$(date -d '1 hour ago' '+%b %e %H' 2>/dev/null)
             grep 'CMD.*cron_events' /var/log/cron 2>/dev/null | tail -60 | awk -v s=\"\$since\" 'index(\$0,substr(s,1,9))>0' | wc -l

             echo '=== задания BCM в /etc/cron.d ==='
             ls -1 /etc/cron.d/bcm-* 2>/dev/null || echo '(нет)'
             test -f /etc/bitrix-cluster/bcm-portal-master.disabled && echo 'bcm-portal-master: вынесен из cron.d (нода BACKUP)'

             echo '=== процессы агента ==='
             pgrep -af 'cron_events\.php' 2>/dev/null | head -3 || echo '(сейчас не выполняются)'" \
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
    total=$(echo "$content" | grep -c . || true)   # grep -c rc=1 при 0 строк + pipefail → set -e (здесь content непуст, но страхуемся)
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
# Фоновая шина Messenger ядра: с хитов на master-cron
#
# Ядро при run_mode=web (умолчание) на каждом хите обходит все очереди шины и
# берёт на каждую GET_LOCK — на нагруженном портале это 4/5 запросов к БД.
# run_mode=cli в .settings.php снимает опрос с хитов; очереди разбирает
# потребитель local/cron/bcm-messenger.php раз в минуту из класса «только master»
# (переезжает вместе с web-VRRP). Исполнитель на web — bin/lib/bcm_messenger.sh.
# ─────────────────────────────────────────────────────────────────────────────
MESSENGER_LIB="/opt/bcm/bin/lib/bcm_messenger.sh"
MESSENGER_CRON_MARK="local/cron/bcm-messenger.php"
# 55 с работы и 5 с паузы между проходами: проход по ~30 очередям стоит ~50 запросов
# (блокировка + выборка на очередь) — при паузе 1 с потребитель сам давал бы половину
# прежней нагрузки, при 5 с — около 5 %; задержка фоновых задач до 5 с приемлема.
MESSENGER_CRON_LINE='* * * * * bitrix flock -n /home/bitrix/.bcm-messenger.lock /usr/bin/php -f /home/bitrix/www/local/cron/bcm-messenger.php 55 5 2>&1 | logger -t bcm-messenger'
MESSENGER_CRON_COMMENT='# фоновая шина Messenger ядра (очереди main/calendar/bizproc): потребитель вместо опроса на хитах (BCM меню 10 → 10)'

_cron_messenger_status() {
    bcm_section_header "Фоновая шина Messenger — статус"
    local node ip out
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_color "WHITE" "  ── ${node} (${ip}) ──"
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_echo_color "RED_BOLD" "  Узел недоступен"; echo; continue
        fi
        out=$(bcm_ssh_exec_timeout "$ip" 40 "${MESSENGER_LIB} --status" 2>/dev/null) || out=""
        [[ -z "$out" ]] && bcm_warn "  bcm_messenger.sh не отвечает — BCM на ноде устарел (bcm --update)?" || echo "$out" | sed 's/^/  /'
        echo
    done
    bcm_info "RUN_MODE=web — очереди разбирают хиты; cli — потребитель из master-cron. QUEUE_ROWS не должен расти."
    bcm_any_key
}

# Строка cron в классе master: добавить/удалить (идемпотентно).
_cron_messenger_job() {
    local action="$1" content
    content=$(_cron_managed_get master | grep -v '^[[:space:]]*$' || true)
    if [[ "$action" == "add" ]]; then
        if echo "$content" | grep -qF "$MESSENGER_CRON_MARK"; then
            bcm_ok "  Строка cron уже есть в bcm-portal-master."
            return 0
        fi
        content="${content:+$content$'\n'}${MESSENGER_CRON_COMMENT}"$'\n'"${MESSENGER_CRON_LINE}"
    else
        echo "$content" | grep -qF "$MESSENGER_CRON_MARK" || { bcm_ok "  Строки cron в bcm-portal-master нет."; return 0; }
        content=$(echo "$content" | grep -vF "$MESSENGER_CRON_MARK" | grep -vF "$MESSENGER_CRON_COMMENT" || true)
    fi
    _cron_managed_push master "$content"
}

_cron_messenger_enable() {
    bcm_section_header "Messenger → master-cron"
    echo "  Шаги:"
    echo "   1. потребитель local/cron/bcm-messenger.php на каждой web (владелец bitrix);"
    echo "   2. строка в классе «только master» (каждую минуту, 55 с работы / 5 с пауза, под flock, журнал — syslog bcm-messenger);"
    echo "   3. .settings.php: messenger run_mode=cli на каждой web (секция под сторожем), reload httpd;"
    echo "   4. пробный прогон потребителя на master-ноде."
    echo "  При сбое шага 3 сделанное откатывается (run_mode=web, строка cron снимается)."
    echo
    bcm_confirm "Перенести разбор очередей Messenger на master-cron?" || { bcm_info "Отменено."; bcm_any_key; return; }
    echo
    local node ip out
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_error "${node}: недоступна — перенос прерван, ничего не изменено."
            bcm_any_key; return
        fi
        out=$(bcm_ssh_exec_timeout "$ip" 60 "${MESSENGER_LIB} --install-files" 2>&1) || {
            bcm_error "${node}: потребитель — ${out//$'\n'/ }"; bcm_any_key; return; }
        echo "$out" | sed "s/^/  ${node}: /"
    done
    _cron_messenger_job add || { bcm_error "Строка cron не раскатана на все web — перенос прерван."; bcm_any_key; return; }

    local -a done_nodes=()
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        out=$(bcm_ssh_exec_timeout "$ip" 120 "${MESSENGER_LIB} --settings cli" 2>&1) || {
            bcm_error "${node}: .settings.php — ${out//$'\n'/ }; откат."
            local n
            for n in "${done_nodes[@]}"; do
                bcm_ssh_exec_timeout "${BCM_NODE_IP[$n]}" 120 "${MESSENGER_LIB} --settings web" >/dev/null 2>&1
            done
            _cron_messenger_job remove >/dev/null
            bcm_any_key; return
        }
        echo "$out" | sed "s/^/  ${node}: /"
        done_nodes+=("$node")
    done

    local master master_ip
    master=$(_cron_get_master_node 2>/dev/null || echo "")
    master_ip="${BCM_NODE_IP[$master]:-}"
    if [[ -n "$master_ip" ]]; then
        bcm_info "Пробный прогон потребителя на ${master} (3 с)..."
        out=$(bcm_ssh_exec_timeout "$master_ip" 60 "${MESSENGER_LIB} --consume-test" 2>&1) || true
        echo "$out" | sed "s/^/  ${master}: /"
        if ! echo "$out" | grep -q '^RESULT=OK'; then
            bcm_warn "Пробный прогон не подтвердил работу потребителя — проверьте вывод; очереди тем временем разбирает cron (journalctl -t bcm-messenger)."
        fi
    fi
    bcm_log_info "Messenger переведён на master-cron (run_mode=cli, bcm-messenger.php)."
    echo
    bcm_ok "Готово: хиты очереди не опрашивают, потребитель запускается из bcm-portal-master раз в минуту."
    bcm_info "Наблюдать: пункт «статус» (QUEUE_ROWS не растёт, CONSUMER_RUNNING=1 на master) и journalctl -t bcm-messenger."
    bcm_any_key
}

_cron_messenger_disable() {
    bcm_section_header "Messenger → обратно на хиты"
    bcm_confirm "Вернуть разбор очередей на хиты (run_mode=web) и снять строку cron?" || { bcm_info "Отменено."; bcm_any_key; return; }
    local node ip out
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "  ${node}: недоступна — выполните позже: ${MESSENGER_LIB} --settings web"; continue
        fi
        out=$(bcm_ssh_exec_timeout "$ip" 120 "${MESSENGER_LIB} --settings web" 2>&1) || true
        echo "$out" | sed "s/^/  ${node}: /"
    done
    _cron_messenger_job remove || bcm_warn "Строка cron снята не на всех web."
    bcm_log_info "Messenger возвращён на хиты (run_mode=web)."
    bcm_ok "Очереди снова разбирают хиты. Файл потребителя оставлен (без run_mode=cli он бездействует)."
    bcm_any_key
}

_cron_messenger_menu() {
    while true; do
        bcm_section_header "Фоновая шина Messenger ядра (очереди main/calendar/bizproc)"
        local -a items=(
            "1.  Статус на web-нодах (режим, потребитель, глубина очередей)"
            "2.  Перенести на master-cron (run_mode=cli + потребитель раз в минуту)"
            "3.  Вернуть на хиты (run_mode=web, снять строку cron)"
            "0.  Назад"
        )
        bcm_print_menu items
        local choice
        bcm_read_choice "Ваш выбор" choice
        case "$choice" in
            1) _cron_messenger_status ;;
            2) _cron_messenger_enable ;;
            3) _cron_messenger_disable ;;
            0|"") break ;;
            *) bcm_warn "Неверный выбор: ${choice}" ;;
        esac
    done
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
            "10. Фоновая шина Messenger ядра: на master-cron / на хиты"
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
            10) _cron_messenger_menu       ;;
            0) return 0                    ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: ${choice}" ;;
        esac
    done
}

_cron_menu
