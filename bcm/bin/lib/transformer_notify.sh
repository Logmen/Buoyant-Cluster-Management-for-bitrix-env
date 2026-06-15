#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# transformer_notify.sh — лог переходов VRRP для VIP генератора документов.
#
# ⚠️ Дизайн HA: rabbitmq-server + transformer (workerd) работают на ОБЕИХ web-нодах
# ВСЕГДА (enabled). keepalived только держит TRANSFORMER_VIP; портал и воркеры ходят
# на `default` → VIP → RabbitMQ держателя VIP. На failover VIP уезжает на запасную,
# её (уже работающий) RabbitMQ принимает клиентов — без start/stop сервисов.
#
# Почему НЕ start/stop в notify (как у redis): rabbitmq/transformer стартуют/гасятся
# МЕДЛЕННО (transformer stop до 60с) → notify блокировался → VRRP флапал
# (MASTER↔BACKUP, RabbitMQ оставался inactive на держателе VIP) — ловили вживую.
# Поэтому здесь notify только ЛОГИРУЕТ; сервисами управляет systemd (Restart=always),
# а кто «активен» решает VIP.
#
# Вызов keepalived: transformer_notify.sh <STATE>
# =============================================================================
STATE="$1"
LOG_FILE="/var/log/bcm/transformer_notify.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
echo "$(date '+%Y-%m-%d %H:%M:%S') [${STATE}] transformer VRRP: VIP $( [[ "$STATE" == MASTER ]] && echo 'на этой ноде — клиенты идут сюда' || echo 'на другой ноде' )" >> "$LOG_FILE"
exit 0
