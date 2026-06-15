#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181
# =============================================================================
# pxc_autorecover.sh — автоматическое восстановление Galera (PXC) после
# полного обесточивания кластера.
#
# Запускается на КАЖДОЙ PXC-ноде при загрузке (systemd: pxc-autorecover.service).
# Скрипт симметричный: один и тот же код на всех нодах детерминированно
# выбирает ОДНУ ноду-бутстрапера (с самой свежей БД), остальные джойнятся.
#
# Зачем: после одновременной остановки всех нод Galera НЕ стартует сама —
# никто не знает, у кого самые свежие данные → нет Primary Component → БД нет.
# Штатно это лечится ручным bootstrap'ом самой свежей ноды. Этот агент делает
# то же самое автоматически, СОБЛЮДАЯ КВОРУМ (без split-brain и без подъёма
# устаревших данных).
#
# Конфиг: /etc/bitrix-cluster/pxc-autorecover.env (раскатывает install.sh).
# Режимы:
#   (без аргумента)  — полный алгоритм восстановления (вызывает systemd).
#   --report         — печать recovery-позиции для опроса с других нод:
#                        "PRIMARY"           если локальный mysql уже Primary,
#                        "<uuid> <seqno>"    иначе (seqno из grastate либо
#                                            из `mysqld --wsrep-recover`).
#
# Все данные о топологии — только из env-файла; хардкода IP/имён нет.
# =============================================================================
# ВНИМАНИЕ: НЕ ставить `set -e`. Агент по своей сути best-effort: при одновременной
# загрузке всех нод (целевой сценарий!) пиры поднимают sshd не сразу, и опрос
# `rep=$(peer_report ...)` штатно возвращает ненулевой код, пока пир не готов — это
# нормальная часть retry-цикла рандеву, а НЕ фатальная ошибка. С `set -e` первый же
# неудачный SSH (или `(( x++ ))`, дающий код 1) убивал агент на этапе рандеву
# (exit 255/EXCEPTION). Корректность обеспечивается явными return-кодами функций.
set -uo pipefail

# ──── Конфигурация ───────────────────────────────────────────────────────────
ENV_FILE="${PXC_AUTORECOVER_ENV:-/etc/bitrix-cluster/pxc-autorecover.env}"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# Значения по умолчанию (перекрываются env-файлом)
PXC_PEERS="${PXC_PEERS:-}"                 # пробел-разделённый список IP всех PXC-нод (включая себя)
SELF_IP="${SELF_IP:-}"                     # IP этой ноды
SSH_KEY="${SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}"
GRASTATE="${GRASTATE:-/var/lib/mysql/grastate.dat}"
LOG_FILE="${LOG_FILE:-/var/log/bcm/pxc-autorecover.log}"
POS_CACHE="${POS_CACHE:-/run/pxc-autorecover.pos}"   # tmpfs → очищается перезагрузкой

# Таймауты (секунды)
WAIT_ALL="${WAIT_ALL:-120}"          # ждать появления ВСЕХ нод, прежде чем согласиться на большинство
WAIT_MAJORITY="${WAIT_MAJORITY:-300}" # суммарный дедлайн; < большинства после него → abort
RETRY="${RETRY:-5}"                  # пауза между опросами рандеву
BOOTSTRAP_WAIT="${BOOTSTRAP_WAIT:-300}" # ждать Synced после старта mysql/mysql@bootstrap
PEER_PROBE_TIMEOUT="${PEER_PROBE_TIMEOUT:-10}" # таймаут одного SSH-опроса пира

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=8
          -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR)

# ──── Логирование ────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$(hostname -s 2>/dev/null || echo '?')] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    echo "$msg" >&2
}

# ──── Локальное состояние mysql ──────────────────────────────────────────────
# Локальный mysql — рабочий Primary?
local_is_primary() {
    local status ready
    status=$(mysql -N -e "SHOW STATUS LIKE 'wsrep_cluster_status'" 2>/dev/null | awk '{print $2}')
    ready=$(mysql -N -e  "SHOW STATUS LIKE 'wsrep_ready'"          2>/dev/null | awk '{print $2}')
    [[ "$status" == "Primary" && "$ready" == "ON" ]]
}

# Локальный mysql вошёл в кластер и синхронизирован?
local_is_synced() {
    [[ "$(mysql -N -e "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}')" == "Synced" ]]
}

# Удалённый пир — рабочий Primary? (опрос по SSH через --report)
peer_is_primary() {
    local ip="$1"
    [[ "$(peer_report "$ip")" == "PRIMARY" ]]
}

# ──── Recovery-позиция ───────────────────────────────────────────────────────
# Вернуть "<uuid> <seqno>" для ЭТОЙ ноды. Кэшируется в POS_CACHE на сессию загрузки.
#   1) seqno из grastate.dat, если он >= 0 (чистая остановка);
#   2) иначе `mysqld --wsrep-recover` (грязная остановка / реальное обесточивание).
# Обёртка с flock: свой recover() и входящий по SSH `--report` от пира не должны
# запускать `mysqld --wsrep-recover` одновременно на одном datadir (конфликт блокировки
# InnoDB). Лок межпроцессный (по файлу), кэш проверяется уже под локом.
local_recovery_pos() {
    ( flock 9; _recovery_pos_locked ) 9>"${POS_CACHE}.lock" 2>/dev/null || _recovery_pos_locked
}

_recovery_pos_locked() {
    if [[ -f "$POS_CACHE" ]]; then
        cat "$POS_CACHE"; return 0
    fi

    local uuid="" seqno=""
    if [[ -f "$GRASTATE" ]]; then
        uuid=$(awk '/^uuid:/{print $2}'   "$GRASTATE" 2>/dev/null)
        seqno=$(awk '/^seqno:/{print $2}' "$GRASTATE" 2>/dev/null)
    fi

    # seqno=-1 (или пусто/некорректно) → восстанавливаем позицию из лога
    if ! [[ "$seqno" =~ ^[0-9]+$ ]] || [[ "$seqno" == "-1" ]]; then
        log "grastate seqno=${seqno:-<нет>} — запускаю mysqld --wsrep-recover"
        local tmplog rec
        tmplog=$(mktemp /tmp/wsrep-recover.XXXXXX)
        # Восстановление позиции из InnoDB; mysqld пишет её в указанный log-error и завершается.
        runuser -u mysql -- mysqld --wsrep-recover --log-error="$tmplog" >/dev/null 2>&1 || \
            mysqld --wsrep-recover --user=mysql --log-error="$tmplog" >/dev/null 2>&1 || true
        rec=$(grep -oE 'Recovered position[: ]+[0-9a-f-]+:[0-9-]+' "$tmplog" 2>/dev/null | tail -1 \
              | grep -oE '[0-9a-f-]+:[0-9-]+$')
        rm -f "$tmplog"
        if [[ -n "$rec" ]]; then
            uuid="${rec%%:*}"
            seqno="${rec##*:}"
            log "wsrep-recover: позиция ${uuid}:${seqno}"
        fi
    fi

    # Финальная подстраховка
    [[ "$seqno" =~ ^[0-9]+$ ]] || seqno="-1"
    [[ -n "$uuid" ]] || uuid="00000000-0000-0000-0000-000000000000"

    printf '%s %s' "$uuid" "$seqno" | tee "$POS_CACHE" 2>/dev/null || printf '%s %s' "$uuid" "$seqno"
}

# Опрос пира по SSH: печатает "PRIMARY" или "<uuid> <seqno>" или пусто (недоступен).
peer_report() {
    local ip="$1"
    if [[ "$ip" == "$SELF_IP" ]]; then
        if local_is_primary; then echo "PRIMARY"; else local_recovery_pos; fi
        return 0
    fi
    timeout "$PEER_PROBE_TIMEOUT" ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "root@${ip}" \
        "/opt/bcm/bin/lib/pxc_autorecover.sh --report" 2>/dev/null
}

# Прочитать wsrep-переменную с узла (локально или по SSH).
peer_wsrep() {
    local ip="$1" var="$2"
    local q="mysql -N -e \"SHOW STATUS LIKE '${var}'\" 2>/dev/null | awk '{print \$2}'"
    if [[ "$ip" == "$SELF_IP" ]]; then
        eval "$q" | tr -d '[:space:]'
    else
        timeout "$PEER_PROBE_TIMEOUT" ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "root@${ip}" "$q" 2>/dev/null | tr -d '[:space:]'
    fi
}

# ──── Действия ───────────────────────────────────────────────────────────────
# Дождаться Synced на локальном mysql.
wait_local_synced() {
    local timeout="${1:-$BOOTSTRAP_WAIT}" waited=0
    while (( waited < timeout )); do
        local_is_synced && return 0
        sleep 5; (( waited += 5 ))
    done
    return 1
}

# Дождаться, пока удалённый пир станет Primary.
wait_peer_primary() {
    local ip="$1" timeout="${2:-$BOOTSTRAP_WAIT}" waited=0
    while (( waited < timeout )); do
        peer_is_primary "$ip" && return 0
        sleep 5; (( waited += 5 ))
    done
    return 1
}

# Дождаться своей очереди на join (сериализация).
# Одновременный join нескольких узлов к только что забутстрапленному Primary вызывает
# гонку gcomm и фрагментацию (узлы виснут в NON_PRIM, systemd убивает mysqld по таймауту).
# Поэтому join строго по очереди: узел ранга rank ждёт, пока бутстрапер снова Synced
# (т.е. НЕ Donor/Desynced — предыдущий joiner закончил SST) и cluster_size достиг 1+rank.
# wait_join_turn <winner_ip> <rank>
wait_join_turn() {
    local ip="$1" rank="$2" timeout="${3:-$BOOTSTRAP_WAIT}" waited=0
    local target=$(( 1 + rank ))
    while (( waited < timeout )); do
        local st sz
        st=$(peer_wsrep "$ip" "wsrep_local_state_comment")
        sz=$(peer_wsrep "$ip" "wsrep_cluster_size")
        if [[ "$st" == "Synced" ]] && [[ "$sz" =~ ^[0-9]+$ ]] && (( sz >= target )); then
            return 0
        fi
        sleep 3; (( waited += 3 ))
    done
    return 1
}

# Сбросить failed/start-limit состояние юнитов mysql, иначе systemd может отказать
# в `systemctl start` (start-limit-hit) — например, если штатный mysql.service всё же
# был включён в автозапуск и успел несколько раз упасть до запуска агента.
clear_mysql_failed() {
    systemctl reset-failed mysql mysqld mysql@bootstrap 2>/dev/null || true
}

# Бутстрап ЭТОЙ ноды как нового Primary.
do_bootstrap() {
    log "Я — нода-бутстрапер. Запускаю новый Primary Component."
    systemctl stop mysql mysqld mysql@bootstrap 2>/dev/null || true
    clear_mysql_failed
    [[ -f "$GRASTATE" ]] && sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' "$GRASTATE" || true
    if ! systemctl start mysql@bootstrap; then
        log "ОШИБКА: systemctl start mysql@bootstrap завершился неудачно."
        return 1
    fi
    if wait_local_synced; then
        log "Bootstrap OK — нода синхронизирована (Synced)."
        return 0
    fi
    log "ОШИБКА: после bootstrap нода не достигла Synced за ${BOOTSTRAP_WAIT}с."
    return 1
}

# Присоединить ЭТУ ноду к живому Primary (SST/IST).
do_join() {
    log "Присоединяюсь к живому кластеру (join, возможен SST)."
    systemctl stop mysql mysqld mysql@bootstrap 2>/dev/null || true
    clear_mysql_failed
    if ! systemctl start mysql; then
        log "ОШИБКА: systemctl start mysql завершился неудачно."
        return 1
    fi
    if wait_local_synced; then
        log "Join OK — нода синхронизирована (Synced)."
        return 0
    fi
    log "ОШИБКА: после join нода не достигла Synced за ${BOOTSTRAP_WAIT}с."
    return 1
}

# ──── Основной алгоритм ──────────────────────────────────────────────────────
recover() {
    # Валидация конфигурации
    if [[ -z "$PXC_PEERS" || -z "$SELF_IP" ]]; then
        log "ОШИБКА: PXC_PEERS/SELF_IP не заданы в ${ENV_FILE}. Выход."
        return 1
    fi

    local -a peers=()
    read -r -a peers <<< "$PXC_PEERS"
    local total="${#peers[@]}"
    local majority=$(( total / 2 + 1 ))
    log "Старт. Ноды: ${PXC_PEERS} (всего ${total}, кворум ${majority}). Я: ${SELF_IP}."

    # Шаг 0 — локальный mysql уже живой?
    if local_is_primary || local_is_synced; then
        log "Локальный mysql уже в рабочем кластере — ничего делать не нужно."
        return 0
    fi

    # Шаг 1 — кластер уже жив на ком-то? (одиночная перезагрузка)
    local p
    for p in "${peers[@]}"; do
        [[ "$p" == "$SELF_IP" ]] && continue
        if peer_is_primary "$p"; then
            log "Обнаружен живой Primary на ${p} — кластер цел, джойнюсь."
            do_join; return $?
        fi
    done
    log "Живого Primary нет ни на одной ноде — сценарий полного обесточивания."

    # Шаг 2 — моя recovery-позиция
    local my_pos my_uuid my_seq
    my_pos=$(local_recovery_pos)
    my_uuid="${my_pos%% *}"; my_seq="${my_pos##* }"
    log "Моя recovery-позиция: uuid=${my_uuid} seqno=${my_seq}"

    # Шаг 3 — рандеву + кворум.
    # Собираем позиции пиров; ждём ВСЕХ, по таймауту WAIT_ALL соглашаемся на большинство.
    local start_ts now elapsed
    start_ts=$(date +%s)
    declare -A pos_uuid=() pos_seq=()
    while :; do
        pos_uuid=(); pos_seq=()
        pos_uuid["$SELF_IP"]="$my_uuid"; pos_seq["$SELF_IP"]="$my_seq"

        for p in "${peers[@]}"; do
            [[ "$p" == "$SELF_IP" ]] && continue
            # Пир может быть ещё не готов (sshd не поднят при одновременной загрузке) —
            # пустой ответ штатен, повторим на следующей итерации рандеву.
            local rep; rep=$(peer_report "$p" 2>/dev/null || true)
            if [[ "$rep" == "PRIMARY" ]]; then
                log "Во время рандеву ${p} стал Primary — джойнюсь."
                do_join; return $?
            fi
            if [[ "$rep" =~ ^[0-9a-f-]+\ -?[0-9]+$ ]]; then
                pos_uuid["$p"]="${rep%% *}"
                pos_seq["$p"]="${rep##* }"
            fi
        done

        local responders="${#pos_seq[@]}"
        now=$(date +%s); elapsed=$(( now - start_ts ))
        log "Рандеву: ответили ${responders}/${total} (прошло ${elapsed}с)."

        # Все на месте — идеальный случай, выбираем freshest среди всех.
        (( responders == total )) && break
        # Прошёл WAIT_ALL и есть большинство — действуем по большинству.
        (( elapsed >= WAIT_ALL && responders >= majority )) && {
            log "Истёк WAIT_ALL (${WAIT_ALL}с); есть большинство — продолжаю без отсутствующих."
            break
        }
        # Истёк общий дедлайн — решаем по кворуму.
        if (( elapsed >= WAIT_MAJORITY )); then
            if (( responders >= majority )); then
                log "Истёк WAIT_MAJORITY; есть большинство — продолжаю."
                break
            fi
            log "ОТМЕНА: истёк WAIT_MAJORITY, ответили ${responders}/${total} (< кворума ${majority})."
            log "Бутстрап НЕ выполняется (защита от split-brain/устаревших данных). Нужен ручной разбор."
            return 1
        fi
        sleep "$RETRY"
    done

    # Шаг 4 — детерминированный выбор winner.
    # Берём только ноды с самым частым uuid (защита от разных инкарнаций кластера),
    # среди них max(seqno); тай-брейк — наименьший IP (стабильно и одинаково на всех).
    local dominant_uuid
    dominant_uuid=$(for p in "${!pos_uuid[@]}"; do echo "${pos_uuid[$p]}"; done \
                    | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
    log "Доминирующий uuid: ${dominant_uuid}"

    local winner="" winner_seq=-2
    for p in "${peers[@]}"; do
        [[ -n "${pos_seq[$p]:-}" ]] || continue
        [[ "${pos_uuid[$p]}" == "$dominant_uuid" ]] || continue
        local s="${pos_seq[$p]}"
        if (( s > winner_seq )); then
            winner_seq="$s"; winner="$p"
        elif (( s == winner_seq )) && [[ -n "$winner" ]]; then
            # тай-брейк: наименьший IP лексикографически по октетам
            [[ "$(printf '%s\n%s\n' "$p" "$winner" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)" == "$p" ]] && winner="$p"
        fi
    done

    if [[ -z "$winner" ]]; then
        log "ОТМЕНА: не удалось определить ноду-бутстрапера. Нужен ручной разбор."
        return 1
    fi
    log "Выбран бутстрапер: ${winner} (seqno=${winner_seq})."

    # Шаг 5 — действие.
    if [[ "$winner" == "$SELF_IP" ]]; then
        do_bootstrap; return $?
    fi

    # Не-winner: join строго по очереди (сериализация, см. wait_join_turn).
    # Очередь — по возрастанию IP среди не-winner узлов; rank = позиция в очереди.
    local -a joiners=()
    while IFS= read -r jp; do [[ -n "$jp" ]] && joiners+=("$jp"); done < <(
        for p in "${peers[@]}"; do [[ "$p" != "$winner" ]] && echo "$p"; done \
            | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)
    local my_rank=0
    for jp in "${joiners[@]}"; do [[ "$jp" == "$SELF_IP" ]] && break; my_rank=$(( my_rank + 1 )); done

    log "Бутстрапер — ${winner}. Моя очередь join: rank=${my_rank} (жду Synced и cluster_size>=$((my_rank+1)) на ${winner})."
    if ! wait_join_turn "$winner" "$my_rank"; then
        log "ОШИБКА: не дождался своей очереди join на ${winner} за ${BOOTSTRAP_WAIT}с. Джойн отложен."
        return 1
    fi
    do_join; return $?
}

# ──── Точка входа ────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --report)
            if local_is_primary; then echo "PRIMARY"; else local_recovery_pos; fi
            ;;
        ""|--recover)
            recover
            ;;
        *)
            echo "usage: $0 [--report|--recover]" >&2
            exit 2
            ;;
    esac
}

main "$@"
