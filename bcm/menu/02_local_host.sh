#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 02_local_host.sh — Настройка локального хоста
# Hostname, NTP, обновление пакетов, репозитории bitrix-env, диск, память.
#
# Выполняется на ТЕКУЩЕМ узле (localhost). SSH используется только для
# распространения изменений hostname на соседние узлы кластера.
# =============================================================================
set -euo pipefail

# ──── Загрузка библиотек ─────────────────────────────────────────────────────
source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"

# ──── Показать статус хоста ───────────────────────────────────────────────────
_lh_show_status() {
    bcm_section_header "Статус локального хоста"

    local hn
    hn=$(hostname -f 2>/dev/null || hostname)
    local hn_short
    hn_short=$(hostname -s 2>/dev/null || hostname)
    local ips
    ips=$(hostname -I 2>/dev/null | tr ' ' ',' | sed 's/,$//')

    bcm_info "Полное имя хоста:  ${hn}"
    bcm_info "Короткое имя:      ${hn_short}"
    bcm_info "IP-адреса:         ${ips:-не определены}"
    echo

    # NTP / chrony статус
    bcm_color "WHITE" "  ── Синхронизация времени (chrony) ──"
    if systemctl is-active --quiet chronyd 2>/dev/null; then
        bcm_ok  "chronyd активен"
        echo
        echo "  Источники:"
        chronyc sources -v 2>/dev/null | sed 's/^/  /' || bcm_warn "chronyc недоступен"
        echo
        echo "  Слежение:"
        chronyc tracking 2>/dev/null | grep -E 'Reference|System time|Last offset|RMS offset|Frequency' | sed 's/^/  /' || true
    else
        bcm_warn "chronyd не активен"
        if systemctl is-active --quiet ntpd 2>/dev/null; then
            bcm_info "Обнаружен ntpd (активен)"
            ntpq -p 2>/dev/null | head -20 | sed 's/^/  /' || true
        else
            bcm_error "Служба времени не запущена."
        fi
    fi

    echo
    bcm_color "WHITE" "  ── Роль в кластере BCM ──"
    local role
    role=$(bcm_get_current_role 2>/dev/null || echo "unknown")
    local node_name
    node_name=$(bcm_get_current_node_name 2>/dev/null || hostname -s)
    bcm_info "Роль:    ${role}"
    bcm_info "Узел:    ${node_name}"

    echo
    bcm_any_key
}

# ──── Сменить hostname ────────────────────────────────────────────────────────
_lh_change_hostname() {
    bcm_section_header "Смена hostname"

    local current_hn
    current_hn=$(hostname -s)
    bcm_info "Текущий hostname: ${current_hn}"
    echo

    local new_hn
    bcm_read_choice "Введите новый hostname" new_hn

    if [[ -z "$new_hn" ]]; then
        bcm_error "Hostname не может быть пустым."
        bcm_any_key
        return
    fi

    if ! bcm_valid_hostname "$new_hn"; then
        bcm_error "Недопустимое имя: '${new_hn}'. Только латиница, цифры и дефис."
        bcm_any_key
        return
    fi

    if [[ "$new_hn" == "$current_hn" ]]; then
        bcm_warn "Hostname уже установлен: ${current_hn}"
        bcm_any_key
        return
    fi

    echo
    if ! bcm_confirm "Изменить hostname с '${current_hn}' на '${new_hn}'?"; then
        bcm_info "Отменено."
        bcm_any_key
        return
    fi

    # Применяем на локальном узле
    bcm_info "Применение hostname..."
    hostnamectl set-hostname "$new_hn"
    bcm_ok "hostname изменён на '${new_hn}'."

    # Обновить /etc/hosts локально
    local local_ip
    local_ip=$(hostname -I | awk '{print $1}')
    if grep -q "$current_hn" /etc/hosts; then
        sed -i "s/${current_hn}/${new_hn}/g" /etc/hosts
        bcm_ok "Локальный /etc/hosts обновлён."
    else
        # Добавить запись
        echo "${local_ip}  ${new_hn}" >> /etc/hosts
        bcm_ok "Добавлена запись в /etc/hosts: ${local_ip} ${new_hn}"
    fi

    # Распространить на все узлы кластера
    if bcm_load_topology 2>/dev/null; then
        bcm_info "Обновление /etc/hosts на узлах кластера..."
        local local_hostname
        local_hostname=$(hostname -s)
        local -a all_nodes=()
        for layer in lb web pxc s3; do
            local ns_str
            ns_str=$(bcm_get_nodes "$layer" 2>/dev/null) || continue
            [[ -z "$ns_str" ]] && continue
            read -ra _arr <<< "$ns_str"
            for n in "${_arr[@]}"; do
                [[ -z "$n" || "$n" == "$local_hostname" ]] && continue
                all_nodes+=("$n")
            done
        done

        local success=0 failed=0
        for node in "${all_nodes[@]}"; do
            local nip
            nip="${BCM_NODE_IP[$node]:-}"
            [[ -z "$nip" ]] && continue

            if bcm_ssh_reachable "$nip" 5 2>/dev/null; then
                # Обновить на удалённом узле
                bcm_ssh_exec "$nip" \
                    "sed -i 's/${current_hn}/${new_hn}/g' /etc/hosts 2>/dev/null || true; \
                     grep -q '${new_hn}' /etc/hosts || echo '${local_ip}  ${new_hn}' >> /etc/hosts" \
                    2>/dev/null && {
                    bcm_ok "  ${node} (${nip}): /etc/hosts обновлён."
                    ((success++))
                } || {
                    bcm_warn "  ${node} (${nip}): не удалось обновить /etc/hosts."
                    ((failed++))
                }
            else
                bcm_warn "  ${node} (${nip}): недоступен — пропущен."
                ((failed++))
            fi
        done
        echo
        bcm_info "Обновлено узлов: ${success}, пропущено: ${failed}"
    fi

    bcm_log_info "Hostname изменён с ${current_hn} на ${new_hn}"
    bcm_any_key
}

# ──── Настройка NTP (chrony) ───────────────────────────────────────────────────
_lh_configure_ntp() {
    bcm_section_header "Настройка NTP (chrony)"

    # Показать текущие серверы
    local chrony_conf="/etc/chrony.conf"
    if [[ -f "$chrony_conf" ]]; then
        bcm_info "Текущие серверы NTP в ${chrony_conf}:"
        grep -E '^(server|pool)' "$chrony_conf" | sed 's/^/  /' || bcm_warn "Серверы не настроены."
    else
        bcm_warn "Файл ${chrony_conf} не найден."
    fi
    echo

    local new_server
    bcm_read_choice "Введите адрес NTP-сервера (Enter — пропустить)" new_server

    if [[ -z "$new_server" ]]; then
        bcm_info "Без изменений."
        bcm_any_key
        return
    fi

    if ! bcm_confirm "Добавить сервер '${new_server}' в chrony и перезапустить?"; then
        bcm_info "Отменено."
        bcm_any_key
        return
    fi

    # Добавить сервер в конфиг (не дублировать)
    if grep -qFx "server ${new_server} iburst" "$chrony_conf" 2>/dev/null; then
        bcm_warn "Сервер '${new_server}' уже присутствует в конфиге."
    else
        echo "server ${new_server} iburst" >> "$chrony_conf"
        bcm_ok "Сервер '${new_server}' добавлен."
    fi

    # Перезапустить chronyd
    if systemctl restart chronyd 2>/dev/null; then
        bcm_ok "chronyd перезапущен."
        sleep 2
        bcm_info "Принудительная синхронизация..."
        chronyc makestep 2>/dev/null || true
        bcm_ok "Синхронизация выполнена."
    else
        bcm_error "Не удалось перезапустить chronyd."
    fi

    bcm_log_info "NTP сервер ${new_server} добавлен, chronyd перезапущен"
    bcm_any_key
}

# ──── Обновление пакетов ──────────────────────────────────────────────────────
_lh_update_packages() {
    bcm_section_header "Обновление пакетов (dnf update)"

    bcm_warn "Будет выполнено обновление ВСЕХ установленных пакетов на этом узле."
    echo

    # Показать список доступных обновлений
    bcm_info "Проверка доступных обновлений..."
    local update_list
    update_list=$(dnf check-update 2>/dev/null | grep -v "^$\|^Last metadata\|^Loaded\|^Loading" | head -20 || true)

    if [[ -z "$update_list" ]]; then
        bcm_ok "Обновлений нет — система актуальна."
        bcm_any_key
        return
    fi

    echo "  Доступные обновления (первые 20):"
    echo "$update_list" | sed 's/^/  /'
    echo

    if ! bcm_confirm "Выполнить dnf update -y?"; then
        bcm_info "Отменено."
        bcm_any_key
        return
    fi

    echo
    bcm_info "Запуск dnf update -y ..."
    echo
    dnf update -y 2>&1 | tail -30 | sed 's/^/  /'
    echo
    bcm_ok "Обновление завершено."
    bcm_log_info "dnf update -y выполнен вручную"
    bcm_any_key
}

# ──── Смена репозитория bitrix-env ────────────────────────────────────────────
_lh_change_repo() {
    bcm_section_header "Смена репозитория bitrix-env"

    # Найти файлы репозитория bitrix
    local repo_files=()
    while IFS= read -r -d '' f; do
        repo_files+=("$f")
    done < <(find /etc/yum.repos.d/ -name 'bitrix*.repo' -print0 2>/dev/null)

    if [[ ${#repo_files[@]} -eq 0 ]]; then
        bcm_warn "Файлы репозитория bitrix не найдены в /etc/yum.repos.d/"
        bcm_any_key
        return
    fi

    bcm_info "Найдены файлы репозитория:"
    for f in "${repo_files[@]}"; do
        echo "  ${f}"
    done
    echo

    # Показать текущие baseurl/enabled
    for f in "${repo_files[@]}"; do
        bcm_color "WHITE" "  ── $(basename "$f") ──"
        grep -E '^(baseurl|enabled|name)' "$f" 2>/dev/null | sed 's/^/  /' || true
        echo
    done

    echo "  Выберите канал обновлений:"
    echo "    1. stable — стабильный (рекомендуется)"
    echo "    2. beta   — бета-канал (тестовые версии)"
    echo "    0. Отмена"
    echo

    local ch
    bcm_read_choice "Ваш выбор" ch

    local new_channel
    case "$ch" in
        1) new_channel="stable" ;;
        2) new_channel="beta"   ;;
        0|"") bcm_info "Отменено."; bcm_any_key; return ;;
        *) bcm_error "Неверный выбор."; bcm_any_key; return ;;
    esac

    if ! bcm_confirm "Переключить репозиторий на '${new_channel}'?"; then
        bcm_info "Отменено."
        bcm_any_key
        return
    fi

    local changed=0
    for f in "${repo_files[@]}"; do
        # Заменяем /stable/ на /new_channel/ и наоборот
        if grep -q '/stable/\|/beta/' "$f" 2>/dev/null; then
            sed -i "s|/stable/|/__BCM_NEW_CHANNEL__/|g; s|/beta/|/__BCM_NEW_CHANNEL__/|g" "$f"
            sed -i "s|/__BCM_NEW_CHANNEL__/|/${new_channel}/|g" "$f"
            bcm_ok "  Обновлён: $(basename "$f")"
            ((changed++))
        else
            bcm_warn "  Не содержит /stable/ или /beta/: $(basename "$f") — пропущен"
        fi
    done

    if [[ $changed -gt 0 ]]; then
        bcm_info "Очистка кэша dnf..."
        dnf clean all 2>/dev/null || true
        bcm_ok "Репозиторий переключён на '${new_channel}'."
        bcm_log_info "bitrix-env репозиторий переключён на ${new_channel}"
    else
        bcm_warn "Ни один файл не был изменён."
    fi

    bcm_any_key
}

# ──── Дисковое пространство ───────────────────────────────────────────────────
_lh_disk_space() {
    bcm_section_header "Дисковое пространство"

    echo "  $(df -h --output=source,size,used,avail,pcent,target 2>/dev/null | head -1)"
    bcm_divider "${BCM_LINE_H1}"
    df -h --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n +2 | \
        while IFS= read -r line; do
            local pct
            pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
            if [[ "$pct" =~ ^[0-9]+$ && "$pct" -ge 90 ]]; then
                bcm_echo_color "RED_BOLD" "  ${line}"
            elif [[ "$pct" =~ ^[0-9]+$ && "$pct" -ge 75 ]]; then
                bcm_echo_color "YELLOW_BOLD" "  ${line}"
            else
                echo "  ${line}"
            fi
            echo
        done

    echo
    bcm_info "Использование inode:"
    df -i 2>/dev/null | sed 's/^/  /' || true
    echo

    bcm_any_key
}

# ──── Память ─────────────────────────────────────────────────────────────────
_lh_memory() {
    bcm_section_header "Память и Swap"

    echo "  Оперативная память:"
    free -h 2>/dev/null | sed 's/^/  /'
    echo

    echo "  Использование памяти по процессам (top-10):"
    ps aux --sort=-%mem 2>/dev/null | head -11 | awk '{printf "  %-10s %6s%% %s\n", $1, $4, $11}' || true
    echo

    # Swap подробно
    if swapon --show 2>/dev/null | grep -q .; then
        echo "  Swap-разделы:"
        swapon --show 2>/dev/null | sed 's/^/  /'
    else
        bcm_info "Swap не настроен."
    fi

    echo
    bcm_any_key
}

# ──── Меню ────────────────────────────────────────────────────────────────────
_lh_print_menu() {
    local -a items=(
        "1.  Статус хоста (hostname, IP, NTP)"
        "2.  Сменить hostname"
        "3.  Настроить NTP (chrony)"
        "4.  Обновить пакеты (dnf update)"
        "5.  Сменить репозиторий bitrix-env (stable/beta)"
        "6.  Дисковое пространство (df -h)"
        "7.  Память и Swap (free -h)"
        "0.  Назад"
    )
    bcm_print_menu items
}

# ──── Главная функция ─────────────────────────────────────────────────────────
main() {
    bcm_load_topology 2>/dev/null || true

    local app_ver benv_ver current_role current_node
    app_ver=$(bcm_get_app_version)
    benv_ver=$(bcm_get_local_benv_version)
    current_role=$(bcm_get_current_role 2>/dev/null || echo "unknown")
    current_node=$(bcm_get_current_node_name 2>/dev/null || hostname -s)

    while true; do
        bcm_print_header "$app_ver" "$benv_ver" "$current_role" "$current_node"
        bcm_color "WHITE" "  ═══ Настройка локального хоста ═══"
        echo

        _lh_print_menu

        local choice
        bcm_read_choice "Введите ваш выбор" choice

        case "$choice" in
            1) _lh_show_status ;;
            2) _lh_change_hostname ;;
            3) _lh_configure_ntp ;;
            4) _lh_update_packages ;;
            5) _lh_change_repo ;;
            6) _lh_disk_space ;;
            7) _lh_memory ;;
            0) break ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: '${choice}'. Введите число от 0 до 7." ;;
        esac
    done
}

main "$@"
