#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181,SC2206
# =============================================================================
# bcm_backup.sh — резервное копирование кластера в S3 (MinIO) с учётом HA.
#
# Первая линия — MinIO кластера (бакет с versioning + lifecycle), вторая
# (offsite) — отдельным этапом. Запускается systemd-таймерами НА нодах,
# привязки к конкретной ноде нет — только к РОЛИ в момент запуска:
#
#   --conf   на КАЖДОЙ ноде: tar конфигов/состояния (cluster.conf, серты,
#            acme-учётка, .settings.php, proxysql.db…) → openssl enc → S3.
#            Внутри секреты, поэтому ШИФРУЕТСЯ (aes-256, ключ в backup.env).
#   --db     на PXC-нодах: xtrabackup --stream | gzip | mc pipe → S3.
#            HA-гейты: (1) только Synced; (2) кандидаты упорядочены — реплики
#            раньше writer'а, стартовый sleep RANK*STAGGER разводит их во
#            времени; (3) идемпотентный маркер db/<дата>/.done в S3 — кто
#            успел, тот и сделал, остальные выходят (упал штатный бэкапер —
#            следующий кандидат подхватит; худший случай гонки — безвредный
#            дубль); (4) wsrep_desync=ON на время бэкапа, иначе flow control
#            Galera тормозит ВЕСЬ кластер (сброс по trap при любом исходе).
#   --files  на web-нодах: только ТЕКУЩИЙ источник lsyncd (lsyncd active —
#            тот же признак, что в lsyncd_role.sh) → mc mirror кода в S3.
#            История правок/защита от rm -rf — versioning бакета (lsyncd —
#            репликация, НЕ бэкап: удаление разъезжается по нодам).
#            /upload не трогаем — он уже в S3 (бакет bitrix-upload, его
#            история — versioning, включается в configure_backup).
#   --status машинно-читаемый статус последних копий (для меню 13).
#
# ⚠️ mc — ТОЛЬКО /usr/local/bin/mc: на web-нодах /usr/bin/mc — это Midnight
# Commander из bitrix-env. Креды S3 уходят через env MC_HOST_* (не в argv/ps).
# Параметры — из /etc/bitrix-cluster/backup.env (раскатывает install.sh).
# НЕ ставить set -e: гейты штатно выходят ненулевыми кодами.
# =============================================================================
set -uo pipefail

ENV_FILE="${BCM_BACKUP_ENV:-/etc/bitrix-cluster/backup.env}"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SELF_NODE="${SELF_NODE:-$(hostname -s 2>/dev/null || echo '?')}"
ROLE="${ROLE:-}"                          # web | lb | pxc | s3
S3_ENDPOINT="${S3_ENDPOINT:-}"            # https://<VIP>:9000 (MinIO TLS, CA доверен)
S3_ACCESS="${S3_ACCESS:-}"
S3_SECRET="${S3_SECRET:-}"
BUCKET="${BUCKET:-bitrix-backups}"
ENC_KEY="${ENC_KEY:-}"                    # ключ шифрования conf-архивов (hex)
RETENTION_DAYS="${RETENTION_DAYS:-14}"    # фактически применяет lifecycle MinIO
DB_RANK="${DB_RANK:-0}"                   # порядок PXC-кандидата (реплики раньше writer)
DB_STAGGER="${DB_STAGGER:-180}"           # сек между слотами кандидатов
SITE_PATH="${SITE_PATH:-/home/bitrix/www}"
MC_BIN="${MC_BIN:-/usr/local/bin/mc}"     # НЕ /usr/bin/mc (Midnight Commander!)
LOG_FILE="${LOG_FILE:-/var/log/bcm/backup.log}"
XB_TMP="${XB_TMP:-/tmp/bcm-xtrabackup}"

ALIAS="bcmbk"
DATE_TAG="$(date +%Y-%m-%d)"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${SELF_NODE}] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    echo "$msg" >&2
}

# ──── mc: алиас в /root/.mc/config.json (0600), ключи через stdin ────────────
# ⚠️ НЕ через MC_HOST_<alias>: mc не URL-декодирует userinfo — секрет со
# спецсимволами (: $ & + / …) ломает парсинг («The security token included in
# the request is invalid»); percent-encoding НЕ помогает (проверено вживую).
# argv для ключей тоже нельзя (видны в ps) → mc alias set читает их со stdin.
_mc() { "$MC_BIN" --quiet "$@"; }

_mc_setup() {
    _mc ls "${ALIAS}/" >/dev/null 2>&1 && return 0
    printf '%s\n%s\n' "$S3_ACCESS" "$S3_SECRET" \
        | "$MC_BIN" --quiet alias set "$ALIAS" "$S3_ENDPOINT" >/dev/null 2>&1
    _mc ls "${ALIAS}/" >/dev/null 2>&1 \
        || { log "ОШИБКА: mc alias ${ALIAS} → ${S3_ENDPOINT} не работает (креды/доступность S3?)."; return 1; }
}

_require_tools() {
    [[ -x "$MC_BIN" ]] || { log "ОШИБКА: ${MC_BIN} не найден (MinIO Client)."; return 1; }
    [[ -n "$S3_ENDPOINT" && -n "$S3_ACCESS" && -n "$S3_SECRET" ]] \
        || { log "ОШИБКА: S3-параметры не заданы в ${ENV_FILE}."; return 1; }
    _mc_setup || return 1
    return 0
}

# ──── conf: конфиги/состояние этой ноды (шифрованный tar) ────────────────────
backup_conf() {
    _require_tools || return 1
    [[ -n "$ENC_KEY" ]] || { log "ОШИБКА: ENC_KEY пуст — conf-архив должен шифроваться."; return 1; }

    # Состав по ролям; берём только существующие пути.
    local want=(/etc/bitrix-cluster)
    case "$ROLE" in
        lb)  want+=(/etc/haproxy/haproxy.cfg /etc/haproxy/certs /etc/keepalived) ;;
        web) want+=(/etc/keepalived /etc/nginx/ssl/cert.pem
                    /etc/nginx/bx/settings /etc/nginx/bx/site_enabled
                    /etc/push-server /etc/lsyncd /etc/sysconfig/lsyncd
                    /var/lib/proxysql/proxysql.db
                    "${SITE_PATH}/bitrix/.settings.php"
                    "${SITE_PATH}/bitrix/php_interface/dbconn.php") ;;
        pxc) want+=(/etc/my.cnf /etc/my.cnf.d /etc/mysql) ;;
        s3)  want+=(/etc/default/minio) ;;
    esac
    local paths=() p
    for p in "${want[@]}"; do [[ -e "$p" ]] && paths+=("$p"); done
    [[ ${#paths[@]} -gt 0 ]] || { log "conf: нечего бэкапить (пути не найдены)."; return 1; }

    local dst="${ALIAS}/${BUCKET}/conf/${SELF_NODE}/${DATE_TAG}.tar.gz.enc"
    log "conf: ${#paths[@]} путей → ${dst}"
    export BCM_ENC_KEY="$ENC_KEY"
    if tar -czf - "${paths[@]}" 2>>"$LOG_FILE" \
        | openssl enc -aes-256-cbc -pbkdf2 -pass env:BCM_ENC_KEY 2>>"$LOG_FILE" \
        | _mc pipe "$dst" 2>>"$LOG_FILE"; then
        log "conf: ок ($(_mc stat "$dst" 2>/dev/null | sed -n 's/^Size *: *//p' | head -1))"
    else
        log "conf: ОШИБКА (см. ${LOG_FILE})."
        return 1
    fi
}

# ──── db: xtrabackup с HA-гейтами (только PXC-ноды) ──────────────────────────
_wsrep_state() { mysql -N -e "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}'; }
_desync() { mysql -e "SET GLOBAL wsrep_desync=$1" 2>>"$LOG_FILE"; }

backup_db() {
    local force="${1:-}"
    [[ "$ROLE" == "pxc" ]] || { log "db: нода не PXC — пропуск."; return 0; }
    _require_tools || return 1
    command -v xtrabackup >/dev/null 2>&1 \
        || { log "ОШИБКА: xtrabackup не установлен (dnf install -y percona-xtrabackup-84)."; return 1; }

    local marker="${ALIAS}/${BUCKET}/db/${DATE_TAG}/.done"

    # Слоты кандидатов: реплики раньше writer'а; --force (ручной запуск) — без слота.
    if [[ "$force" != "--force" ]]; then
        local slot=$((DB_RANK * DB_STAGGER))
        [[ $slot -gt 0 ]] && { log "db: кандидат rank=${DB_RANK} — жду слот ${slot}с..."; sleep "$slot"; }
        if _mc stat "$marker" >/dev/null 2>&1; then
            log "db: копия за ${DATE_TAG} уже сделана другим кандидатом — выход."
            return 0
        fi
    fi

    # Только синхронизированная нода: бэкап отстающей = тихо битая копия.
    local st; st=$(_wsrep_state)
    [[ "$st" == "Synced" ]] || { log "db: состояние '${st:-нет mysql}' != Synced — пропуск."; return 1; }

    local dst="${ALIAS}/${BUCKET}/db/${DATE_TAG}/${SELF_NODE}.xbstream.gz"
    mkdir -p "$XB_TMP"
    log "db: wsrep_desync=ON, xtrabackup → ${dst}"
    _desync ON || { log "db: не удалось включить desync — стоп."; return 1; }
    # desync ОБЯЗАН сняться при любом исходе (иначе нода навсегда вне flow control)
    trap '_desync OFF' EXIT

    local t0=$SECONDS rc=0
    # --galera-info пишет wsrep-позицию (нужна при восстановлении кластера)
    if xtrabackup --backup --stream=xbstream --galera-info \
            --target-dir="$XB_TMP" 2>>"$LOG_FILE" \
        | gzip -1 \
        | _mc pipe "$dst" 2>>"$LOG_FILE"; then
        printf 'node=%s date=%s duration=%ss\n' "$SELF_NODE" "$DATE_TAG" "$((SECONDS - t0))" \
            | _mc pipe "$marker" 2>>"$LOG_FILE"
        log "db: ок за $((SECONDS - t0))с ($(_mc stat "$dst" 2>/dev/null | sed -n 's/^Size *: *//p' | head -1))"
    else
        rc=1
        log "db: ОШИБКА xtrabackup/выгрузки (см. ${LOG_FILE}); маркер НЕ ставлю."
    fi
    _desync OFF; trap - EXIT
    rm -rf "$XB_TMP"
    return $rc
}

# ──── files: код портала с ТЕКУЩЕГО источника lsyncd ─────────────────────────
backup_files() {
    local force="${1:-}"
    [[ "$ROLE" == "web" ]] || { log "files: нода не web — пропуск."; return 0; }
    _require_tools || return 1

    # Источник lsyncd = у кого active lsyncd (тот же признак, что lsyncd_role status).
    if [[ "$(systemctl is-active lsyncd 2>/dev/null)" != "active" && "$force" != "--force" ]]; then
        log "files: эта нода не источник lsyncd — пропуск (бэкапит источник)."
        return 0
    fi

    local marker="${ALIAS}/${BUCKET}/files/${DATE_TAG}.done"
    if [[ "$force" != "--force" ]] && _mc stat "$marker" >/dev/null 2>&1; then
        log "files: копия за ${DATE_TAG} уже есть — выход."
        return 0
    fi

    # Исключения = списку lsyncd (кэш per-node, /upload уже в S3).
    local dst="${ALIAS}/${BUCKET}/www"
    log "files: mirror ${SITE_PATH} → ${dst} (история — versioning бакета)"
    local t0=$SECONDS
    # Маркер — часть условия успеха: mc mirror умеет выходить с кодом 0 при
    # частичных ошибках записи (ловили вживую), а заливка маркера — честная
    # проверка, что доступ на запись в бакет действительно работает.
    if _mc mirror --overwrite --remove \
        --exclude "upload/*" \
        --exclude "bitrix/cache/*" \
        --exclude "bitrix/managed_cache/*" \
        --exclude "bitrix/stack_cache/*" \
        --exclude "bitrix/html_pages/*" \
        --exclude "bitrix/tmp/*" \
        --exclude "bitrix/backup/*" \
        --exclude "*.tmp" \
        --exclude ".git/*" \
        "$SITE_PATH" "$dst" 2>>"$LOG_FILE" \
        && printf 'node=%s date=%s duration=%ss\n' "$SELF_NODE" "$DATE_TAG" "$((SECONDS - t0))" \
            | _mc pipe "$marker" 2>>"$LOG_FILE"; then
        log "files: ок за $((SECONDS - t0))с."
    else
        log "files: ОШИБКА mirror/маркера (см. ${LOG_FILE})."
        return 1
    fi
}

# ──── status: последние копии (для меню 13; формат key|...) ──────────────────
status() {
    _require_tools || return 1
    echo "conf|$(_mc ls "${ALIAS}/${BUCKET}/conf/${SELF_NODE}/" 2>/dev/null | tail -1 | tr -s ' ')"
    echo "db|$(_mc ls "${ALIAS}/${BUCKET}/db/" 2>/dev/null | tail -1 | tr -s ' ')"
    echo "files_marker|$(_mc ls "${ALIAS}/${BUCKET}/files/" 2>/dev/null | tail -1 | tr -s ' ')"
    echo "www_size|$(_mc du "${ALIAS}/${BUCKET}/www" 2>/dev/null | tr -s ' ')"
    return 0
}

case "${1:-}" in
    --conf)   backup_conf ;;
    --db)     shift; backup_db "${1:-}" ;;
    --files)  shift; backup_files "${1:-}" ;;
    --status) status ;;
    *) echo "usage: $0 {--conf|--db [--force]|--files [--force]|--status}" >&2; exit 2 ;;
esac
