#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# transformer_check.sh — health-check для keepalived (track_script) transformer-HA.
#
# Transformer работает в режиме active/standby (в отличие от redis master-replica):
# rabbitmq-server + transformer (workerd) подняты ТОЛЬКО на VIP-холдере, на standby
# они выключены. Поэтому проверка VIP-AWARE:
#   • держим VIP → должны быть живы rabbitmq-server И transformer → иначе FAIL
#     (keepalived снизит приоритет/уйдёт в FAULT → VIP уедет на standby, тот поднимет);
#   • НЕ держим VIP (standby) → возвращаем 0 (выключенные сервисы — норма).
#
# Использование: transformer_check.sh <VIP>
# =============================================================================
VIP="${1:-}"
[[ -z "$VIP" ]] && exit 0   # без VIP проверять нечего — не валим keepalived

# Держим ли мы VIP?
if ip -4 addr 2>/dev/null | grep -q "inet ${VIP}/"; then
    # Активная нода: критичен RabbitMQ — точка подключения клиентов через VIP.
    # transformer (workerd) НЕ проверяем: у него Restart=always (падение чинит
    # systemd, не VIP), а его forking-старт отдавал 'activating' и вызывал ФЛАП VIP
    # (FAULT→stop→MASTER→start→FAULT… — ловили вживую).
    systemctl is-active --quiet rabbitmq-server 2>/dev/null || exit 1
    exit 0
fi

# Standby: сервисы выключены штатно — здоровы.
exit 0
