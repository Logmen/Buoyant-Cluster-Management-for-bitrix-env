#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181,SC2206
# =============================================================================
# bcm_confedit.sh — редактирование конфигов кластера через $EDITOR (на мозг-ноде).
#
# Общий цикл: скачать эталон с доступной ноды слоя → открыть в $EDITOR →
# валидация нативным тулом → бэкап + push на ВСЕ ноды слоя → применить.
#
#   bcm_confedit_haproxy  — /etc/haproxy/conf.d/90-custom.cfg (LB, ОБЩИЙ слой).
#                           Базовый /etc/haproxy/haproxy.cfg НЕ трогается: он
#                           генерируется install.sh из шаблона, и правки в нём
#                           терялись бы при следующем прогоне. Валидация —
#                           связкой (базовый + весь conf.d), rolling reload
#                           (VIP-холдер последним, откат на бэкап при ошибке).
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
HAPROXY_CUSTOM="/etc/haproxy/conf.d/90-custom.cfg"
# ⚠️ Проверять конфиг нужно ТАК ЖЕ, как его читает юнит: `-f базовый -f каталог`.
# Проверка одного базового файла даёт ложную ошибку, как только он ссылается на
# бэкенд из conf.d (`unable to find required use_backend`) — ловили вживую, из-за
# этого редактор и раскатка сертификата откатывались на исправном конфиге.
HAPROXY_CHECK="haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/"

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
    bcm_section_header "Свои настройки HAProxy (все LB)"

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

    bcm_info "Редактируется ${HAPROXY_CUSTOM} — ваш слой, BCM его не перезаписывает."
    bcm_info "Базовый haproxy.cfg собирается из шаблона и остаётся нетронутым."
    bcm_warn "⚠ Слой ДОПОЛНЯЮЩИЙ: заводите НОВЫЕ frontend/backend. Переоткрыть существующую"
    bcm_warn "  секцию (напр. backend web_backend) нельзя — HAProxy отвергнет как duplicate."
    bcm_info "Эталон берётся с ${ref_node}; после сохранения раскатывается на ВСЕ LB (reload по очереди, VIP-холдер последним)."
    bcm_confirm "Открыть редактор (\${EDITOR:-vi})?" || { bcm_any_key; return; }

    local tmp; tmp=$(mktemp /tmp/bcm-haproxy.XXXXXX)
    # Файла может не быть (кластер поставлен до появления слоя) — тогда начинаем
    # с шаблона-заготовки, чтобы оператор видел контракт и пример.
    if ! bcm_ssh_fetch_file "$ref_ip" "$HAPROXY_CUSTOM" "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
        if [[ -f "${BCM_BASE_DIR}/templates/haproxy-custom.cfg.tmpl" ]]; then
            cp "${BCM_BASE_DIR}/templates/haproxy-custom.cfg.tmpl" "$tmp"
            bcm_info "Слой ещё не создан — открываю заготовку."
        else
            : > "$tmp"
        fi
    fi

    if ! _ce_open_editor "$tmp"; then
        bcm_info "Изменений нет — ничего не применяю."; rm -f "$tmp"; bcm_any_key; return
    fi

    # Валидация на эталонной LB (там есть бинарь haproxy).
    # ⚠️ Проверяем СВЯЗКУ, а не один файл: собираем во временном каталоге копию
    # conf.d с подставленным кандидатом и скармливаем её вместе с базовым
    # конфигом. Живой conf.d при этом не трогаем — если конфиг окажется битым,
    # на ноде ничего не изменится.
    bcm_info "Проверка конфига (haproxy -c, базовый + conf.d) на ${ref_node}..."
    bcm_ssh_copy_file "$tmp" "$ref_ip" "/tmp/bcm-haproxy-candidate.cfg"
    local vout
    vout=$(bcm_ssh_exec_timeout "$ref_ip" 20 "
        d=\$(mktemp -d /tmp/bcm-hacheck.XXXXXX)
        cp /etc/haproxy/conf.d/*.cfg \"\$d\"/ 2>/dev/null
        cp /tmp/bcm-haproxy-candidate.cfg \"\$d\"/90-custom.cfg
        haproxy -c -f /etc/haproxy/haproxy.cfg -f \"\$d\" 2>&1
        rm -rf \"\$d\" /tmp/bcm-haproxy-candidate.cfg" 2>/dev/null)
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
                mkdir -p /etc/haproxy/conf.d /etc/haproxy/backups
                [ -f ${HAPROXY_CUSTOM} ] && cp ${HAPROXY_CUSTOM} /etc/haproxy/backups/90-custom.cfg.bcm-bak-${ts}
                cp /tmp/bcm-haproxy-new.cfg ${HAPROXY_CUSTOM}
                if ${HAPROXY_CHECK} -q && systemctl reload haproxy; then
                    rm -f /tmp/bcm-haproxy-new.cfg
                else
                    if [ -f /etc/haproxy/backups/90-custom.cfg.bcm-bak-${ts} ]; then
                        cp /etc/haproxy/backups/90-custom.cfg.bcm-bak-${ts} ${HAPROXY_CUSTOM}
                    else
                        rm -f ${HAPROXY_CUSTOM}
                    fi
                    systemctl reload haproxy 2>/dev/null
                    exit 1
                fi" 2>/dev/null; then
            bcm_ok "  ${n}: применён, reload (бэкап: backups/90-custom.cfg.bcm-bak-${ts})."
        else
            bcm_error "  ${n}: ошибка — выполнен откат на бэкап."
            ok=0
        fi
    done
    rm -f "$tmp"
    [[ $ok -eq 1 ]] && bcm_ok "Слой настроек обновлён на всех LB." || bcm_warn "Применено с ошибками (см. выше)."
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

# =============================================================================
# Redis (слой поверх базового конфига инстанса)
# =============================================================================
# Базовые /etc/redis/redis-{session,push,cache}.conf генерируются install.sh и
# ПОДКЛЮЧАЮТ этот слой последней строкой. В redis побеждает последнее вхождение
# параметра, поэтому слой реально ПЕРЕОПРЕДЕЛЯЕТ базовые значения.
#
# ⚠️ Применение — рестарт инстанса, а он держит роль master/replica по VRRP.
# Поэтому идём ПО ОДНОЙ ноде и начинаем с реплик: рестарт мастера уронил бы
# запись на время старта. Роль определяем опросом самого redis.
bcm_confedit_redis() {
    bcm_section_header "Свои настройки Redis (все web-ноды)"

    if [[ ${#BCM_NODES_WEB[@]} -eq 0 ]]; then
        bcm_error "Web-узлы не заданы в cluster.conf."; bcm_any_key; return
    fi

    echo "  Инстанс:"
    echo "    1. сессии (6380)"
    echo "    2. push (6381)"
    echo "    3. кэш (6382)"
    echo "    0. Назад"
    local ch; read -r -p "  Выбор: " ch
    local inst port
    case "$ch" in
        1) inst="session"; port=6380 ;;
        2) inst="push";    port=6381 ;;
        3) inst="cache";   port=6382 ;;
        0|"") bcm_info "Отменено."; bcm_any_key; return ;;
        *) bcm_error "Неверный выбор."; bcm_any_key; return ;;
    esac

    local custom="/etc/redis/redis-${inst}-custom.conf"
    local ref ref_node ref_ip
    ref=$(_ce_reachable_nodes BCM_NODES_WEB | head -1) || true
    [[ -z "$ref" ]] && { bcm_error "Нет доступных web-нод."; bcm_any_key; return; }
    read -r ref_node ref_ip <<< "$ref"

    bcm_info "Редактируется ${custom} — ваш слой, BCM его не перезаписывает."
    bcm_warn "⚠ Файл подключается последним и ПЕРЕОПРЕДЕЛЯЕТ базовый конфиг."
    bcm_warn "⚠ Удалять его нельзя: без подключаемого файла redis не стартует."
    bcm_confirm "Открыть редактор (\${EDITOR:-vi})?" || { bcm_any_key; return; }

    local tmp; tmp=$(mktemp /tmp/bcm-redis.XXXXXX)
    bcm_ssh_fetch_file "$ref_ip" "$custom" "$tmp" 2>/dev/null || : > "$tmp"

    if ! _ce_open_editor "$tmp"; then
        bcm_info "Изменений нет — ничего не применяю."; rm -f "$tmp"; bcm_any_key; return
    fi

    echo
    bcm_confirm "Раскатать на все web-ноды и перезапустить redis-${inst}?" || {
        bcm_info "Отменено."; rm -f "$tmp"; bcm_any_key; return; }

    # Порядок: реплики, мастер последним (роль спрашиваем у самого redis).
    local -a order_master=() order_replica=() node ip role
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        role=$(bcm_ssh_exec_timeout "$ip" 8 \
            "redis-cli -p ${port} info replication 2>/dev/null | awk -F: '/^role/{print \$2}' | tr -d '\r'" 2>/dev/null | tr -d '[:space:]')
        if [[ "$role" == "master" ]]; then order_master+=("$node"); else order_replica+=("$node"); fi
    done

    local ts; ts=$(date +%Y%m%d-%H%M%S) ok=1
    for node in "${order_replica[@]}" "${order_master[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        if bcm_ssh_copy_file "$tmp" "$ip" "/tmp/bcm-redis-new.conf" && \
           bcm_ssh_exec_timeout "$ip" 30 "
                [ -f ${custom} ] && cp ${custom} ${custom}.bcm-bak-${ts}
                cp /tmp/bcm-redis-new.conf ${custom}
                rm -f /tmp/bcm-redis-new.conf
                if systemctl restart redis-${inst}; then
                    sleep 2; redis-cli -p ${port} ping >/dev/null 2>&1
                else
                    [ -f ${custom}.bcm-bak-${ts} ] && cp ${custom}.bcm-bak-${ts} ${custom}
                    systemctl restart redis-${inst} 2>/dev/null
                    exit 1
                fi" 2>/dev/null; then
            bcm_ok "  ${node}: применено, redis-${inst} перезапущен."
        else
            bcm_error "  ${node}: ошибка — выполнен откат на бэкап."
            ok=0; break
        fi
    done
    rm -f "$tmp"
    [[ $ok -eq 1 ]] && bcm_ok "Слой redis-${inst} обновлён на всех web-нодах." \
                    || bcm_warn "Применено с ошибками — остальные ноды НЕ тронуты."
    bcm_any_key
}

# =============================================================================
# Keepalived (слой поверх базового конфига)
# =============================================================================
# ⚠️ Валидация — по ТЕКСТУ вывода `keepalived -t`, а не по коду возврата: сборка
# 2.2.8 отдаёт rc=0 даже при «Unknown keyword» (проверено вживую).
# ⚠️ Применяем ПО ОДНОЙ ноде, держатель VIP последним: неудачный конфиг на всех
# сразу увёл бы адрес совсем.
bcm_confedit_keepalived() {
    bcm_section_header "Свои настройки keepalived"

    echo "  Слой узлов:"
    echo "    1. LB (балансировщики)"
    echo "    2. WEB"
    echo "    0. Назад"
    local ch; read -r -p "  Выбор: " ch
    local -a nodes=()
    case "$ch" in
        1) nodes=("${BCM_NODES_LB[@]}") ;;
        2) nodes=("${BCM_NODES_WEB[@]}") ;;
        0|"") bcm_info "Отменено."; bcm_any_key; return ;;
        *) bcm_error "Неверный выбор."; bcm_any_key; return ;;
    esac
    [[ ${#nodes[@]} -eq 0 ]] && { bcm_error "Узлы слоя не заданы."; bcm_any_key; return; }

    local custom="/etc/keepalived/conf.d/90-custom.conf"
    local ref_ip="${BCM_NODE_IP[${nodes[0]}]:-}"
    [[ -z "$ref_ip" ]] && { bcm_error "Нет IP у ${nodes[0]}."; bcm_any_key; return; }

    bcm_info "Редактируется ${custom} — ваш слой, BCM его не перезаписывает."
    bcm_warn "⚠ Слой ДОПОЛНЯЮЩИЙ: заводите НОВЫЕ vrrp_script/vrrp_instance."
    bcm_warn "  Параметры существующих (priority, unicast_peer, notify) задаёт шаблон."
    bcm_confirm "Открыть редактор (\${EDITOR:-vi})?" || { bcm_any_key; return; }

    local tmp; tmp=$(mktemp /tmp/bcm-keepalived.XXXXXX)
    bcm_ssh_fetch_file "$ref_ip" "$custom" "$tmp" 2>/dev/null || : > "$tmp"

    if ! _ce_open_editor "$tmp"; then
        bcm_info "Изменений нет — ничего не применяю."; rm -f "$tmp"; bcm_any_key; return
    fi

    # Валидация связки на эталонной ноде, живой conf.d не трогаем.
    bcm_info "Проверка конфига (keepalived -t) на ${nodes[0]}..."
    bcm_ssh_copy_file "$tmp" "$ref_ip" "/tmp/bcm-ka-candidate.conf"
    local vout
    vout=$(bcm_ssh_exec_timeout "$ref_ip" 20 "
        d=\$(mktemp -d /tmp/bcm-kacheck.XXXXXX)
        cp /etc/keepalived/conf.d/*.conf \"\$d\"/ 2>/dev/null
        cp /tmp/bcm-ka-candidate.conf \"\$d\"/90-custom.conf
        sed 's#include /etc/keepalived/conf.d/\*.conf#include '\"\$d\"'/*.conf#' /etc/keepalived/keepalived.conf > \"\$d\"/base.conf
        keepalived -t -f \"\$d\"/base.conf 2>&1
        rm -rf \"\$d\" /tmp/bcm-ka-candidate.conf" 2>/dev/null)
    if echo "$vout" | grep -qiE "unknown keyword|invalid|error"; then
        bcm_error "Конфиг НЕ валиден — изменения НЕ применены:"
        echo "$vout" | grep -iE "unknown keyword|invalid|error" | sed 's/^/    /' | head -10
        rm -f "$tmp"; bcm_any_key; return
    fi
    bcm_ok "keepalived -t: замечаний нет."
    echo
    bcm_confirm "Раскатать на все узлы слоя и перезапустить keepalived?" || {
        bcm_info "Отменено."; rm -f "$tmp"; bcm_any_key; return; }

    # Держатель VIP — последним (для LB порядок уже умеет _ce_lb_ordered).
    local -a order=()
    if [[ "$ch" == "1" ]]; then
        local -a _lines=(); mapfile -t _lines < <(_ce_lb_ordered)
        local _l n i; for _l in "${_lines[@]}"; do read -r n i <<< "$_l"; [[ -n "$n" ]] && order+=("$n"); done
    else
        order=("${nodes[@]}")
    fi

    local ts; ts=$(date +%Y%m%d-%H%M%S) ok=1 node ip
    for node in "${order[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        if bcm_ssh_copy_file "$tmp" "$ip" "/tmp/bcm-ka-new.conf" && \
           bcm_ssh_exec_timeout "$ip" 30 "
                mkdir -p /etc/keepalived/conf.d
                [ -f ${custom} ] && cp ${custom} ${custom}.bcm-bak-${ts}
                cp /tmp/bcm-ka-new.conf ${custom}
                rm -f /tmp/bcm-ka-new.conf
                if systemctl restart keepalived; then
                    sleep 3; systemctl is-active --quiet keepalived
                else
                    [ -f ${custom}.bcm-bak-${ts} ] && cp ${custom}.bcm-bak-${ts} ${custom}
                    systemctl restart keepalived 2>/dev/null
                    exit 1
                fi" 2>/dev/null; then
            bcm_ok "  ${node}: применено, keepalived перезапущен."
        else
            bcm_error "  ${node}: ошибка — выполнен откат на бэкап."
            ok=0; break
        fi
    done
    rm -f "$tmp"
    [[ $ok -eq 1 ]] && bcm_ok "Слой keepalived обновлён." \
                    || bcm_warn "Применено с ошибками — остальные узлы НЕ тронуты."
    bcm_any_key
}

# =============================================================================
# nginx на web-нодах (слой в контексте http)
# =============================================================================
# ⚠️ Файл называется zzz-bcm-custom.conf, чтобы сортироваться ПОСЛЕ
# zz-bcm-lb.conf: nginx подключает каталог по алфавиту (`include
# bx/settings/*.conf`), и для простых директив побеждает последняя.
# ⚠️ Каталог /etc/nginx/bx/settings ansible синхронизирует с delete:yes при
# добавлении web-ноды, поэтому эталон дублируется в /etc/bitrix-cluster и его
# стережёт bcm_settings_guard.sh.
NGINX_CUSTOM="/etc/nginx/bx/settings/zzz-bcm-custom.conf"
NGINX_CUSTOM_REF="/etc/bitrix-cluster/nginx-custom.conf"

bcm_confedit_nginx() {
    bcm_section_header "Свои настройки nginx (все web-ноды)"

    if [[ ${#BCM_NODES_WEB[@]} -eq 0 ]]; then
        bcm_error "Web-узлы не заданы в cluster.conf."; bcm_any_key; return
    fi
    local ref ref_node ref_ip
    ref=$(_ce_reachable_nodes BCM_NODES_WEB | head -1) || true
    [[ -z "$ref" ]] && { bcm_error "Нет доступных web-нод."; bcm_any_key; return; }
    read -r ref_node ref_ip <<< "$ref"

    bcm_info "Редактируется ${NGINX_CUSTOM} — ваш слой, BCM его не перезаписывает."
    bcm_warn "⚠ Только директивы уровня http: файл включается из блока http nginx.conf."
    bcm_warn "⚠ Подключается ПОСЛЕ zz-bcm-lb.conf, поэтому простые директивы отсюда побеждают."
    bcm_confirm "Открыть редактор (\${EDITOR:-vi})?" || { bcm_any_key; return; }

    local tmp; tmp=$(mktemp /tmp/bcm-nginx.XXXXXX)
    bcm_ssh_fetch_file "$ref_ip" "$NGINX_CUSTOM" "$tmp" 2>/dev/null || : > "$tmp"

    if ! _ce_open_editor "$tmp"; then
        bcm_info "Изменений нет — ничего не применяю."; rm -f "$tmp"; bcm_any_key; return
    fi

    # Валидация на эталонной ноде: подставляем кандидата, проверяем nginx -t и
    # СРАЗУ возвращаем прежний файл — живой конфиг не остаётся изменённым.
    bcm_info "Проверка конфига (nginx -t) на ${ref_node}..."
    bcm_ssh_copy_file "$tmp" "$ref_ip" "/tmp/bcm-nginx-candidate.conf"
    local vout
    vout=$(bcm_ssh_exec_timeout "$ref_ip" 25 "
        [ -f ${NGINX_CUSTOM} ] && cp ${NGINX_CUSTOM} /tmp/bcm-nginx-prev.conf
        cp /tmp/bcm-nginx-candidate.conf ${NGINX_CUSTOM}
        nginx -t 2>&1
        if [ -f /tmp/bcm-nginx-prev.conf ]; then cp /tmp/bcm-nginx-prev.conf ${NGINX_CUSTOM}; else rm -f ${NGINX_CUSTOM}; fi
        rm -f /tmp/bcm-nginx-prev.conf /tmp/bcm-nginx-candidate.conf" 2>/dev/null)
    if ! echo "$vout" | grep -qi "syntax is ok"; then
        bcm_error "Конфиг НЕ валиден — изменения НЕ применены:"
        echo "$vout" | sed 's/^/    /' | tail -10
        rm -f "$tmp"; bcm_any_key; return
    fi
    bcm_ok "nginx -t: конфиг валиден."
    echo
    bcm_confirm "Раскатать на все web-ноды и перечитать nginx?" || {
        bcm_info "Отменено."; rm -f "$tmp"; bcm_any_key; return; }

    local ts; ts=$(date +%Y%m%d-%H%M%S) ok=1 node ip
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        if bcm_ssh_copy_file "$tmp" "$ip" "/tmp/bcm-nginx-new.conf" && \
           bcm_ssh_exec_timeout "$ip" 30 "
                [ -f ${NGINX_CUSTOM} ] && cp ${NGINX_CUSTOM} ${NGINX_CUSTOM}.bcm-bak-${ts}
                cp /tmp/bcm-nginx-new.conf ${NGINX_CUSTOM}
                rm -f /tmp/bcm-nginx-new.conf
                if nginx -t >/dev/null 2>&1 && systemctl reload nginx; then
                    # Обновляем эталон сторожа, иначе он вернёт прежнюю версию.
                    cp ${NGINX_CUSTOM} ${NGINX_CUSTOM_REF}; chmod 600 ${NGINX_CUSTOM_REF}
                else
                    [ -f ${NGINX_CUSTOM}.bcm-bak-${ts} ] && cp ${NGINX_CUSTOM}.bcm-bak-${ts} ${NGINX_CUSTOM}
                    systemctl reload nginx 2>/dev/null
                    exit 1
                fi" 2>/dev/null; then
            bcm_ok "  ${node}: применено, nginx перечитан."
        else
            bcm_error "  ${node}: ошибка — выполнен откат на бэкап."
            ok=0; break
        fi
    done
    rm -f "$tmp"
    [[ $ok -eq 1 ]] && bcm_ok "Слой nginx обновлён на всех web-нодах." \
                    || bcm_warn "Применено с ошибками — остальные ноды НЕ тронуты."
    bcm_any_key
}

# =============================================================================
# ProxySQL (слой = SQL, применяемый к admin-интерфейсу)
# =============================================================================
# ⚠️ У ProxySQL файлового слоя быть НЕ может: /etc/proxysql.cnf читается только
# при ПЕРВОМ старте (пустая sqlite), дальше источник правды — /var/lib/proxysql.
# Поэтому слой оператора — это SQL-файл, применяемый к admin :6032.
#
# ⚠️ Откат делается родными средствами и не требует возни с файлами: изменения
# сначала уходят в RUNTIME, и только после успешной проверки — SAVE TO DISK.
# Если проверка не прошла, `LOAD ... FROM DISK` возвращает последнее сохранённое
# (заведомо рабочее) состояние.
PROXYSQL_CUSTOM="/etc/bitrix-cluster/proxysql-custom.sql"

bcm_confedit_proxysql() {
    bcm_section_header "Свои настройки ProxySQL (все web-ноды)"

    if [[ ${#BCM_NODES_WEB[@]} -eq 0 ]]; then
        bcm_error "Web-узлы не заданы в cluster.conf."; bcm_any_key; return
    fi
    local ref ref_node ref_ip
    ref=$(_ce_reachable_nodes BCM_NODES_WEB | head -1) || true
    [[ -z "$ref" ]] && { bcm_error "Нет доступных web-нод."; bcm_any_key; return; }
    read -r ref_node ref_ip <<< "$ref"

    bcm_info "Редактируется ${PROXYSQL_CUSTOM} — ваш SQL, применяется к admin-интерфейсу."
    bcm_warn "⚠ ProxySQL хранит живую конфигурацию в своей БД, а не в файле:"
    bcm_warn "  правки /etc/proxysql.cnf на работающем узле не действуют вовсе."
    bcm_warn "⚠ Пишите идемпотентный SQL (INSERT OR REPLACE / UPDATE) — он применяется"
    bcm_warn "  на каждой web-ноде, у каждой свой экземпляр ProxySQL."
    bcm_info "Порядок: применить в RUNTIME → проверить маршрутизацию → SAVE TO DISK."
    bcm_confirm "Открыть редактор (\${EDITOR:-vi})?" || { bcm_any_key; return; }

    local tmp; tmp=$(mktemp /tmp/bcm-proxysql.XXXXXX)
    if ! bcm_ssh_fetch_file "$ref_ip" "$PROXYSQL_CUSTOM" "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
        printf '%s\n' \
            '-- Ваш слой настроек ProxySQL. Применяется к admin :6032 на каждой web-ноде.' \
            '-- BCM этот файл не перезаписывает. Меню BCM: 4 → 9.' \
            '--' \
            '-- ⚠️ SQL должен быть идемпотентным: он выполняется при каждом применении' \
            '--    и на каждой ноде. Пример — поднять лимит соединений к бэкендам:' \
            '--' \
            '-- UPDATE global_variables SET variable_value=2000' \
            "--   WHERE variable_name='mysql-max_connections';" \
            '--' \
            '-- LOAD/SAVE делать НЕ нужно — их выполняет BCM после проверки.' \
            > "$tmp"
        bcm_info "Слой ещё не создан — открываю заготовку."
    fi

    if ! _ce_open_editor "$tmp"; then
        bcm_info "Изменений нет — ничего не применяю."; rm -f "$tmp"; bcm_any_key; return
    fi

    echo
    bcm_confirm "Применить на всех web-нодах (по одной, с откатом при сбое)?" || {
        bcm_info "Отменено."; rm -f "$tmp"; bcm_any_key; return; }

    local au ap bu bp pport
    au=$(bcm_conf_get proxysql admin_user);        ap=$(bcm_conf_get proxysql admin_password)
    bu=$(bcm_conf_get proxysql bitrix_db_user);    bp=$(bcm_conf_get proxysql bitrix_db_password)
    pport=$(bcm_conf_get proxysql port); [[ -z "$pport" ]] && pport=6033
    if [[ -z "$au" || -z "$ap" ]]; then
        bcm_error "В cluster.conf нет реквизитов admin ProxySQL."; rm -f "$tmp"; bcm_any_key; return
    fi

    local ok=1 node ip
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        bcm_ssh_copy_file "$tmp" "$ip" "$PROXYSQL_CUSTOM"
        # ⚠️ Пароль инлайном в команду (-p'...'): вынесенный в переменную и
        # ре-экспандированный, он приезжает вместе с кавычками и даёт Access denied
        # (ловили дважды). MYSQL_PWD и --defaults-extra-file клиент 8 отвергает.
        # ⚠️ Каждый вызов mysql пишется ЦЕЛИКОМ, без сборки команды в переменную:
        # `A="mysql … -p'pass'"; eval $A -e "SQL"` ломается дважды — кавычки вокруг
        # пароля становятся его частью (Access denied), а многословный SQL после
        # -e разлетается на отдельные аргументы, и клиент печатает справку.
        # Ловили обоими способами, поэтому здесь только инлайн.
        if bcm_ssh_exec_timeout "$ip" 60 "
                mysql -h127.0.0.1 -P6032 -u'${au}' -p'${ap}' -N < ${PROXYSQL_CUSTOM} || exit 1
                mysql -h127.0.0.1 -P6032 -u'${au}' -p'${ap}' -N -e 'LOAD MYSQL VARIABLES TO RUNTIME; LOAD MYSQL SERVERS TO RUNTIME; LOAD MYSQL QUERY RULES TO RUNTIME; LOAD MYSQL USERS TO RUNTIME;' || exit 1
                # Проверка: ходит ли запрос через прокси к базе.
                if mysql -h127.0.0.1 -P${pport} -u'${bu}' -p'${bp}' --default-auth=mysql_native_password -N -e 'SELECT 1' >/dev/null 2>&1; then
                    mysql -h127.0.0.1 -P6032 -u'${au}' -p'${ap}' -N -e 'SAVE MYSQL VARIABLES TO DISK; SAVE MYSQL SERVERS TO DISK; SAVE MYSQL QUERY RULES TO DISK; SAVE MYSQL USERS TO DISK;'
                else
                    # Возврат к последнему сохранённому состоянию — SAVE ещё не делали.
                    mysql -h127.0.0.1 -P6032 -u'${au}' -p'${ap}' -N -e 'LOAD MYSQL VARIABLES FROM DISK; LOAD MYSQL SERVERS FROM DISK; LOAD MYSQL QUERY RULES FROM DISK; LOAD MYSQL USERS FROM DISK; LOAD MYSQL VARIABLES TO RUNTIME; LOAD MYSQL SERVERS TO RUNTIME; LOAD MYSQL QUERY RULES TO RUNTIME; LOAD MYSQL USERS TO RUNTIME;'
                    exit 1
                fi" 2>/dev/null; then
            bcm_ok "  ${node}: применено и сохранено (маршрутизация проверена)."
        else
            bcm_error "  ${node}: сбой — состояние возвращено к сохранённому на диске."
            ok=0; break
        fi
    done
    rm -f "$tmp"
    [[ $ok -eq 1 ]] && bcm_ok "Слой ProxySQL применён на всех web-нодах." \
                    || bcm_warn "Применено с ошибками — остальные ноды НЕ тронуты."
    bcm_any_key
}
