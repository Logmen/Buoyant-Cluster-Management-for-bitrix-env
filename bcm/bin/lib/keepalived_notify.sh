#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# keepalived_notify.sh — Обработчик событий Keepalived для lb-нод
# Вызывается Keepalived при смене роли MASTER/BACKUP/FAULT
# =============================================================================
STATE="$1"
NODE="$2"
LOG_FILE="/var/log/bcm/keepalived_notify.log"

mkdir -p "$(dirname "$LOG_FILE")"
echo "$(date '+%Y-%m-%d %H:%M:%S') [${STATE}] Node=${NODE}" >> "$LOG_FILE"

case "$STATE" in
    MASTER)
        # Этот узел стал MASTER — убедиться что HAProxy работает
        systemctl start haproxy 2>/dev/null || true
        echo "$(date '+%Y-%m-%d %H:%M:%S') [MASTER] HAProxy started/confirmed" >> "$LOG_FILE"
        ;;
    BACKUP)
        # Стали BACKUP — всё ок, HAProxy продолжает работать (для отказоустойчивости)
        echo "$(date '+%Y-%m-%d %H:%M:%S') [BACKUP] Switched to backup role" >> "$LOG_FILE"
        ;;
    FAULT)
        # Ошибка VRRP — логируем
        echo "$(date '+%Y-%m-%d %H:%M:%S') [FAULT] VRRP fault on ${NODE}" >> "$LOG_FILE"
        ;;
esac
