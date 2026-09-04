#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_messenger.sh — фоновая шина Messenger ядра Bitrix: с хитов на master-cron
# (CLI, на web-ноде)
#
# Зачем. Ядро (main 26.x) при run_mode=web — умолчание, секции messenger в
# .settings.php нет — на КАЖДОМ хите обходит все очереди шины (main, calendar,
# bizproc…), и каждая берёт именованную блокировку GET_LOCK с нулевым таймаутом.
# На crm-портале это давало 4/5 всех запросов к БД (8 000+ GET_LOCK/RELEASE_LOCK
# в минуту, три попытки из четырёх упираются в соседний хит) и спам варнингов PXC.
# Штатный выход ядра — run_mode=cli (Application::initializeMessengerWorker() тогда
# выходит сразу) плюс потребитель, разбирающий очереди в цикле. Консольная команда
# messenger:consume здесь непригодна: bitrix.php требует Symfony Console, которого
# в bitrix-env нет, — поэтому потребитель свой (templates/messenger_consume.php →
# <docroot>/local/cron/bcm-messenger.php), а его запуск раз в минуту — строка в
# классе кронов «только master» (/etc/cron.d/bcm-portal-master, меню 10).
#
# Слои этого скрипта (локально на web-ноде):
#   • файл потребителя в /local/cron (владелец/режим — как у соседей);
#   • секция messenger в .settings.php (messenger_repoint.php) + переснятие эталона
#     сторожа (секция под его защитой) + graceful reload httpd (opcache);
#   • статус: режим, наличие файла и cron-строки, работающий потребитель, глубина
#     очередей. Строку cron пишет оркестратор (меню 10 → 10) через bcm-portal-master.
#
# Команды: --status | --install-files | --settings cli|web | --consume-test
# =============================================================================
set -uo pipefail

source /opt/bcm/bin/lib/bcm_config.sh

SITE_ROOT="${BCM_SITE_ROOT:-/home/bitrix/www}"
CONSUMER_SRC="/opt/bcm/templates/messenger_consume.php"
CONSUMER_DST="${SITE_ROOT}/local/cron/bcm-messenger.php"
REPOINT_PHP="/opt/bcm/templates/messenger_repoint.php"
GUARD="/opt/bcm/bin/lib/bcm_settings_guard.sh"
GUARD_REFERENCE="/etc/bitrix-cluster/settings-cluster.php"
CRON_MASTER="/etc/cron.d/bcm-portal-master"
CRON_MASTER_OFF="/etc/bitrix-cluster/bcm-portal-master.disabled"
LOG="/var/log/bcm/messenger.log"

_ms_log()  { mkdir -p /var/log/bcm 2>/dev/null || true; echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }
_ms_err()  { echo "ОШИБКА: $*" >&2; _ms_log "ERROR: $*"; }
_ms_info() { echo "$*"; }
_ms_require_root() { [[ "$(id -u)" -eq 0 ]] || { _ms_err "нужен root."; exit 1; }; }

_ms_run_mode() {
    [[ -f "$REPOINT_PHP" ]] || { echo "?"; return; }
    BX_DOCROOT="$SITE_ROOT" BX_MODE=status php "$REPOINT_PHP" 2>/dev/null | sed -n 's/^RUN_MODE=//p' | head -1
}

# ──── Файл потребителя ──────────────────────────────────────────────────────
_ms_install_files() {
    _ms_require_root
    [[ -f "$CONSUMER_SRC" ]] || { _ms_err "нет ${CONSUMER_SRC} — раскатайте BCM на ноду (bcm --update)."; exit 1; }
    [[ -d "${SITE_ROOT}/local" ]] || { _ms_err "нет ${SITE_ROOT}/local — портал не развёрнут."; exit 1; }
    php -l "$CONSUMER_SRC" >/dev/null 2>&1 || { _ms_err "${CONSUMER_SRC} не проходит проверку синтаксиса PHP этой ноды."; exit 1; }
    if [[ -f "$CONSUMER_DST" ]] && cmp -s "$CONSUMER_SRC" "$CONSUMER_DST"; then
        _ms_info "✓ Потребитель актуален (${CONSUMER_DST})."
        return 0
    fi
    mkdir -p "$(dirname "$CONSUMER_DST")"
    cp -f "$CONSUMER_SRC" "$CONSUMER_DST" || { _ms_err "не удалось записать ${CONSUMER_DST}."; exit 1; }
    chown --reference="${SITE_ROOT}/local" "$(dirname "$CONSUMER_DST")" "$CONSUMER_DST" 2>/dev/null || chown bitrix:bitrix "$(dirname "$CONSUMER_DST")" "$CONSUMER_DST"
    chmod 0644 "$CONSUMER_DST"
    _ms_log "потребитель установлен: ${CONSUMER_DST}"
    _ms_info "✓ Потребитель установлен (${CONSUMER_DST})."
}

# ──── .settings.php ─────────────────────────────────────────────────────────
_ms_settings() {
    local mode="$1"
    _ms_require_root
    [[ -f "$REPOINT_PHP" ]] || { _ms_err "нет ${REPOINT_PHP} — раскатайте BCM на ноду."; exit 1; }
    [[ -f "${SITE_ROOT}/bitrix/.settings.php" ]] || { _ms_err "нет ${SITE_ROOT}/bitrix/.settings.php — портал не развёрнут."; exit 1; }
    if [[ "$mode" == "cli" && ! -f "$CONSUMER_DST" ]]; then
        # Fail-closed: без потребителя очереди перестали бы разбираться вовсе.
        _ms_err "нет ${CONSUMER_DST} — сначала --install-files."
        exit 1
    fi
    local out res
    out=$(BX_DOCROOT="$SITE_ROOT" BX_MODE="$mode" php "$REPOINT_PHP" 2>&1)
    res=$(echo "$out" | sed -n 's/^RESULT=//p' | head -1)
    if [[ "$res" != "OK" ]]; then
        _ms_err ".settings.php не переписан (${out//$'\n'/ })."
        exit 1
    fi
    if [[ -x "$GUARD" && -f "$GUARD_REFERENCE" ]]; then
        "$GUARD" --install >/dev/null 2>&1 || _ms_err "bcm_settings_guard.sh --install завершился с ошибкой — проверьте ${GUARD} --status."
    fi
    # Хиты перечитают .settings.php по opcache-ревалидации; graceful reload убирает окно.
    systemctl is-active httpd >/dev/null 2>&1 && systemctl reload httpd >/dev/null 2>&1 || true
    _ms_log "settings: run_mode=${mode}"
    _ms_info "✓ .settings.php: messenger run_mode=${mode}."
}

# ──── Пробный прогон потребителя (3 с) из-под bitrix ─────────────────────────
_ms_consume_test() {
    [[ -f "$CONSUMER_DST" ]] || { echo "RESULT=NO_CONSUMER"; return 1; }
    local out rc
    if id bitrix >/dev/null 2>&1; then
        out=$(BCM_MESSENGER_VERBOSE=1 runuser -u bitrix -- php -f "$CONSUMER_DST" 3 1 2>&1); rc=$?
    else
        out=$(BCM_MESSENGER_VERBOSE=1 php -f "$CONSUMER_DST" 3 1 2>&1); rc=$?
    fi
    echo "RUN_MODE=$(_ms_run_mode)"
    echo "PASSES=$(echo "$out" | sed -n 's/^passes=//p' | head -1)"
    [[ -n "$out" ]] && echo "OUTPUT=$(echo "$out" | grep -v '^passes=' | tr '\n' ' ' | cut -c1-200)"
    echo "RC=${rc}"
    if [[ $rc -eq 0 ]]; then echo "RESULT=OK"; else echo "RESULT=FAIL"; return 1; fi
}

# ──── Статус ────────────────────────────────────────────────────────────────
_ms_status() {
    echo "RUN_MODE=$(_ms_run_mode)"
    echo "CONSUMER_SCRIPT=$( [[ -f "$CONSUMER_DST" ]] && echo present || echo missing )"
    local cron_state="absent"
    if grep -qsF "bcm-messenger.php" "$CRON_MASTER"; then cron_state="active"
    elif grep -qsF "bcm-messenger.php" "$CRON_MASTER_OFF"; then cron_state="present (нода BACKUP)"; fi
    echo "CRON_JOB=${cron_state}"
    echo "HA_CRON_ROLE=$(cat /run/bcm-ha-cron.role 2>/dev/null || echo '?')"
    echo "CONSUMER_RUNNING=$(pgrep -fc 'local/cron/bcm-messenger.php' 2>/dev/null || echo 0)"
    local port user pass depth
    port=$(bcm_conf_get proxysql port 2>/dev/null); user=$(bcm_conf_get proxysql bitrix_db_user 2>/dev/null); pass=$(bcm_conf_get proxysql bitrix_db_password 2>/dev/null)
    if [[ -n "$user" && -n "$pass" ]]; then
        # Сумма строк во всех таблицах шины (*_messenger_message*): растёт — потребитель не успевает.
        local dbname
        dbname=$(BX_DOCROOT="$SITE_ROOT" BX_MODE=read php /opt/bcm/templates/db_repoint.php 2>/dev/null | sed -n 's/^DB_NAME=//p' | head -1)
        depth=$(mysql --default-auth=mysql_native_password -h127.0.0.1 -P"${port:-6033}" -u"$user" -p"$pass" -N -e \
            "SELECT IFNULL(SUM(TABLE_ROWS),0) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name LIKE '%messenger_%message%';" \
            "${dbname:-sitemanager}" 2>/dev/null | tr -d '[:space:]')
        echo "QUEUE_ROWS=${depth:-?}"
    fi
    echo "LOG=${LOG}"
}

# При source (тесты) диспетчер не запускается.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0 2>/dev/null || true

case "${1:-}" in
    --status)        _ms_status ;;
    --install-files) _ms_install_files ;;
    --settings)
        case "${2:-}" in
            cli|web) _ms_settings "$2" ;;
            *) _ms_err "--settings cli|web"; exit 2 ;;
        esac ;;
    --consume-test)  _ms_consume_test ;;
    *) echo "Использование: $0 --status | --install-files | --settings cli|web | --consume-test" >&2; exit 2 ;;
esac
