#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_cluster_mode.sh — «Режим единой ноды» (single-active) для кластера
#
# Зачем: при первичной установке или переносе сайта/портала удобно временно
# закрепить всю нагрузку на ОДНОЙ web-ноде, чтобы трафик и БД-запросы не
# «гуляли» между нодами (round-robin, чтения с разных реплик), пока заливаются
# данные. Остальные ноды остаются тёплыми (службы работают, lsyncd синхронит).
#
# Что делает режим single:
#   • HAProxy (на всех lb): все web-сервера, кроме активного → state maint
#     (drain). Весь HTTP идёт на активную ноду. Возврат → state ready.
#   • ProxySQL (на всех web): правило ^SELECT (rule_id=4) → HG_WRITE, т.е. и
#     чтения уходят на writer. Возврат → обратно на HG_READ.
#   • Состояние пишется в cluster.conf: [cluster] mode=single, active_node=<web>.
#
# Зависимости: bcm_utils.sh, bcm_config.sh, bcm_ssh.sh (должны быть подключены).
# =============================================================================

# ──── HAProxy admin-сокет на lb-узле ─────────────────────────────────────────
_bcm_hap_admin() {
    local lb_ip="$1"
    local cmd="$2"
    # socat предпочтительно; ncat/nc -U как запасной вариант
    bcm_ssh_exec "$lb_ip" \
        "echo '${cmd}' | socat - /run/haproxy-admin.sock 2>/dev/null \
         || echo '${cmd}' | nc -U /run/haproxy-admin.sock 2>/dev/null \
         || echo '${cmd}' | ncat -U /run/haproxy-admin.sock 2>/dev/null"
}

# ──── HAProxy: закрепить web-трафик на active (остальные → other_state) ───────
# _bcm_haproxy_pin_web <active_node|""> <other_state: maint|ready>
# Возвращает 0, только если хотя бы один lb реально принял команды (admin-сокет
# отвечает) и ни один достижимый lb не вернул ошибку. Иначе — ненулевой код.
# Раньше любые ошибки молча глотались (>/dev/null 2>&1) — pin «успешно» делал ничего.
_bcm_haproxy_pin_web() {
    local active_node="$1"
    local other_state="$2"

    local lb_nodes web_nodes
    lb_nodes=$(bcm_get_nodes "lb" 2>/dev/null) || lb_nodes=""
    web_nodes=$(bcm_get_nodes "web" 2>/dev/null) || web_nodes=""

    if [[ -z "$lb_nodes" || -z "$web_nodes" ]]; then
        bcm_log_warn "_bcm_haproxy_pin_web: пустой список lb/web-нод — HAProxy не тронут."
        return 1
    fi

    local lb applied=0 failed=0
    for lb in $lb_nodes; do
        local lb_ip
        lb_ip=$(bcm_get_node_ip "lb" "$lb") || continue
        if ! bcm_node_reachable "$lb_ip" 4 2>/dev/null; then
            bcm_log_warn "  LB ${lb} (${lb_ip}): недоступен — пропуск."
            failed=$((failed+1))
            continue
        fi
        # Проба admin-сокета: 'show info' должен что-то вернуть. Пусто → нет
        # socat/nc или сокет недоступен (иначе 'set server' молча терялся).
        if [[ -z "$(_bcm_hap_admin "$lb_ip" "show info" 2>/dev/null)" ]]; then
            bcm_log_error "  LB ${lb} (${lb_ip}): admin-сокет HAProxy не отвечает (нет socat/nc?) — состояние НЕ изменено."
            failed=$((failed+1))
            continue
        fi

        local wn err_any=0 out
        for wn in $web_nodes; do
            local st="$other_state"
            [[ "$wn" == "$active_node" ]] && st="ready"
            # Публичный трафик и админка/запись следуют за активной нодой, чтобы
            # источник lsyncd, публичный бэкенд и админка были на одной ноде.
            # HAProxy на успешный 'set server' отвечает пустотой; непустой ответ — ошибка.
            out=$(_bcm_hap_admin "$lb_ip" "set server web_backend/${wn} state ${st}" 2>/dev/null)
            [[ -n "${out//[[:space:]]/}" ]] && { bcm_log_warn "    ${lb}: web_backend/${wn} → ${st}: ${out//$'\n'/ }"; err_any=1; }
            out=$(_bcm_hap_admin "$lb_ip" "set server web_admin_backend/${wn} state ${st}" 2>/dev/null)
            [[ -n "${out//[[:space:]]/}" ]] && { bcm_log_warn "    ${lb}: web_admin_backend/${wn} → ${st}: ${out//$'\n'/ }"; err_any=1; }
        done
        if [[ $err_any -eq 0 ]]; then
            bcm_log_info "  LB ${lb} (${lb_ip}): web-бэкенды переключены (active=${active_node:-—}, прочие=${other_state})."
            applied=$((applied+1))
        else
            failed=$((failed+1))
        fi
    done

    if [[ $applied -eq 0 || $failed -gt 0 ]]; then
        bcm_log_error "_bcm_haproxy_pin_web: lb применено=${applied}, с ошибкой/недоступно=${failed}."
        return 1
    fi
    return 0
}

# ──── ProxySQL: куда направлять ^SELECT (rule_id=4 в proxysql.cnf.tmpl) ───────
# _bcm_proxysql_select_target <hostgroup>
# Применяет на ВСЕХ доступных web-нодах И проверяет runtime-результат. Возвращает
# 0, только если хотя бы одна нода переключена и ни одна доступная не дала сбой;
# иначе — ненулевой код. Раньше ошибки UPDATE молча глотались (>/dev/null 2>&1),
# и при неверном пароле (см. баг с '#' в admin_password) pin «успешно» не делал
# ничего — отсюда повторяющаяся ошибка 9006 на установке портала.
_bcm_proxysql_select_target() {
    local hg="$1"
    local web_nodes ap au aps
    web_nodes=$(bcm_get_nodes "web" 2>/dev/null) || web_nodes=""
    ap=$(bcm_get_proxysql_admin_port 2>/dev/null || echo "6032")
    au=$(bcm_get_proxysql_admin_user 2>/dev/null || echo "admin")
    aps=$(bcm_get_proxysql_admin_pass 2>/dev/null || echo "admin")

    if [[ -z "$web_nodes" ]]; then
        bcm_log_error "_bcm_proxysql_select_target: список web-нод пуст."
        return 1
    fi

    # ProxySQL принимает пароль только как -p<pass> (не MYSQL_PWD/defaults-file).
    # Одинарное квотирование с экранированием самих '  для удалённого шелла —
    # пароль может содержать спецсимволы (#, !, ), $, …).
    local aps_q="'${aps//\'/\'\\\'\'}'"

    local wn ip out rc got applied=0 failed=0
    for wn in $web_nodes; do
        ip=$(bcm_get_node_ip "web" "$wn") || { bcm_log_warn "  ${wn}: не найден IP — пропуск."; failed=$((failed+1)); continue; }
        if ! bcm_node_reachable "$ip" 4 2>/dev/null; then
            bcm_log_warn "  ${wn} (${ip}): недоступна — ProxySQL не переключён."
            failed=$((failed+1))
            continue
        fi

        out=$(bcm_ssh_exec_verbose "$ip" \
            "mysql --default-auth=mysql_native_password -h127.0.0.1 -P${ap} -u${au} -p${aps_q} -e \
             \"UPDATE mysql_query_rules SET destination_hostgroup=${hg} WHERE rule_id=4; \
               LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK;\"" 2>&1)
        rc=$?
        if [[ $rc -ne 0 ]]; then
            bcm_log_error "  ${wn} (${ip}): ошибка ProxySQL admin — ${out//$'\n'/ }"
            failed=$((failed+1))
            continue
        fi

        # Верификация: правило rule_id=4 реально указывает на нужную HG в RUNTIME.
        got=$(bcm_ssh_exec "$ip" \
            "mysql --default-auth=mysql_native_password -h127.0.0.1 -P${ap} -u${au} -p${aps_q} -N -e \
             \"SELECT destination_hostgroup FROM runtime_mysql_query_rules WHERE rule_id=4;\"")
        got="${got//[[:space:]]/}"
        if [[ "$got" == "$hg" ]]; then
            bcm_log_info "  ${wn} (${ip}): ^SELECT → HG ${hg} (подтверждено)."
            applied=$((applied+1))
        else
            bcm_log_error "  ${wn} (${ip}): переключение НЕ подтверждено (rule_id=4 → '${got:-?}', ожидалось ${hg})."
            failed=$((failed+1))
        fi
    done

    if [[ $failed -gt 0 || $applied -eq 0 ]]; then
        bcm_log_error "_bcm_proxysql_select_target: переключено=${applied}, с ошибкой=${failed} (HG ${hg})."
        return 1
    fi
    bcm_log_info "_bcm_proxysql_select_target: ^SELECT → HG ${hg} на всех web-нодах (${applied})."
    return 0
}

# ──── Включить режим single ──────────────────────────────────────────────────
# bcm_cluster_pin <active_web_node>
bcm_cluster_pin() {
    local active_node="$1"
    if [[ -z "$active_node" ]]; then
        bcm_log_error "bcm_cluster_pin: не указана активная нода."
        return 1
    fi

    local hg_write
    hg_write=$(bcm_get_proxysql_hg_write 2>/dev/null || echo "10")

    bcm_log_info "Режим единой ноды ВКЛ: active=${active_node}"

    # HAProxy-переключение некритично для БД-ошибок (9006) — при сбое предупреждаем,
    # но продолжаем. Критичен ProxySQL: без него чтения внутри транзакций падают.
    _bcm_haproxy_pin_web "$active_node" "maint" \
        || bcm_log_warn "bcm_cluster_pin: HAProxy переключён НЕ полностью (см. выше) — проверь lb."

    if ! _bcm_proxysql_select_target "$hg_write"; then
        bcm_log_error "bcm_cluster_pin: ^SELECT НЕ переведён на writer — режим НЕ активирован (cluster.conf не изменён)."
        return 1
    fi

    bcm_conf_set "cluster" "mode" "single"
    bcm_conf_set "cluster" "active_node" "$active_node"
    bcm_conf_sync 2>/dev/null || true
    bcm_log_info "Режим единой ноды активирован (active=${active_node})."
    return 0
}

# ──── Выключить режим single (вернуть HA) ────────────────────────────────────
bcm_cluster_unpin() {
    local hg_read
    hg_read=$(bcm_get_proxysql_hg_read 2>/dev/null || echo "20")

    bcm_log_info "Режим единой ноды ВЫКЛ: возврат в HA."

    _bcm_haproxy_pin_web "" "ready" \
        || bcm_log_warn "bcm_cluster_unpin: HAProxy восстановлен НЕ полностью (см. выше) — проверь lb."

    if ! _bcm_proxysql_select_target "$hg_read"; then
        bcm_log_error "bcm_cluster_unpin: ^SELECT НЕ возвращён на readers — режим НЕ снят (cluster.conf не изменён)."
        return 1
    fi

    bcm_conf_set "cluster" "mode" "normal"
    bcm_conf_sync 2>/dev/null || true
    bcm_log_info "Возврат в HA выполнен (^SELECT → HG ${hg_read})."
    return 0
}

# ──── Баннер режима для шапки BCM ────────────────────────────────────────────
bcm_cluster_mode_banner() {
    local mode
    mode=$(bcm_get_cluster_mode)
    [[ "$mode" != "single" ]] && return 0
    local an
    an=$(bcm_get_active_node)
    bcm_color "YELLOW_BOLD" "  ⚠  РЕЖИМ ЕДИНОЙ НОДЫ: весь HTTP → ${an:-?}, БД → writer. Балансировка/HA приостановлены."
}
