#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181
# =============================================================================
# search_role.sh — контролёр кластера Manticore (поиск портала) на web-узле.
#
# Кластер Manticore из двух web-узлов не держит кворум сам: Galera внутри Manticore
# при падении одного из двух узлов оставляет второго без кворума (non-primary — поиск
# работает, запись нет). Решение за внешним контролёром, как у остального web-слоя:
# главный для поиска — master web-VRRP HA Cron (/run/bcm-ha-cron.role пишет
# cron_notify.sh). На том же узле работает обработчик очередей (bcm-messenger) —
# единственный писатель в индекс (отложенная индексация, см. templates/search).
#
# Правила (проверены на стенде из двух узлов Manticore 29.9, ноябрь 2026):
#   • вес узла pc.weight: master — 2, остальные — 1. Падение резервного главный тогда
#     переживает без вмешательства (2 из 3 голосов);
#   • главный без кворума, живого primary нигде нет → pc.bootstrap (master только);
#   • узел в closed/recovery-required (оба падали разом), есть живой primary → перезапуск
#     службы: узел сам входит в кластер и догоняет данные (IST/SST);
#   • primary нигде нет → master поднимается с --new-cluster-force, остальные потом
#     перезапускаются и входят к нему. ⚠️ Только master: два «новых кластера» = раскол;
#   • раскол (оба primary из одного узла, а связь есть) → резервный стирает свою копию и
#     входит заново (SST). ⚠️ Простой перезапуск НЕ лечит: после раскола у обеих сторон
#     одинаковый номер транзакции, Galera считает их согласованными — расхождение тихое;
#   • после bootstrap / new-cluster / чистого входа — досинхронизация индекса из
#     b_search_content (cli.php repair) в фоне: записи стороны, которая проиграла,
#     потеряны, но в базе портала они есть.
#   • ⚠️ DELETE CLUSTER в Manticore удаляет кластер на ВСЕХ узлах — здесь не используется.
#
# Запуск: systemd-таймер bcm-search-role.timer (каждые 15 с) и cron_notify.sh при смене
# роли VRRP. Пауза контролёра: файл /etc/bitrix-cluster/search.maint (bcm_search.sh
# ставит его на время установки и изменения схемы).
#
# Команды: tick [--reason X] | status | maint on|off | --decide ROLE L LS P PS (тесты)
# =============================================================================
set -uo pipefail

ENV_FILE="${BCM_SEARCH_ENV:-/etc/bitrix-cluster/search.env}"
ROLE_FILE="${BCM_SEARCH_ROLE_FILE:-/run/bcm-ha-cron.role}"
MAINT_FILE="/etc/bitrix-cluster/search.maint"
STATE_DIR="/run/bcm-search"
LIB_STATE="/var/lib/bcm/search"
LOG="/var/log/bcm/search-role.log"
DATA_DIR="/var/lib/manticore"
# Пауза между «тяжёлыми» действиями узла (перезапуск, bootstrap, чистый вход), с.
COOLDOWN="${BCM_SEARCH_COOLDOWN:-90}"

_sr_log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; echo "$(date '+%F %T') $*" >> "$LOG"; }

# ──── Решение (чистая функция: без побочных эффектов, для юнит-тестов) ───────
# _sr_decide ROLE L LS P PS → действие
#   ROLE  MASTER | BACKUP | "" (роль ещё не известна)
#   L, P  состояние локального узла и лучшего из соседей:
#         primary | non-primary | closed (closed/recovery-required) | none (вне кластера)
#         | busy (идёт передача состояния) | down (не отвечает)
#   LS,PS размер кластера, каким его видит узел
# Действия: weight | join | restart | bootstrap | new-cluster | rejoin-clean | split | wait
_sr_decide() {
    local role="$1" l="$2" ls="${3:-0}" p="$4" ps="${5:-0}"
    case "$l" in
        down|busy) echo "wait" ;;
        none)
            if [[ "$p" == "primary" ]]; then echo "join"; else echo "wait"; fi ;;
        primary)
            if [[ "$ls" -le 1 && "$p" == "primary" && "$ps" -le 1 ]]; then
                # Оба считают себя кластером из одного узла, а друг друга видят — раскол.
                if [[ "$role" == "BACKUP" ]]; then echo "rejoin-clean"; else echo "split"; fi
            else
                echo "weight"
            fi ;;
        non-primary)
            if [[ "$p" == "primary" ]]; then echo "restart"
            elif [[ "$role" == "MASTER" ]]; then echo "bootstrap"
            else echo "wait"; fi ;;
        closed)
            if [[ "$p" == "primary" ]]; then echo "restart"
            elif [[ "$role" == "MASTER" ]]; then echo "new-cluster"
            else echo "wait"; fi ;;
        *) echo "wait" ;;
    esac
}

# ──── Наблюдение ─────────────────────────────────────────────────────────────
_sr_env() {
    [[ -r "$ENV_FILE" ]] || return 1
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    SEARCH_PORT="${SEARCH_PORT:-9306}"; SEARCH_API_PORT="${SEARCH_API_PORT:-9312}"
    SEARCH_SITE_ROOT="${SEARCH_SITE_ROOT:-/home/bitrix/www}"
    [[ -n "${SEARCH_CLUSTER:-}" && -n "${SEARCH_SELF_IP:-}" ]]
}

# SQL к узлу (Manticore: логин не нужен; --no-defaults — мимо ~/.my.cnf bitrix-env).
_sr_sql() {
    local host="$1" sql="$2" t="${3:-5}"
    timeout "$t" mysql --no-defaults -h"$host" -P"$SEARCH_PORT" --connect-timeout=2 -N -B -e "$sql" 2>/dev/null
}

# Состояние узла: «состояние размер».
_sr_state() {
    local host="$1" out st="" ns="" sz=0 k v
    out="$(_sr_sql "$host" "SHOW STATUS LIKE 'cluster_${SEARCH_CLUSTER}_%'")" || { echo "down 0"; return; }
    # Узел ответил, но строк кластера нет — он вне кластера. Пустой ответ при живой
    # службе отличаем от недоступности проверкой SELECT 1.
    if [[ -z "$out" ]]; then
        if [[ "$(_sr_sql "$host" "SHOW STATUS LIKE 'uptime'" | awk '{print $1}')" == "uptime" ]]; then
            echo "none 0"
        else
            echo "down 0"
        fi
        return
    fi
    while IFS=$'\t' read -r k v; do
        case "$k" in
            "cluster_${SEARCH_CLUSTER}_status")     st="$v" ;;
            "cluster_${SEARCH_CLUSTER}_node_state") ns="$v" ;;
            "cluster_${SEARCH_CLUSTER}_size")       sz="$v" ;;
        esac
    done <<< "$out"
    [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
    case "$st/$ns" in
        recovery-required/*|*/closed|closed/*)           echo "closed $sz" ;;
        primary/synced|primary/donor|primary/desynced)  echo "primary $sz" ;;
        primary/*)                                      echo "busy $sz" ;;
        non-primary/*)                                  echo "non-primary $sz" ;;
        *)                                              echo "busy $sz" ;;
    esac
}

# Лучшее состояние среди соседей: «состояние размер ip». primary важнее всего,
# затем живые, затем down. ⚠️ Зовётся через $(…) — адрес возвращается выводом,
# присвоение переменной из подоболочки до вызывающего не дошло бы.
_sr_peer_state() {
    local best="down" bsz=0 bip="-" ip st sz rank brank=9
    for ip in ${SEARCH_PEERS:-}; do
        read -r st sz <<< "$(_sr_state "$ip")"
        case "$st" in
            primary) rank=0 ;; non-primary) rank=1 ;; closed) rank=2 ;;
            busy) rank=3 ;; none) rank=4 ;; *) rank=5 ;;
        esac
        if [[ $rank -lt $brank ]]; then best="$st"; bsz="$sz"; bip="$ip"; brank=$rank; fi
    done
    echo "$best $bsz $bip"
}

_sr_role() { local r; r="$(cat "$ROLE_FILE" 2>/dev/null)"; [[ "$r" == "MASTER" || "$r" == "BACKUP" ]] && echo "$r" || echo ""; }

_sr_cooldown_ok() {
    local last now; now=$(date +%s)
    last=$(cat "${LIB_STATE}/last_action" 2>/dev/null || echo 0)
    [[ $((now - last)) -ge $COOLDOWN ]]
}
_sr_mark_action() { mkdir -p "$LIB_STATE"; date +%s > "${LIB_STATE}/last_action"; }

# ──── Действия ───────────────────────────────────────────────────────────────
_sr_weight() {
    local want=1 pid key
    [[ "$(_sr_role)" == "MASTER" ]] && want=2
    pid="$(systemctl show -p MainPID --value manticore 2>/dev/null)"
    key="${pid}:${want}"
    mkdir -p "$STATE_DIR"
    [[ "$(cat "${STATE_DIR}/weight" 2>/dev/null)" == "$key" ]] && return 0
    if _sr_sql 127.0.0.1 "SET CLUSTER ${SEARCH_CLUSTER} GLOBAL 'pc.weight' = ${want}" >/dev/null; then
        echo "$key" > "${STATE_DIR}/weight"
        _sr_log "вес узла pc.weight = ${want}"
    fi
}

_sr_wait_ready() {
    local i
    for i in $(seq 1 60); do
        [[ "$(_sr_state 127.0.0.1 | awk '{print $1}')" != "down" ]] && return 0
        sleep 2
    done
    return 1
}

# Досинхронизация индекса из базы портала — в фоне, если портал переведён на кластер.
_sr_repair_bg() {
    local cli="${SEARCH_SITE_ROOT}/local/modules/bcm.search/cli.php"
    [[ "${SEARCH_PORTAL:-0}" == "1" && -f "$cli" ]] || return 0
    _sr_log "досинхронизация индекса из b_search_content запущена в фоне ($1)"
    nohup runuser -u bitrix -- php "$cli" repair >> /var/log/bcm/search-repair.log 2>&1 &
}

_sr_act() {
    local action="$1"
    case "$action" in
        weight) _sr_weight ;;
        wait) : ;;
        # Раскол лечит резервный (rejoin-clean); master свою копию не трогает. В журнал
        # раскол попадает строкой картины (`→ split`) один раз, а не каждый такт.
        split) : ;;
        join)
            _sr_cooldown_ok || return 0; _sr_mark_action
            _sr_log "вне кластера, у ${PEER_PRIMARY_IP} есть primary — JOIN"
            _sr_sql 127.0.0.1 "JOIN CLUSTER ${SEARCH_CLUSTER} AT '${PEER_PRIMARY_IP}:${SEARCH_API_PORT}'" 600 >/dev/null \
                || _sr_log "JOIN не удался" ;;
        restart)
            _sr_cooldown_ok || return 0; _sr_mark_action
            _sr_log "кластер жив у соседа, этот узел не в нём — перезапуск manticore (войдёт сам)"
            timeout 900 systemctl restart manticore || _sr_log "перезапуск не удался" ;;
        bootstrap)
            _sr_cooldown_ok || return 0; _sr_mark_action
            _sr_log "master без кворума, primary нигде нет — pc.bootstrap"
            if _sr_sql 127.0.0.1 "SET CLUSTER ${SEARCH_CLUSTER} GLOBAL 'pc.bootstrap' = 1" >/dev/null; then
                rm -f "${STATE_DIR}/weight"; _sr_weight; _sr_repair_bg "bootstrap"
            else
                _sr_log "pc.bootstrap не удался"
            fi ;;
        new-cluster)
            _sr_cooldown_ok || return 0; _sr_mark_action
            _sr_log "primary нигде нет, узел закрыт — старт с --new-cluster-force (master)"
            systemctl stop manticore 2>/dev/null
            systemctl set-environment _ADDITIONAL_SEARCHD_PARAMS=--new-cluster-force
            timeout 900 systemctl start manticore; local rc=$?
            systemctl set-environment _ADDITIONAL_SEARCHD_PARAMS=
            if [[ $rc -eq 0 ]] && _sr_wait_ready; then
                rm -f "${STATE_DIR}/weight"; _sr_weight; _sr_repair_bg "new-cluster"
            else
                _sr_log "старт с --new-cluster-force не удался"
            fi ;;
        rejoin-clean)
            _sr_cooldown_ok || return 0; _sr_mark_action
            local keep; keep="${DATA_DIR}.bcm-split-$(date +%Y%m%d-%H%M%S)"
            _sr_log "РАСКОЛ, этот узел резервный — копия в ${keep}, чистый вход к ${PEER_PRIMARY_IP}"
            systemctl stop manticore 2>/dev/null
            mv "$DATA_DIR" "$keep" && install -d -o manticore -g manticore -m 0750 "$DATA_DIR" \
                || { _sr_log "не удалось освободить ${DATA_DIR}"; systemctl start manticore; return 1; }
            # Старые копии после раскола: хранить две последние.
            ls -1d "${DATA_DIR}".bcm-split-* 2>/dev/null | sort | head -n -2 | while IFS= read -r old; do
                [[ "$old" == "${DATA_DIR}".bcm-split-* ]] && rm -rf -- "$old"
            done
            systemctl start manticore && _sr_wait_ready \
                && _sr_sql 127.0.0.1 "JOIN CLUSTER ${SEARCH_CLUSTER} AT '${PEER_PRIMARY_IP}:${SEARCH_API_PORT}'" 600 >/dev/null \
                && _sr_repair_bg "rejoin-clean" \
                || _sr_log "чистый вход не удался" ;;
    esac
}

# Обновление модуля поиска Битрикса может добавить поле индекса в любой момент — без
# релиза BCM. Master раз в 10 минут (при здоровом кластере и переведённом портале)
# сверяет схему; запись с новым полем до этого ждёт в очереди («unknown column» класс
# считает повторимой ошибкой).
_sr_schema_check() {
    [[ "$(_sr_role)" == "MASTER" && "${SEARCH_PORTAL:-0}" == "1" ]] || return 0
    local now last; now=$(date +%s)
    last=$(cat "${LIB_STATE}/schema_check" 2>/dev/null || echo 0)
    [[ $((now - last)) -ge 600 ]] || return 0
    mkdir -p "$LIB_STATE"; echo "$now" > "${LIB_STATE}/schema_check"
    nohup "$(dirname "$0")/bcm_search.sh" --schema-sync --auto >> "$LOG" 2>&1 < /dev/null &
}

_sr_tick() {
    local reason="${1:-timer}"
    _sr_env || return 0
    [[ -f "$MAINT_FILE" ]] && return 0
    mkdir -p "$STATE_DIR"
    exec 9>"${STATE_DIR}/tick.lock"
    flock -n 9 || return 0

    local role l ls p ps action PEER_PRIMARY_IP
    role="$(_sr_role)"
    if [[ "$(systemctl is-active manticore 2>/dev/null)" != "active" ]]; then
        # Службу поднимает systemd (Restart=on-failure); остановленную руками не трогаем.
        l="down"; ls=0
    else
        read -r l ls <<< "$(_sr_state 127.0.0.1)"
    fi
    read -r p ps PEER_PRIMARY_IP <<< "$(_sr_peer_state)"
    action="$(_sr_decide "$role" "$l" "$ls" "$p" "$ps")"

    # В журнал — только смены картины, а не каждый тик.
    local pic="role=${role:-?} local=${l}/${ls} peer=${p}/${ps} → ${action}"
    if [[ "$(cat "${STATE_DIR}/last" 2>/dev/null)" != "$pic" ]]; then
        echo "$pic" > "${STATE_DIR}/last"
        _sr_log "[${reason}] ${pic}"
    fi
    _sr_act "$action"
    [[ "$action" == "weight" ]] && _sr_schema_check
}

_sr_status() {
    _sr_env || { echo "SEARCH_ENV=absent"; return 1; }
    local l ls p ps
    read -r l ls <<< "$(_sr_state 127.0.0.1)"
    read -r p ps _ <<< "$(_sr_peer_state)"
    echo "SERVICE=$(systemctl is-active manticore 2>/dev/null)"
    echo "ROLE=$(_sr_role)"
    echo "LOCAL=${l} SIZE=${ls}"
    echo "PEER=${p} SIZE=${ps}"
    echo "ROWS=$(_sr_sql 127.0.0.1 "SELECT COUNT(*) FROM ${SEARCH_TABLE:-bitrix}" | head -1)"
    echo "MAINT=$([[ -f "$MAINT_FILE" ]] && echo on || echo off)"
    echo "LAST=$(cat "${STATE_DIR}/last" 2>/dev/null)"
    echo "TIMER=$(systemctl is-active bcm-search-role.timer 2>/dev/null)"
}

case "${1:-}" in
    tick)    shift; [[ "${1:-}" == "--reason" ]] && _sr_tick "${2:-?}" || _sr_tick ;;
    status)  _sr_status ;;
    maint)   case "${2:-}" in
                 on)  mkdir -p "$(dirname "$MAINT_FILE")"; touch "$MAINT_FILE"; _sr_log "пауза контролёра включена" ;;
                 off) rm -f "$MAINT_FILE"; _sr_log "пауза контролёра снята" ;;
                 *)   echo "usage: $0 maint on|off" >&2; exit 2 ;;
             esac ;;
    --decide) shift; _sr_decide "$@" ;;
    *) echo "usage: $0 tick [--reason X] | status | maint on|off | --decide ROLE L LS P PS" >&2; exit 2 ;;
esac
