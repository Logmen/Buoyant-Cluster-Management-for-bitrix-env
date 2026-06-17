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
# ⚠️ ВСЕ локальные переменные здесь с префиксом `o_`. Причина (динамическая
# область видимости bash + ловили вживую): вызываемые bcm_*-функции используют
# generic-имена циклов (node/ip/lb/web_node/…) БЕЗ `local` → при вызове из функции,
# где объявлен `local node`, они ПЕРЕЗАПИСЫВАЮТ наш `node` (db01 → s3-02 в логе).
# Префикс `o_` исключает коллизию.
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
    local o_lb_ip="$1" o_cmd="$2"
    bcm_ssh_exec "$o_lb_ip" \
        "echo '${o_cmd}' | socat - /run/haproxy-admin.sock 2>/dev/null \
         || echo '${o_cmd}' | nc -U /run/haproxy-admin.sock 2>/dev/null \
         || echo '${o_cmd}' | ncat -U /run/haproxy-admin.sock 2>/dev/null"
}

# Перевести server в backend'ах на всех LB в нужный state (maint|ready).
# _osu_hap_set_server <backend> <server> <state>
_osu_hap_set_server() {
    local o_backend="$1" o_server="$2" o_state="$3" o_lb o_lb_ip
    for o_lb in $(bcm_get_nodes "lb" 2>/dev/null); do
        o_lb_ip=$(bcm_get_node_ip "lb" "$o_lb") || continue
        bcm_node_reachable "$o_lb_ip" 4 2>/dev/null || continue
        _osu_hap_admin "$o_lb_ip" "set server ${o_backend}/${o_server} state ${o_state}" >/dev/null 2>&1
    done
}

# ──── Низкоуровневые проверки ────────────────────────────────────────────────
# wsrep-переменная на pxc-ноде (локальный root-сокет mysql).
_osu_wsrep() {
    bcm_ssh_exec "$1" "mysql -N -e \"SHOW STATUS LIKE '$2'\" 2>/dev/null | awk '{print \$2}'" 2>/dev/null | tr -d '[:space:]'
}

# Ждать, пока pxc-нода Synced и cluster_size >= expected.
_osu_pxc_wait_synced() {
    local o_ip="$1" o_expected="$2" o_timeout="${3:-$_OSU_PXC_SYNC_TIMEOUT}" o_waited=0 o_st o_sz
    while [[ $o_waited -lt $o_timeout ]]; do
        o_st=$(_osu_wsrep "$o_ip" "wsrep_local_state_comment")
        o_sz=$(_osu_wsrep "$o_ip" "wsrep_cluster_size")
        [[ "$o_st" == "Synced" && "${o_sz:-0}" =~ ^[0-9]+$ && "${o_sz:-0}" -ge "$o_expected" ]] && return 0
        sleep 5; o_waited=$((o_waited+5))
    done
    return 1
}

# Число pxc-нод, ожидаемых в кворуме (без тех, что в обслуживании).
_osu_pxc_active_count() {
    local o_pxc o_n o_cnt=0
    o_pxc=$(bcm_get_nodes "pxc" 2>/dev/null) || { echo 0; return; }
    for o_n in $o_pxc; do
        bcm_node_in_maintenance "$o_n" 2>/dev/null && continue
        o_cnt=$((o_cnt+1))
    done
    echo "$o_cnt"
}

# Все pxc Synced и cluster_size == числу активных (не-обслуживаемых) нод? (gate целостности)
_osu_pxc_cluster_full() {
    local o_pxc o_count o_n o_ip o_st o_sz
    o_pxc=$(bcm_get_nodes "pxc" 2>/dev/null) || return 1
    o_count=$(_osu_pxc_active_count)
    for o_n in $o_pxc; do
        o_ip=$(bcm_get_node_ip "pxc" "$o_n") || return 1
        bcm_node_in_maintenance "$o_n" 2>/dev/null && continue
        bcm_node_reachable "$o_ip" 4 2>/dev/null || return 1
        o_st=$(_osu_wsrep "$o_ip" "wsrep_local_state_comment")
        o_sz=$(_osu_wsrep "$o_ip" "wsrep_cluster_size")
        [[ "$o_st" == "Synced" && "${o_sz:-0}" -ge "$o_count" ]] || return 1
    done
    return 0
}

# Ждать возврата ноды по SSH после reboot (сначала дать ей УЙТИ вниз).
_osu_wait_ssh() {
    local o_ip="$1" o_timeout="${2:-$_OSU_SSH_BACK_TIMEOUT}" o_waited=0
    while bcm_node_reachable "$o_ip" 2 2>/dev/null && [[ $o_waited -lt 40 ]]; do sleep 3; o_waited=$((o_waited+3)); done
    o_waited=0
    while [[ $o_waited -lt $o_timeout ]]; do
        bcm_node_reachable "$o_ip" 3 2>/dev/null && return 0
        sleep 5; o_waited=$((o_waited+5))
    done
    return 1
}

# Нужна ли перезагрузка после обновления? (0 = нужна)
# ⚠️ needs-restarting (пакет dnf-utils) на минимальных образах ОТСУТСТВУЕТ (rc=127 на
# s3/pxc/lb — ловили вживую: из-за этого фолбэк всегда срабатывал и нода ребутилась зря).
# Поэтому: ставим dnf-utils тихо, затем needs-restarting -r (точно: ядро+glibc/systemd/…).
# Фолбэк UEK-aware — сравнить running-ядро с НАИБОЛЕЕ свежим установленным пакетом ядра
# ТОГО ЖЕ семейства (kernel-uek/kernel); прежний код сравнивал UEK с пакетом `kernel`
# (RHCK) → версии РАЗНЫЕ всегда → ложное «нужна перезагрузка».
_osu_needs_reboot() {
    local o_ip="$1" o_rc o_run o_latest
    o_rc=$(bcm_ssh_exec "$o_ip" \
        "command -v needs-restarting >/dev/null 2>&1 || dnf -y -q install dnf-utils >/dev/null 2>&1; \
         if command -v needs-restarting >/dev/null 2>&1; then needs-restarting -r >/dev/null 2>&1; echo \$?; else echo X; fi" \
        2>/dev/null | tr -d '[:space:]')
    [[ "$o_rc" == "1" ]] && return 0
    [[ "$o_rc" == "0" ]] && return 1
    # Фолбэк: running vs самый свежий установленный пакет ядра (любого семейства).
    o_run=$(bcm_ssh_exec "$o_ip" "uname -r" 2>/dev/null | tr -d '[:space:]')
    o_latest=$(bcm_ssh_exec "$o_ip" \
        "rpm -q kernel-uek kernel 2>/dev/null | grep -E '^kernel' | sed -E 's/^kernel(-uek)?-//' | sort -V | tail -1" \
        2>/dev/null | tr -d '[:space:]')
    [[ -n "$o_latest" && "$o_run" != "$o_latest" ]] && return 0
    return 1
}

# Перезагрузить ноду и дождаться возврата.
_osu_reboot_wait() {
    local o_ip="$1" o_name="$2"
    bcm_info "  ${o_name}: требуется перезагрузка — перезагружаю..."
    bcm_ssh_exec "$o_ip" "systemctl reboot >/dev/null 2>&1 &" >/dev/null 2>&1 || true
    if _osu_wait_ssh "$o_ip"; then
        bcm_ok "  ${o_name}: вернулась по SSH после перезагрузки."
        return 0
    fi
    bcm_error "  ${o_name}: НЕ вернулась по SSH за ${_OSU_SSH_BACK_TIMEOUT}с."
    return 1
}

# Выполнить dnf-обновление (стек на hold). Печатает краткий хвост, возвращает rc.
_osu_run_dnf() {
    local o_ip="$1" o_name="$2" o_out o_rc
    bcm_info "  ${o_name}: dnf update (Percona/ProxySQL на hold)..."
    o_out=$(bcm_ssh_exec_timeout "$o_ip" "$_OSU_DNF_TIMEOUT" \
        "dnf -y -q update ${_OSU_EXCLUDE_ARGS} 2>&1; echo RC=\$?" 2>&1)
    o_rc=$(echo "$o_out" | sed -n 's/^RC=//p' | tail -1)
    echo "$o_out" | grep -vE '^RC=' | tail -4 | sed 's/^/      /' || true   # pipefail: grep -v (rc1 если все строки RC=) убил бы под set -e
    [[ "${o_rc:-1}" == "0" ]] && return 0
    bcm_error "  ${o_name}: dnf update вернул rc=${o_rc:-?}."
    return 1
}

# ──── Смена writer (вес) на already-updated Synced ноду ──────────────────────
# _osu_pxc_switch_writer <new_writer_node>  (обновляет cluster.conf + ProxySQL на web)
_osu_pxc_switch_writer() {
    local o_new_writer="$1" o_new_ip o_web o_web_ip o_ok=0 o_fail=0
    o_new_ip=$(bcm_get_node_ip "pxc" "$o_new_writer") || return 1
    local o_ap o_au o_aps
    o_ap=$(bcm_get_proxysql_admin_port 2>/dev/null || echo "6032")
    o_au=$(bcm_get_proxysql_admin_user 2>/dev/null || echo "admin")
    o_aps=$(bcm_get_proxysql_admin_pass 2>/dev/null || echo "admin")
    local o_aps_q="'${o_aps//\'/\'\\\'\'}'"
    for o_web in $(bcm_get_nodes "web" 2>/dev/null); do
        o_web_ip=$(bcm_get_node_ip "web" "$o_web") || continue
        bcm_node_reachable "$o_web_ip" 4 2>/dev/null || { o_fail=$((o_fail+1)); continue; }
        # ⚠️ Пароль ProxySQL-admin инлайнится как -p${o_aps_q} ПРЯМО в команду (как в
        # bcm_cluster_mode.sh). Через промежуточную переменную ($M="...-p'pass'"; $M -e)
        # НЕЛЬЗЯ: при ре-экспансии $M кавычки остаются ЛИТЕРАЛЬНЫМИ → пароль = 'pass' →
        # ProxySQL Access denied (ловили вживую на rolling-тесте db01).
        local o_r
        o_r=$(bcm_ssh_exec "$o_web_ip" \
            "mysql --default-auth=mysql_native_password -h127.0.0.1 -P${o_ap} -u${o_au} -p${o_aps_q} -e \"UPDATE mysql_servers SET weight=100; UPDATE mysql_servers SET weight=1000 WHERE hostname='${o_new_ip}'; LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;\" >/dev/null 2>&1 && echo OK || echo FAIL")
        [[ "$o_r" == *OK* ]] && o_ok=$((o_ok+1)) || o_fail=$((o_fail+1))
    done
    [[ $o_ok -gt 0 && $o_fail -eq 0 ]] || return 1
    bcm_conf_set "layer.pxc" "writer" "$o_new_writer" 2>/dev/null || true
    bcm_conf_sync 2>/dev/null || true
    return 0
}

# ──── Обновление одной ноды (диспетчер по слою) ──────────────────────────────
# _osu_update_node <layer> <node> <ip> <self_node>
# Возвращает 0 при успехе+пройденном health-гейте, иначе ненулевой код.
_osu_update_node() {
    local o_layer="$1" o_node="$2" o_ip="$3" o_self="$4"
    bcm_section_header "Обновление ОС: ${o_node} (${o_ip}) [${o_layer}]"

    if bcm_node_in_maintenance "$o_node" 2>/dev/null; then
        bcm_warn "  ${o_node}: в режиме обслуживания — пропуск."
        return 0
    fi
    if ! bcm_node_reachable "$o_ip" 5 2>/dev/null; then
        bcm_error "  ${o_node}: недоступна по SSH — пропуск (обновите позже)."
        return 1
    fi

    local o_is_self=0
    [[ "$o_node" == "$o_self" ]] && o_is_self=1

    # ── Дренаж + предусловия по слою ──
    case "$o_layer" in
        s3)
            _osu_hap_set_server "s3_backend" "$o_node" "maint"
            ;;
        web)
            _osu_hap_set_server "web_backend" "$o_node" "maint"
            _osu_hap_set_server "web_admin_backend" "$o_node" "maint"
            sleep 3   # дать соединениям стечь
            ;;
        lb)
            # Снять VIP с этой ноды (если держит) — keepalived stop → VIP к пиру.
            bcm_ssh_exec "$o_ip" "systemctl stop keepalived >/dev/null 2>&1" >/dev/null 2>&1 || true
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
    if ! _osu_run_dnf "$o_ip" "$o_node"; then
        # вернуть из дренажа на всякий случай
        [[ "$o_layer" == "web" ]] && { _osu_hap_set_server web_backend "$o_node" ready; _osu_hap_set_server web_admin_backend "$o_node" ready; }
        [[ "$o_layer" == "s3" ]] && _osu_hap_set_server s3_backend "$o_node" ready
        [[ "$o_layer" == "lb" ]] && bcm_ssh_exec "$o_ip" "systemctl start keepalived >/dev/null 2>&1" >/dev/null 2>&1
        return 1
    fi

    # ── Перезагрузка при необходимости ──
    local o_need_reboot=1
    _osu_needs_reboot "$o_ip" && o_need_reboot=0   # 0 = нужна

    if [[ $o_need_reboot -eq 0 && $o_is_self -eq 1 ]]; then
        bcm_warn "  ${o_node}: это нода, где запущен BCM — АВТО-перезагрузку НЕ делаю."
        bcm_warn "  Пакеты обновлены; перезагрузите ${o_node} вручную в окно обслуживания."
        # снять дренаж, не перезагружая
        [[ "$o_layer" == "web" ]] && { _osu_hap_set_server web_backend "$o_node" ready; _osu_hap_set_server web_admin_backend "$o_node" ready; }
        return 0
    fi

    if [[ $o_need_reboot -eq 0 ]]; then
        # PXC: если ребутим writer — сперва увести writer на другую Synced-ноду.
        if [[ "$o_layer" == "pxc" ]]; then
            local o_rw; o_rw=$(bcm_get_pxc_runtime_writer 2>/dev/null || bcm_get_pxc_writer 2>/dev/null)
            if [[ "$o_rw" == "$o_node" ]]; then
                local o_alt o_alt_found="" o_alt_ip
                for o_alt in $(bcm_get_nodes "pxc" 2>/dev/null); do
                    [[ "$o_alt" == "$o_node" ]] && continue
                    o_alt_ip=$(bcm_get_node_ip "pxc" "$o_alt") || continue
                    if _osu_pxc_wait_synced "$o_alt_ip" 1 10; then o_alt_found="$o_alt"; break; fi
                done
                if [[ -n "$o_alt_found" ]] && _osu_pxc_switch_writer "$o_alt_found"; then
                    bcm_ok "  writer уведён с ${o_node} → ${o_alt_found} перед перезагрузкой."
                else
                    bcm_error "  ${o_node} — текущий writer, не удалось увести writer — перезагрузку отменяю (смените writer вручную, меню 03)."
                    return 1
                fi
            fi
        fi
        _osu_reboot_wait "$o_ip" "$o_node" || return 1
    else
        bcm_info "  ${o_node}: перезагрузка не требуется."
        # Применить обновлённые библиотеки рестартом служб слоя (нода дренирована).
        case "$o_layer" in
            web) bcm_ssh_exec "$o_ip" "systemctl restart nginx httpd >/dev/null 2>&1" >/dev/null 2>&1 || true ;;
            lb)  bcm_ssh_exec "$o_ip" "systemctl restart haproxy >/dev/null 2>&1" >/dev/null 2>&1 || true ;;
            # pxc: Percona на hold → mysqld не трогаем; s3: minio-бинарь не из dnf.
        esac
    fi

    # ── Возврат в работу + health-гейт ──
    local o_waited=0
    case "$o_layer" in
        s3)
            bcm_ssh_exec_timeout "$o_ip" 30 "systemctl is-active minio >/dev/null 2>&1 || systemctl start minio" >/dev/null 2>&1 || true
            o_waited=0
            while [[ $o_waited -lt $_OSU_SVC_TIMEOUT ]]; do
                [[ "$(bcm_check_s3_health "$o_ip" 2>/dev/null)" == "ok" ]] && break
                sleep 5; o_waited=$((o_waited+5))
            done
            _osu_hap_set_server "s3_backend" "$o_node" "ready"
            [[ "$(bcm_check_s3_health "$o_ip" 2>/dev/null)" == "ok" ]] || { bcm_error "  ${o_node}: MinIO health не прошёл."; return 1; }
            bcm_ok "  ${o_node}: MinIO здоров, возвращён в s3_backend."
            ;;
        pxc)
            if ! _osu_pxc_wait_synced "$o_ip" "$(_osu_pxc_active_count)"; then
                bcm_error "  ${o_node}: не вернулась в Synced/полный кворум за ${_OSU_PXC_SYNC_TIMEOUT}с — СТОП."
                return 1
            fi
            bcm_ok "  ${o_node}: Synced, кворум полный."
            ;;
        web)
            o_waited=0
            while [[ $o_waited -lt $_OSU_SVC_TIMEOUT ]]; do
                bcm_ssh_exec "$o_ip" "systemctl is-active httpd nginx proxysql >/dev/null 2>&1" >/dev/null 2>&1 && break
                sleep 5; o_waited=$((o_waited+5))
            done
            _osu_hap_set_server "web_backend" "$o_node" "ready"
            _osu_hap_set_server "web_admin_backend" "$o_node" "ready"
            if ! bcm_ssh_exec "$o_ip" "systemctl is-active httpd nginx proxysql >/dev/null 2>&1" >/dev/null 2>&1; then
                bcm_error "  ${o_node}: httpd/nginx/proxysql не все active — СТОП."
                return 1
            fi
            bcm_ok "  ${o_node}: web-службы active, возвращён в балансировку."
            ;;
        lb)
            bcm_ssh_exec_timeout "$o_ip" 30 "systemctl start haproxy keepalived >/dev/null 2>&1" >/dev/null 2>&1 || true
            sleep 3
            if ! bcm_ssh_exec "$o_ip" "systemctl is-active haproxy keepalived >/dev/null 2>&1" >/dev/null 2>&1; then
                bcm_error "  ${o_node}: haproxy/keepalived не active — СТОП."
                return 1
            fi
            bcm_ok "  ${o_node}: haproxy/keepalived active."
            ;;
    esac
    return 0
}

# ──── Упорядочивание нод внутри слоя ─────────────────────────────────────────
# pxc: не-writer первыми, writer последним.  echo "node1 node2 ..."
_osu_order_pxc() {
    local o_nodes o_writer o_rest="" o_n
    o_nodes=$(bcm_get_nodes "pxc" 2>/dev/null)
    o_writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || bcm_get_pxc_writer 2>/dev/null)
    for o_n in $o_nodes; do [[ "$o_n" != "$o_writer" ]] && o_rest+="$o_n "; done
    echo "$o_rest${o_writer:+$o_writer}"
}
# lb: не-VIP-холдер первыми, VIP-холдер последним.
_osu_order_lb() {
    local o_nodes o_holder o_rest="" o_vip o_n
    o_nodes=$(bcm_get_nodes "lb" 2>/dev/null)
    o_vip=$(bcm_get_vip 2>/dev/null)
    o_holder=$(bcm_get_vip_holder "$o_vip" 2>/dev/null)
    for o_n in $o_nodes; do [[ "$o_n" != "$o_holder" ]] && o_rest+="$o_n "; done
    echo "$o_rest${o_holder:+$o_holder}"
}
# web: brain-нода (где запущен BCM) последней.
_osu_order_web() {
    local o_nodes o_self="$1" o_rest="" o_n
    o_nodes=$(bcm_get_nodes "web" 2>/dev/null)
    for o_n in $o_nodes; do [[ "$o_n" != "$o_self" ]] && o_rest+="$o_n "; done
    echo "$o_rest${o_self:+$o_self}"
}

# ──── Главная процедура: rolling по всему кластеру ───────────────────────────
bcm_osupdate_rolling() {
    bcm_section_header "HA-rolling обновление ОС по кластеру"
    local o_self
    o_self=$(bcm_get_current_node_name 2>/dev/null || hostname -s)

    echo
    bcm_info "Порядок: s3 → pxc (writer последним) → web (brain последней) → lb (VIP-холдер последним)."
    bcm_info "Кластерный стек на hold: percona-*, proxysql* (НЕ обновляются)."
    bcm_info "Перезагрузка — авто (кроме brain-ноды ${o_self}: только пакеты)."
    bcm_warn "Процесс идёт ПО ОДНОЙ ноде с health-гейтами; при сбое гейта — ОСТАНОВКА."
    echo
    if ! bcm_confirm "Запустить HA-rolling обновление ОС всего кластера?"; then
        bcm_info "Отменено."; bcm_any_key; return
    fi

    local o_layer o_order o_node o_ip o_done=0 o_fail=0
    for o_layer in s3 pxc web lb; do
        case "$o_layer" in
            pxc) o_order=$(_osu_order_pxc) ;;
            lb)  o_order=$(_osu_order_lb) ;;
            web) o_order=$(_osu_order_web "$o_self") ;;
            *)   o_order=$(bcm_get_nodes "$o_layer" 2>/dev/null) ;;
        esac
        [[ -z "${o_order// }" ]] && continue

        bcm_color "CYAN_BOLD" "  ── Слой ${o_layer}: ${o_order} ──"
        for o_node in $o_order; do
            [[ -z "$o_node" ]] && continue
            o_ip=$(bcm_get_node_ip "$o_layer" "$o_node") || { bcm_warn "  ${o_node}: нет IP — пропуск."; continue; }
            if _osu_update_node "$o_layer" "$o_node" "$o_ip" "$o_self"; then
                o_done=$((o_done+1))
            else
                o_fail=$((o_fail+1))
                bcm_error "Обновление остановлено на ноде ${o_node} (слой ${o_layer})."
                bcm_warn "Оставшиеся ноды НЕ тронуты. Разберите причину и перезапустите процедуру."
                bcm_any_key
                return
            fi
        done
        # Доп. гейт целостности PXC после слоя pxc.
        if [[ "$o_layer" == "pxc" ]] && ! _osu_pxc_cluster_full; then
            bcm_error "После слоя pxc кластер не в полном Synced — СТОП."
            bcm_any_key; return
        fi
    done

    echo
    bcm_ok "HA-rolling обновление завершено: обновлено нод=${o_done}, сбоев=${o_fail}."
    bcm_warn "Напоминание: Percona/ProxySQL остались на прежних версиях (hold). Их обновление — отдельной процедурой по одной ноде."
    bcm_any_key
}
