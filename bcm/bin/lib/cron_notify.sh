#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# cron_notify.sh — Обработчик событий Keepalived для web-нод (HA Cron)
# Агенты Битрикс (cron_events.php) должны работать ТОЛЬКО на master web-VRRP,
# иначе агенты/рассылки выполняются дважды.
#
# ⚠️ Управляем НАПРЯМУЮ строкой в /etc/crontab: bitrix-env 9 кладёт задание
# cron_events.php именно туда (НЕ в crontab пользователя bitrix). Прежний вызов
# /opt/webdir/bin/bx_cron_services.sh был ошибкой — этот скрипт запускает
# xmppd/smtpd-демоны и к крону отношения не имеет (его вызов молча падал под
# `|| true`, из-за чего агенты крутились на ОБЕИХ нодах — ловили вживую).
#
# BACKUP → строка комментируется маркером '#bcm-ha-backup#'
# MASTER → маркер снимается
# assert → переприменить сохранённую роль (/run/bcm-ha-cron.role): защита от
#          перезаписи /etc/crontab ansible'ом bitrix-env между VRRP-событиями;
#          дёргается guard'ом из /etc/cron.d/bcm-ha-cron-guard раз в 10 минут.
#
# Пользовательские master-only задания (BCM меню 10): файл
# /etc/cron.d/bcm-portal-master. Переключение — перемещением файла ЦЕЛИКОМ
# в /etc/bitrix-cluster/bcm-portal-master.disabled (вне cron.d).
# ⚠️ cronie (RHEL) ИСПОЛНЯЕТ файлы с точкой в /etc/cron.d — правило «имена с
# точкой игнорируются» это Debian; ловили вживую: задание из *.disabled
# продолжало выполняться. Поэтому только вынос из каталога.
# =============================================================================
STATE="$1"
LOG_FILE="/var/log/bcm/cron_notify.log"
CRONTAB_FILE="/etc/crontab"
ROLE_FILE="/run/bcm-ha-cron.role"
MARK="#bcm-ha-backup#"
PORTAL_CRON="/etc/cron.d/bcm-portal-master"
PORTAL_CRON_OFF="/etc/bitrix-cluster/bcm-portal-master.disabled"
# Роль источника lsyncd следует за master web-VRRP (этот же HA-Cron-инстанс):
# MASTER → стать источником (promote), BACKUP → приёмником (demote).
LSYNCD_ROLE="/opt/bcm/bin/lib/lsyncd_role.sh"

mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [${STATE}] $*" >> "$LOG_FILE"; }

# Закомментировать активные строки cron_events.php (идемпотентно)
_agents_disable() {
    if grep -qE "^[^#].*cron_events\.php" "$CRONTAB_FILE" 2>/dev/null; then
        sed -i "s|^\([^#].*cron_events\.php.*\)\$|${MARK} \1|" "$CRONTAB_FILE"
        log "агенты Битрикс ВЫКЛЮЧЕНЫ (cron_events в ${CRONTAB_FILE} закомментирован)"
    fi
}

# Снять маркер (идемпотентно). Только НАШ маркер — чужие комментарии не трогаем.
_agents_enable() {
    if grep -q "^${MARK} " "$CRONTAB_FILE" 2>/dev/null; then
        sed -i "s|^${MARK} ||" "$CRONTAB_FILE"
        log "агенты Битрикс ВКЛЮЧЕНЫ (маркер снят в ${CRONTAB_FILE})"
    fi
}

# Пользовательские master-only задания (файл целиком, rename-toggle)
_portal_enable() {
    if [[ -f "$PORTAL_CRON_OFF" ]]; then
        mv -f "$PORTAL_CRON_OFF" "$PORTAL_CRON" \
            && log "bcm-portal-master ВКЛЮЧЁН (задания меню 10)"
    fi
}

_portal_disable() {
    if [[ -f "$PORTAL_CRON" ]]; then
        mv -f "$PORTAL_CRON" "$PORTAL_CRON_OFF" \
            && log "bcm-portal-master ВЫКЛЮЧЕН (нода BACKUP)"
    fi
}

case "$STATE" in
    MASTER)
        log "HA Cron VRRP event: становлюсь MASTER — включаю агенты Битрикс"
        echo "MASTER" > "$ROLE_FILE"
        _agents_enable
        _portal_enable
        # Убедиться что crond работает
        systemctl start crond 2>/dev/null || systemctl start cron 2>/dev/null || true
        # Стать источником lsyncd (с catch-up — без потери наработок пиров)
        [[ -x "$LSYNCD_ROLE" ]] && bash "$LSYNCD_ROLE" promote >> "$LOG_FILE" 2>&1 || true
        ;;
    BACKUP)
        log "HA Cron VRRP event: становлюсь BACKUP — выключаю агенты Битрикс"
        echo "BACKUP" > "$ROLE_FILE"
        _agents_disable
        _portal_disable
        # Стать приёмником lsyncd (источник — новый master)
        [[ -x "$LSYNCD_ROLE" ]] && bash "$LSYNCD_ROLE" demote >> "$LOG_FILE" 2>&1 || true
        ;;
    FAULT)
        log "HA Cron VRRP event: FAULT — состояние агентов не меняю"
        # Роль lsyncd на транзиентном фоле не трогаем.
        ;;
    assert)
        # Guard: bitrix-env (ansible) может перезаписать /etc/crontab свежей
        # незакомментированной строкой, пока нода — BACKUP. Переприменяем
        # сохранённую роль; до первого VRRP-события (нет файла) — не вмешиваемся.
        role=$(cat "$ROLE_FILE" 2>/dev/null || echo "")
        case "$role" in
            MASTER) _agents_enable; _portal_enable ;;
            BACKUP) _agents_disable; _portal_disable ;;
        esac
        ;;
    *)
        echo "usage: $0 {MASTER|BACKUP|FAULT|assert}" >&2
        exit 2
        ;;
esac
