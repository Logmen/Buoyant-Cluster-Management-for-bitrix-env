#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 15_mail.sh — Почта: HA Postfix smarthost-релей (оркестрация bcm_mail.sh)
#
# Исполнитель — bin/lib/bcm_mail.sh на КАЖДОЙ web-ноде (Postfix как smarthost →
# единый внешний SMTP-релей, локальная очередь+ретраи, node-agnostic). VIP не нужен:
# отправка per-node и stateless к кластеру; единая идентичность = внешний релей.
#
# ⚠️ Как Transformer — ОСОЗНАННО не в install.sh: требует внешних SMTP-кред
# (хост/логин/пароль релея), которых нет в answers. Настройка — через это меню.
#
# Конфиг: не-секрет в cluster.conf [mail] и /etc/bitrix-cluster/mail.env (на нодах),
# пароль релея — отдельным raw-файлом /etc/bitrix-cluster/.mail_relay_pass (0600).
# =============================================================================
set -euo pipefail

source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"

MAIL_LIB="/opt/bcm/bin/lib/bcm_mail.sh"
MAIL_ENV="/etc/bitrix-cluster/mail.env"
MAIL_PASS_FILE="/etc/bitrix-cluster/.mail_relay_pass"

# ──── Статус релея на всех web-нодах ─────────────────────────────────────────
_mail_show_status() {
    bcm_section_header "Статус почтового релея (Postfix smarthost)"
    local node ip out
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_color "WHITE" "  ── ${node} (${ip}) ──"
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_echo_color "RED_BOLD" "  Узел недоступен"; echo; continue
        fi
        out=$(bcm_ssh_exec_timeout "$ip" 15 "${MAIL_LIB} --status" 2>/dev/null) || out=""
        if [[ -z "$out" ]]; then
            bcm_warn "  релей не настроен (bcm_mail.sh нет статуса)."
        else
            echo "$out" | sed 's/^/  /'
        fi
        echo
    done
    bcm_any_key
}

# ──── Настроить / обновить smarthost ─────────────────────────────────────────
_mail_configure() {
    bcm_section_header "Настройка Postfix-smarthost (внешний SMTP-релей)"

    local cur_host cur_port cur_user cur_tls cur_from cur_dom
    cur_host=$(bcm_conf_get mail relay_host 2>/dev/null || echo "")
    cur_port=$(bcm_conf_get mail relay_port 2>/dev/null || echo "587")
    cur_user=$(bcm_conf_get mail relay_user 2>/dev/null || echo "")
    cur_tls=$(bcm_conf_get mail relay_tls 2>/dev/null || echo "starttls")
    cur_from=$(bcm_conf_get mail from_address 2>/dev/null || echo "")
    cur_dom=$(bcm_conf_get mail from_domain 2>/dev/null || echo "")

    bcm_info "Текущий релей: ${cur_host:-—}:${cur_port:-—} (0/пусто на хосте — отмена)."
    echo

    local host port user tls from_addr from_dom pass
    bcm_read_choice "SMTP-хост релея${cur_host:+ [${cur_host}]}" host
    [[ "$host" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ -z "$host" ]] && host="$cur_host"
    [[ -z "$host" ]] && { bcm_error "Хост релея обязателен."; bcm_any_key; return; }

    bcm_read_choice "Порт [${cur_port:-587}] (587=STARTTLS, 465=TLS-wrapper, 25=без TLS)" port
    [[ -z "$port" ]] && port="${cur_port:-587}"

    bcm_read_choice "Логин SASL (e-mail/username)${cur_user:+ [${cur_user}]}" user
    [[ -z "$user" ]] && user="$cur_user"

    # Пароль — скрытый ввод; пусто = оставить уже сохранённый на нодах
    read -rsp "  Пароль SASL (пусто — оставить сохранённый): " pass; echo

    # TLS-режим (дефолт по порту)
    local tls_def="starttls"
    [[ "$port" == "465" ]] && tls_def="wrapper"
    [[ "$port" == "25"  ]] && tls_def="none"
    [[ -n "$cur_tls" ]] && tls_def="$cur_tls"
    bcm_read_choice "TLS-режим: starttls|wrapper|none [${tls_def}]" tls
    [[ -z "$tls" ]] && tls="$tls_def"

    bcm_read_choice "Домен отправителя для SPF/DKIM/DMARC${cur_dom:+ [${cur_dom}]}" from_dom
    [[ -z "$from_dom" ]] && from_dom="$cur_dom"

    bcm_read_choice "Переписать envelope-from на единый адрес (пусто — не переписывать)${cur_from:+ [${cur_from}]}" from_addr
    [[ -z "$from_addr" ]] && from_addr="$cur_from"

    echo
    bcm_info "Релей: [${host}]:${port}  логин: ${user:-—}  TLS: ${tls}  домен: ${from_dom:-—}"
    [[ -n "$from_addr" ]] && bcm_info "envelope-from → ${from_addr}"
    if ! bcm_confirm "Раскатать и применить на ВСЕХ web-нодах (${BCM_NODES_WEB[*]})?"; then
        bcm_info "Отменено."; bcm_any_key; return
    fi

    # Персист не-секрет в cluster.conf
    bcm_conf_set mail enabled "yes"      2>/dev/null || true
    bcm_conf_set mail relay_host "$host" 2>/dev/null || true
    bcm_conf_set mail relay_port "$port" 2>/dev/null || true
    bcm_conf_set mail relay_user "$user" 2>/dev/null || true
    bcm_conf_set mail relay_tls "$tls"   2>/dev/null || true
    bcm_conf_set mail from_address "$from_addr" 2>/dev/null || true
    bcm_conf_set mail from_domain "$from_dom"   2>/dev/null || true

    # Раскатка по web-нодам (for-цикл по массиву — ssh в теле безопасен)
    local node ip ok=0 fail=0
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "  ${node} (${ip}) недоступен — пропуск."; fail=$((fail+1)); continue
        fi
        bcm_info "  ${node}: запись mail.env..."

        # mail.env (не-секрет, KEY='value' — пароля здесь нет)
        printf '%s\n' \
            "# Сгенерировано BCM (меню 15) — параметры bcm_mail.sh" \
            "MAIL_ENABLED='yes'" \
            "SELF_NODE='${node}'" \
            "SELF_IP='${ip}'" \
            "RELAY_HOST='${host}'" \
            "RELAY_PORT='${port}'" \
            "RELAY_USER='${user}'" \
            "RELAY_TLS='${tls}'" \
            "FROM_ADDRESS='${from_addr}'" \
            "FROM_DOMAIN='${from_dom}'" \
            | bcm_ssh_exec "$ip" "mkdir -p /etc/bitrix-cluster && cat > ${MAIL_ENV} && chmod 600 ${MAIL_ENV}" 2>/dev/null \
            || { bcm_warn "  ${node}: не удалось записать mail.env."; fail=$((fail+1)); continue; }

        # Пароль (raw, 0600) — только если введён новый; иначе оставляем сохранённый
        if [[ -n "$pass" ]]; then
            printf '%s' "$pass" \
                | bcm_ssh_exec "$ip" "cat > ${MAIL_PASS_FILE} && chmod 600 ${MAIL_PASS_FILE}" 2>/dev/null \
                || { bcm_warn "  ${node}: не удалось записать пароль релея."; fail=$((fail+1)); continue; }
        fi

        bcm_info "  ${node}: применение (postfix configure)..."
        if bcm_ssh_exec_timeout "$ip" 180 "${MAIL_LIB} --configure" 2>&1 | sed 's/^/    /'; then
            bcm_ok "  ${node}: применено."
            ok=$((ok+1))
        else
            bcm_warn "  ${node}: ошибка применения (см. вывод выше / /var/log/bcm/mail.log)."
            fail=$((fail+1))
        fi
    done

    echo
    bcm_log_info "Postfix-smarthost: применено=${ok}, с ошибкой=${fail}, релей=[${host}]:${port}"
    [[ "$fail" -eq 0 ]] && bcm_ok "Готово на всех web-нодах (${ok})." || bcm_warn "Готово частично (ok=${ok}, fail=${fail})."
    bcm_info "Дальше: пункт 3 — тест отправки; пункт 4 — DNS-записи (SPF/DKIM/DMARC)."
    bcm_any_key
}

# ──── Тест отправки ──────────────────────────────────────────────────────────
_mail_test() {
    bcm_section_header "Тест отправки письма через релей"
    local to
    bcm_read_choice "Адрес получателя (0 — отмена)" to
    [[ "$to" == "0" || -z "$to" ]] && { bcm_info "Отменено."; bcm_any_key; return; }

    bcm_info "С какой ноды отправить?"
    local i=1; local -a nodes=()
    for n in "${BCM_NODES_WEB[@]}"; do echo "    ${i}. ${n}"; nodes+=("$n"); i=$((i+1)); done
    echo "    ${i}. Со всех"
    echo "    0. Назад"
    local sel; bcm_read_choice "Выбор" sel
    [[ "$sel" == "0" || -z "$sel" ]] && { bcm_info "Отменено."; bcm_any_key; return; }

    local -a targets=()
    if [[ "$sel" == "$i" ]]; then
        targets=("${BCM_NODES_WEB[@]}")
    elif [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -lt "$i" ]]; then
        targets=("${nodes[$((sel-1))]}")
    else
        bcm_error "Неверный выбор."; bcm_any_key; return
    fi

    local node ip
    for node in "${targets[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_color "WHITE" "  ── ${node} (${ip}) ──"
        bcm_ssh_exec_timeout "$ip" 30 "${MAIL_LIB} --test '${to}'" 2>&1 | sed 's/^/  /'
        echo
    done
    bcm_any_key
}

# ──── DNS-подсказки ──────────────────────────────────────────────────────────
_mail_dns_hints() {
    bcm_section_header "DNS-записи для доставляемости (SPF / DKIM / DMARC)"
    local dom relay
    dom=$(bcm_conf_get mail from_domain 2>/dev/null || echo "")
    relay=$(bcm_conf_get mail relay_host 2>/dev/null || echo "")
    [[ -z "$dom" ]] && dom="<ваш-домен>"
    echo
    bcm_info "Домен отправителя: ${dom}   Релей: ${relay:-—}"
    echo

    # ⚠️ Если домен отправителя == домен провайдера релея (релей — хост под ним),
    # то SPF/DKIM/DMARC этого домена ведёт ПРОВАЙДЕР — публиковать у себя нечего
    # (и нельзя — это не твой домен). Записи нужны ТОЛЬКО при отправке от СВОЕГО домена.
    if [[ -n "$relay" && "$dom" != "<ваш-домен>" ]] && { [[ "$relay" == "$dom" ]] || [[ "$relay" == *".${dom}" ]]; }; then
        bcm_ok "Отправитель (${dom}) — это домен самого провайдера релея (${relay})."
        echo "  → SPF/DKIM/DMARC для ${dom} ведёт ПРОВАЙДЕР; на твоей стороне публиковать"
        echo "    НИЧЕГО не нужно (и нельзя — это не твой домен). PTR/reverse-DNS — тоже у него."
        echo
        echo "  DNS-записи понадобятся, ТОЛЬКО если будешь слать от СВОЕГО домена"
        echo "  (напр. noreply@<домен-портала>): тогда меняешь в меню 15→2 «домен отправителя»"
        echo "  + envelope-from на свой домен и публикуешь записи на НЁМ (этот экран их покажет)."
        echo
        bcm_any_key
        return
    fi

    echo "  Письма идут как ${dom} через чужой релей (${relay:-внешний SMTP}) → получатель"
    echo "  проверяет DNS ИМЕННО ${dom}. Опубликуй на СВОЁМ домене (точные значения — у провайдера):"
    echo
    echo "  • SPF (TXT @ ${dom}):"
    echo "      v=spf1 include:<spf-релея> -all"
    echo "      (include из доков провайдера, напр. include:_spf.${relay#mail.}; IP web-нод НЕ перечислять)"
    echo
    echo "  • DKIM (TXT <selector>._domainkey.${dom}):"
    echo "      <публичный ключ от релея>   (подпись делает релей; селектор выдаёт он)"
    echo
    echo "  • DMARC (TXT _dmarc.${dom}):"
    echo "      v=DMARC1; p=quarantine; rua=mailto:dmarc@${dom}; adkim=s; aspf=s"
    echo "      (начните с p=none для мониторинга, затем ужесточайте)"
    echo
    echo "  ⚠️ Header From писем Bitrix должен быть на ${dom} (Настройки → e-mail сайта),"
    echo "     иначе DMARC-alignment не сойдётся. PTR/reverse-DNS — на стороне релея."
    echo
    bcm_any_key
}

# ──── Очередь ────────────────────────────────────────────────────────────────
_mail_queue() {
    bcm_section_header "Очередь почты Postfix (mailq)"
    local node ip
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_color "WHITE" "  ── ${node} (${ip}) ──"
        bcm_node_reachable "$ip" 5 2>/dev/null || { bcm_echo_color "RED_BOLD" "  недоступен"; echo; continue; }
        bcm_ssh_exec_timeout "$ip" 15 "${MAIL_LIB} --queue" 2>/dev/null | tail -n 8 | sed 's/^/  /'
        echo
    done
    if bcm_confirm "Вытолкнуть очередь (flush) на всех нодах сейчас?"; then
        for node in "${BCM_NODES_WEB[@]}"; do
            ip="${BCM_NODE_IP[$node]:-}"
            [[ -z "$ip" ]] && continue
            bcm_node_reachable "$ip" 5 2>/dev/null || continue
            bcm_ssh_exec_timeout "$ip" 30 "${MAIL_LIB} --flush" 2>/dev/null | sed 's/^/  /'
        done
    fi
    bcm_any_key
}

# ──── Отключить релей ────────────────────────────────────────────────────────
_mail_disable() {
    bcm_section_header "Отключить Postfix-релей (вернуть msmtp)"
    if ! bcm_confirm "Отключить релей и вернуть отправку на msmtp на ВСЕХ web-нодах?"; then
        bcm_info "Отменено."; bcm_any_key; return
    fi
    local node ip
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_node_reachable "$ip" 5 2>/dev/null || { bcm_warn "  ${node} недоступен — пропуск."; continue; }
        bcm_ssh_exec_timeout "$ip" 60 "${MAIL_LIB} --disable" 2>&1 | sed 's/^/  /'
    done
    bcm_conf_set mail enabled "no" 2>/dev/null || true
    bcm_log_info "Postfix-релей отключён на web-нодах (откат на msmtp)."
    bcm_any_key
}

# ──── Меню ────────────────────────────────────────────────────────────────────
_mail_print_menu() {
    local -a items=(
        "1.  Статус релея на всех web-нодах"
        "2.  Настроить / обновить smarthost (внешний SMTP)"
        "3.  Тест отправки письма"
        "4.  DNS-записи (SPF / DKIM / DMARC)"
        "5.  Очередь почты (mailq / flush)"
        "6.  Отключить релей (вернуть msmtp)"
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
        bcm_color "WHITE" "  ═══ Почта — HA Postfix smarthost-релей ═══"
        echo

        local en relay port
        en=$(bcm_conf_get mail enabled 2>/dev/null || echo "no")
        relay=$(bcm_conf_get mail relay_host 2>/dev/null || echo "")
        port=$(bcm_conf_get mail relay_port 2>/dev/null || echo "")
        if [[ "$en" == "yes" && -n "$relay" ]]; then
            bcm_info "Релей: [${relay}]:${port}  (включён; отправка Bitrix → Postfix → релей)"
        else
            bcm_info "Релей не настроен — отправка идёт через msmtp (по умолчанию bitrix-env)."
        fi
        echo

        _mail_print_menu
        local choice
        bcm_read_choice "Введите ваш выбор" choice
        case "$choice" in
            1) _mail_show_status ;;
            2) _mail_configure ;;
            3) _mail_test ;;
            4) _mail_dns_hints ;;
            5) _mail_queue ;;
            6) _mail_disable ;;
            0) break ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: '${choice}'. Введите число от 0 до 6." ;;
        esac

        bcm_clear_cache
        BCM_CONF_LOADED=0
        bcm_load_topology 2>/dev/null || true
    done
}

main "$@"
