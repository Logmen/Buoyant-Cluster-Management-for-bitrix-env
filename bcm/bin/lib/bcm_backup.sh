#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181,SC2206
# =============================================================================
# bcm_backup.sh — резервное копирование кластера с учётом HA.
#
# Хранилище выбирается параметром BACKUP_TARGET в backup.env:
#   s3   — бакет MinIO/совместимого хранилища (versioning + lifecycle);
#   nfs  — смонтированный сетевой каталог.
# Различия, о которых нужно помнить при выборе:
#   • S3 сам чистит старое по lifecycle бакета; для NFS ротацию делаем мы
#     (`--prune`, по RETENTION_DAYS), поэтому таймеры её и вызывают.
#   • История правок на S3 — versioning бакета. На NFS его нет, поэтому копия
#     кода портала кладётся ДАТИРОВАННЫМИ снимками через rsync --link-dest:
#     неизменившиеся файлы связываются жёсткими ссылками, место занимает только
#     разница. Это возвращает свойство, ради которого на S3 включён versioning —
#     удаление в портале не уничтожает вчерашнюю копию.
#   • ⚠️ Перед записью на NFS проверяется, что каталог РЕАЛЬНО является точкой
#     монтирования. Иначе отвалившийся NFS превращает бэкап в тихую заливку
#     копий на системный диск ноды до его переполнения.
#
# Запускается systemd-таймерами НА нодах,
# привязки к конкретной ноде нет — только к РОЛИ в момент запуска:
#
#   --conf   на КАЖДОЙ ноде: tar конфигов/состояния (cluster.conf, серты,
#            acme-учётка, .settings.php, proxysql.db…) → openssl enc → S3.
#            Внутри секреты, поэтому ШИФРУЕТСЯ (aes-256, ключ в backup.env).
#   --db     на PXC-нодах: xtrabackup --stream | gzip → хранилище.
#            HA-гейты: (1) только Synced; (2) кандидаты упорядочены — реплики
#            раньше writer'а, стартовый sleep RANK*STAGGER разводит их во
#            времени; (3) идемпотентный маркер db/<дата>/.done в S3 — кто
#            успел, тот и сделал, остальные выходят (упал штатный бэкапер —
#            следующий кандидат подхватит; худший случай гонки — безвредный
#            дубль); (4) wsrep_desync=ON на время бэкапа, иначе flow control
#            Galera тормозит ВЕСЬ кластер (сброс по trap при любом исходе).
#   --files  на web-нодах: только ТЕКУЩИЙ источник lsyncd (lsyncd active —
#            тот же признак, что в lsyncd_role.sh) → копия кода в хранилище.
#            Защита от rm -rf: на S3 — versioning бакета, на NFS — датированные
#            снимки (lsyncd — репликация, НЕ бэкап: удаление разъезжается).
#            ⚠️ /upload исключён: при развёрнутом S3 он уже лежит в бакете
#            bitrix-upload. В кластере БЕЗ S3 (файлы на дисках web-нод) его
#            нужно бэкапить отдельно — сюда он не попадает.
#   --prune  ротация по RETENTION_DAYS (нужна только для nfs).
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
XB_PARALLEL="${XB_PARALLEL:-2}"           # потоки копирования файлов xtrabackup
XB_GZ_THREADS="${XB_GZ_THREADS:-3}"       # потоки pigz (если установлен); gzip -1 — фолбэк
XB_LOG_DIR="${XB_LOG_DIR:-/var/log/bcm}"  # вывод xtrabackup — отдельным файлом, не в backup.log

ALIAS="bcmbk"
DATE_TAG="$(date +%Y-%m-%d)"

# ──── Выбор хранилища ────────────────────────────────────────────────────────
BACKUP_TARGET="${BACKUP_TARGET:-s3}"          # s3 | nfs
NFS_SERVER="${NFS_SERVER:-}"                  # хост NFS (пусто = каталог монтируют вне BCM)
NFS_EXPORT="${NFS_EXPORT:-}"                  # экспортируемый путь на сервере
NFS_MOUNT="${NFS_MOUNT:-/mnt/bcm-backup}"     # точка монтирования на ноде
# hard+intr: при недоступности сервера операция ждёт, а не отдаёт битую копию;
# _netdev откладывает монтирование до поднятия сети.
NFS_OPTIONS="${NFS_OPTIONS:-rw,hard,timeo=600,retrans=2,noatime,_netdev}"
NFS_SUBDIR="${NFS_SUBDIR:-}"                  # подкаталог под кластер (напр. имя портала)

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
# ⚠️ MC_QUIET=true, а не только --quiet: флаг НЕ глушит прогресс-метр у `mc pipe`
# (проверено вживую на mc 2025+) — счётчик байтов уходил в backup.log сотнями
# килобайт CR-строк на каждую копию БД. Env гасит его, ошибки остаются видны.
_mc() { MC_QUIET=true "$MC_BIN" --quiet "$@"; }

_mc_setup() {
    _mc ls "${ALIAS}/" >/dev/null 2>&1 && return 0
    printf '%s\n%s\n' "$S3_ACCESS" "$S3_SECRET" \
        | "$MC_BIN" --quiet alias set "$ALIAS" "$S3_ENDPOINT" >/dev/null 2>&1
    _mc ls "${ALIAS}/" >/dev/null 2>&1 \
        || { log "ОШИБКА: mc alias ${ALIAS} → ${S3_ENDPOINT} не работает (креды/доступность S3?)."; return 1; }
}

# ──── NFS: монтирование и проверка ──────────────────────────────────────────
# ⚠️ Ключевая проверка — mountpoint. Без неё отвалившийся или несмонтированный
# NFS означает запись копий в обычный каталог системного диска: место кончится
# молча, а оператор будет уверен, что бэкапы уезжают на хранилище.
_nfs_setup() {
    if ! mountpoint -q "$NFS_MOUNT" 2>/dev/null; then
        if [[ -z "$NFS_SERVER" || -z "$NFS_EXPORT" ]]; then
            log "ОШИБКА: ${NFS_MOUNT} не смонтирован, а NFS_SERVER/NFS_EXPORT не заданы."
            return 1
        fi
        mkdir -p "$NFS_MOUNT"
        log "nfs: монтирую ${NFS_SERVER}:${NFS_EXPORT} → ${NFS_MOUNT}"
        mount -t nfs -o "$NFS_OPTIONS" "${NFS_SERVER}:${NFS_EXPORT}" "$NFS_MOUNT" 2>>"$LOG_FILE" \
            || { log "ОШИБКА: не удалось смонтировать NFS."; return 1; }
    fi
    mountpoint -q "$NFS_MOUNT" 2>/dev/null \
        || { log "ОШИБКА: ${NFS_MOUNT} не является точкой монтирования — запись отменена."; return 1; }
    # Право на запись проверяем делом, а не по флагам: экспорт может быть ro.
    local probe="${NFS_MOUNT}/.bcm-write-probe.$$"
    if ! ( : > "$probe" ) 2>/dev/null; then
        log "ОШИБКА: нет записи в ${NFS_MOUNT} (экспорт только для чтения?)."
        return 1
    fi
    rm -f "$probe"
    return 0
}

# Корень хранилища для NFS: точка монтирования + необязательный подкаталог.
_nfs_root() { printf '%s' "${NFS_MOUNT}${NFS_SUBDIR:+/$NFS_SUBDIR}"; }

# ⚠️ Умеет ли экспорт менять владельца — проверяем делом, как и запись выше.
# Сетевые хранилища обычно сквошат root (root_squash/all_squash): файлы создаются
# под фиксированным uid, а chown запрещён. `rsync -a` владельца переносит ВСЕГДА,
# поэтому на таком экспорте он возвращает 23 при фактически скопированном дереве —
# и копия ночь за ночью считалась бы неуспешной (маркер не выставляется).
_nfs_can_chown() {
    local probe="${1}/.bcm-chown-probe.$$" rc=1
    ( : > "$probe" ) 2>/dev/null || return 1
    chown 0:0 "$probe" 2>/dev/null && rc=0
    rm -f "$probe"
    return $rc
}

_require_tools() {
    case "$BACKUP_TARGET" in
        s3)
            [[ -x "$MC_BIN" ]] || { log "ОШИБКА: ${MC_BIN} не найден (MinIO Client)."; return 1; }
            [[ -n "$S3_ENDPOINT" && -n "$S3_ACCESS" && -n "$S3_SECRET" ]] \
                || { log "ОШИБКА: S3-параметры не заданы в ${ENV_FILE}."; return 1; }
            _mc_setup || return 1
            ;;
        nfs)
            command -v rsync >/dev/null 2>&1 || { log "ОШИБКА: rsync не установлен."; return 1; }
            _nfs_setup || return 1
            ;;
        *)  log "ОШИБКА: неизвестный BACKUP_TARGET='${BACKUP_TARGET}' (ожидается s3 или nfs)."; return 1 ;;
    esac
    return 0
}

# ──── Операции над хранилищем (одинаковый интерфейс для s3 и nfs) ───────────
# Путь всюду ОТНОСИТЕЛЬНЫЙ: conf/<нода>/<дата>.tar.gz.enc и т.п.

# stdin → объект/файл
_bk_put() {
    local rel="$1"
    if [[ "$BACKUP_TARGET" == "s3" ]]; then
        _mc pipe "${ALIAS}/${BUCKET}/${rel}"
    else
        local dst; dst="$(_nfs_root)/${rel}"
        mkdir -p "$(dirname "$dst")" || return 1
        cat > "$dst"
    fi
}

# Содержимое объекта/файла (маленького) в stdout.
_bk_cat() {
    local rel="$1"
    if [[ "$BACKUP_TARGET" == "s3" ]]; then
        _mc cat "${ALIAS}/${BUCKET}/${rel}" 2>/dev/null
    else
        cat "$(_nfs_root)/${rel}" 2>/dev/null
    fi
}

_bk_exists() {
    local rel="$1"
    if [[ "$BACKUP_TARGET" == "s3" ]]; then
        _mc stat "${ALIAS}/${BUCKET}/${rel}" >/dev/null 2>&1
    else
        [[ -e "$(_nfs_root)/${rel}" ]]
    fi
}

_bk_size() {
    local rel="$1"
    if [[ "$BACKUP_TARGET" == "s3" ]]; then
        _mc stat "${ALIAS}/${BUCKET}/${rel}" 2>/dev/null | sed -n 's/^Size *: *//p' | head -1
    else
        du -h "$(_nfs_root)/${rel}" 2>/dev/null | awk '{print $1}'
    fi
}

# Объём каталога-префикса (не объекта). ⚠️ mc stat по префиксу пуст — это не
# объект, размер считает mc du. ⚠️⚠️ ВЫЗЫВАТЬ ТОЛЬКО в backup_files: du обходит
# ВСЕ объекты префикса (на 300k файлов портала — минуты) и в --status ему не
# место: статус читает зонд bcm-portal с бюджетом в секунды, и медленный ответ
# рушит сбор метрик всей ноды. Поэтому размер считается раз в сутки после
# зеркалирования и кладётся в files/last.size, а --status его просто читает.
_bk_dir_size() {
    local rel="$1"
    if [[ "$BACKUP_TARGET" == "s3" ]]; then
        _mc du "${ALIAS}/${BUCKET}/${rel}" 2>/dev/null | tail -1 | awk '{print $1}'
    else
        du -sh "$(_nfs_root)/${rel}" 2>/dev/null | awk '{print $1}'
    fi
}

# Последняя запись под префиксом. ⚠️ Второй аргумент 'r' — рекурсивно, и он
# ОБЯЗАТЕЛЕН там, где под префиксом лежат каталоги (db/<дата>/): нерекурсивный
# листинг вернул бы саму «папку», а её время mc подставляет ТЕКУЩЕЕ — портал
# показывал бы свежую копию БД всегда, даже если её не делали неделю.
_bk_list() {
    local rel="$1" mode="${2:-}"
    if [[ "$BACKUP_TARGET" == "s3" ]]; then
        if [[ "$mode" == "r" ]]; then
            _mc ls --recursive "${ALIAS}/${BUCKET}/${rel}" 2>/dev/null | tail -1 | tr -s ' '
        else
            _mc ls "${ALIAS}/${BUCKET}/${rel}" 2>/dev/null | tail -1 | tr -s ' '
        fi
    else
        local d; d="$(_nfs_root)/${rel}"
        [[ -d "$d" ]] || return 0
        if [[ "$mode" == "r" ]]; then
            find "$d" -type f -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' 2>/dev/null | sort -r | head -1
        else
            ls -1t "$d" 2>/dev/null | head -1
        fi
    fi
}

# Зеркало каталога. На S3 — mc mirror в один префикс (история = versioning),
# на NFS — датированный снимок с жёсткими ссылками на предыдущий (история есть,
# место занимает только разница).
_bk_mirror_site() {
    local src="$1"; shift
    local -a ex=("$@")
    if [[ "$BACKUP_TARGET" == "s3" ]]; then
        local -a mcex=(); local e
        for e in "${ex[@]}"; do mcex+=(--exclude "$e"); done
        _mc mirror --overwrite --remove "${mcex[@]}" "$src" "${ALIAS}/${BUCKET}/www" 2>>"$LOG_FILE"
    else
        local root; root="$(_nfs_root)/www"
        local dst="${root}/${DATE_TAG}"
        mkdir -p "$root" || return 1
        # Предыдущий снимок — донор жёстких ссылок.
        local prev; prev=$(ls -1 "$root" 2>/dev/null | grep -vx "$DATE_TAG" | sort | tail -1)
        local -a rex=(); local e
        for e in "${ex[@]}"; do rex+=(--exclude "$e"); done
        local -a link=()
        [[ -n "$prev" ]] && link=(--link-dest="../${prev}")
        # Где владельца сменить нельзя — переносим без него: права, время и симлинки
        # сохраняются, владельца выставляет восстановление (chown -R bitrix:bitrix).
        local -a own=()
        _nfs_can_chown "$root" || own=(--no-owner --no-group)
        rsync -a "${own[@]}" --delete "${rex[@]}" "${link[@]}" "${src}/" "${dst}/" 2>>"$LOG_FILE"
    fi
}

# Ротация (только NFS: на S3 её делает lifecycle бакета).
prune() {
    [[ "$BACKUP_TARGET" == "nfs" ]] || { log "prune: цель ${BACKUP_TARGET} чистится сама (lifecycle) — пропуск."; return 0; }
    _require_tools || return 1
    local root; root="$(_nfs_root)"
    local n=0
    # conf/db — датированные артефакты, www — датированные каталоги-снимки.
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        rm -rf -- "$p" && n=$((n+1))
    done < <(
        find "${root}/conf" "${root}/db" -mindepth 1 -maxdepth 2 -mtime "+${RETENTION_DAYS}" -print 2>/dev/null
        find "${root}/www" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -print 2>/dev/null
    )
    log "prune: удалено устаревших копий: ${n} (старше ${RETENTION_DAYS} дней)"
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

    local rel="conf/${SELF_NODE}/${DATE_TAG}.tar.gz.enc"
    log "conf: ${#paths[@]} путей → ${BACKUP_TARGET}:${rel}"
    export BCM_ENC_KEY="$ENC_KEY"
    if tar -czf - "${paths[@]}" 2>>"$LOG_FILE" \
        | openssl enc -aes-256-cbc -pbkdf2 -pass env:BCM_ENC_KEY 2>>"$LOG_FILE" \
        | _bk_put "$rel" 2>>"$LOG_FILE"; then
        log "conf: ок ($(_bk_size "$rel"))"
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

    local marker="db/${DATE_TAG}/.done"

    # Слоты кандидатов: реплики раньше writer'а; --force (ручной запуск) — без слота.
    if [[ "$force" != "--force" ]]; then
        local slot=$((DB_RANK * DB_STAGGER))
        [[ $slot -gt 0 ]] && { log "db: кандидат rank=${DB_RANK} — жду слот ${slot}с..."; sleep "$slot"; }
        if _bk_exists "$marker"; then
            log "db: копия за ${DATE_TAG} уже сделана другим кандидатом — выход."
            return 0
        fi
    fi

    # Только синхронизированная нода: бэкап отстающей = тихо битая копия.
    local st; st=$(_wsrep_state)
    [[ "$st" == "Synced" ]] || { log "db: состояние '${st:-нет mysql}' != Synced — пропуск."; return 1; }

    local rel="db/${DATE_TAG}/${SELF_NODE}.xbstream.gz"
    mkdir -p "$XB_TMP" "$XB_LOG_DIR"
    # ⚠️ Вывод xtrabackup (сотни строк за прогон, на боевом узле — тысячи за неделю) —
    # в СВОЙ файл: backup.log читают по строкам «db: ок» и меню 13, и зонд портала,
    # чужой шум там мешает и раздувает ротацию.
    local xb_log="${XB_LOG_DIR}/xtrabackup-${DATE_TAG}.log"
    # pigz жмёт в несколько потоков тем же форматом gzip: на многоядерном узле копия
    # снимается в 2–3 раза быстрее при том же размере. Узел на это время в desync,
    # соседей мы не тормозим. Нет pigz — прежний однопоточный gzip.
    local -a gz=(gzip -1)
    command -v pigz >/dev/null 2>&1 && gz=(pigz -1 -p "$XB_GZ_THREADS")
    log "db: wsrep_desync=ON, xtrabackup → ${BACKUP_TARGET}:${rel} ($(basename "${gz[0]}"), parallel=${XB_PARALLEL})"
    _desync ON || { log "db: не удалось включить desync — стоп."; return 1; }
    # desync ОБЯЗАН сняться при любом исходе (иначе нода навсегда вне flow control)
    trap '_desync OFF' EXIT

    local t0=$SECONDS rc=0
    # --galera-info пишет wsrep-позицию (нужна при восстановлении кластера)
    if xtrabackup --backup --stream=xbstream --galera-info \
            --parallel="$XB_PARALLEL" \
            --target-dir="$XB_TMP" 2>>"$xb_log" \
        | "${gz[@]}" \
        | _bk_put "$rel" 2>>"$LOG_FILE"; then
        printf 'node=%s date=%s duration=%ss\n' "$SELF_NODE" "$DATE_TAG" "$((SECONDS - t0))" \
            | _bk_put "$marker" 2>>"$LOG_FILE"
        log "db: ок за $((SECONDS - t0))с ($(_bk_size "$rel"))"
    else
        rc=1
        log "db: ОШИБКА xtrabackup/выгрузки (см. ${xb_log}); маркер НЕ ставлю."
    fi
    _desync OFF; trap - EXIT
    rm -rf "$XB_TMP"
    # Логи xtrabackup живут не дольше самих копий.
    find "$XB_LOG_DIR" -maxdepth 1 -name 'xtrabackup-*.log' -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null
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

    local marker="files/${DATE_TAG}.done"
    if [[ "$force" != "--force" ]] && _bk_exists "$marker"; then
        log "files: копия за ${DATE_TAG} уже есть — выход."
        return 0
    fi

    # ⚠️⚠️ upload/* исключается всегда, но «он уже в S3» верно ЛИШЬ когда файлы
    # действительно уехали в бакет. При узких FILE_RULES или кластере без хранилища
    # /upload остаётся на дисках — и тогда это единственное, что не попадает НИ В ОДНУ
    # копию: зеркало lsyncd не бэкап (удаление разъезжается, шифровальщик доедет до
    # обеих нод). Молчать об этом нельзя — пишем в лог и в --status.
    if [[ -d "${SITE_PATH}/upload" ]] && [[ -n "$(find "${SITE_PATH}/upload" -mindepth 2 -type f -print -quit 2>/dev/null)" ]]; then
        local up_size; up_size=$(du -sh "${SITE_PATH}/upload" 2>/dev/null | cut -f1)
        log "files: ВНИМАНИЕ — ${SITE_PATH}/upload (${up_size:-?}) лежит на диске и в копию НЕ входит; защищён только зеркалом lsyncd."
        printf '%s\n' "${up_size:-?}" | _bk_put "meta/upload_on_disk" 2>>"$LOG_FILE" || true
    elif _bk_exists "meta/upload_on_disk"; then
        printf '' | _bk_put "meta/upload_on_disk" 2>>"$LOG_FILE" || true
    fi

    # Исключения = списку lsyncd (кэш per-node, /upload уже в S3).
    log "files: копия ${SITE_PATH} → ${BACKUP_TARGET}:www ($([[ "$BACKUP_TARGET" == s3 ]] && echo 'история — versioning бакета' || echo "снимок ${DATE_TAG}, ссылки на предыдущий"))"
    local t0=$SECONDS
    # Маркер — часть условия успеха: mc mirror умеет выходить с кодом 0 при
    # частичных ошибках записи (ловили вживую), а заливка маркера — честная
    # проверка, что доступ на запись в бакет действительно работает.
    if _bk_mirror_site "$SITE_PATH" \
        "upload/*" "bitrix/cache/*" "bitrix/managed_cache/*" "bitrix/stack_cache/*" \
        "bitrix/html_pages/*" "bitrix/tmp/*" "bitrix/backup/*" "*.tmp" ".git/*" \
        && printf 'node=%s date=%s duration=%ss\n' "$SELF_NODE" "$DATE_TAG" "$((SECONDS - t0))" \
            | _bk_put "$marker" 2>>"$LOG_FILE"; then
        # Кэш объёма копии для --status (портал показывает его в разделе копий):
        # пересчитывать на каждый статус нельзя — du обходит все объекты.
        # ⚠️ НЕ в files/: там лежат маркеры дней, а _bk_list берёт последний по
        # алфавиту — посторонний объект подменил бы собой маркер свежей копии.
        _bk_dir_size "www" | _bk_put "meta/www_size" 2>>"$LOG_FILE" || true
        log "files: ок за $((SECONDS - t0))с."
    else
        log "files: ОШИБКА mirror/маркера (см. ${LOG_FILE})."
        return 1
    fi
}

# ──── status: последние копии (для меню 13; формат key|...) ──────────────────
status() {
    _require_tools || return 1
    echo "target|${BACKUP_TARGET}$([[ "$BACKUP_TARGET" == nfs ]] && echo " ($(_nfs_root))")"
    echo "conf|$(_bk_list "conf/${SELF_NODE}/")"
    echo "db|$(_bk_list "db/" r)"
    echo "files_marker|$(_bk_list "files/")"
    # Размер копии кода — из кэша, записанного последним backup_files (одно GET),
    # а не пересчётом: --status зовёт зонд портала раз в минуту.
    echo "www_size|$(_bk_cat "meta/www_size" | tr -d '[:space:]')"
    # Непустое значение = /upload лежит на дисках узлов и вне копий (см. backup_files).
    echo "upload_on_disk|$(_bk_cat "meta/upload_on_disk" | tr -d '[:space:]')"
    return 0
}

case "${1:-}" in
    --conf)   backup_conf ;;
    --db)     shift; backup_db "${1:-}" ;;
    --files)  shift; backup_files "${1:-}" ;;
    --status) status ;;
    --prune)  prune ;;
    *) echo "usage: $0 {--conf|--db [--force]|--files [--force]|--prune|--status}" >&2; exit 2 ;;
esac
