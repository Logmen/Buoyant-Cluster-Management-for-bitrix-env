#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181,SC2206
# =============================================================================
# bcm_php_update.sh — смена версии PHP на web-нодах БЕЗ простоя портала.
#
# Зачем отдельная процедура. Штатное меню bitrix-env умеет менять версию PHP,
# но ⚠️ обновит только ноды, попавшие в его пул: в кластере BCM в инвентаре
# ansible обычно одна нода (`/etc/ansible/hosts`), остальные для bitrix-env
# «не существуют». Прогон его меню оставил бы кластер с разными версиями PHP на
# разных нодах — расхождение, которое проявится случайными ошибками в
# зависимости от того, какая нода ответила.
#
# Порядок обхода: сначала запасные ноды, ⚠️ brain-нода (источник lsyncd, где
# запущен BCM) — ПОСЛЕДНЕЙ. На ней держится админка и запись кода, поэтому её
# трогают, когда остальные уже проверены и снова в строю.
#
# Каждая нода проходит цикл: дренаж в HAProxy → смена потока модуля → конвертация
# ini вспомогательными скриптами bitrix-env → рестарт httpd → ПРОВЕРКИ → возврат
# в балансировку. ⚠️ Гейты fail-closed: не прошла проверка — процедура
# ОСТАНАВЛИВАЕТСЯ, остальные ноды не трогаются, кластер остаётся частично на
# старой версии (это лучше, чем сломать все ноды разом).
#
# ⚠️⚠️ Проверка версии и расширений делается В ВЕБ-КОНТЕКСТЕ, а не только через
# `php -m`: mod_php читает /etc/php.d ТОЛЬКО при старте, и CLI показывает уже
# новую картину, когда веб-сервер ещё работает на старой. На этом обжигались
# дважды (php-pecl-amqp, curl).
#
# ⚠️ Смена версии сбрасывает профиль расширений: bitrix-env держит минимальный
# набор, а часть расширений включают вручную. Поэтому набор снимается ДО смены и
# сверяется ПОСЛЕ — пропавшие перечисляются в отчёте.
# =============================================================================

_PHPU_HTTPD_TIMEOUT=120     # ожидание подъёма httpd после рестарта
_PHPU_DNF_TIMEOUT=900       # смена потока модуля + перекачка пакетов
_PHPU_DRAIN_SETTLE=8        # пауза после возврата ноды в балансировку

# ──── HAProxy: дренаж ноды на всех LB ───────────────────────────────────────
# Повторяет приём из bcm_os_update.sh: команда идёт в admin-сокет каждого LB,
# иначе нода останется в пуле на том балансировщике, до которого не дошли.
_phpu_hap_set() {
    local p_server="$1" p_state="$2" p_lb p_lb_ip p_be
    for p_lb in $(bcm_get_nodes "lb" 2>/dev/null); do
        p_lb_ip=$(bcm_get_node_ip "lb" "$p_lb") || continue
        bcm_node_reachable "$p_lb_ip" 4 2>/dev/null || continue
        for p_be in web_backend web_cache_backend web_admin_backend mcp_backend; do
            bcm_ssh_exec "$p_lb_ip" \
                "echo 'set server ${p_be}/${p_server} state ${p_state}' | socat - /run/haproxy-admin.sock 2>/dev/null \
                 || echo 'set server ${p_be}/${p_server} state ${p_state}' | nc -U /run/haproxy-admin.sock 2>/dev/null" \
                >/dev/null 2>&1
        done
    done
}

# ──── Снимок состояния PHP на ноде ──────────────────────────────────────────
_phpu_cli_version() {
    bcm_ssh_exec "$1" "php -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;' 2>/dev/null" 2>/dev/null | tr -d '[:space:]'
}

_phpu_extensions() {
    bcm_ssh_exec "$1" "php -m 2>/dev/null | grep -viE '^\[|^$' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' '" 2>/dev/null
}

# Версия и ключевые расширения глазами ВЕБ-СЕРВЕРА (mod_php), а не CLI.
# Файл-зонд кладётся в корень портала и удаляется сразу же.
_phpu_web_version() {
    local p_ip="$1" p_domain="$2" p_out
    p_out=$(bcm_ssh_exec "$p_ip" "
        f=/home/bitrix/www/.bcm-phpu-probe.php
        printf '<?php echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;' > \$f
        chown bitrix:bitrix \$f 2>/dev/null
        curl -s -m 10 -H 'Host: ${p_domain}' http://127.0.0.1/.bcm-phpu-probe.php 2>/dev/null
        rm -f \$f" 2>/dev/null | tr -d '[:space:]')
    echo "$p_out"
}

# ──── Обновление одной ноды ─────────────────────────────────────────────────
# Возвращает 0 при успехе; при любом провале гейта — ненулевой код, и вызывающий
# ОСТАНАВЛИВАЕТ обход.
_phpu_update_node() {
    local p_node="$1" p_ip="$2" p_target="$3" p_domain="$4"
    local p_ext_before p_ver_before p_ver_cli p_ver_web p_ext_after p_missing

    p_ver_before=$(_phpu_cli_version "$p_ip")
    p_ext_before=$(_phpu_extensions "$p_ip")
    bcm_info "  ${p_node}: сейчас PHP ${p_ver_before:-?}, расширений $(echo "$p_ext_before" | wc -w)"

    bcm_info "  ${p_node}: вывожу из балансировки..."
    _phpu_hap_set "$p_node" "maint"
    sleep 3

    # Бэкап php.ini средствами bitrix-env (если есть) — он же кладёт копию туда,
    # где её ищут штатные процедуры отката.
    bcm_ssh_exec "$p_ip" "[ -x /opt/webdir/bin/backup_php_ini_file.sh ] && /opt/webdir/bin/backup_php_ini_file.sh >/dev/null 2>&1; true" >/dev/null 2>&1

    bcm_info "  ${p_node}: переключаю поток модуля на remi-${p_target}..."
    # ⚠️ distro-sync, а НЕ update: update умеет только повышать версию, а эта же
    # процедура используется и для отката на младшую.
    if ! bcm_ssh_exec_timeout "$p_ip" "$_PHPU_DNF_TIMEOUT" "
            dnf -y -q module reset php >/dev/null 2>&1
            dnf -y -q module enable php:remi-${p_target} >/dev/null 2>&1 || exit 1
            dnf -y distro-sync 'php*' >/dev/null 2>&1 || exit 1
            # Приведение ini расширений и php.ini к новой версии — скрипты bitrix-env.
            [ -x /opt/webdir/bin/convert_phpd_files.sh ] && /opt/webdir/bin/convert_phpd_files.sh >/dev/null 2>&1
            [ -x /opt/webdir/bin/convert_php_ini_file.sh ] && /opt/webdir/bin/convert_php_ini_file.sh >/dev/null 2>&1
            true" 2>/dev/null; then
        bcm_error "  ${p_node}: смена потока/пакетов не удалась."
        _phpu_hap_set "$p_node" "ready"
        return 1
    fi

    bcm_info "  ${p_node}: перезапускаю httpd..."
    bcm_ssh_exec_timeout "$p_ip" "$_PHPU_HTTPD_TIMEOUT" "systemctl restart httpd" >/dev/null 2>&1
    sleep 4

    # ── Гейты ───────────────────────────────────────────────────────────────
    if [[ "$(bcm_ssh_exec "$p_ip" "systemctl is-active httpd" 2>/dev/null | tr -d '[:space:]')" != "active" ]]; then
        bcm_error "  ${p_node}: httpd не поднялся — ОСТАНОВКА, нода осталась вне балансировки."
        return 1
    fi

    p_ver_cli=$(_phpu_cli_version "$p_ip")
    if [[ "$p_ver_cli" != "$p_target" ]]; then
        bcm_error "  ${p_node}: CLI показывает PHP ${p_ver_cli:-?}, ожидалось ${p_target} — ОСТАНОВКА."
        return 1
    fi

    # ⚠️ Главная проверка: что видит веб-сервер. CLI мог обновиться, а mod_php —
    # нет (он читает /etc/php.d только при старте).
    p_ver_web=$(_phpu_web_version "$p_ip" "$p_domain")
    if [[ "$p_ver_web" != "$p_target" ]]; then
        bcm_error "  ${p_node}: веб-сервер отдаёт PHP ${p_ver_web:-нет ответа}, ожидалось ${p_target} — ОСТАНОВКА."
        return 1
    fi

    # Профиль расширений: смена версии приносит свои ini, часть включённых вручную
    # может отвалиться. Не считаем это провалом, но обязаны сообщить.
    p_ext_after=$(_phpu_extensions "$p_ip")
    p_missing=""
    local p_e
    for p_e in $p_ext_before; do
        [[ " $p_ext_after " == *" $p_e "* ]] || p_missing+="$p_e "
    done

    bcm_ok "  ${p_node}: PHP ${p_target} (CLI и веб), httpd поднят."
    if [[ -n "$p_missing" ]]; then
        bcm_warn "  ${p_node}: ПРОПАЛИ расширения: ${p_missing}"
        bcm_warn "     включить: /etc/php.d/<NN>-<имя>.ini + systemctl restart httpd"
    fi

    bcm_info "  ${p_node}: возвращаю в балансировку..."
    _phpu_hap_set "$p_node" "ready"
    sleep "$_PHPU_DRAIN_SETTLE"
    return 0
}

# ──── Порядок обхода: brain-нода последней ──────────────────────────────────
_phpu_order_web() {
    local p_self="$1" p_rest="" p_n
    for p_n in $(bcm_get_nodes "web" 2>/dev/null | sort); do
        [[ "$p_n" != "$p_self" ]] && p_rest+="$p_n "
    done
    echo "${p_rest}${p_self:+$p_self}"
}

# ──── Показать текущее состояние ────────────────────────────────────────────
bcm_php_status() {
    bcm_section_header "Версии PHP на web-нодах"
    local p_n p_ip p_cli p_streams
    # ⚠️ bcm_pad, а не printf %-Ns: printf дополняет по БАЙТАМ, и ячейки с
    # кириллицей («Нода», «SSH недоступен») визуально уже — разделители уезжают.
    printf "  %s │ %s │ %s\n" "$(bcm_pad 'Нода' 10)" "$(bcm_pad 'PHP' 8)" "Расширений"
    echo "  ────────────────────────────────────────────"
    for p_n in $(bcm_get_nodes "web" 2>/dev/null | sort); do
        p_ip=$(bcm_get_node_ip "web" "$p_n") || continue
        if ! bcm_node_reachable "$p_ip" 5 2>/dev/null; then
            printf "  %s │ %s │ %s\n" "$(bcm_pad "$p_n" 10)" "$(bcm_pad '—' 8)" "SSH недоступен"; continue
        fi
        p_cli=$(_phpu_cli_version "$p_ip")
        printf "  %s │ %s │ %s\n" "$(bcm_pad "$p_n" 10)" "$(bcm_pad "${p_cli:-?}" 8)" "$(_phpu_extensions "$p_ip" | wc -w)"
    done
    echo
    # ⚠️ первое СЛОВО, а не первая строка: bcm_get_nodes отдаёт узлы в одну
    # строку через пробел, и `head -1` вернул бы весь список как одно имя.
    local p_first; p_first=$(bcm_get_nodes "web" 2>/dev/null | awk '{print $1}')
    p_ip=$(bcm_get_node_ip "web" "$p_first" 2>/dev/null)
    if [[ -n "$p_ip" ]]; then
        p_streams=$(bcm_ssh_exec "$p_ip" "dnf module list php 2>/dev/null | awk '/^php +remi-/{print \$2}' | tr '\n' ' '" 2>/dev/null)
        bcm_info "Доступные потоки: ${p_streams:-не определены}"
    fi
}

# ──── Главная процедура ─────────────────────────────────────────────────────
bcm_php_rolling() {
    local p_target="$1"
    bcm_section_header "Смена версии PHP на web-нодах (последовательно)"

    [[ "$p_target" =~ ^8\.[0-9]$ ]] || { bcm_error "Версия задаётся как 8.2 / 8.3 / 8.4."; bcm_any_key; return 1; }

    local p_self p_domain p_order p_n p_ip
    p_self=$(hostname -s 2>/dev/null)
    p_domain=$(bcm_conf_get network portal_domain 2>/dev/null); [[ -z "$p_domain" ]] && p_domain="localhost"
    p_order=$(_phpu_order_web "$p_self")

    bcm_info "Порядок: ${p_order}(brain-нода последней)"
    bcm_warn "⚠ Ноды обновляются ПО ОДНОЙ с выводом из балансировки; портал остаётся доступен."
    bcm_warn "⚠ При провале проверки процедура ОСТАНАВЛИВАЕТСЯ: часть нод останется на прежней версии."
    echo
    bcm_confirm "Перевести web-ноды на PHP ${p_target}?" || { bcm_info "Отменено."; bcm_any_key; return 0; }

    local p_done=0 p_failed=""
    for p_n in $p_order; do
        p_ip=$(bcm_get_node_ip "web" "$p_n") || continue
        if ! bcm_node_reachable "$p_ip" 5 2>/dev/null; then
            bcm_error "  ${p_n}: SSH недоступен — ОСТАНОВКА."
            p_failed="$p_n"; break
        fi
        echo
        if _phpu_update_node "$p_n" "$p_ip" "$p_target" "$p_domain"; then
            p_done=$((p_done + 1))
        else
            p_failed="$p_n"; break
        fi
    done

    echo
    if [[ -n "$p_failed" ]]; then
        bcm_error "Процедура остановлена на ноде ${p_failed}. Обновлено нод: ${p_done}."
        bcm_warn "Кластер сейчас с РАЗНЫМИ версиями PHP — разберитесь с ${p_failed} и повторите."
        bcm_info "Откат ноды: тот же пункт меню с прежней версией."
    else
        bcm_ok "Все web-ноды переведены на PHP ${p_target} (обновлено: ${p_done})."
        bcm_info "⚠ Профиль расширений bitrix-env минимален: проверьте предупреждения выше."
    fi
    bcm_any_key
}
