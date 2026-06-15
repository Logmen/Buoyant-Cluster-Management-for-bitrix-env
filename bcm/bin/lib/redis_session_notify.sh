#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# redis_session_notify.sh — обработчик событий Keepalived для плавающего VIP redis.
# Управляет ролью локального redis-инстанса в зависимости от VRRP:
#   MASTER  → этот узел держит VIP → redis становится master (REPLICAOF NO ONE)
#   BACKUP  → VIP на другом узле   → redis реплицируется от VIP (текущий master)
#   FAULT   → как BACKUP (пытаемся следовать за VIP)
# Вызывается keepalived: redis_session_notify.sh <STATE> <VIP> <PORT> [POLICY]
#   POLICY — maxmemory-policy на master (по умолчанию noeviction для сессий;
#            push-redis передаёт allkeys-lru). Скрипт общий для session- и push-redis.
# =============================================================================
STATE="$1"
VIP="$2"
PORT="${3:-6380}"
POLICY="${4:-noeviction}"
# 5-й арг (опц.): сервис для ПЕРЕЗАПУСКА при промоуте этого redis в master.
# Для push-redis = "push-server": после повышения реплики в master push-server
# должен переподключиться к НОВОМУ мастеру, иначе держит соединение/подписку к
# мёртвому старому → доставка push ломается (вьюер transformer'а и уведомления
# таймаутят — ловили вживую при failover web01). Пусто (session/cache) → не трогаем.
RESTART_SVC="${5:-}"

LOG_FILE="/var/log/bcm/redis_session_notify.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
echo "$(date '+%Y-%m-%d %H:%M:%S') [${STATE}] redis VRRP event vip=${VIP} port=${PORT} policy=${POLICY} restart=${RESTART_SVC:-нет}" >> "$LOG_FILE"

RCLI=(redis-cli -p "$PORT")

case "$STATE" in
    MASTER)
        # Стать master: разорвать репликацию и зафиксировать политику вытеснения
        "${RCLI[@]}" REPLICAOF NO ONE >> "$LOG_FILE" 2>&1 || true
        "${RCLI[@]}" CONFIG SET maxmemory-policy "$POLICY" >> "$LOG_FILE" 2>&1 || true
        # Переподключить зависимый сервис к новому мастеру (push-server для push-redis).
        # В фоне — чтобы не блокировать keepalived-notify на время рестарта.
        if [[ -n "$RESTART_SVC" ]]; then
            ( systemctl restart "$RESTART_SVC" >> "$LOG_FILE" 2>&1 ) &
        fi
        ;;
    BACKUP|FAULT)
        # Следовать за тем, кто держит VIP (текущий master).
        # На самом master VIP локальный — REPLICAOF VIP туда и укажет, но в роли
        # MASTER этот узел сюда не попадёт, так что гонки нет.
        "${RCLI[@]}" REPLICAOF "$VIP" "$PORT" >> "$LOG_FILE" 2>&1 || true
        ;;
    *)
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] неизвестное состояние: ${STATE}" >> "$LOG_FILE"
        ;;
esac
