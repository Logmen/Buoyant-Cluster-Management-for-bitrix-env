#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181,SC2206
# =============================================================================
# bcm_confedit.sh — редактирование конфигов кластера через $EDITOR (на мозг-ноде).
#
# Общий цикл: скачать эталон с доступной ноды слоя → открыть в $EDITOR →
# валидация нативным тулом → бэкап + push на ВСЕ ноды слоя → применить.
#
#   bcm_confedit_haproxy  — /etc/haproxy/haproxy.cfg (LB, файл одинаков на всех LB).
#                           Валидация `haproxy -c`, rolling reload (VIP-холдер последним).
#                           ⚠ файл генерируется install.sh — правки теряются при его повторе.
#   bcm_confedit_mysql    — /etc/my.cnf.d/zz-bcm-custom.cnf (PXC, ОБЩИЙ drop-in).
#                           Базовый /etc/my.cnf (server-id, wsrep_node_* — идентичность
#                           ноды) НЕ трогается; drop-in переопределяет тюнинг и одинаков
#                           на всех PXC. Валидация `mysqld --validate-config` на combined
#                           конфиге; применение — rolling restart (readers→writer, ждём Synced).
#
# Требует загруженной топологии (BCM_NODES_LB/PXC, BCM_NODE_IP) и bcm_utils/ssh.
# Запускается ТОЛЬКО на web-ноде (мозг) — там есть $EDITOR и SSH-ключ ко всем нодам.
# =============================================================================

MYSQL_DROPIN="/etc/my.cnf.d/zz-bcm-custom.cnf"

# ──── Открыть файл в $EDITOR (на терминале пользователя) ─────────────────────
# Возвращает 0, если содержимое изменилось.
_ce_open_editor() {
    local file="$1"
    local before after ed
    # ⚠️ pipefail: sha256sum (rc≠0 если файла нет) просочился бы через | cut (rc0) →
    # присваивание rc≠0 → set -e. || true нейтрализует (пустой хэш — валидный кейс).
    before=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1 || true)
    ed="${EDITOR:-${VISUAL:-}}"
    [[ -z "$ed" ]] && { command -v nano >/dev/null 2>&1 && ed="nano" || ed="vi"; }
    # </dev/tty: редактору нужен терминал даже если stdin меню перенаправлен.
    "$ed" "$file" </dev/tty >/dev/tty 2>&1 || true
    after=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1 || true)
    [[ "$before" != "$after" ]]
}

# ──── Список доступных нод слоя: "node ip" построчно ─────────────────────────
# _ce_reachable_nodes <BCM_NODES_LB|BCM_NODES_PXC array name>
_ce_reachable_nodes() {
    local -n _arr=$1
    local node ip
    for node in "${_arr[@]}"; do
        [[ -z "$node" ]] && continue
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_node_reachable "$ip" 5 2>/dev/null && echo "${node} ${ip}"
    done
}

# ──── LB по порядку: держатель VIP — ПОСЛЕДНИМ (бесшовный reload) ─────────────
_ce_lb_ordered() {
    local vip holder="" node ip
    vip=$(bcm_get_vip 2>/dev/null || echo "")
    for node in "${BCM_NODES_LB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        bcm_node_reachable "$ip" 5 2>/dev/null || continue
        if [[ -n "$vip" ]] && bcm_ssh_exec_timeout "$ip" 8 "ip -4 addr | grep -q 'inet ${vip}/'" 2>/dev/null; then
            holder="${node} ${ip}"
        else
            echo "${node} ${ip}"
        fi
    done
    [[ -n "$holder" ]] && echo "$holder"
}

# =============================================================================
# HAProxy
# =============================================================================
bcm_confedit_haproxy() {
    bcm_section_header "Редактирование haproxy.cfg (все LB)"

    if [[ ${#BCM_NODES_LB[@]} -eq 0 ]]; then
        bcm_error "LB-узлы не заданы в cluster.conf."; bcm_any_key; return
    fi
    local ref ref_node ref_ip
    # ⚠️ `|| true`: head -1 закрывает пайп после первой строки → _ce_reachable_nodes
    # (медленный из-за SSH-проверок) ловит SIGPIPE на следующем echo, при `set -o
    # pipefail` пайп возвращает 141, и `set -e` УБИВАЕТ весь TUI (ловили вживую на
    # lb01: меню вываливалось в shell, rc=141). Также гасит случай, когда последняя
    # нода в _ce_reachable_nodes недоступна (функция вернёт ненулевой код).
    ref=$(_ce_reachable_nodes BCM_NODES_LB | head -1) || true
    [[ -z "$ref" ]] && { bcm_error "Нет доступных LB-нод."; bcm_any_key; return; }
    read -r ref_node ref_ip <<< "$ref"

    bcm_warn "⚠ haproxy.cfg генерируется install.sh — ручные правки ТЕРЯЮТСЯ при повторном install.sh."
    bcm_info "Эталон берётся с ${ref_node}; после сохранения раскатывается на ВСЕ LB (reload по очереди, VIP-холдер последним)."
    bcm_confirm "Открыть редактор (\${EDITOR:-vi})?" || { bcm_any_key; return; }

    local tmp; tmp=$(mktemp /tmp/bcm-haproxy.XXXXXX)
    if ! bcm_ssh_fetch_file "$ref_ip" "/etc/haproxy/haproxy.cfg" "$tmp"; then
        bcm_error "Не удалось скачать haproxy.cfg с ${ref_node}."; rm -f "$tmp"; bcm_any_key; return
    fi

    if ! _ce_open_editor "$tmp"; then
        bcm_info "Изменений нет — ничего не применяю."; rm -f "$tmp"; bcm_any_key; return
    fi

    # Валидация на эталонной LB (там есть бинарь haproxy)
    bcm_info "Проверка конфига (haproxy -c) на ${ref_node}..."
    bcm_ssh_copy_file "$tmp" "$ref_ip" "/tmp/bcm-haproxy-validate.cfg"
    local vout
    vout=$(bcm_ssh_exec_timeout "$ref_ip" 15 \
        "haproxy -c -f /tmp/bcm-haproxy-validate.cfg 2>&1; rm -f /tmp/bcm-haproxy-validate.cfg" 2>/dev/null)
    if ! echo "$vout" | grep -qi "valid"; then
        bcm_error "Конфиг НЕ валиден — изменения НЕ применены:"
        echo "$vout" | sed 's/^/    /' | tail -15
        rm -f "$tmp"; bcm_any_key; return
    fi
    bcm_ok "haproxy -c: конфиг валиден."
    echo
    bcm_confirm "Раскатать на все LB и перечитать?" || { bcm_info "Отменено."; rm -f "$tmp"; bcm_any_key; return; }

    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local ok=1 n i
    # ⚠️ Список LB читаем в массив ДО цикла (mapfile), НЕ итерируем «живой»
    # process substitution: ssh в теле (без -n) съедает остаток stdin (строки
    # следующих LB) → цикл обрывается после первой ноды (ловили вживую на 12→5:
    # force_https применялся только к одному LB). Добавить -n/`</dev/null` в
    # bcm_ssh_* нельзя — они используются как приёмник stdin (echo … | bcm_ssh_*).
    local -a _lb_lines=(); mapfile -t _lb_lines < <(_ce_lb_ordered)
    local _l
    for _l in "${_lb_lines[@]}"; do
        read -r n i <<< "$_l"
        [[ -z "$i" ]] && continue
        if bcm_ssh_copy_file "$tmp" "$i" "/tmp/bcm-haproxy-new.cfg" && \
           bcm_ssh_exec_timeout "$i" 20 "
                cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bcm-bak-${ts}
                cp /tmp/bcm-haproxy-new.cfg /etc/haproxy/haproxy.cfg
                if haproxy -c -f /etc/haproxy/haproxy.cfg -q && systemctl reload haproxy; then
                    rm -f /tmp/bcm-haproxy-new.cfg
                else
                    cp /etc/haproxy/haproxy.cfg.bcm-bak-${ts} /etc/haproxy/haproxy.cfg
                    systemctl reload haproxy 2>/dev/null
                    exit 1
                fi" 2>/dev/null; then
            bcm_ok "  ${n}: применён, reload (бэкап: haproxy.cfg.bcm-bak-${ts})."
        else
            bcm_error "  ${n}: ошибка — выполнен откат на бэкап."
            ok=0
        fi
    done
    rm -f "$tmp"
    [[ $ok -eq 1 ]] && bcm_ok "haproxy.cfg обновлён на всех LB." || bcm_warn "Применено с ошибками (см. выше)."
    bcm_any_key
}

# =============================================================================
# MySQL / PXC (общий drop-in)
# =============================================================================

# Ждать Synced на ноде (для rolling restart)
_ce_wait_synced() {
    local ip="$1" timeout="${2:-180}" t=0 st
    while [[ $t -lt $timeout ]]; do
        st=$(bcm_ssh_exec_timeout "$ip" 8 \
            "mysql -N -e \"SHOW STATUS LIKE 'wsrep_local_state_comment'\" 2>/dev/null | awk '{print \$2}'" 2>/dev/null | tr -d '[:space:]')
        [[ "$st" == "Synced" ]] && return 0
        sleep 5; ((t+=5))
    done
    return 1
}

# Rolling restart PXC: readers по очереди (ждём Synced), writer — последним.
_ce_mysql_rolling_restart() {
    local writer
    writer=$(bcm_get_pxc_runtime_writer 2>/dev/null || echo "")
    [[ -z "$writer" ]] && writer=$(bcm_get_pxc_writer 2>/dev/null || echo "")

    # Порядок: сначала readers (по возрастанию IP), writer последним.
    local -a order=() node
    for node in $(for n in "${BCM_NODES_PXC[@]}"; do [[ "$n" != "$writer" ]] && echo "${BCM_NODE_IP[$n]} $n"; done | sort | awk '{print $2}'); do
        order+=("$node")
    done
    [[ -n "$writer" ]] && order+=("$writer")

    bcm_info "Порядок рестарта: ${order[*]} (writer '${writer}' последним)."
    local node ip
    for node in "${order[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        bcm_info "  ${node}: restart mysql..."
        if ! bcm_ssh_exec_timeout "$ip" 120 "systemctl restart mysql" 2>/dev/null; then
            bcm_error "  ${node}: рестарт не удался — ОСТАНАВЛИВАЮ rolling (остальные не трогаю)."
            return 1
        fi
        if _ce_wait_synced "$ip" 300; then
            bcm_ok "  ${node}: Synced."
        else
            bcm_error "  ${node}: НЕ достиг Synced за 5 мин — ОСТАНАВЛИВАЮ rolling."
            return 1
        fi
    done
    bcm_ok "Rolling restart завершён — все PXC-ноды Synced."
}

bcm_confedit_mysql() {
    bcm_section_header "Редактирование общих настроек MySQL (drop-in, все PXC)"

    if [[ ${#BCM_NODES_PXC[@]} -eq 0 ]]; then
        bcm_error "PXC-узлы не заданы в cluster.conf."; bcm_any_key; return
    fi
    local ref ref_node ref_ip
    # ⚠️ `|| true`: см. bcm_confedit_haproxy — head -1 + SIGPIPE + pipefail + set -e
    # иначе валит TUI (rc=141); плюс защита от ненулевого кода _ce_reachable_nodes.
    ref=$(_ce_reachable_nodes BCM_NODES_PXC | head -1) || true
    [[ -z "$ref" ]] && { bcm_error "Нет доступных PXC-нод."; bcm_any_key; return; }
    read -r ref_node ref_ip <<< "$ref"

    bcm_info "Правки кладутся в ${MYSQL_DROPIN} (одинаков на всех PXC), переопределяют базовый my.cnf."
    bcm_info "Базовый /etc/my.cnf (server-id, wsrep_node_* — идентичность ноды) НЕ трогается."
    bcm_warn "⚠ НЕ помещайте сюда node-specific параметры (server-id, wsrep_node_name/address)."
    bcm_warn "Большинство правок требуют РЕСТАРТА mysql (предложу rolling в конце)."
    bcm_confirm "Открыть редактор (\${EDITOR:-vi})?" || { bcm_any_key; return; }

    local tmp; tmp=$(mktemp /tmp/bcm-mysql-dropin.XXXXXX)
    # Существующий drop-in или шаблон-заготовка
    if ! bcm_ssh_fetch_file "$ref_ip" "$MYSQL_DROPIN" "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
        cat > "$tmp" <<'SEED'
# /etc/my.cnf.d/zz-bcm-custom.cnf
# Общие переопределения MySQL/PXC (BCM). ОДИНАКОВ на всех PXC-нодах, читается ПОСЛЕ
# базового /etc/my.cnf (last-wins). НЕ класть сюда node-specific (server-id,
# wsrep_node_name/address) — они в /etc/my.cnf на каждой ноде.
[mysqld]
# Пример (раскомментируйте/правьте):
# innodb_buffer_pool_size = 2G
# max_connections         = 800
SEED
    fi

    if ! _ce_open_editor "$tmp"; then
        bcm_info "Изменений нет — ничего не применяю."; rm -f "$tmp"; bcm_any_key; return
    fi

    # Валидация drop-in в ИЗОЛЯЦИИ (mysqld --validate-config на самом drop-in).
    # ⚠️ combined (my.cnf+drop-in) НЕЛЬЗЯ: базовый my.cnf несёт wsrep_provider →
    # mysqld в validate-режиме грузит Galera и абортит на SSL независимо от drop-in
    # (RC недостоверен — ловили вживую). Drop-in без wsrep_provider проверяется честно:
    # имена/значения/диапазоны параметров. Ограничение: взаимодействие с base не
    # проверяется (но опечатки/неизвестные ключи/битые значения — да).
    bcm_info "Проверка (mysqld --validate-config) на ${ref_node}..."
    bcm_ssh_copy_file "$tmp" "$ref_ip" "/tmp/bcm-mysql-dropin.new"
    local vout
    vout=$(bcm_ssh_exec_timeout "$ref_ip" 20 "
        mysqld --defaults-file=/tmp/bcm-mysql-dropin.new --validate-config 2>&1; echo RC=\$?
        rm -f /tmp/bcm-mysql-dropin.new" 2>/dev/null)
    if ! echo "$vout" | grep -q "^RC=0$"; then
        bcm_error "Конфиг НЕ валиден — изменения НЕ применены:"
        echo "$vout" | grep -iE 'error|unknown|invalid|suffix' | sed 's/^/    /' | tail -15 || true
        rm -f "$tmp"; bcm_any_key; return
    fi
    bcm_ok "mysqld --validate-config: ок."
    echo
    bcm_confirm "Раскатать drop-in на все PXC-ноды?" || { bcm_info "Отменено."; rm -f "$tmp"; bcm_any_key; return; }

    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local ok=1 node ip
    for node in "${BCM_NODES_PXC[@]}"; do
        [[ -z "$node" ]] && continue
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "  ${node}: недоступен — пропуск (раскатайте позже)."; ok=0; continue
        fi
        # 1) гарантировать !includedir в базовом my.cnf (идемпотентно)
        # 2) бэкап старого drop-in, положить новый
        if bcm_ssh_copy_file "$tmp" "$ip" "/tmp/bcm-mysql-dropin.push" && \
           bcm_ssh_exec_timeout "$ip" 15 "
                mkdir -p /etc/my.cnf.d
                grep -qE '^[[:space:]]*!includedir[[:space:]]+/etc/my.cnf.d' /etc/my.cnf || echo '!includedir /etc/my.cnf.d' >> /etc/my.cnf
                [ -f '${MYSQL_DROPIN}' ] && cp '${MYSQL_DROPIN}' '${MYSQL_DROPIN}.bcm-bak-${ts}'
                cp /tmp/bcm-mysql-dropin.push '${MYSQL_DROPIN}' && chmod 644 '${MYSQL_DROPIN}'
                rm -f /tmp/bcm-mysql-dropin.push" 2>/dev/null; then
            bcm_ok "  ${node}: drop-in обновлён (includedir подключён)."
        else
            bcm_error "  ${node}: ошибка записи drop-in."; ok=0
        fi
    done
    rm -f "$tmp"

    if [[ $ok -ne 1 ]]; then
        bcm_warn "Раскатано с ошибками — rolling restart НЕ предлагаю (сначала устраните)."
        bcm_any_key; return
    fi

    echo
    bcm_ok "drop-in раскатан на все PXC."
    bcm_warn "Изменения вступят в силу при РЕСТАРТЕ mysql. Динамические параметры можно применить и через SET GLOBAL вручную."
    if bcm_confirm "Сделать rolling restart СЕЙЧАС (readers→writer, ждём Synced между нодами)?"; then
        _ce_mysql_rolling_restart
    else
        bcm_info "Рестарт отложен. Конфиг применится при следующем рестарте mysql на каждой ноде."
    fi
    bcm_any_key
}
