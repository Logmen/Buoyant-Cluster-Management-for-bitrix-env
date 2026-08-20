#!/usr/bin/env bash
# shellcheck disable=SC2155
# =============================================================================
# portal_export.sh — упаковка портала bitrix-env с ОДИНОЧНОГО сервера для
# переноса в кластер BCM (закрытый контур клиента).
#
# Запускается НА ИСХОДНОМ сервере под root. Ничего не меняет: читает дерево
# портала и базу, складывает артефакты в отдельный каталог. Формат — zstd
# (tar -I zstd), потоком, без промежуточных несжатых копий.
#
# На выходе (в --out):
#   files.tar.zst      дерево портала без кэша и временных файлов
#   db-<имя>.sql.zst   дамп базы (single-transaction, с процедурами/триггерами)
#   system.tar.zst     системный контекст: vhost'ы, php.ini, cron, сертификаты
#   conflicts/         файлы, которые в кластере принадлежат BCM (см. REPORT.md)
#   MANIFEST.txt       версии, размеры, sha256 артефактов
#   REPORT.md          что обнаружено на источнике и что доделать после импорта
#
# ⚠️ Артефакты содержат СЕКРЕТЫ (реквизиты БД в .settings.php, пароли SMTP,
# приватные ключи сертификатов). Каталог создаётся с правами 0700, файлы 0600 —
# передавайте защищённым каналом.
#
#   bash portal_export.sh --dry-run
#   bash portal_export.sh --out /var/backups/portal-export
# =============================================================================
set -euo pipefail

DOC_ROOT=""
OUT=""
DB_NAME=""
ZLEVEL=10
THREADS=0
DO_FILES=1
DO_DB=1
DO_SYSTEM=1
WITH_CACHE=0
DRY_RUN=0

usage() {
    cat <<'USAGE'
portal_export.sh — упаковка портала bitrix-env для переноса в кластер BCM.

  -o, --out DIR        каталог для артефактов (по умолчанию /var/backups/portal-export-<дата>)
  -r, --doc-root DIR   корень портала (по умолчанию определяется автоматически)
  -d, --db NAME        имя базы (по умолчанию — из .settings.php)
  -l, --level N        уровень сжатия zstd 1..19 (по умолчанию 10)
  -T, --threads N      потоков zstd (по умолчанию по числу ядер)
      --with-cache     не исключать кэш портала (обычно НЕ нужно)
      --no-files       не паковать дерево портала
      --no-db          не снимать дамп базы
      --no-system      не паковать системный контекст
  -n, --dry-run        только показать, что будет упаковано, и оценить размеры
  -h, --help           эта справка
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--out)       OUT="${2:-}"; shift 2 ;;
        -r|--doc-root)  DOC_ROOT="${2:-}"; shift 2 ;;
        -d|--db)        DB_NAME="${2:-}"; shift 2 ;;
        -l|--level)     ZLEVEL="${2:-}"; shift 2 ;;
        -T|--threads)   THREADS="${2:-}"; shift 2 ;;
        --with-cache)   WITH_CACHE=1; shift ;;
        --no-files)     DO_FILES=0; shift ;;
        --no-db)        DO_DB=0; shift ;;
        --no-system)    DO_SYSTEM=0; shift ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then
    C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_B=$'\033[1m'; C_N=$'\033[0m'
else
    C_G=""; C_Y=""; C_R=""; C_B=""; C_N=""
fi
say()  { printf '%s==>%s %s\n' "$C_B" "$C_N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$C_Y" "$C_N" "$*"; }
die()  { printf '%sОшибка:%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "запускать под root (нужен доступ к дереву портала, БД и /etc)"
for t in tar zstd sha256sum du df awk sed; do
    command -v "$t" >/dev/null 2>&1 || die "нет утилиты '$t' (zstd ставится: dnf install zstd)"
done
(( THREADS > 0 )) || THREADS="$(nproc 2>/dev/null || echo 2)"

# ──── Корень портала ─────────────────────────────────────────────────────────
if [[ -z "$DOC_ROOT" ]]; then
    if [[ -x /opt/webdir/bin/bx-sites ]]; then
        DOC_ROOT="$(/opt/webdir/bin/bx-sites -a list -o json 2>/dev/null \
            | sed -n 's/.*"DocumentRoot":"\([^"]*\)".*/\1/p' | head -1)"
    fi
    [[ -z "$DOC_ROOT" && -d /home/bitrix/www ]] && DOC_ROOT="/home/bitrix/www"
fi
[[ -n "$DOC_ROOT" && -d "$DOC_ROOT" ]] || die "не найден корень портала (укажите --doc-root)"
SETTINGS="${DOC_ROOT}/bitrix/.settings.php"
[[ -f "$SETTINGS" ]] || die "нет ${SETTINGS} — это не корень портала Bitrix"

# ──── Реквизиты БД из .settings.php ──────────────────────────────────────────
# Пароль не печатается и не попадает в argv: читается в переменную и уходит
# в mysqldump через временный defaults-файл с правами 0600.
command -v php >/dev/null 2>&1 || die "нет php — не прочитать .settings.php"
_db_field() {
    php -r '$c=include $argv[1]; $d=$c["connections"]["value"]["default"] ?? []; echo $d[$argv[2]] ?? "";' \
        "$SETTINGS" "$1" 2>/dev/null
}
DB_HOST="$(_db_field host)"; DB_LOGIN="$(_db_field login)"; DB_PASS="$(_db_field password)"
[[ -n "$DB_NAME" ]] || DB_NAME="$(_db_field database)"
[[ -n "$DB_NAME" ]] || die "не удалось определить имя базы (укажите --db)"

MYCNF=""
# ⚠️ EXIT-trap обязан завершаться успешно: код его последней команды становится
# кодом возврата всего скрипта (иначе удачный экспорт рапортует об ошибке).
_cleanup() { [[ -n "$MYCNF" && -f "$MYCNF" ]] && rm -f "$MYCNF"; return 0; }
trap _cleanup EXIT
# Локальный root по сокету — если работает, реквизиты портала не нужны вовсе.
if mysql -e 'SELECT 1' >/dev/null 2>&1; then
    DB_AUTH="root-socket"
else
    MYCNF="$(mktemp /tmp/.bcmexp.XXXXXX)"; chmod 600 "$MYCNF"
    printf '[client]\nhost=%s\nuser=%s\npassword=%s\n' "$DB_HOST" "$DB_LOGIN" "$DB_PASS" > "$MYCNF"
    mysql --defaults-file="$MYCNF" -e 'SELECT 1' >/dev/null 2>&1 \
        || die "не подключиться к БД ни root-сокетом, ни реквизитами портала"
    DB_AUTH="portal-creds"
fi
_mysql()     { if [[ -n "$MYCNF" ]]; then mysql --defaults-file="$MYCNF" "$@"; else mysql "$@"; fi; }
_mysqldump() { if [[ -n "$MYCNF" ]]; then mysqldump --defaults-file="$MYCNF" "$@"; else mysqldump "$@"; fi; }

# ──── Что исключаем из дерева ────────────────────────────────────────────────
# Кэш и временные файлы: на приёмнике регенерируются, а per-node кэш в кластере
# ещё и вреден (сбивает инвалидацию по тегам). Пути — относительно корня портала.
EXCLUDES=(
    "bitrix/cache" "bitrix/managed_cache" "bitrix/stack_cache" "bitrix/html_pages"
    "bitrix/tmp" "bitrix/backup" "bitrix/updates"
    "upload/resize_cache" "upload/tmp" "upload/.bx_temp"
)
(( WITH_CACHE )) && EXCLUDES=()

# ⚠️ Файлы подключения и кэша в кластере ПРИНАДЛЕЖАТ BCM и bitrix-env: у приёмника
# уже есть свои, указывающие на ProxySQL и redis-VIP. Файлы источника указывают на
# localhost и memcache, и, приехав поверх, тихо оторвали бы портал от кластера
# (.settings_extra.php накладывается ПОВЕРХ .settings.php без проверки readonly).
# Поэтому они не едут в общий архив, а откладываются в conflicts/ — не потеряны,
# но переносятся только осознанно, по значениям (см. REPORT.md).
CONFLICT_FILES=(
    "bitrix/.settings.php"
    "bitrix/.settings_extra.php"
    "bitrix/php_interface/dbconn.php"
)

# ──── Каталог вывода ─────────────────────────────────────────────────────────
STAMP="$(date +%Y%m%d-%H%M%S)"
[[ -n "$OUT" ]] || OUT="/var/backups/portal-export-${STAMP}"
FILES_TAR="${OUT}/files.tar.zst"
DB_DUMP="${OUT}/db-${DB_NAME}.sql.zst"
SYS_TAR="${OUT}/system.tar.zst"

# ──── Оценка объёмов ─────────────────────────────────────────────────────────
# ⚠️ Под `set -o pipefail` справочные команды нельзя звать «голыми»: du на живом
# дереве спотыкается об исчезнувший файл кэша, df — об ещё не созданный каталог,
# и ненулевой код убил бы весь экспорт на этапе оценки.
_kb() { local v; v="$(du -sk "$1" 2>/dev/null | awk '{print $1; exit}')" || true; echo "${v:-0}"; }
_avail_kb() {   # свободно в ближайшем СУЩЕСТВУЮЩЕМ родителе пути
    local d="$1" v
    while [[ -n "$d" && ! -d "$d" ]]; do d="$(dirname "$d")"; done
    v="$(df -Pk "${d:-/}" 2>/dev/null | awk 'NR==2{print $4; exit}')" || true
    echo "${v:-0}"
}
say "Источник"
echo "  корень портала : $DOC_ROOT"
echo "  база           : $DB_NAME (доступ: $DB_AUTH)"
echo "  каталог вывода : $OUT"

raw_kb="$(_kb "$DOC_ROOT")"
skip_kb=0
for e in "${EXCLUDES[@]}"; do
    [[ -e "${DOC_ROOT}/${e}" ]] || continue
    skip_kb=$(( skip_kb + $(_kb "${DOC_ROOT}/${e}") ))
done
pack_kb=$(( raw_kb - skip_kb ))
db_mb="$(_mysql -N -B -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,1) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo '?')"
avail_kb="$(_avail_kb "$OUT")"

printf '  дерево портала : %s (исключается кэш/временное: %s → пакуется %s)\n' \
    "$(numfmt --to=iec --from-unit=1024 "$raw_kb" 2>/dev/null || echo "${raw_kb}K")" \
    "$(numfmt --to=iec --from-unit=1024 "$skip_kb" 2>/dev/null || echo "${skip_kb}K")" \
    "$(numfmt --to=iec --from-unit=1024 "$pack_kb" 2>/dev/null || echo "${pack_kb}K")"
printf '  база           : %s МБ\n' "$db_mb"
printf '  свободно       : %s\n' "$(numfmt --to=iec --from-unit=1024 "${avail_kb:-0}" 2>/dev/null || echo '?')"

# Запас: архив дерева обычно ужимается вдвое и лучше, но считаем консервативно.
need_kb=$(( pack_kb / 2 + 512*1024 ))
if (( avail_kb < need_kb )); then
    warn "свободного места может не хватить (нужно ориентировочно $(numfmt --to=iec --from-unit=1024 $need_kb 2>/dev/null))"
fi

if (( DRY_RUN )); then
    say "Будет упаковано (dry-run)"
    (( DO_FILES ))  && echo "  $FILES_TAR"
    (( DO_DB ))     && echo "  $DB_DUMP"
    (( DO_SYSTEM )) && echo "  $SYS_TAR"
    echo "  ${OUT}/{MANIFEST.txt,REPORT.md,conflicts/}"
    say "Исключения дерева"
    for e in "${EXCLUDES[@]}"; do [[ -e "${DOC_ROOT}/${e}" ]] && echo "  $e"; done
    exit 0
fi

mkdir -p "$OUT/conflicts"; chmod 700 "$OUT"
ZSTD_OPTS=(-"${ZLEVEL}" -T"${THREADS}" -q)

# ──── Дамп базы ──────────────────────────────────────────────────────────────
# --single-transaction: снимок без блокировок (InnoDB), портал продолжает работать.
# --set-gtid-purged=OFF и --skip-add-locks: импорт в PXC (strict mode запрещает
# LOCK TABLES, а GTID-строка ломает загрузку в Galera).
if (( DO_DB )); then
    say "Дамп базы ${DB_NAME}"
    set +e
    _mysqldump --single-transaction --quick --routines --triggers --events \
        --set-gtid-purged=OFF --skip-add-locks --no-tablespaces \
        --default-character-set=utf8mb4 --hex-blob "$DB_NAME" \
        | zstd "${ZSTD_OPTS[@]}" -o "$DB_DUMP"
    rc=("${PIPESTATUS[@]}")
    set -e
    [[ "${rc[0]}" == "0" ]] || die "mysqldump завершился с кодом ${rc[0]} — дамп неполный"
    [[ "${rc[1]}" == "0" ]] || die "zstd завершился с кодом ${rc[1]}"
    chmod 600 "$DB_DUMP"
    ok "$(basename "$DB_DUMP") — $(du -h "$DB_DUMP" | cut -f1)"
fi

# ──── Дерево портала ─────────────────────────────────────────────────────────
if (( DO_FILES )); then
    say "Упаковка дерева портала"
    for f in "${CONFLICT_FILES[@]}"; do
        [[ -f "${DOC_ROOT}/${f}" ]] || continue
        install -m 600 -D "${DOC_ROOT}/${f}" "${OUT}/conflicts/${f}"
        warn "$f отложен в conflicts/ (в кластере этот файл принадлежит BCM)"
    done
    tar_args=( --numeric-owner --acls --xattrs -C "$DOC_ROOT" )
    for e in "${EXCLUDES[@]}";      do tar_args+=( --exclude="./${e}" ); done
    for f in "${CONFLICT_FILES[@]}"; do tar_args+=( --exclude="./${f}" ); done
    tar -I "zstd ${ZSTD_OPTS[*]}" -cf "$FILES_TAR" "${tar_args[@]}" . \
        || die "tar завершился с ошибкой — архив дерева неполный"
    chmod 600 "$FILES_TAR"
    ok "$(basename "$FILES_TAR") — $(du -h "$FILES_TAR" | cut -f1)"
fi

# ──── Системный контекст ─────────────────────────────────────────────────────
# Не для наката «как есть» (в кластере всё это раскатывает install.sh/BCM), а
# чтобы не потерять настройки: лимиты php, кастомные vhost'ы, крон, сертификаты.
if (( DO_SYSTEM )); then
    say "Системный контекст"
    SYSDIR="${OUT}/.system"; rm -rf "$SYSDIR"; mkdir -p "$SYSDIR"
    for p in /etc/nginx/bx/site_settings /etc/nginx/bx/site_avaliable /etc/nginx/bx/site_enabled \
             /etc/nginx/nginx.conf /etc/httpd/bx /etc/httpd/conf.d /etc/php.d /etc/php.ini \
             /etc/my.cnf /etc/my.cnf.d /etc/crontab /etc/cron.d /etc/msmtprc /etc/postfix/main.cf \
             /etc/push-server /etc/hosts; do
        [[ -e "$p" ]] && { mkdir -p "${SYSDIR}$(dirname "$p")"; cp -a "$p" "${SYSDIR}${p}" 2>/dev/null || true; }
    done
    # Сертификаты (в кластере TLS терминирует HAProxy — pem пригодится, если в
    # закрытом контуре Let's Encrypt недоступен).
    for d in /home/bitrix/dehydrated/certs /etc/letsencrypt/live /etc/pki/tls/certs/portal; do
        [[ -d "$d" ]] && { mkdir -p "${SYSDIR}$(dirname "$d")"; cp -aL "$d" "${SYSDIR}${d}" 2>/dev/null || true; }
    done
    crontab -l -u bitrix > "${SYSDIR}/crontab.bitrix.txt" 2>/dev/null || true
    crontab -l -u root   > "${SYSDIR}/crontab.root.txt"   2>/dev/null || true
    tar -I "zstd ${ZSTD_OPTS[*]}" -cf "$SYS_TAR" -C "$SYSDIR" . || die "не собрать системный контекст"
    rm -rf "$SYSDIR"
    chmod 600 "$SYS_TAR"
    ok "$(basename "$SYS_TAR") — $(du -h "$SYS_TAR" | cut -f1)"
fi

# ──── Сведения об источнике ──────────────────────────────────────────────────
say "Сбор сведений об источнике"
( cd "$OUT" && sha256sum ./*.zst > SHA256SUMS 2>/dev/null ) || true
chmod 600 "${OUT}/SHA256SUMS" 2>/dev/null || true
MANIFEST="${OUT}/MANIFEST.txt"
{
    echo "portal_export — $(date '+%F %T %Z')"
    echo "хост:        $(hostname -f 2>/dev/null || hostname)"
    echo "ОС:          $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "корень:      $DOC_ROOT"
    echo "база:        $DB_NAME"
    echo
    echo "== Версии =="
    echo "Bitrix (SM_VERSION): $(sed -n 's/.*SM_VERSION",[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${DOC_ROOT}/bitrix/modules/main/classes/general/version.php" 2>/dev/null)"
    echo "PHP:    $(php -v 2>/dev/null | head -1 || true)"
    echo "MySQL:  $(mysql --version 2>/dev/null || true)"
    echo "nginx:  $(nginx -v 2>&1 | head -1 || true)"
    rpm -q bitrix-env 2>/dev/null || true
    echo
    echo "== Расширения PHP =="
    php -m 2>/dev/null | paste -sd' ' - || true
    echo
    echo "== Модули портала (bitrix/modules) =="
    ls "${DOC_ROOT}/bitrix/modules" 2>/dev/null | paste -sd' ' - || true
    echo
    echo "== Кастомные модули (local/modules) =="
    ls "${DOC_ROOT}/local/modules" 2>/dev/null | paste -sd' ' - || true
    echo
    echo "== Размеры =="
    du -sh "$DOC_ROOT" 2>/dev/null || true
    _mysql -N -B -e "SELECT CONCAT('база ${DB_NAME}: ', ROUND(SUM(data_length+index_length)/1024/1024,1), ' МБ, таблиц ', COUNT(*)) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || true
    echo
    echo "== Артефакты =="
    cat "${OUT}/SHA256SUMS" 2>/dev/null
} > "$MANIFEST"
chmod 600 "$MANIFEST"

# ──── Отчёт: что доделать после импорта ──────────────────────────────────────
# Пункты не абстрактные: каждый включается по факту, обнаруженному на источнике.
REPORT="${OUT}/REPORT.md"
cache_type="$(php -r '$c=@include $argv[1]; echo $c["cache"]["value"]["type"] ?? "";' "$SETTINGS" 2>/dev/null)"
[[ -z "$cache_type" ]] && cache_type="$(grep -oP 'BX_CACHE_TYPE"\s*,\s*"\K[^"]+' \
    "${DOC_ROOT}/bitrix/php_interface/dbconn.php" 2>/dev/null | head -1)"
buckets="$(_mysql -N -B -e "SELECT CONCAT(BUCKET,' (',SERVICE_ID,', активен: ',ACTIVE,', файлов: ',FILE_COUNT,')') FROM ${DB_NAME}.b_clouds_file_bucket;" 2>/dev/null || true)"
cloud_files="$(_mysql -N -B -e "SELECT CONCAT(SUM(HANDLER_ID IS NOT NULL),' из ',COUNT(*)) FROM ${DB_NAME}.b_file;" 2>/dev/null || true)"
usercron="$(crontab -l -u bitrix 2>/dev/null | grep -vcE '^\s*(#|$)' || true)"
agents="$(_mysql -N -B -e "SELECT COUNT(*) FROM ${DB_NAME}.b_agent WHERE ACTIVE='Y';" 2>/dev/null || true)"
{
    echo "# Перенос портала в кластер BCM — что доделать после импорта"
    echo
    echo "Источник: \`$(hostname -f 2>/dev/null || hostname)\`, корень \`$DOC_ROOT\`, база \`$DB_NAME\`."
    echo "Артефакты: \`files.tar.zst\`, \`db-${DB_NAME}.sql.zst\`, \`system.tar.zst\` (см. MANIFEST.txt)."
    echo
    echo "## Порядок импорта"
    echo
    echo '1. Развернуть кластер (`install.sh`) — портал ставить не нужно, дерево приедет из архива.'
    echo '2. Дерево распаковать на ИСТОЧНИК lsyncd (первая web-нода) в корень портала:'
    echo '   `tar -I zstd -xf files.tar.zst -C /home/bitrix/www` и вернуть владельца `chown -R bitrix:bitrix`.'
    echo '3. Базу залить на writer PXC (не через ProxySQL — быстрее и без правил роутинга):'
    echo '   `zstd -dc db-'"${DB_NAME}"'.sql.zst | mysql -h <writer> '"${DB_NAME}"'`.'
    echo '4. Переподключить портал на ProxySQL — это делает `install.sh` (`configure_portal_db`)'
    echo '   при повторном прогоне, либо вручную правкой `connections` в `.settings.php`.'
    echo '5. Выключить локальный `mysqld` на web-нодах и перезапустить ProxySQL, чтобы он занял'
    echo '   `127.0.0.1:3306` (иначе self-check bitrix-env валит сайт в статус `error`).'
    echo '6. Прогреть: очистить кэш портала, проверить «Проверку системы», запустить lsyncd-раздачу.'
    echo
    echo "## Обнаружено на источнике"
    echo
    if [[ -n "$cache_type" && "$cache_type" != "redis" ]]; then
        echo "- **Кэш: \`${cache_type}\`.** В кластере кэш общий — redis на плавающем CACHE_VIP."
        echo "  Настройки memcache из \`dbconn.php\` и \`.settings_extra.php\` переносить НЕЛЬЗЯ:"
        echo "  \`.settings_extra.php\` в кластере принадлежит BCM (слой наложений поверх"
        echo "  \`.settings.php\`), а посторонний блок кэша тихо победит кластерный."
        echo "  Файл источника отложен в \`conflicts/\` — сверьте и не копируйте поверх."
    fi
    if [[ -n "$buckets" ]]; then
        echo "- **Облачное хранилище подключено:**"
        echo "$buckets" | sed 's/^/    - /'
        echo "  В облаке ${cloud_files:-?} файлов. Если в закрытом контуре этот S3 недоступен,"
        echo "  файлы надо вернуть на диск (\`CCloudStorage::MoveFile\` в обратную сторону) и"
        echo "  деактивировать бакет — иначе картинки и документы отдадут 404."
        echo "  Если слоя S3 в кластере нет, \`/upload\` зеркалится между web-нодами (меню 6 → 10)."
    fi
    if [[ "${usercron:-0}" != "0" ]]; then
        echo "- **Пользовательский crontab (\`bitrix\`): ${usercron} задан(ий).**"
        echo "  В кластере такие задания ставятся через меню 10 → 8 классом «только master»,"
        echo "  иначе они будут тикать на КАЖДОЙ web-ноде. Исходный crontab — в \`system.tar.zst\`."
    fi
    echo "- **Активных агентов в базе: ${agents:-?}.** Агенты запускает cron только на держателе"
    echo "  web-VRRP (HA Cron); после импорта убедитесь, что \`cron_events.php\` тикает на одной ноде."
    echo "- **Почта.** Отправка на источнике идёт через msmtp (без очереди). В кластере включите"
    echo "  Postfix-smarthost: меню 15 → «Настроить» (нужны SMTP-реквизиты релея)."
    echo "- **Сертификат.** TLS в кластере терминирует HAProxy. Скопированный из \`system.tar.zst\`"
    echo "  pem ставится через меню 12 → 2; в закрытом контуре Let's Encrypt недоступен."
    echo "- **Push & Pull.** \`path_to_publish\` источника указывает на конкретный хост; в кластере"
    echo "  его переписывает \`install.sh\` (\`configure_push_redis\`) на \`127.0.0.1\`, а \`security.key\`"
    echo "  выравнивается по \`pull.signature_key\` со всех нод. Вручную ничего копировать не нужно."
    echo "- **Конвертер документов (transformer).** Ставится отдельно, только после развёртывания"
    echo "  портала и при редакции Enterprise: меню 14."
    echo
    echo "## Файлы в \`conflicts/\`"
    echo
    echo "Они НЕ входят в \`files.tar.zst\`: в кластере эти файлы уже созданы"
    echo "bitrix-env и BCM и указывают на ProxySQL и redis-VIP. Копировать их поверх"
    echo "нельзя — портал уедет на localhost и memcache. Переносить только значения:"
    echo
    echo "- \`bitrix/.settings.php\` — из источника забрать \`crypto\` (ключ шифрования:"
    echo "  без него не расшифруются сохранённые токены и пароли модулей), \`cookies\`,"
    echo "  \`cache_flags\`, \`exception_handling\`, \`utf_mode\`. Секции \`connections\`,"
    echo "  \`cache\` и \`session\` брать НЕ надо — они кластерные."
    echo "  \`pull.signature_key\`: либо оставить кластерный, либо, если переносите ключ"
    echo "  источника, после правки заново выровнять \`security.key\` push-серверов на всех"
    echo "  web-нодах (иначе клиенты получат \`4010 Wrong Channel Id\`)."
    echo "- \`bitrix/.settings_extra.php\` — в кластере это файл BCM (слой наложений)."
    echo "  Из источника не переносить ничего: там кэш, который перебьёт кластерный."
    echo "- \`bitrix/php_interface/dbconn.php\` — забрать прикладные константы"
    echo "  (\`CACHED_*\`, \`BX_FILE_PERMISSIONS\`/\`BX_DIR_PERMISSIONS\`, свои define'ы)."
    echo "  \`BX_CACHE_TYPE\`/\`BX_MEMCACHE_*\` и реквизиты БД — НЕ переносить."
    echo
    echo "## Проверка целостности архивов"
    echo
    echo '```bash'
    echo "cd $OUT && sha256sum -c SHA256SUMS && zstd -t ./*.zst"
    echo '```'
} > "$REPORT"
chmod 600 "$REPORT"

# ──── Проверка артефактов ────────────────────────────────────────────────────
say "Проверка артефактов"
for a in "$FILES_TAR" "$DB_DUMP" "$SYS_TAR"; do
    [[ -f "$a" ]] || continue
    zstd -t "$a" 2>/dev/null && ok "$(basename "$a") — целостность zstd подтверждена" \
        || die "битый архив: $a"
done
if [[ -f "$FILES_TAR" ]]; then
    cnt="$(tar -I zstd -tf "$FILES_TAR" 2>/dev/null | wc -l || true)"
    ok "в дереве ${cnt} объектов"
fi

say "Готово"
echo "  $OUT"
ls -lh "$OUT" | tail -n +2 | sed 's/^/  /'
echo
echo "  Дальше: прочитайте REPORT.md — там пункты, которые не переносятся автоматически."
warn "Артефакты содержат секреты (реквизиты БД, ключи сертификатов) — передавайте защищённым каналом."
