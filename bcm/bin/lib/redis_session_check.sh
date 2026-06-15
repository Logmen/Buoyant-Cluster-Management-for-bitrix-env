#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# redis_session_check.sh — health-check для keepalived (track_script)
# Возвращает 0, если локальный redis-инстанс сессий отвечает на PING.
# Использование: redis_session_check.sh [PORT]
# =============================================================================
PORT="${1:-6380}"
out=$(redis-cli -p "$PORT" ping 2>/dev/null)
[[ "$out" == "PONG" ]]
