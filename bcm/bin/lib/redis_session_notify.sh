#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# redis_session_notify.sh — обработчик событий Keepalived для плавающего VIP redis.
# Управляет ролью локального redis-инстанса в зависимости от VRRP:
#   MASTER  → этот узел держит VIP → redis становится master (REPLICAOF NO ONE)
#   BACKUP  → VIP на другом узле   → redis реплицируется от VIP (текущий master)
#   FAULT   → как BACKUP (пытаемся следовать за VIP)
#   ASSERT  → не событие keepalived, а сверка: роль redis приводится к тому, кто
#             фактически держит VIP. Нужна потому, что роль задаётся ТОЛЬКО командой
#             в момент перехода VRRP и нигде не закреплена: рестарт redis (в конфиге
#             replicaof нет) или пропущенный notify оставляют узел standalone-мастером
#             с пустой базой — и при следующем переезде VIP сессии теряются целиком
#             (ловили вживую: web-реплика 3 недели была мастером с 0 ключей).
#             Дёргается из /etc/cron.d/bcm-redis-role-guard, как assert у HA-Cron.
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

LOG_FILE="${LOG_FILE:-/var/log/bcm/redis_session_notify.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
# ⚠️ Сверка (ASSERT) идёт по расписанию каждые несколько минут и в норме ничего не
# меняет — её в журнал не пишем, иначе он утонет в шуме. Пишет только сама ветка
# ASSERT и только когда действительно правит роль.
if [[ "${STATE}" != "ASSERT" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${STATE}] redis VRRP event vip=${VIP} port=${PORT} policy=${POLICY} restart=${RESTART_SVC:-нет}" >> "$LOG_FILE"
fi

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
    ASSERT)
        # Кто держит VIP — тот и master. Смотрим по адресам на интерфейсах, а не по
        # состоянию keepalived: важен факт, а не то, что он должен был сделать.
        #
        # ⚠️⚠️ PATH задаём ЯВНО. Сверка ходит из /etc/cron.d, а cron выполняет строку с
        # минимальным окружением (PATH=/usr/bin:/bin), тогда как ip лежит в /usr/sbin.
        # Без этого «держим ли мы VIP» отвечало ЛОЖЬЮ всегда — и сторож делал держателя
        # VIP репликой самого себя: кэш уходил в read-only, портал отдавал 500 на обеих
        # web (ловили вживую 2026-09-10). Проверять такой код надо в cron-окружении
        # (env -i), а не из своей сессии с полным PATH.
        # ⚠️ ДОПОЛНЯЕМ PATH, а не задаём его целиком: перезапись отобрала бы у вызова
        # его собственное окружение (и сломала бы любой стенд с подменными командами).
        PATH="${PATH}:/usr/sbin:/sbin:/usr/local/sbin:/usr/local/bin"
        export PATH
        if ! "${RCLI[@]}" PING >/dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [ASSERT] redis :${PORT} не отвечает — пропуск" >> "$LOG_FILE"
            exit 0
        fi
        # ⚠️ Fail-safe: не знаем расклад адресов — НИЧЕГО не трогаем. Сторож, который
        # действует вслепую, опаснее дрейфа роли, который он призван чинить.
        _addrs=$(ip -4 -o addr show 2>/dev/null)
        if [[ -z "$_addrs" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [ASSERT] не удалось прочитать адреса интерфейсов — роль не трогаю" >> "$LOG_FILE"
            exit 0
        fi
        # ⚠️ redis отдаёт INFO со строками, завершёнными CRLF. Убираем CR ЯВНО через
        # tr: в sed-BRE «\r» — это буква r, а не возврат каретки, и значение уезжало
        # в сравнение вместе с CR — сверка считала роль неверной на каждом прогоне.
        _info=$("${RCLI[@]}" INFO replication 2>/dev/null | tr -d '\r')
        _role=$(printf '%s\n' "$_info" | sed -n 's/^role:\(.*\)$/\1/p')
        _mhost=$(printf '%s\n' "$_info" | sed -n 's/^master_host:\(.*\)$/\1/p')
        if printf '%s\n' "$_addrs" | grep -qE "[[:space:]]${VIP}/"; then
            if [[ "$_role" != "master" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [ASSERT] держим VIP ${VIP}, но роль '${_role}' — повышаю в master" >> "$LOG_FILE"
                "${RCLI[@]}" REPLICAOF NO ONE >> "$LOG_FILE" 2>&1 || true
                "${RCLI[@]}" CONFIG SET maxmemory-policy "$POLICY" >> "$LOG_FILE" 2>&1 || true
            fi
        else
            if [[ "$_role" != "slave" || "$_mhost" != "$VIP" ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [ASSERT] VIP ${VIP} не наш, а роль '${_role}' (master_host='${_mhost}') — реплицирую от VIP" >> "$LOG_FILE"
                "${RCLI[@]}" REPLICAOF "$VIP" "$PORT" >> "$LOG_FILE" 2>&1 || true
            fi
        fi
        ;;
    *)
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] неизвестное состояние: ${STATE}" >> "$LOG_FILE"
        ;;
esac
