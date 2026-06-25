#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# transformer_notify.sh — обработчик переходов VRRP для VIP генератора документов.
#
# ⚠️ Дизайн HA: rabbitmq-server + transformer (workerd) работают на ОБЕИХ web-нодах
# ВСЕГДА (enabled). keepalived держит TRANSFORMER_VIP; портал И ВОРКЕРЫ ВСЕХ нод ходят
# на `default` → VIP → RabbitMQ держателя VIP.
#
# ⚠️⚠️ ПОЧЕМУ ЗДЕСЬ ВСЁ-ТАКИ РЕСТАРТ workerd (ловили вживую, июнь 2026):
# консьюмеры sys_workerd подключаются к `default:5672` ОДИН РАЗ при старте и НЕ
# переподключаются при переезде VIP. После failover воркеры нового держателя остаются
# «зомби»-подключёнными к RabbitMQ СТАРОГО (умершего) держателя → на локальном брокере
# 0 консьюмеров → команда висит в очереди (STATUS_SEND=200) → во вьюере
# transformationTimeout, хотя VIP, rabbitmq и контроллер живы. Поэтому при СМЕНЕ роли
# надо перезапустить workerd, чтобы консьюмеры пере-подключились к RabbitMQ ТЕКУЩЕГО
# держателя VIP:
#   - MASTER (стали держателем): воркеры → ЛОКАЛЬНЫЙ rabbitmq (КРИТИЧНО — иначе
#     конвертация мертва на активной ноде);
#   - BACKUP (роль ушла, но нода жива — controlled failback/возврат): воркеры → rabbitmq
#     нового держателя (восстанавливает полную ёмкость воркеров).
#
# ⚠️ Рестарт — ТОЛЬКО В ФОНЕ (`( … ) &`), как push-server в redis_session_notify.sh:
# `systemctl restart transformer` гасит workerd МЕДЛЕННО (до ~60с) → синхронный вызов
# блокировал бы notify → VRRP флапал (MASTER↔BACKUP). rabbitmq-server НЕ трогаем (он
# и так на обеих нодах). FAULT — только лог (нет VIP, не дёргать сервис впустую).
#
# Вызов keepalived: transformer_notify.sh <STATE>
# =============================================================================
STATE="$1"
LOG_FILE="/var/log/bcm/transformer_notify.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [${STATE}] $*" >> "$LOG_FILE"; }

case "$STATE" in
    MASTER)
        _log "TRANSFORMER_VIP на этой ноде — клиенты идут сюда; рестарт workerd (фон) для переподключения консьюмеров к ЛОКАЛЬНОМУ rabbitmq"
        ( systemctl restart transformer >> "$LOG_FILE" 2>&1 ) &
        ;;
    BACKUP)
        _log "TRANSFORMER_VIP ушёл на другую ноду; рестарт workerd (фон) для переподключения консьюмеров к rabbitmq нового держателя"
        ( systemctl restart transformer >> "$LOG_FILE" 2>&1 ) &
        ;;
    *)
        _log "VRRP fault/прочее — только лог, сервис не трогаем"
        ;;
esac

exit 0
