#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181,SC2206
# =============================================================================
# lsyncd_role.sh — управление ролью узла в одностороннем lsyncd (source/target).
#
# Источник lsyncd следует за «первичной web-нодой» (master web-VRRP, HA-Cron).
# Вызывается из cron_notify.sh по событиям keepalived:
#   MASTER → promote (этот узел становится источником и пушит код на остальные web)
#   BACKUP → demote  (этот узел становится приёмником, свой lsyncd останавливает)
#
# КЛЮЧЕВАЯ БЕЗОПАСНОСТЬ — catch-up при promote: прежде чем начать пушить (с --delete),
# новый источник ПОДТЯГИВАЕТ свежие файлы с пиров (rsync --update, БЕЗ --delete).
# Поэтому и failover (web02 принял нагрузку), и failback (web01 вернулся и перехватил
# по preempt) проходят без потери наработок: перехватчик сперва вбирает чужие изменения,
# затем пушит уже объединённое состояние — старое дерево не затирает свежее.
#
# ПРЕДОХРАНИТЕЛИ ОТ КАТАСТРОФИЧЕСКОГО WIPE (после инцидента июнь 2026, когда churn
# обновлятора Bitrix под живым lsyncd+`--delete` обрезал дерево кода на ОБЕИХ нодах):
#   1) single-режим (mode=single) ЗАМОРАЖИВАЕТ lsyncd — promote по VRRP становится
#      no-op до unpin (тёплые ноды = неизменная known-good копия на время рисков).
#   2) sanity-гейт: деградировавшее дерево (есть bitrix/modules, нет ядра) НЕ
#      становится источником — не затрёт здоровый приёмник.
#   3) `--max-delete=${MAX_DELETE}` в каждом sync: один проход не удалит больше
#      порога → «источник потерял тысячи файлов» отклоняется, приёмник цел.
#   4) /bitrix/updates исключён — временный churn обновлятора не синкается.
#
# Параметры — из /etc/bitrix-cluster/lsyncd-role.env (раскатывает install.sh).
# Действия: promote | demote | status.
#   status → "SOURCE", если локальный lsyncd active, иначе текущий active_node-хинт.
#
# ВНИМАНИЕ: НЕ ставить `set -e` — операции с пирами best-effort (пир может быть недоступен).
# =============================================================================
set -uo pipefail

ENV_FILE="${LSYNCD_ROLE_ENV:-/etc/bitrix-cluster/lsyncd-role.env}"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SELF_NODE="${SELF_NODE:-$(hostname -s 2>/dev/null || echo '?')}"
SELF_IP="${SELF_IP:-}"
WEB_PEERS="${WEB_PEERS:-}"                 # пробел-разделённый список IP всех web-нод (включая себя)
SITE_PATH="${SITE_PATH:-/home/bitrix/www}"
SSH_KEY="${SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}"
LSYNCD_CONF="${LSYNCD_CONF:-/etc/lsyncd/lsyncd.conf}"
CLUSTER_CONF="${CLUSTER_CONF:-/etc/bitrix-cluster/cluster.conf}"
LOG_FILE="${LOG_FILE:-/var/log/bcm/lsyncd-role.log}"
# Предохранитель: максимум файлов, которые ОДИН проход rsync вправе удалить на
# приёмнике. Нормальное обновление убирает десятки устаревших файлов; «источник
# потерял тысячи файлов» (обрезанное/недосинканное дерево, churn обновлятора)
# → проход отклоняется (rsync rc=25), приёмник СОХРАНЯЕТСЯ. Перекрытие — env
# LSYNCD_MAX_DELETE. Большие легитимные удаления — через контролируемую
# реконсиляцию в single-режиме, а не «вживую».
MAX_DELETE="${LSYNCD_MAX_DELETE:-1000}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=8
          -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR)

# Что НЕ синхронизируем (единый список с menu/06_lsyncd.sh): /upload — в S3;
# кэш/tmp/backup — локальны per-node; /bitrix/updates — временные каталоги
# обновлятора Bitrix (создаются/удаляются пачками → бессмысленный churn и гонка
# «cannot open dir» при синке; именно эта churn под --delete покалечила дерево).
EXCLUDES=(
    "--exclude=/upload/"
    "--exclude=/bitrix/cache/"
    "--exclude=/bitrix/managed_cache/"
    "--exclude=/bitrix/stack_cache/"
    "--exclude=/bitrix/html_pages/"
    "--exclude=/bitrix/tmp/"
    "--exclude=/bitrix/updates/"
    "--exclude=/bitrix/backup/"
    "--exclude=*.tmp"
    "--exclude=.git/"
)

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${SELF_NODE}] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    echo "$msg" >&2
}

# Список IP пиров (все web, кроме себя)
_other_peers() {
    local p
    for p in $WEB_PEERS; do
        [[ "$p" == "$SELF_IP" ]] && continue
        echo "$p"
    done
}

# Доступен ли узел по SSH
_reachable() {
    local ip="$1"
    timeout 8 ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "root@${ip}" "exit 0" 2>/dev/null
}

# ──── Режим кластера из cluster.conf (секция [cluster] mode=) ─────────────────
# Секция-aware: в conf есть и [ssl] mode= — простой grep ^mode брал бы не ту.
_conf_get_cluster_mode() {
    awk '
        /^\[/{ inc = ($0 ~ /^\[cluster\]/) }
        inc && /^[[:space:]]*mode[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print; exit
        }
    ' "$CLUSTER_CONF" 2>/dev/null
}

# ──── Деградировано ли локальное дерево портала ──────────────────────────────
# true, если каталог модулей присутствует, но ядро (prolog_before.php) отсутствует —
# признак обрезанного/недосинканного дерева. Пустой/свежий www (нет bitrix/modules)
# деградацией НЕ считается — защищать нечего, это нормальный первичный деплой.
_source_degraded() {
    [[ -d "${SITE_PATH}/bitrix/modules" \
       && ! -f "${SITE_PATH}/bitrix/modules/main/include/prolog_before.php" ]]
}

# Гарантированно остановить локальный lsyncd (без пуша)
_freeze_local() {
    systemctl stop lsyncd 2>/dev/null || true
    systemctl reset-failed lsyncd 2>/dev/null || true
}

# ──── /etc/sysconfig/lsyncd → наш конфиг (иначе unit грузит дефолтный пример) ──
_set_sysconfig() {
    printf 'LSYNCD_OPTIONS="%s"\n' "$LSYNCD_CONF" > /etc/sysconfig/lsyncd 2>/dev/null || true
}

# ──── Сгенерировать конфиг lsyncd: source=я → все остальные web ───────────────
_gen_lsyncd_conf() {
    mkdir -p "$(dirname "$LSYNCD_CONF")" /var/log/lsyncd 2>/dev/null || true
    {
        cat <<HEAD
-- ${LSYNCD_CONF}
-- Сгенерировано BCM lsyncd_role.sh (источник: ${SELF_NODE})
-- НЕ редактировать вручную.

settings {
    logfile    = "/var/log/lsyncd/lsyncd.log",
    statusFile = "/var/run/lsyncd.status",
    statusInterval = 10,
}
HEAD
        local ip
        for ip in $(_other_peers); do
            cat <<BLOCK

sync {
    default.rsync,
    source = "${SITE_PATH}/",
    target = "root@${ip}:${SITE_PATH}/",
    rsync = {
        archive  = true,
        compress = true,
        rsh      = "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -i ${SSH_KEY}",
        _extra = {
            "--max-delete=${MAX_DELETE}",
            "--exclude=/upload/",
            "--exclude=/bitrix/cache/",
            "--exclude=/bitrix/managed_cache/",
            "--exclude=/bitrix/stack_cache/",
            "--exclude=/bitrix/html_pages/",
            "--exclude=/bitrix/tmp/",
            "--exclude=/bitrix/updates/",
            "--exclude=/bitrix/backup/",
            "--exclude=*.tmp",
            "--exclude=.git/",
        },
    },
    delete = true,
    delay  = 5,
}

-- /upload: статика модулей (en/ru-хелп, картинки crm/main, лого sale и т.п.) —
-- НЕ CFile-объекты, в S3 не уходят, но обязаны быть на ВСЕХ web (иначе round-robin
-- → 404). Пользовательский контент /upload живёт в S3/MinIO (catch-all FILE_RULES),
-- локально его нет → отдельный односторонний блок БЕЗ --delete безопасен: статика
-- расходится источник→пиры, ничего на приёмнике не затирается (анти-клоббер), кэши
-- (resize_cache) и tmp исключены (per-node, регенерируются).
sync {
    default.rsync,
    source = "${SITE_PATH}/upload/",
    target = "root@${ip}:${SITE_PATH}/upload/",
    rsync = {
        archive  = true,
        compress = true,
        rsh      = "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -i ${SSH_KEY}",
        _extra = {
            "--exclude=/resize_cache/",
            "--exclude=/tmp/",
            "--exclude=/.bx_temp/",
            "--exclude=*.tmp",
        },
    },
    delete = false,
    delay  = 10,
}
BLOCK
        done
    } > "$LSYNCD_CONF"
}

# ──── Catch-up: подтянуть свежие файлы с пиров (БЕЗ --delete) ─────────────────
# rsync --update берёт только файлы, которые на пире новее, и НИКОГДА не удаляет —
# защита от затирания: вернувшийся/перехватывающий источник вбирает наработки,
# сделанные на пире, пока он был «первичным».
_catchup_from_peers() {
    local ip
    for ip in $(_other_peers); do
        if ! _reachable "$ip"; then
            log "catch-up: пир ${ip} недоступен — пропуск."
            continue
        fi
        log "catch-up: тяну свежее с ${ip} (rsync --update, без --delete)..."
        rsync -az --update "${EXCLUDES[@]}" \
            -e "ssh ${SSH_OPTS[*]} -i ${SSH_KEY}" \
            "root@${ip}:${SITE_PATH}/" "${SITE_PATH}/" >>"$LOG_FILE" 2>&1 \
            && log "catch-up с ${ip}: ок." \
            || log "catch-up с ${ip}: rsync вернул ошибку (см. лог)."
    done
}

# ──── Записать active_node в cluster.conf (локально) и раздать пирам ──────────
_set_active_node() {
    local node="$1"
    [[ -f "$CLUSTER_CONF" ]] || { log "cluster.conf не найден — active_node не записан."; return 0; }
    if grep -qE '^[[:space:]]*active_node[[:space:]]*=' "$CLUSTER_CONF"; then
        sed -i -E "s|^[[:space:]]*active_node[[:space:]]*=.*|active_node = ${node}|" "$CLUSTER_CONF"
    elif grep -qE '^\[cluster\]' "$CLUSTER_CONF"; then
        sed -i -E "/^\[cluster\]/a active_node = ${node}" "$CLUSTER_CONF"
    else
        printf '\n[cluster]\nactive_node = %s\n' "$node" >> "$CLUSTER_CONF"
    fi
    # Раздать обновлённый cluster.conf доступным пирам (best-effort)
    local ip
    for ip in $(_other_peers); do
        _reachable "$ip" || continue
        scp -q "${SSH_OPTS[@]}" -i "$SSH_KEY" "$CLUSTER_CONF" "root@${ip}:${CLUSTER_CONF}" 2>/dev/null \
            || log "active_node: не удалось раздать cluster.conf на ${ip}."
    done
}

# ──── PROMOTE: стать источником lsyncd ───────────────────────────────────────
promote() {
    # 0a) Режим единой ноды: lsyncd ОБЯЗАН быть заморожен. Рискованные операции
    # на active (деплой/обновление портала) НЕ должны зеркалиться с --delete на
    # тёплые ноды — они держатся как известно-целая копия. Авто-promote по VRRP
    # подавляется до bcm_cluster_unpin.
    if [[ "$(_conf_get_cluster_mode)" == "single" ]]; then
        log "PROMOTE пропущен: режим единой ноды (mode=single) — lsyncd заморожен до unpin."
        _freeze_local
        return 0
    fi
    log "PROMOTE: становлюсь источником lsyncd."
    _catchup_from_peers          # 1) вобрать свежее с пиров (без удаления)
    # 1a) Sanity-гейт: если ПОСЛЕ catch-up дерево всё ещё деградировано (есть
    # bitrix/modules, но нет ядра) — НЕ становиться источником: пуш с --delete
    # затёр бы здоровый приёмник. Лучше остаться без синка и поднять тревогу.
    if _source_degraded; then
        log "ОТКАЗ promote: локальное дерево портала деградировано (нет ${SITE_PATH}/bitrix/modules/main/include/prolog_before.php при наличии bitrix/modules). lsyncd НЕ запущен — приёмник защищён от затирания. Нужно ручное восстановление кода."
        _freeze_local
        return 1
    fi
    _set_sysconfig               # 2) sysconfig → наш конфиг
    _gen_lsyncd_conf             # 3) конфиг: я → остальные web
    if systemctl restart lsyncd 2>>"$LOG_FILE"; then
        log "lsyncd запущен (источник=${SELF_NODE}, active=$(systemctl is-active lsyncd))."
    else
        log "ОШИБКА: не удалось запустить lsyncd."
    fi
    _set_active_node "$SELF_NODE" # 4) зафиксировать источник в cluster.conf + раздать
    log "PROMOTE завершён."
}

# ──── DEMOTE: стать приёмником (источник — другой узел) ───────────────────────
demote() {
    log "DEMOTE: становлюсь приёмником — останавливаю локальный lsyncd."
    systemctl stop lsyncd 2>>"$LOG_FILE" || true
    # lsyncd на SIGTERM завершается ненулевым кодом → unit остаётся в failed;
    # сбрасываем, чтобы статус был чистым inactive (косметика + чистый re-promote).
    systemctl reset-failed lsyncd 2>/dev/null || true
    # Полную актуализацию выполнит lsyncd нового источника (стартовый rsync на все target).
    log "DEMOTE завершён (lsyncd active=$(systemctl is-active lsyncd 2>/dev/null))."
}

# ──── STATUS: для опроса/диагностики ─────────────────────────────────────────
status() {
    if [[ "$(systemctl is-active lsyncd 2>/dev/null)" == "active" ]]; then
        echo "SOURCE"
    else
        grep -E '^[[:space:]]*active_node[[:space:]]*=' "$CLUSTER_CONF" 2>/dev/null \
            | sed -E 's|.*=[[:space:]]*||' | tr -d '[:space:]'
    fi
}

case "${1:-}" in
    promote) promote ;;
    demote)  demote  ;;
    status)  status  ;;
    *) echo "usage: $0 {promote|demote|status}" >&2; exit 2 ;;
esac
