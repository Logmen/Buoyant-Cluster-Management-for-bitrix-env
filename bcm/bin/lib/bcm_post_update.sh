#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181
# =============================================================================
# bcm_post_update.sh [версия] — доводка кластера под НОВЫЙ пакет BCM.
#
# ⚠️⚠️ Зачем отдельный процесс. `bcm --update` исполняется кодом ПРЕДЫДУЩЕЙ
# версии: её библиотеки уже загружены в память, когда новый пакет ложится в
# /opt/bcm. Всё, что должно сделать именно новое ядро, при этом не выполняется —
# ловили дважды: каталог ключей модулей (1.0.23) и охрана crypto_key стражем
# (1.0.30) появились на кластерах только после ручных шагов. Поэтому апдейтер
# лишь ЗАПУСКАЕТ этот файл из свежего пакета, а знание «что довести» живёт здесь
# и приезжает вместе с новой версией.
#
# Апдейтер вызывает его, начиная с 1.0.31. Значит, при обновлении С 1.0.31 и
# дальше шаги ниже выполняются сами; до этого — запуском руками:
#   /opt/bcm/bin/lib/bcm_post_update.sh
#
# Шаги (все идемпотентны, повторный запуск ничего не портит):
#   1. эталоны стража настроек — дописать секции, которые начали охраняться в
#      новой версии (bcm_settings_guard.sh --merge-new); уже снятые не трогаются;
#   2. наборы logrotate BCM на всех узлах — к текущей версии (bcm_logrotate.sh);
#   3. каталог ключей поставщиков модулей на всех узлах.
# =============================================================================
set -uo pipefail

BCM_BASE_DIR="${BCM_BASE_DIR:-/opt/bcm}"
BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"
source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_logrotate.sh"

[[ $EUID -eq 0 ]] || { bcm_error "нужны права root"; exit 1; }
bcm_load_topology || { bcm_error "не удалось прочитать топологию"; exit 1; }
VER="${1:-$(cat "${BCM_BASE_DIR}/VERSION" 2>/dev/null)}"
GUARD="/opt/bcm/bin/lib/bcm_settings_guard.sh"
fail=0

bcm_info "Доводка кластера под BCM ${VER}"

# ──── 1. Эталоны стража ──────────────────────────────────────────────────────
# ⚠️ Порядок: приёмники lsyncd первыми, источник последним. Новое наложение
# источника уезжает lsyncd'ом на приёмники, и там оно должно совпасть с УЖЕ
# дописанным эталоном — иначе страж приёмника откатит его к старому.
bcm_info "1. Эталоны стража настроек портала:"
declare -a recv=() src=()
for n in "${BCM_NODES_WEB[@]}"; do
    ip="${BCM_NODE_IP[$n]:-}"; [[ -n "$ip" ]] || continue
    if ! bcm_node_reachable "$ip" 5 2>/dev/null; then bcm_warn "  ${n}: недоступен — пропуск."; fail=1; continue; fi
    if [[ "$(bcm_ssh_exec_timeout "$ip" 10 "systemctl is-active lsyncd 2>/dev/null" </dev/null)" == "active" ]]; then
        src+=("$n $ip")
    else
        recv+=("$n $ip")
    fi
done
for row in "${recv[@]}" "${src[@]}"; do
    [[ -n "$row" ]] || continue
    read -r n ip <<< "$row"
    out="$(bcm_ssh_exec_timeout "$ip" 60 "[ -x '$GUARD' ] || { echo 'страж не установлен'; exit 0; }; '$GUARD' --merge-new 2>&1" </dev/null)" || fail=1
    printf '  %-6s %s\n' "$n" "${out:-нет ответа}"
done

# ──── 2. Наборы logrotate ────────────────────────────────────────────────────
bcm_info "2. Наборы logrotate BCM на узлах:"
bcm_lr_deploy_all || fail=1

# ──── 3. Каталог ключей поставщиков модулей ──────────────────────────────────
bcm_info "3. Каталог ключей поставщиков модулей:"
ok=0; total=0
for n in "${!BCM_NODE_IP[@]}"; do
    ip="${BCM_NODE_IP[$n]}"; total=$((total+1))
    bcm_ssh_exec_timeout "$ip" 15 "mkdir -p /etc/bitrix-cluster/module-keys && chmod 755 /etc/bitrix-cluster/module-keys" </dev/null && ok=$((ok+1))
done
printf '  есть на %d из %d узлов\n' "$ok" "$total"
[[ $ok -eq $total ]] || fail=1

echo
if [[ $fail -eq 0 ]]; then
    bcm_ok "Доводка под ${VER} завершена."
else
    bcm_warn "Доводка под ${VER} прошла не везде — см. выше; повторить: ${BCM_LIB_DIR}/bcm_post_update.sh"
fi
exit $fail
