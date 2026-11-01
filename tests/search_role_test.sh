#!/usr/bin/env bash
# =============================================================================
# tests/search_role_test.sh — таблица решений контролёра кластера Manticore
# (bcm/bin/lib/search_role.sh, функция _sr_decide). Без кластера: чистая логика.
#
# Каждая строка — состояние, проверенное на стенде из двух узлов Manticore 29.9
# (ноябрь 2026), и действие, которое его исправляет. Опасные строки помечены ⚠️:
# там неверное действие даёт раскол или тихое расхождение индекса.
# Возвращает число несовпадений (0 — всё верно).
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SR="${ROOT}/bcm/bin/lib/search_role.sh"

fails=0
# роль  локальный  размер  сосед  размер  ожидается      — смысл
while read -r role l ls p ps want note; do
    [[ -z "$role" || "$role" == "#" ]] && continue
    [[ "$role" == "-" ]] && role=""
    got="$(bash "$SR" --decide "$role" "$l" "$ls" "$p" "$ps")"
    if [[ "$got" == "$want" ]]; then
        printf '  ✓ %-6s %-11s/%s %-11s/%s → %-12s %s\n' "${role:-?}" "$l" "$ls" "$p" "$ps" "$got" "$note"
    else
        printf '  ✗ %-6s %-11s/%s %-11s/%s → %s (ждали %s) %s\n' "${role:-?}" "$l" "$ls" "$p" "$ps" "$got" "$want" "$note" >&2
        fails=$((fails+1))
    fi
done <<'TABLE'
MASTER primary     2 primary     2 weight       норма
BACKUP primary     2 primary     2 weight       норма
MASTER primary     1 down        0 weight       резервный_упал_—_master_держит_кворум_весом
MASTER primary     1 non-primary 1 weight       резервный_войдёт_сам
MASTER primary     1 closed      0 weight       резервный_войдёт_сам
BACKUP primary     1 primary     1 rejoin-clean ⚠️раскол:_резервный_стирает_копию_(перезапуск_не_лечит)
MASTER primary     1 primary     1 split        ⚠️раскол:_master_ждёт,_свою_копию_не_трогает
-      primary     1 primary     1 split        ⚠️раскол_без_роли:_ничего_не_стирать
BACKUP non-primary 1 down        0 wait         master_упал:_ждём,_пока_VRRP_сделает_нас_master
MASTER non-primary 1 down        0 bootstrap    новый_master_без_кворума
MASTER non-primary 1 non-primary 1 bootstrap    кворума_нет_ни_у_кого
-      non-primary 1 down        0 wait         ⚠️без_роли_не_повышаться
BACKUP non-primary 1 primary     1 restart      войти_к_живому_primary
MASTER non-primary 1 primary     1 restart      ⚠️primary_у_соседа:_входить,_а_не_bootstrap
MASTER closed      0 down        0 new-cluster  оба_падали,_сосед_мёртв
MASTER closed      0 closed      0 new-cluster  оба_падали
BACKUP closed      0 closed      0 wait         ⚠️второй_new-cluster_=_раскол
BACKUP closed      0 primary     1 restart      войти_к_поднявшемуся
MASTER closed      0 primary     1 restart      ⚠️сосед_сам_поднялся_primary:_входить_к_нему
-      closed      0 down        0 wait         без_роли_не_трогать
BACKUP none        0 primary     2 join         новый_или_чистый_узел
MASTER none        0 down        0 wait         ⚠️кластер_создаёт_только_установщик
MASTER down        0 primary     1 wait         служба_не_отвечает:_её_поднимает_systemd
BACKUP busy        2 primary     2 wait         идёт_передача_состояния
TABLE

if [[ $fails -eq 0 ]]; then echo "  все решения контролёра совпали"; fi
exit $fails
