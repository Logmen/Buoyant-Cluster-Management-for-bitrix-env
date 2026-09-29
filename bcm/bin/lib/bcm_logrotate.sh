#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181
# =============================================================================
# bcm_logrotate.sh — наборы logrotate, которые заводит BCM.
#
#   bcm-node     на КАЖДОМ узле: журналы самого BCM (/var/log/bcm) и то, что BCM
#                заводит сам по роли (keepalived на lb, MinIO на s3);
#   bcm-install  там, где запускали установщик: только /bcm/logs.
#
# Библиотека (install.sh берёт отсюда содержимое наборов) и команда:
#   bcm_logrotate.sh --deploy   привести наборы на всех узлах к текущей версии
#   bcm_logrotate.sh --check    только показать, что logrotate отвергает (logrotate -d)
#
# ⚠️⚠️ Почему это не только забота установщика. Наборы писал install.sh — и
# исправление 1.0.26 («BCM описывал чужие логи») до живых кластеров не доехало:
# bcm --update файлы в /etc/logrotate.d не трогает. На crm.onelab.kz с 16.08 стоял
# старый bcm-node, описывавший журналы haproxy/nginx/proxysql/lsyncd. Один и тот
# же файл в двух наборах logrotate считает дублем и пропускает ОБА набора целиком:
# не ротировались ни чужие журналы (nginx на web-нодах дорос до 160+ МБ), ни сам
# bcm-node. Теперь наборы приводятся к текущим при каждом обновлении ядра
# (bcm_post_update.sh), а install.sh пишет их из этой же библиотеки.
#
# ⚠️ Инвариант: BCM описывает ТОЛЬКО журналы, которые заводит сам. У nginx,
# httpd, proxysql, lsyncd, haproxy, mysql есть наборы от их пакетов (для mysql —
# почасовой набор BCM вне /etc/logrotate.d, см. install.sh). Второе описание того
# же файла ломает ротацию обоих наборов.
#
# ⚠️ Каталог /etc/logrotate.d читается ЦЕЛИКОМ: logrotate пропускает лишь пару
# расширений (.rpmnew, .rpmsave, ~ и т.п.), а копия «bcm-node.bcm-bak-…» для него —
# обычный набор-дубль. Такие копии выносим в /var/backups/bcm-logrotate/.
# =============================================================================

BCM_LR_DIR="/etc/logrotate.d"
BCM_LR_BACKUP_ROOT="/var/backups/bcm-logrotate"

# Содержимое bcm-node для роли lb|web|pxc|s3.
bcm_lr_render_node() {
    local role="${1:-}"
    cat <<'EOF'
# Настройки ротации логов BCM (на всех узлах).
# Файл генерирует BCM (bin/lib/bcm_logrotate.sh) и приводит к текущей версии при
# каждом обновлении ядра — правки здесь будут перезаписаны.
# ⚠️ Только журналы, которые заводит сам BCM: второе описание чужого журнала
# (nginx, haproxy, proxysql, lsyncd, mysql) ломает ротацию обоих наборов.
/var/log/bcm/*.log {
    daily
    rotate 4
    size 10M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    case "$role" in
        lb)
            cat <<'EOF'

# Keepalived (у haproxy есть собственный конфиг пакета — не дублируем)
/var/log/keepalived.log {
    daily
    rotate 4
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
            ;;
        s3)
            cat <<'EOF'

# MinIO S3
/var/log/minio/*.log {
    daily
    rotate 4
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
            ;;
    esac
}

# Содержимое bcm-install (журналы установщика на управляющей машине).
# ⚠️ Только /bcm/logs: /var/log/bcm описывает bcm-node на каждой ноде, включая ту,
# с которой запускали установщик, — дубль выключил бы оба набора.
bcm_lr_render_install() {
    cat <<'EOF'
# Журналы установщика BCM. Файл генерирует BCM (bin/lib/bcm_logrotate.sh).
/bcm/logs/*.log {
    daily
    rotate 5
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

# Привести наборы BCM на одном узле к текущей версии и проверить logrotate -d.
# Печатает «изменено: …» и отказы logrotate, которые остались (чужие наборы
# BCM не трогает — только сообщает). rc 0 — узел ответил.
bcm_lr_apply_node() {
    local ip="$1" role="$2" t_node t_inst
    t_node="$(mktemp)"; t_inst="$(mktemp)"
    bcm_lr_render_node "$role" > "$t_node"
    bcm_lr_render_install > "$t_inst"
    if ! bcm_ssh_copy_file "$t_node" "$ip" "/tmp/bcm-node.lr.new" || ! bcm_ssh_copy_file "$t_inst" "$ip" "/tmp/bcm-install.lr.new"; then
        rm -f "$t_node" "$t_inst"; echo "не удалось скопировать наборы на узел"; return 1
    fi
    rm -f "$t_node" "$t_inst"
    bcm_ssh_exec_timeout "$ip" 60 "
        D='${BCM_LR_DIR}'; B='${BCM_LR_BACKUP_ROOT}/'\$(date +%Y%m%d-%H%M%S); ch=''
        mkdir -p /var/log/bcm
        # Посторонние копии наших наборов внутри каталога include — наружу.
        for f in \"\$D\"/bcm-node.* \"\$D\"/bcm-install.* \"\$D\"/*.bcm-bak*; do
            [ -e \"\$f\" ] || continue
            mkdir -p \"\$B\" && mv -f \"\$f\" \"\$B\"/ && ch=\"\$ch вынесен:\$(basename \"\$f\")\"
        done
        if ! cmp -s /tmp/bcm-node.lr.new \"\$D/bcm-node\"; then
            [ -f \"\$D/bcm-node\" ] && { mkdir -p \"\$B\"; cp -a \"\$D/bcm-node\" \"\$B\"/; }
            install -m 644 /tmp/bcm-node.lr.new \"\$D/bcm-node\" && ch=\"\$ch bcm-node\"
        fi
        # bcm-install — только там, где он уже есть (там запускали установщик).
        if [ -f \"\$D/bcm-install\" ] && ! cmp -s /tmp/bcm-install.lr.new \"\$D/bcm-install\"; then
            mkdir -p \"\$B\"; cp -a \"\$D/bcm-install\" \"\$B\"/
            install -m 644 /tmp/bcm-install.lr.new \"\$D/bcm-install\" && ch=\"\$ch bcm-install\"
        fi
        rm -f /tmp/bcm-node.lr.new /tmp/bcm-install.lr.new
        echo \"изменено:\${ch:- ничего}\"
        logrotate -d /etc/logrotate.conf 2>&1 | grep '^error' | sed 's/^error: /отвергает: /' | sort -u | head -8
        true" </dev/null
}

# Все узлы топологии. Требует bcm_config.sh/bcm_ssh.sh.
bcm_lr_deploy_all() {
    bcm_load_topology || return 1
    local node ip layer out bad=0
    local -a nodes=()
    mapfile -t nodes < <(for node in "${!BCM_NODE_IP[@]}"; do echo "$node"; done | sort)
    for node in "${nodes[@]}"; do
        ip="${BCM_NODE_IP[$node]}"; layer="${BCM_NODE_LAYER[$node]:-}"
        [[ -n "$ip" && -n "$layer" ]] || continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "  ${node} (${ip}): недоступен — пропуск."; bad=1; continue
        fi
        out="$(bcm_lr_apply_node "$ip" "$layer")" || bad=1
        printf '  %-6s %-4s %s\n' "$node" "$layer" "$(printf '%s' "$out" | head -1)"
        printf '%s\n' "$out" | tail -n +2 | sed 's/^/                /'
    done
    return $bad
}

# Только проверка: что logrotate отвергает на каждом узле.
bcm_lr_check_all() {
    bcm_load_topology || return 1
    local node ip out
    local -a nodes=()
    mapfile -t nodes < <(for node in "${!BCM_NODE_IP[@]}"; do echo "$node"; done | sort)
    for node in "${nodes[@]}"; do
        ip="${BCM_NODE_IP[$node]}"
        out="$(bcm_ssh_exec_timeout "$ip" 30 "logrotate -d /etc/logrotate.conf 2>&1 | grep '^error' | sed 's/^error: //' | sort -u | head -8" </dev/null)"
        if [[ -z "$out" ]]; then
            printf '  %-6s чисто\n' "$node"
        else
            printf '  %-6s отвергает:\n' "$node"
            printf '%s\n' "$out" | sed 's/^/           /'
        fi
    done
    return 0
}

# ──── Команда ────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    BCM_BASE_DIR="${BCM_BASE_DIR:-/opt/bcm}"
    BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"
    source "${BCM_LIB_DIR}/bcm_utils.sh"
    source "${BCM_LIB_DIR}/bcm_config.sh"
    source "${BCM_LIB_DIR}/bcm_ssh.sh"
    case "${1:---check}" in
        --deploy) bcm_info "Наборы logrotate BCM → текущая версия на всех узлах:"; bcm_lr_deploy_all ;;
        --check)  bcm_info "Что отвергает logrotate на узлах:"; bcm_lr_check_all ;;
        *) echo "Использование: $(basename "$0") --deploy | --check"; exit 1 ;;
    esac
fi
