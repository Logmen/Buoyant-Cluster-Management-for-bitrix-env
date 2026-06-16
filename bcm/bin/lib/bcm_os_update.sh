#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_os_update.sh — HA-aware rolling-обновление пакетов ОС на узлах кластера
#
# Зачем: `dnf update` на всех нодах разом ломает HA (Galera теряет кворум, VIP
# исчезает при одновременном падении обоих LB, web-трафик рвётся). Этот модуль
# обновляет ОС ПО ОДНОЙ ноде, в безопасном порядке по слоям, с дренажом, авто-
# перезагрузкой (если нужно) и health-гейтами между нодами.
#
# Решения (зафиксированы с оператором):
#   • Объём: ОС-пакеты, но КЛАСТЕРНЫЙ СТЕК на hold — `dnf -x 'percona-*'
#     -x 'proxysql*'`: версии Percona XtraDB Cluster / ProxySQL НЕ трогаем (иначе
#     версионный скачок посреди rolling ломает Galera SST/IST). Их обновляют
#     отдельной осознанной процедурой.
#   • Перезагрузка: авто (needs-restarting -r) с ожиданием возврата по SSH и
#     восстановления роли/health, прежде чем идти к следующей ноде.
#   • Порядок: s3 → pxc (не-writer первыми, writer последним) → web → lb
#     (VIP-холдер последним). Нода, на которой ЗАПУЩЕН BCM (brain), — последней в
#     web и БЕЗ авто-reboot (иначе оркестратор сам себя убьёт).
#
# Fail-closed: если health-гейт ноды не пройден или кластер деградирован — процесс
# ОСТАНАВЛИВАЕТСЯ (следующие ноды не трогаем). Пакеты Percona/ProxySQL на hold.
#
# Зависимости: bcm_utils.sh, bcm_config.sh, bcm_ssh.sh, bcm_runtime.sh.
# =============================================================================

# Пакеты кластерного стека, которые НЕ обновляем в этой процедуре.
# ⚠️ Кавычки внутри строки нужны: аргументы уходят в УДАЛЁННЫЙ шелл одной строкой,
# без них он попытался бы заглобить `percona-*` по своему cwd. dnf --exclude умеет globs.
_OSU_EXCLUDE_ARGS="-x 'percona-*' -x 'proxysql*'"
# Таймауты (сек)
_OSU_DNF_TIMEOUT=900       # dnf update на одной ноде
_OSU_SSH_BACK_TIMEOUT=420  # ожидание ноды после reboot
_OSU_PXC_SYNC_TIMEOUT=900  # ожидание Synced (с запасом на SST)
_OSU_SVC_TIMEOUT=120       # ожидание подъёма служб

# ──── HAProxy admin-сокет (дренаж web/s3-серверов) ───────────────────────────
_osu_hap_admin() {
    local lb_ip="$1" cmd="$2"
    bcm_ssh_exec "$lb_ip" \
        "echo '${cmd}' | socat - /run/haproxy-admin.sock 2>/dev/null \
         || echo '${cmd}' | nc -U /run/haproxy-admin.sock 2>/dev/null \
         || echo '${cmd}' | ncat -U /run/haproxy-admin.sock 2>/dev/null"
}

# Перевести server в backend'ах на всех LB в нужный state (maint|ready).
# _osu_hap_set_server <backend> <server> <state>
_osu_hap_set_server() {
    local backend="$1" server="$2" state="$3" lb lb_ip
    for lb in $(bcm_get_nodes "lb" 2>/dev/null); do
        lb_ip=$(bcm_get_node_ip "lb" "$lb") || continue
        bcm_node_reachable "$lb_ip" 4 2>/dev/null || continue
        _osu_hap_admin "$lb_ip" "set server ${backend}/${server} state ${state}" >/dev/null 2>&1
    done
}

# ──── Низкоуровневые проверки ────────────────────────────────────────────────
# wsrep-переменная на pxc-ноде (локальный root-сокет mysql).
_osu_wsrep() {
    bcm_ssh_exec "$1" "mysql -N -e \"SHOW STATUS LIKE '$2'\" 2>/dev/null | awk '{print \$2}'" 2>/dev/null | tr -d '[:space:]'
}

# Ждать, пока pxc-нода Synced и cluster_size >= expected.
_osu_pxc_wait_synced() {
    local ip="$1" expected="$2" timeout="${3:-$_OSU_PXC_SYNC_TIMEOUT}" waited=0 st sz
    while [[ $waited -lt $timeout ]]; do
        st=$(_osu_wsrep "$ip" "wsrep_local_state_comment")
        sz=$(_osu_wsrep "$ip" "wsrep_cluster_size")
        [[ "$st" == "Synced" && "${sz:-0}" =~ ^[0-9]+$ && "${sz:-0}" -ge "$expected" ]] && return 0
        sleep 5; waited=$((waited+5))
    done
    return 1
}

# Число pxc-нод, ожидаемых в кворуме (без тех, что в обслуживании).
_osu_pxc_active_count() {
    local pxc node n=0
    pxc=$(bcm_get_nodes "pxc" 2>/dev/null) || { echo 0; return; }
    for node in $pxc; do
        bcm_node_in_maintenance "$node" 2>/dev/null && continue
        n=$((n+1))
    done
    echo "$n"
}

# Все pxc Synced и cluster_size == числу активных (не-обслуживаемых) нод? (gate целостности)
_osu_pxc_cluster_full() {
    local pxc count node ip
    pxc=$(bcm_get_nodes "pxc" 2>/dev/null) || return 1
    count=$(_osu_pxc_active_count)
    for node in $pxc; do
        ip=$(bcm_get_node_ip "pxc" "$node") || return 1
        bcm_node_in_maintenance "$node" 2>/dev/null && continue
        bcm_node_reachable "$ip" 4 2>/dev/null || return 1
        local st sz
        st=$(_osu_wsrep "$ip" "wsrep_local_state_comment")
        sz=$(_osu_wsrep "$ip" "wsrep_cluster_size")
        [[ "$st" == "Synced" && "${sz:-0}" -ge "$count" ]] || return 1
    done
    return 0
}

# Ждать возврата ноды по SSH после reboot (сначала дать ей УЙТИ вниз).
_osu_wait_ssh() {
    local ip="$1" timeout="${2:-$_OSU_SSH_BACK_TIMEOUT}" waited=0
    while bcm_node_reachable "$ip" 2 2>/dev/null && [[ $waited -lt 40 ]]; do sleep 3; waited=$((waited+3)); done
    waited=0
    while [[ $waited -lt $timeout ]]; do
        bcm_node_reachable "$ip" 3 2>/dev/null && return 0
        sleep 5; waited=$((waited+5))
    done
    return 1
}

# Нужна ли перезагрузка после обновления? (0 = нужна)
_osu_needs_reboot() {
    local ip="$1" rc cur new
    rc=$(bcm_ssh_exec "$ip" "needs-restarting -r >/dev/null 2>&1; echo \$?" 2>/dev/null | tr -d '[:space:]')
    [[ "$rc" == "1" ]] && return 0
    [[ "$rc" == "0" ]] && return 1
    # needs-restarting нет → сравнить текущее ядро с последним установленным.
    cur=$(bcm_ssh_exec "$ip" "uname -r" 2>/dev/null | tr -d '[:space:]')
    new=$(bcm_ssh_exec "$ip" "rpm -q --last kernel 2>/dev/null | head -1 | awk '{print \$1}' | sed 's/^kernel-//'" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$new" && "$cur" != "$new" ]] && return 0
    return 1
}

# Перезагрузить ноду и дождаться возврата.
_osu_reboot_wait() {
    local ip="$1" name="$2"
    bcm_info "  ${name}: требуется перезагрузка — перезагружаю..."
    bcm_ssh_exec "$ip" "systemctl reboot >/dev/null 2>&1 &" >/dev/null 2>&1 || true
    if _osu_wait_ssh "$ip"; then
        bcm_ok "  ${name}: вернулась по SSH после перезагрузки."
        return 0
    fi
    bcm_error "  ${name}: НЕ вернулась по SSH за ${_OSU_SSH_BACK_TIMEOUT}с."
    return 1
}

# Выполнить dnf-обновление (стек на hold). Печатает краткий хвост, возвращает rc.
_osu_run_dnf() {
    local ip="$1" name="$2" out rc
    bcm_info "  ${name}: dnf update (Percona/ProxySQL на hold)..."
    out=$(bcm_ssh_exec_timeout "$ip" "$_OSU_DNF_TIMEOUT" \
        "dnf -y -q update ${_OSU_EXCLUDE_ARGS} 2>&1; echo RC=\$?" 2>&1)
    rc=$(echo "$out" | sed -n 's/^RC=//p' | tail -1)
    echo "$out" | grep -vE '^RC=' | tail -4 | sed 's/^/      /'
    [[ "${rc:-1}" == "0" ]] && return 0
    bcm_error "  ${name}: dnf update вернул rc=${rc:-?}."
    return 1
}

# ──── Смена writer (вес) на already-updated Synced ноду ──────────────────────
# _osu_pxc_switch_writer <new_writer_node>  (обновляет cluster.conf + ProxySQL на web)
_osu_pxc_switch_writer() {
    local new_writer="$1" new_ip web web_ip ok=0 fail=0
    new_ip=$(bcm_get_node_ip "pxc" "$new_writer") || return 1
    local ap au aps
    ap=$(bcm_get_proxysql_admin_port 2>/dev/null || echo "6032")
    au=$(bcm_get_proxysql_admin_user 2>/dev/null || echo "admin")
    aps=$(bcm_get_proxysql_admin_pass 2>/dev/null || echo "admin")
    local aps_q="'${aps//\'/\'\\\'\'}'"
    for web in $(bcm_get_nodes "web" 2>/dev/null); do
        web_ip=$(bcm_get_node_ip "web" "$web") || continue
        bcm_node_reachable "$web_ip" 4 2>/dev/null || { fail=$((fail+1)); continue; }
        local r
        r=$(bcm_ssh_exec "$web_ip" \
            "M=\"mysql --default-auth=mysql_native_password -h127.0.0.1 -P${ap} -u${au} -p${aps_q}\"; \
             \$M -e \"UPDATE mysql_servers SET weight=100; UPDATE mysql_servers SET weight=1000 WHERE hostname='${new_ip}'; LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;\" >/dev/null 2>&1 && echo OK || echo FAIL")
        [[ "$r" == *OK* ]] && ok=$((ok+1)) || fail=$((fail+1))
    done
    [[ $ok -gt 0 && $fail -eq 0 ]] || return 1
    bcm_conf_set "layer.pxc" "writer" "$new_writer" 2>/dev/null || true
    bcm_conf_sync 2>/dev/null || true
    return 0
}

# ──── Обновление одной ноды (диспетчер по слою) ──────────────────────────────
# _osu_update_node <layer> <node> <ip> <self_node>
# Возвращает 0 при успехе+пройденном health-гейте, иначе ненулевой код.
_osu_update_node() {
    local layer="$1" node="$2" ip="$3" self_node="$4"
    bcm_section_header "Обновление ОС: ${node} (${ip}) [${layer}]"

    if bcm_node_in_maintenance "$node" 2>/dev/null; then
        bcm_warn "  ${node}: в режиме обслуживания — пропуск."
        return 0
    fi
    if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
        bcm_error "  ${node}: недоступна по SSH — пропуск (обновите позже)."
        return 1
    fi

    local is_self=0
    [[ "$node" == "$self_node" ]] && is_self=1

    # ── Дренаж + предусловия по слою ──
    case "$layer" in
        s3)
            _osu_hap_set_server "s3_backend" "$node" "maint"
            ;;
        web)
            _osu_hap_set_server "web_backend" "$node" "maint"
            _osu_hap_set_server "web_admin_backend" "$node" "maint"
            sleep 3   # дать соединениям стечь
            ;;
        lb)
            # Снять VIP с этой ноды (если держит) — keepalived stop → VIP к пиру.
            bcm_ssh_exec "$ip" "systemctl stop keepalived >/dev/null 2>&1" >/dev/null 2>&1 || true
            sleep 2
            ;;
        pxc)
            # Кластер должен быть целым перед тем, как трогать ноду.
            if ! _osu_pxc_cluster_full; then
                bcm_error "  PXC-кластер не в полном Synced-состоянии — обновление pxc остановлено."
                return 1
            fi
            ;;
    esac

    # ── Обновление пакетов ──
    if ! _osu_run_dnf "$ip" "$node"; then
        # вернуть из дренажа на всякий случай
        [[ "$layer" == "web" ]] && { _osu_hap_set_server web_backend "$node" ready; _osu_hap_set_server web_admin_backend "$node" ready; }
        [[ "$layer" == "s3" ]] && _osu_hap_set_server s3_backend "$node" ready
        [[ "$layer" == "lb" ]] && bcm_ssh_exec "$ip" "systemctl start keepalived >/dev/null 2>&1" >/dev/null 2>&1
        return 1
    fi

    # ── Перезагрузка при необходимости ──
    local need_reboot=1
    _osu_needs_reboot "$ip" && need_reboot=0   # 0 = нужна

    if [[ $need_reboot -eq 0 && $is_self -eq 1 ]]; then
        bcm_warn "  ${node}: это нода, где запущен BCM — АВТО-перезагрузку НЕ делаю."
        bcm_warn "  Пакеты обновлены; перезагрузите ${node} вручную в окно обслуживания."
        # снять дренаж, не перезагружая
        [[ "$layer" == "web" ]] && { _osu_hap_set_server web_backend "$node" ready; _osu_hap_set_server web_admin_backend "$node" ready; }
        return 0
    fi

    if [[ $need_reboot -eq 0 ]]; then
        # PXC: если ребутим writer — сперва увести writer на другую Synced-ноду.
        if [[ "$layer" == "pxc" ]]; then
            local rw; rw=$(bcm_get_pxc_runtime_writer 2>/dev/null || bcm_get_pxc_writer 2>/dev/null)
            if [[ "$rw" == "$node" ]]; then
                local alt alt_ip=""
                for alt in $(bcm_get_nodes "pxc" 2>/dev/null); do
                    [[ "$alt" == "$node" ]] && continue
                    alt_ip=$(bcm_get_node_ip "pxc" "$alt") || continue
                    if _osu_pxc_wait_synced "$alt_ip" 1 10; then break; fi
                    alt=""
                done
                if [[ -n "$alt" ]] && _osu_pxc_switch_writer "$alt"; then
                    bcm_ok "  writer уведён с ${node} → ${alt} перед перезагрузкой."
                else
                    bcm_error "  ${node} — текущий writer, не удалось увести writer — перезагрузку отменяю (смените writer вручную, меню 03)."
                    return 1
                fi
            fi
        fi
        _osu_reboot_wait "$ip" "$node" || return 1
    else
        bcm_info "  ${node}: перезагрузка не требуется."
        # Применить обновлённые библиотеки рестартом служб слоя (нода дренирована).
        case "$layer" in
            web) bcm_ssh_exec "$ip" "systemctl restart nginx httpd >/dev/null 2>&1" >/dev/null 2>&1 || true ;;
            lb)  bcm_ssh_exec "$ip" "systemctl restart haproxy >/dev/null 2>&1" >/dev/null 2>&1 || true ;;
            # pxc: Percona на hold → mysqld не трогаем; s3: minio-бинарь не из dnf.
        esac
    fi

    # ── Возврат в работу + health-гейт ──
    case "$layer" in
        s3)
            if ! bcm_ssh_exec_timeout "$ip" 30 "systemctl is-active minio >/dev/null 2>&1 || systemctl start minio" >/dev/null 2>&1; then :; fi
            local waited=0
            while [[ $waited -lt $_OSU_SVC_TIMEOUT ]]; do
                [[ "$(bcm_check_s3_health "$ip" 2>/dev/null)" == "ok" ]] && break
                sleep 5; waited=$((waited+5))
            done
            _osu_hap_set_server "s3_backend" "$node" "ready"
            [[ "$(bcm_check_s3_health "$ip" 2>/dev/null)" == "ok" ]] || { bcm_error "  ${node}: MinIO health не прошёл."; return 1; }
            bcm_ok "  ${node}: MinIO здоров, возвращён в s3_backend."
            ;;
        pxc)
            if ! _osu_pxc_wait_synced "$ip" "$(_osu_pxc_active_count)"; then
                bcm_error "  ${node}: не вернулась в Synced/полный кворум за ${_OSU_PXC_SYNC_TIMEOUT}с — СТОП."
                return 1
            fi
            bcm_ok "  ${node}: Synced, кворум полный."
            ;;
        web)
            local waited=0
            while [[ $waited -lt $_OSU_SVC_TIMEOUT ]]; do
                bcm_ssh_exec "$ip" "systemctl is-active httpd nginx proxysql >/dev/null 2>&1" >/dev/null 2>&1 && break
                sleep 5; waited=$((waited+5))
            done
            _osu_hap_set_server "web_backend" "$node" "ready"
            _osu_hap_set_server "web_admin_backend" "$node" "ready"
            if ! bcm_ssh_exec "$ip" "systemctl is-active httpd nginx proxysql >/dev/null 2>&1" >/dev/null 2>&1; then
                bcm_error "  ${node}: httpd/nginx/proxysql не все active — СТОП."
                return 1
            fi
            bcm_ok "  ${node}: web-службы active, возвращён в балансировку."
            ;;
        lb)
            bcm_ssh_exec_timeout "$ip" 30 "systemctl start haproxy keepalived >/dev/null 2>&1" >/dev/null 2>&1 || true
            sleep 3
            if ! bcm_ssh_exec "$ip" "systemctl is-active haproxy keepalived >/dev/null 2>&1" >/dev/null 2>&1; then
                bcm_error "  ${node}: haproxy/keepalived не active — СТОП."
                return 1
            fi
            bcm_ok "  ${node}: haproxy/keepalived active."
            ;;
    esac
    return 0
}

# ──── Упорядочивание нод внутри слоя ─────────────────────────────────────────
# pxc: не-writer первыми, writer последним.  echo "node1 node2 ..."
_osu_order_pxc() {
    local nodes writer rest=""
    nodes=$(bcm_get_nodes "pxc" 2>/dev/null)
    writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || bcm_get_pxc_writer 2>/dev/null)
    local n
    for n in $nodes; do [[ "$n" != "$writer" ]] && rest+="$n "; done
    echo "$rest${writer:+$writer}"
}
# lb: не-VIP-холдер первыми, VIP-холдер последним.
_osu_order_lb() {
    local nodes holder rest="" vip
    nodes=$(bcm_get_nodes "lb" 2>/dev/null)
    vip=$(bcm_get_vip 2>/dev/null)
    holder=$(bcm_get_vip_holder "$vip" 2>/dev/null)
    local n
    for n in $nodes; do [[ "$n" != "$holder" ]] && rest+="$n "; done
    echo "$rest${holder:+$holder}"
}
# web: brain-нода (где запущен BCM) последней.
_osu_order_web() {
    local nodes self rest=""
    nodes=$(bcm_get_nodes "web" 2>/dev/null)
    self="$1"
    local n
    for n in $nodes; do [[ "$n" != "$self" ]] && rest+="$n "; done
    echo "$rest${self:+$self}"
}

# ──── Главная процедура: rolling по всему кластеру ───────────────────────────
bcm_osupdate_rolling() {
    bcm_section_header "HA-rolling обновление ОС по кластеру"
    local self_node
    self_node=$(bcm_get_current_node_name 2>/dev/null || hostname -s)

    echo
    bcm_info "Порядок: s3 → pxc (writer последним) → web (brain последней) → lb (VIP-холдер последним)."
    bcm_info "Кластерный стек на hold: percona-*, proxysql* (НЕ обновляются)."
    bcm_info "Перезагрузка — авто (кроме brain-ноды ${self_node}: только пакеты)."
    bcm_warn "Процесс идёт ПО ОДНОЙ ноде с health-гейтами; при сбое гейта — ОСТАНОВКА."
    echo
    if ! bcm_confirm "Запустить HA-rolling обновление ОС всего кластера?"; then
        bcm_info "Отменено."; bcm_any_key; return
    fi

    local layer order node ip rc total_fail=0 done_cnt=0
    for layer in s3 pxc web lb; do
        case "$layer" in
            pxc) order=$(_osu_order_pxc) ;;
            lb)  order=$(_osu_order_lb) ;;
            web) order=$(_osu_order_web "$self_node") ;;
            *)   order=$(bcm_get_nodes "$layer" 2>/dev/null) ;;
        esac
        [[ -z "${order// }" ]] && continue

        bcm_color "CYAN_BOLD" "  ── Слой ${layer}: ${order} ──"
        for node in $order; do
            [[ -z "$node" ]] && continue
            ip=$(bcm_get_node_ip "$layer" "$node") || { bcm_warn "  ${node}: нет IP — пропуск."; continue; }
            if _osu_update_node "$layer" "$node" "$ip" "$self_node"; then
                done_cnt=$((done_cnt+1))
            else
                total_fail=$((total_fail+1))
                bcm_error "Обновление остановлено на ноде ${node} (слой ${layer})."
                bcm_warn "Оставшиеся ноды НЕ тронуты. Разберите причину и перезапустите процедуру."
                bcm_any_key
                return
            fi
        done
        # Доп. гейт целостности PXC после слоя pxc.
        if [[ "$layer" == "pxc" ]] && ! _osu_pxc_cluster_full; then
            bcm_error "После слоя pxc кластер не в полном Synced — СТОП."
            bcm_any_key; return
        fi
    done

    echo
    bcm_ok "HA-rolling обновление завершено: обновлено нод=${done_cnt}, сбоев=${total_fail}."
    if [[ "$(bcm_get_cluster_mode 2>/dev/null)" == "single" ]]; then
        bcm_warn "Кластер в режиме единой ноды — это не связано с обновлением, проверьте при необходимости."
    fi
    bcm_warn "Напоминание: Percona/ProxySQL остались на прежних версиях (hold). Их обновление — отдельной процедурой по одной ноде."
    bcm_any_key
}
