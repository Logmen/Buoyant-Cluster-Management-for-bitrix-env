#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181
# =============================================================================
# bcm_proxysql_tune.sh — настройки ProxySQL на web-узлах, которые BCM доводит и
# на живых кластерах, а не только на свежей установке.
#
#   bcm_proxysql_tune.sh --apply   привести все web-узлы к текущим значениям
#   bcm_proxysql_tune.sh --check   только показать, что стоит сейчас
#
# ⚠️⚠️ Почему не только шаблон. ProxySQL читает /etc/proxysql.cnf лишь при ПЕРВОМ
# старте, дальше его конфигурация живёт в /var/lib/proxysql/proxysql.db. Правка
# шаблона до работающего кластера не доходит, и повторный install.sh её тоже не
# применит: он переписывает cnf и перезапускает сервис, а база остаётся прежней.
# Поэтому значения ставятся через admin-интерфейс (LOAD … TO RUNTIME; SAVE … TO
# DISK) — установщиком после старта ProxySQL и bcm_post_update.sh при обновлении.
#
# 1. Проверка здоровья Galera (mysql_galera_hostgroups). DDL в PXC идёт через TOI:
#    пока он выполняется, узлы не отвечают на запрос статуса, которым ProxySQL
#    проверяет их здоровье. С умолчаниями ProxySQL (раз в 5 с, таймаут 800 мс, три
#    таймаута подряд) любой DDL дольше ~10 с — обычный ALTER из обновления
#    Битрикса по таблице в сотни мегабайт — выводил из групп ВСЕ узлы сразу:
#    портал без базы, открытые соединения рвутся («MySQL server has gone away»),
#    новые 10 с ждут и падают (9001). crm.onelab.kz, 01.11.2026: ALTER
#    b_mail_message_uid из обновления mail 26.1100.0 — 30 с без базы, скрипт
#    обновления упал на полпути.
#    Мёртвый или недоступный узел длинным порогом не маскируется: его выводят
#    ping-монитор (monitor_ping_*) и ошибки соединения (shun_on_failures), а ping во
#    время TOI отвечает. Узел вне Primary или в Donor проверка видит сразу — это
#    ответ, а не таймаут. Поэтому таймаут проверки 3 с и 10 таймаутов подряд
#    (≈50 с при интервале 5 с): DDL такой длины кластер переживает без выпадения
#    узлов, запросы на это время ждут, а не падают. Переопределяются в cluster.conf:
#    [proxysql] galera_hc_timeout_ms, galera_hc_max_timeouts.
#    ⚠️ 10 — предел ProxySQL (2.6.6: max_timeout_count 1…10). Большее значение
#    LOAD … TO RUNTIME молча отвергает («Impossible to set variable … Resetting to
#    current») и возвращает прежнее — так 1.0.33 оставил на crm 3000 мс × 3 вместо
#    × 24. Поэтому значение из cluster.conf зажимается в 1…10.
# 2. Лог ProxySQL. errorlog в шаблоне — /var/log/proxysql/proxysql.log, а каталог
#    установщик создавал от root. ProxySQL работает от пользователя proxysql, файл
#    создать не мог — лога не было вовсе (01.11.2026 выпадение узлов пришлось
#    восстанавливать по таблицам монитора, а они живут 10 минут). Каталог отдаётся
#    proxysql, `PROXYSQL FLUSH LOGS` открывает лог заново без перезапуска сервиса.
#    Ротация — в наборе bcm-node (bcm_logrotate.sh): пакетный набор proxysql
#    описывает другой файл, /var/lib/proxysql/proxysql.log.
# =============================================================================

BCM_PSQL_GALERA_HC_TIMEOUT_MS_DEFAULT=3000
BCM_PSQL_GALERA_HC_MAX_TIMEOUTS_DEFAULT=10
BCM_PSQL_GALERA_HC_MAX_TIMEOUTS_LIMIT=10
BCM_PSQL_LOG_DIR="/var/log/proxysql"

# «таймаут_мс макс_таймаутов» — из cluster.conf, иначе значения по умолчанию.
# cluster.conf может ещё не существовать (вызов из установщика) — тогда умолчания.
bcm_psql_galera_hc_values() {
    local t="" m=""
    if [[ -n "${BCM_CONF_FILE:-}" && -r "${BCM_CONF_FILE}" ]]; then
        t="$(bcm_conf_get proxysql galera_hc_timeout_ms 2>/dev/null || true)"
        m="$(bcm_conf_get proxysql galera_hc_max_timeouts 2>/dev/null || true)"
    fi
    [[ "$t" =~ ^[0-9]+$ ]] || t="$BCM_PSQL_GALERA_HC_TIMEOUT_MS_DEFAULT"
    [[ "$m" =~ ^[0-9]+$ ]] || m="$BCM_PSQL_GALERA_HC_MAX_TIMEOUTS_DEFAULT"
    (( m < 1 )) && m=1
    (( m > BCM_PSQL_GALERA_HC_MAX_TIMEOUTS_LIMIT )) && m="$BCM_PSQL_GALERA_HC_MAX_TIMEOUTS_LIMIT"
    echo "$t $m"
}

# bcm_psql_tune_node <ip> <apply|check> [admin_port admin_user admin_pass]
# Печатает одну строку состояния. rc 0 — значения и лог на месте, 1 — нет,
# 2 — admin ProxySQL не ответил. Учётку admin берёт из cluster.conf, если не
# передана (установщик передаёт свою: cluster.conf на узлах ещё нет).
bcm_psql_tune_node() {
    local ip="$1" mode="${2:-check}" ap="${3:-}" au="${4:-}" aps="${5:-}" t m
    [[ -n "$ap" ]]  || ap="$(bcm_get_proxysql_admin_port 2>/dev/null || echo 6032)"
    [[ -n "$au" ]]  || au="$(bcm_get_proxysql_admin_user 2>/dev/null || echo admin)"
    [[ -n "$aps" ]] || aps="$(bcm_get_proxysql_admin_pass 2>/dev/null || echo admin)"
    read -r t m <<< "$(bcm_psql_galera_hc_values)"
    [[ "$mode" == "apply" ]] || mode="check"

    # ⚠️ Пароль admin — только `-p'…'` прямо в команде: MYSQL_PWD и defaults-file
    # ProxySQL отвергает (см. bcm_confedit.sh). Команда не логируется.
    bcm_ssh_exec_timeout "$ip" 40 "
        A() { mysql --default-auth=mysql_native_password -h127.0.0.1 -P${ap} -u${au} -p'${aps}' -N -e \"\$1\" 2>/dev/null; }
        q() { A \"SELECT variable_value FROM runtime_global_variables WHERE variable_name='mysql-monitor_galera_healthcheck_\$1'\"; }
        # После перезапуска (установщик) admin поднимается не мгновенно.
        for i in 1 2 3 4 5 6 7 8 9 10; do [ -n \"\$(A 'SELECT 1')\" ] && break; sleep 1; done
        ct=\$(q timeout); cm=\$(q max_timeout_count)
        [ -n \"\$ct\" ] || { echo 'admin ProxySQL не отвечает'; exit 2; }
        L='${BCM_PSQL_LOG_DIR}'; ch=''
        if [ '${mode}' = apply ]; then
            if [ \"\$ct\" != '${t}' ] || [ \"\$cm\" != '${m}' ]; then
                A \"UPDATE global_variables SET variable_value='${t}' WHERE variable_name='mysql-monitor_galera_healthcheck_timeout'; UPDATE global_variables SET variable_value='${m}' WHERE variable_name='mysql-monitor_galera_healthcheck_max_timeout_count'; LOAD MYSQL VARIABLES TO RUNTIME; SAVE MYSQL VARIABLES TO DISK;\" >/dev/null
                ch=\"\$ch проверка Galera \${ct} мс × \${cm} → ${t} мс × ${m};\"
                ct=\$(q timeout); cm=\$(q max_timeout_count)
            fi
            mkdir -p \"\$L\"
            if [ \"\$(stat -c %U \"\$L\")\" != proxysql ]; then
                chown proxysql:proxysql \"\$L\" && ch=\"\$ch каталог лога отдан proxysql;\"
            fi
            # Лог не создан — ProxySQL не смог открыть его на старте; открыть заново.
            if [ ! -e \"\$L/proxysql.log\" ]; then
                A 'PROXYSQL FLUSH LOGS' >/dev/null; sleep 1
                [ -e \"\$L/proxysql.log\" ] && ch=\"\$ch лог открыт;\"
            fi
        fi
        lg='нет'; [ -e \"\$L/proxysql.log\" ] && lg=\"есть, \$(stat -c %s \"\$L/proxysql.log\") байт\"
        echo \"проверка Galera \${ct} мс × \${cm}; лог: \${lg}\${ch:+; изменено:\$ch}\"
        [ \"\$ct\" = '${t}' ] && [ \"\$cm\" = '${m}' ] && [ -e \"\$L/proxysql.log\" ]
    " </dev/null
}

# Все web-узлы топологии. Требует bcm_config.sh/bcm_ssh.sh.
bcm_psql_tune_all() {
    local mode="${1:-check}" node ip out bad=0
    bcm_load_topology || return 1
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -n "$ip" ]] || continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "  ${node} (${ip}): недоступен — пропуск."; bad=1; continue
        fi
        out="$(bcm_psql_tune_node "$ip" "$mode")" || bad=1
        printf '  %-6s %s\n' "$node" "${out:-нет ответа}"
    done
    return $bad
}

# ──── Команда ────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    BCM_BASE_DIR="${BCM_BASE_DIR:-/opt/bcm}"
    BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"
    source "${BCM_LIB_DIR}/bcm_utils.sh"
    source "${BCM_LIB_DIR}/bcm_config.sh"
    source "${BCM_LIB_DIR}/bcm_ssh.sh"
    read -r _t _m <<< "$(bcm_psql_galera_hc_values)"
    case "${1:---check}" in
        --apply) bcm_info "ProxySQL на web-узлах → проверка Galera ${_t} мс × ${_m}, лог в ${BCM_PSQL_LOG_DIR}:"; bcm_psql_tune_all apply ;;
        --check) bcm_info "ProxySQL на web-узлах (ожидается проверка Galera ${_t} мс × ${_m}):"; bcm_psql_tune_all check ;;
        *) echo "Использование: $(basename "$0") --apply | --check"; exit 1 ;;
    esac
fi
