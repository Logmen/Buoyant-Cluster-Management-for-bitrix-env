#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_dbrouter.sh — разделение чтений БД между узлами PXC (CLI, на web-ноде)
#
# Зачем. ProxySQL в BCM работает HA-прокси: все запросы портала идут на writer PXC,
# реплики простаивают. Штатное разделение чтений Bitrix (модуль «Веб-кластер»)
# доступно не во всех редакциях и рассчитано на классическую репликацию. BCM даёт
# свой класс подключения Bcm\DbRouter\Connection (/local/modules/bcm.dbrouter),
# который подставляется в bitrix/.settings.php через штатный параметр className:
# чистые SELECT уходят по отдельному соединению на пользователя-читателя ProxySQL
# (default_hostgroup = HG_READ), остальное — по основному соединению на writer.
# Ядро Bitrix не правится, редакция не важна.
#
# Слои, за которые отвечает этот скрипт (всё локально на web-ноде):
#   • ProxySQL: пользователь-читатель <db_user>_ro (тот же пароль, что у основного,
#     default_hostgroup=HG_READ), правило ^SELECT (rule_id=4) ограничивается основным
#     пользователем — иначе оно перехватывало бы SELECT читателя и уводило на writer;
#   • файлы модуля: /opt/bcm/templates/dbrouter → <docroot>/local/modules/bcm.dbrouter
#     (владелец и режим — как у соседей в дереве портала);
#   • .settings.php: className + блок reader (dbrouter_repoint.php); эталон сторожа
#     переснимается (bcm_settings_guard.sh --install) — автозагрузчик класса живёт в
#     .settings_extra.php; httpd перечитывает конфиг (graceful reload, opcache);
#   • старый API ($DB->Query исполняет SQL мимо класса подключения): блок bcm:dbrouter
#     в действующем php_interface/init.php подключает legacy.php модуля, который
#     подменяет $GLOBALS['DB'] на Bcm\DbRouter\LegacyDatabase. ⚠️ Правится тот init.php,
#     который ядро реально грузит: /local/php_interface/init.php, если он есть, иначе
#     /bitrix/php_interface/init.php; создавать local-вариант при существующем
#     bitrix-варианте НЕЛЬЗЯ — ядро берёт только один из них (local вытесняет bitrix).
# PXC-сторона (пользователь-читатель, wsrep_sync_wait=1) — оркестратор (меню 4 → 8)
# или install.sh: отсюда до PXC не ходим.
#
# Рубильник: файл /etc/bitrix-cluster/dbrouter.off → класс шлёт всё на writer без
# правки конфигов (перечитывается раз в 5 с и долгоживущими процессами).
#
# Команды: --status | --proxysql enable|disable | --install-files |
#          --settings enable|disable | --selftest | --kill on|off
# =============================================================================
set -uo pipefail

source /opt/bcm/bin/lib/bcm_config.sh

SITE_ROOT="${BCM_SITE_ROOT:-/home/bitrix/www}"
MODULE_SRC="/opt/bcm/templates/dbrouter"
MODULE_DST="${SITE_ROOT}/local/modules/bcm.dbrouter"
REPOINT_PHP="/opt/bcm/templates/dbrouter_repoint.php"
GUARD="/opt/bcm/bin/lib/bcm_settings_guard.sh"
GUARD_REFERENCE="/etc/bitrix-cluster/settings-cluster.php"
KILL_SWITCH="/etc/bitrix-cluster/dbrouter.off"
LOG="/var/log/bcm/dbrouter.log"
HOOK_BEGIN="// bcm:dbrouter-begin"
HOOK_END="// bcm:dbrouter-end"

_dr_log()  { mkdir -p /var/log/bcm 2>/dev/null || true; echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }
_dr_err()  { echo "ОШИБКА: $*" >&2; _dr_log "ERROR: $*"; }
_dr_info() { echo "$*"; }
_dr_require_root() { [[ "$(id -u)" -eq 0 ]] || { _dr_err "нужен root."; exit 1; }; }

# ──── Параметры из cluster.conf ─────────────────────────────────────────────
_dr_load_conf() {
    PROXY_PORT=$(bcm_conf_get proxysql port 2>/dev/null);           [[ -z "$PROXY_PORT" ]] && PROXY_PORT="6033"
    ADMIN_PORT=$(bcm_conf_get proxysql admin_port 2>/dev/null);     [[ -z "$ADMIN_PORT" ]] && ADMIN_PORT="6032"
    ADMIN_USER=$(bcm_conf_get proxysql admin_user 2>/dev/null);     [[ -z "$ADMIN_USER" ]] && ADMIN_USER="admin"
    ADMIN_PASS=$(bcm_conf_get proxysql admin_password 2>/dev/null)
    HG_WRITE=$(bcm_conf_get proxysql hg_write 2>/dev/null);         [[ -z "$HG_WRITE" ]] && HG_WRITE="10"
    HG_READ=$(bcm_conf_get proxysql hg_read 2>/dev/null);           [[ -z "$HG_READ" ]] && HG_READ="20"
    DB_USER=$(bcm_conf_get proxysql bitrix_db_user 2>/dev/null)
    DB_PASS=$(bcm_conf_get proxysql bitrix_db_password 2>/dev/null)
    RO_USER=$(bcm_conf_get proxysql reader_user 2>/dev/null);       [[ -z "$RO_USER" ]] && RO_USER="${DB_USER}_ro"
    if [[ -z "$DB_USER" || -z "$ADMIN_PASS" ]]; then
        _dr_err "в ${BCM_CONF_FILE} нет [proxysql] bitrix_db_user/admin_password."
        exit 1
    fi
}

# SQL к admin-интерфейсу ProxySQL (SQLite). Пароль — только как -p<pass>: MYSQL_PWD и
# defaults-file клиент MySQL 8 к ProxySQL не доносит. SQL идёт через stdin, чтобы
# кавычки и спецсимволы паролей не проходили через shell.
_dr_admin() {
    printf '%s\n' "$1" | mysql --default-auth=mysql_native_password -h127.0.0.1 -P"$ADMIN_PORT" \
        -u"$ADMIN_USER" -p"$ADMIN_PASS" -N 2>&1 | grep -v 'Using a password'
}
# Литерал для SQLite: экранируется только одинарная кавычка.
_dr_lit() { printf '%s' "${1//\'/\'\'}"; }

# Через какой узел PXC ProxySQL отвечает данному пользователю (пусто — не отвечает).
_dr_route_host() {
    local user="$1"
    mysql --default-auth=mysql_native_password -h127.0.0.1 -P"$PROXY_PORT" -u"$user" -p"$DB_PASS" \
        --connect-timeout=5 -N -e 'SELECT @@hostname' 2>/dev/null | tr -d '[:space:]'
}

# ──── ProxySQL ──────────────────────────────────────────────────────────────
_dr_proxysql_enable() {
    _dr_require_root; _dr_load_conf
    local sql
    sql="INSERT OR REPLACE INTO mysql_users (username, password, default_hostgroup, transaction_persistent, active, max_connections)
         VALUES ('$(_dr_lit "$RO_USER")', '$(_dr_lit "$DB_PASS")', ${HG_READ}, 1, 1, 10000);
         UPDATE mysql_query_rules SET username='$(_dr_lit "$DB_USER")' WHERE rule_id=4;
         LOAD MYSQL USERS TO RUNTIME; LOAD MYSQL QUERY RULES TO RUNTIME;
         SAVE MYSQL USERS TO DISK; SAVE MYSQL QUERY RULES TO DISK;"
    local out
    out=$(_dr_admin "$sql")
    if [[ -n "$out" ]]; then
        _dr_err "ProxySQL admin: ${out}"
        exit 1
    fi

    # Проверка маршрута: читатель обязан отвечать и попадать НЕ на writer. Пустой ответ —
    # HG_READ пуст (реплики не Synced) либо пользователя нет в PXC; совпадение с writer —
    # правило ^SELECT не ограничилось основным пользователем.
    local ro_host rw_host
    ro_host=$(_dr_route_host "$RO_USER")
    rw_host=$(_dr_route_host "$DB_USER")
    if [[ -z "$ro_host" ]]; then
        _dr_err "пользователь-читатель ${RO_USER} через ProxySQL не отвечает (нет реплик в HG${HG_READ} или пользователя нет в PXC) — откатываю."
        _dr_proxysql_disable_quiet
        exit 1
    fi
    if [[ -n "$rw_host" && "$ro_host" == "$rw_host" ]]; then
        _dr_err "читатель ${RO_USER} попадает на writer (${rw_host}) — маршрутизация в ProxySQL не сработала, откатываю."
        _dr_proxysql_disable_quiet
        exit 1
    fi
    _dr_log "proxysql: reader ${RO_USER} → HG${HG_READ} (${ro_host}), writer ${DB_USER} → ${rw_host:-?}"
    _dr_info "✓ ProxySQL: читатель ${RO_USER} → ${ro_host} (HG${HG_READ}); writer ${DB_USER} → ${rw_host:-?}."
}

_dr_proxysql_disable_quiet() {
    _dr_admin "UPDATE mysql_query_rules SET username=NULL WHERE rule_id=4;
               DELETE FROM mysql_users WHERE username='$(_dr_lit "$RO_USER")';
               LOAD MYSQL USERS TO RUNTIME; LOAD MYSQL QUERY RULES TO RUNTIME;
               SAVE MYSQL USERS TO DISK; SAVE MYSQL QUERY RULES TO DISK;" >/dev/null
}

_dr_proxysql_disable() {
    _dr_require_root; _dr_load_conf
    local out
    out=$(_dr_admin "UPDATE mysql_query_rules SET username=NULL WHERE rule_id=4;
                     DELETE FROM mysql_users WHERE username='$(_dr_lit "$RO_USER")';
                     LOAD MYSQL USERS TO RUNTIME; LOAD MYSQL QUERY RULES TO RUNTIME;
                     SAVE MYSQL USERS TO DISK; SAVE MYSQL QUERY RULES TO DISK;")
    if [[ -n "$out" ]]; then
        _dr_err "ProxySQL admin: ${out}"
        exit 1
    fi
    _dr_log "proxysql: reader ${RO_USER} удалён, rule_id=4 без ограничения по пользователю"
    _dr_info "✓ ProxySQL: пользователь-читатель удалён, правило ^SELECT снова общее."
}

# ──── Файлы модуля в дереве портала ─────────────────────────────────────────
_dr_install_files() {
    _dr_require_root
    [[ -f "${MODULE_SRC}/lib/Connection.php" ]] || { _dr_err "нет ${MODULE_SRC}/lib/Connection.php — раскатайте BCM на ноду (bcm --update)."; exit 1; }
    [[ -d "${SITE_ROOT}/local/modules" ]] || { _dr_err "нет ${SITE_ROOT}/local/modules — портал не развёрнут."; exit 1; }
    if ! php -l "${MODULE_SRC}/lib/Connection.php" >/dev/null 2>&1; then
        _dr_err "Connection.php не проходит проверку синтаксиса PHP этой ноды ($(php -v | head -1))."
        exit 1
    fi
    if [[ -d "$MODULE_DST" ]] && diff -rq "$MODULE_SRC" "$MODULE_DST" >/dev/null 2>&1; then
        _dr_info "✓ Файлы модуля актуальны (${MODULE_DST})."
        return 0
    fi
    mkdir -p "$MODULE_DST"
    cp -r "${MODULE_SRC}/." "${MODULE_DST}/" || { _dr_err "не удалось скопировать файлы модуля."; exit 1; }
    # Владелец — как у каталога модулей портала; режимы — как у bitrix-env (dirs 0775, files 0664).
    chown -R --reference="${SITE_ROOT}/local/modules" "$MODULE_DST" 2>/dev/null || chown -R bitrix:bitrix "$MODULE_DST"
    find "$MODULE_DST" -type d -exec chmod 0775 {} + 2>/dev/null
    find "$MODULE_DST" -type f -exec chmod 0664 {} + 2>/dev/null
    _dr_log "файлы модуля установлены в ${MODULE_DST}"
    _dr_info "✓ Файлы модуля установлены (${MODULE_DST})."
}

# ──── init.php: подмена $DB для старого API ──────────────────────────────────
# Действующий init.php (см. шапку). Пусто — ни одного нет.
_dr_init_php() {
    if [[ -f "${SITE_ROOT}/local/php_interface/init.php" ]]; then
        echo "${SITE_ROOT}/local/php_interface/init.php"
    elif [[ -f "${SITE_ROOT}/bitrix/php_interface/init.php" ]]; then
        echo "${SITE_ROOT}/bitrix/php_interface/init.php"
    fi
}

_dr_hook_present() {
    local f; f=$(_dr_init_php)
    [[ -n "$f" ]] && grep -qF "$HOOK_BEGIN" "$f"
}

# Добавить блок в конец действующего init.php (создать /local/php_interface/init.php,
# только если нет ни одного). Владелец/режим — как у соседей в дереве портала.
_dr_hook_add() {
    local f; f=$(_dr_init_php)
    if [[ -z "$f" ]]; then
        f="${SITE_ROOT}/local/php_interface/init.php"
        mkdir -p "$(dirname "$f")"
        printf '<?php\n' > "$f"
        chown --reference="${SITE_ROOT}/local/modules" "$f" 2>/dev/null || chown bitrix:bitrix "$f"
        chmod 0664 "$f"
    fi
    if grep -qF "$HOOK_BEGIN" "$f"; then
        _dr_info "✓ Блок bcm:dbrouter уже в ${f}."
        return 0
    fi
    php -l "$f" >/dev/null 2>&1 || { _dr_err "${f} не проходит проверку синтаксиса ещё ДО правки — блок не добавлен."; return 1; }
    local bak="${f}.bcm-bak-dbrouter"
    [[ -f "$bak" ]] || cp -p "$f" "$bak"
    # Если файл закрыт тегом ?>, блок открывается своим <?php; иначе мы уже внутри
    # PHP-кода и повторный <?php был бы синтаксической ошибкой.
    local open_tag=""
    if tail -c 200 "$f" | tr -d '[:space:]' | grep -qE '\?>$'; then
        open_tag=$'<?php\n'
    fi
    cat >> "$f" <<HOOK

${open_tag}${HOOK_BEGIN} — разделение чтений BCM: маршрутизирующий \$DB для старого API (bcm_dbrouter.sh)
if (is_file(\$_SERVER['DOCUMENT_ROOT'] . '/local/modules/bcm.dbrouter/legacy.php')) {
    require_once \$_SERVER['DOCUMENT_ROOT'] . '/local/modules/bcm.dbrouter/legacy.php';
}
${HOOK_END}
HOOK
    if ! php -l "$f" >/dev/null 2>&1; then
        cp -p "$bak" "$f"
        _dr_err "${f} после добавления блока не проходит проверку синтаксиса — возвращён из бэкапа."
        return 1
    fi
    _dr_log "init.php: блок bcm:dbrouter добавлен в ${f}"
    _dr_info "✓ Блок bcm:dbrouter добавлен в ${f}."
}

_dr_hook_remove() {
    local f; f=$(_dr_init_php)
    [[ -n "$f" ]] && grep -qF "$HOOK_BEGIN" "$f" || { _dr_info "✓ Блока bcm:dbrouter в init.php нет."; return 0; }
    local tmp; tmp=$(mktemp)
    # Удаляем блок вместе с открывающим его тегом <?php и пустой строкой перед ним.
    awk -v b="$HOOK_BEGIN" -v e="$HOOK_END" '
        { lines[NR]=$0 }
        END {
            n=NR; skip_from=0; skip_to=0
            for (i=1;i<=n;i++) if (index(lines[i], b)==1) { skip_from=i; break }
            for (i=skip_from;i<=n;i++) if (index(lines[i], e)==1) { skip_to=i; break }
            if (skip_from>0 && skip_to>0) {
                if (skip_from>1 && lines[skip_from-1]=="<?php") skip_from--
                if (skip_from>1 && lines[skip_from-1]=="") skip_from--
            }
            for (i=1;i<=n;i++) if (skip_from==0 || i<skip_from || i>skip_to) print lines[i]
        }' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
    php -l "$f" >/dev/null 2>&1 || _dr_err "${f} после удаления блока не проходит проверку синтаксиса — проверьте вручную (бэкап ${f}.bcm-bak-dbrouter)."
    _dr_log "init.php: блок bcm:dbrouter удалён из ${f}"
    _dr_info "✓ Блок bcm:dbrouter удалён из ${f}."
}

# ──── .settings.php ─────────────────────────────────────────────────────────
_dr_settings_status() {
    [[ -f "$REPOINT_PHP" ]] || { echo "RESULT=NO_TEMPLATE"; return 1; }
    BX_DOCROOT="$SITE_ROOT" BX_MODE=status php "$REPOINT_PHP" 2>/dev/null
}

_dr_settings() {
    local mode="$1"
    _dr_require_root; _dr_load_conf
    [[ -f "$REPOINT_PHP" ]] || { _dr_err "нет ${REPOINT_PHP} — раскатайте BCM на ноду."; exit 1; }
    [[ -f "${SITE_ROOT}/bitrix/.settings.php" ]] || { _dr_err "нет ${SITE_ROOT}/bitrix/.settings.php — портал не развёрнут."; exit 1; }

    if [[ "$mode" == "enable" ]]; then
        # Fail-closed: без файлов модуля автозагрузчик подставил бы штатный класс и включение
        # прошло бы «успешно» без маршрутизации.
        [[ -f "${MODULE_DST}/lib/Connection.php" ]] || { _dr_err "нет ${MODULE_DST}/lib/Connection.php — сначала --install-files."; exit 1; }
        local ro_host
        ro_host=$(_dr_route_host "$RO_USER")
        [[ -n "$ro_host" ]] || { _dr_err "читатель ${RO_USER} через ProxySQL не отвечает — сначала --proxysql enable."; exit 1; }
    fi

    local out res
    out=$(BX_DOCROOT="$SITE_ROOT" BX_MODE="$mode" BX_READER_HOST="127.0.0.1:${PROXY_PORT}" BX_READER_LOGIN="$RO_USER" php "$REPOINT_PHP" 2>&1)
    res=$(echo "$out" | sed -n 's/^RESULT=//p' | head -1)
    if [[ "$res" != "OK" ]]; then
        _dr_err ".settings.php не переписан (${out//$'\n'/ })."
        exit 1
    fi
    # Старый API: блок в init.php (после .settings.php — без маршрутизатора он бездействует).
    if [[ "$mode" == "enable" ]]; then
        _dr_hook_add || exit 1
    else
        _dr_hook_remove
    fi
    # Сторож настроек: эталон и наложения (.settings_extra.php с автозагрузчиком) — с нового файла.
    if [[ -x "$GUARD" && -f "$GUARD_REFERENCE" ]]; then
        "$GUARD" --install >/dev/null 2>&1 || _dr_err "bcm_settings_guard.sh --install завершился с ошибкой — проверьте ${GUARD} --status."
    elif [[ -x "$GUARD" ]]; then
        _dr_info "  сторож настроек не установлен (нет эталона) — .settings_extra.php не обновлён; поставьте его: ${GUARD} --install."
    fi
    # mod_php перечитает .settings.php по opcache-ревалидации; graceful reload убирает окно.
    systemctl is-active httpd >/dev/null 2>&1 && systemctl reload httpd >/dev/null 2>&1 || true

    local cls
    cls=$(echo "$out" | sed -n 's/^CLASS=//p' | head -1)
    _dr_log "settings ${mode}: className=${cls}"
    _dr_info "✓ .settings.php: className=${cls} (${mode})."
}

# ──── Самопроверка: маршрут читателя и writer из-под ядра Bitrix ──────────────
_dr_selftest() {
    _dr_load_conf
    [[ -f "${SITE_ROOT}/bitrix/modules/main/include/prolog_before.php" ]] || { echo "RESULT=NO_PORTAL"; return 1; }
    local tmp
    tmp=$(mktemp /tmp/bcm-dbrouter-selftest.XXXXXX.php) || { echo "RESULT=TMP_FAIL"; return 1; }
    chmod 0644 "$tmp"
    cat > "$tmp" <<'PHP'
<?php
$_SERVER['DOCUMENT_ROOT'] = getenv('BX_DOCROOT') ?: '/home/bitrix/www';
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('NO_AGENT_CHECK', true);
define('STOP_STATISTICS', true);
define('BX_CRONTAB', true);
require $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/include/prolog_before.php';

$c = \Bitrix\Main\Application::getConnection();
echo 'CLASS=', get_class($c), "\n";
// Без '@' в тексте: такой SELECT маршрутизатор отдаёт читателю.
$reader = $c->query("SELECT VARIABLE_VALUE AS H FROM performance_schema.global_variables WHERE VARIABLE_NAME = 'hostname'")->fetch();
// '@@' — только writer.
$writer = $c->query("SELECT @@hostname AS H")->fetch();
echo 'READER_HOST=', $reader['H'] ?? '', "\n";
echo 'WRITER_HOST=', $writer['H'] ?? '', "\n";
if ($c instanceof \Bcm\DbRouter\Connection) {
    $s = $c->getRouterState();
    echo 'ENABLED=', $s['enabled'] ? 'Y' : 'N', "\n";
    echo 'KILL_SWITCH=', $s['kill_switch'] ? 'Y' : 'N', "\n";
        // Старый API: $DB подменён на LegacyDatabase и его SELECT тоже уходит на reader.
    $legacyClass = get_class($GLOBALS['DB']);
    $lr = $GLOBALS['DB']->Query("SELECT VARIABLE_VALUE AS H FROM performance_schema.global_variables WHERE VARIABLE_NAME = 'hostname'")->Fetch();
    echo 'LEGACY_CLASS=', $legacyClass, "\n";
    echo 'LEGACY_READER_HOST=', $lr['H'] ?? '', "\n";
    echo 'STATS=reader:', $s['stats']['reader'], ',writer:', $s['stats']['writer'], ',fallback:', $s['stats']['fallback'], "\n";
    $legacyOk = ($GLOBALS['DB'] instanceof \Bcm\DbRouter\LegacyDatabase) && ($lr['H'] ?? '') !== '' && $lr['H'] !== $writer['H'];
    echo 'RESULT=', ($s['enabled'] && $s['stats']['reader'] > 0 && $reader['H'] !== $writer['H'] && $legacyOk) ? 'OK' : 'NOROUTE', "\n";
} else {
    echo "ENABLED=N\nRESULT=VENDOR_CLASS\n";
}
PHP
    local out rc
    if id bitrix >/dev/null 2>&1; then
        out=$(BX_DOCROOT="$SITE_ROOT" runuser -u bitrix -- php "$tmp" 2>/dev/null); rc=$?
    else
        out=$(BX_DOCROOT="$SITE_ROOT" php "$tmp" 2>/dev/null); rc=$?
    fi
    rm -f "$tmp"
    echo "$out" | grep -E '^(CLASS|READER_HOST|WRITER_HOST|ENABLED|KILL_SWITCH|LEGACY_CLASS|LEGACY_READER_HOST|STATS|RESULT)='
    [[ $rc -eq 0 ]] && echo "$out" | grep -q '^RESULT=OK$'
}

# ──── Статус ────────────────────────────────────────────────────────────────
_dr_status() {
    _dr_load_conf
    local st cls routed
    st=$(_dr_settings_status)
    cls=$(echo "$st" | sed -n 's/^CLASS=//p' | head -1)
    routed=$(echo "$st" | sed -n 's/^ROUTED=//p' | head -1)
    echo "MODULE_FILES=$( [[ -f "${MODULE_DST}/lib/Connection.php" ]] && echo present || echo missing )"
    echo "SETTINGS_CLASS=${cls:-?}"
    echo "SETTINGS_ROUTED=${routed:-N}"
    echo "KILL_SWITCH=$( [[ -f "$KILL_SWITCH" ]] && echo on || echo off )"
    echo "INIT_HOOK=$( _dr_hook_present && echo present || echo absent ) ($(_dr_init_php))"
    local ro_hg rule_user
    ro_hg=$(_dr_admin "SELECT default_hostgroup FROM runtime_mysql_users WHERE username='$(_dr_lit "$RO_USER")' AND active=1 LIMIT 1;" | tr -d '[:space:]')
    rule_user=$(_dr_admin "SELECT COALESCE(username,'') FROM runtime_mysql_query_rules WHERE rule_id=4;" | tr -d '[:space:]')
    echo "PROXYSQL_READER_USER=${RO_USER}:$( [[ -n "$ro_hg" ]] && echo "HG${ro_hg}" || echo absent )"
    echo "PROXYSQL_RULE4_USER=${rule_user:-any}"
    if [[ -n "$ro_hg" ]]; then
        echo "READER_ROUTE=$(_dr_route_host "$RO_USER")"
    fi
    echo "WRITER_ROUTE=$(_dr_route_host "$DB_USER")"
    local q
    q=$(_dr_admin "SELECT hostgroup, SUM(Queries) FROM stats_mysql_connection_pool GROUP BY hostgroup ORDER BY hostgroup;" | awk '{printf "%sHG%s:%s", (NR>1?",":""), $1, $2}')
    echo "HG_QUERIES=${q:-?}"
    echo "LOG=${LOG}"
}

# ──── Рубильник ─────────────────────────────────────────────────────────────
_dr_kill() {
    _dr_require_root
    case "$1" in
        on)  touch "$KILL_SWITCH"; _dr_log "рубильник ВКЛ (${KILL_SWITCH})"; _dr_info "✓ Рубильник включён: все запросы на writer (${KILL_SWITCH}).";;
        off) rm -f "$KILL_SWITCH"; _dr_log "рубильник ВЫКЛ"; _dr_info "✓ Рубильник снят: маршрутизация по .settings.php.";;
        *)   _dr_err "--kill on|off"; exit 2;;
    esac
}

# При source (тесты) диспетчер не запускается.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0 2>/dev/null || true

case "${1:-}" in
    --status)        _dr_status ;;
    --proxysql)
        case "${2:-}" in
            enable)  _dr_proxysql_enable ;;
            disable) _dr_proxysql_disable ;;
            *) _dr_err "--proxysql enable|disable"; exit 2 ;;
        esac ;;
    --install-files) _dr_install_files ;;
    --settings)
        case "${2:-}" in
            enable|disable) _dr_settings "$2" ;;
            *) _dr_err "--settings enable|disable"; exit 2 ;;
        esac ;;
    --selftest)      _dr_selftest ;;
    --kill)          _dr_kill "${2:-}" ;;
    *) echo "Использование: $0 --status | --proxysql enable|disable | --install-files | --settings enable|disable | --selftest | --kill on|off" >&2; exit 2 ;;
esac
