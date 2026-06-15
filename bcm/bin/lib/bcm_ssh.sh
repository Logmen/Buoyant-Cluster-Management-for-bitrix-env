#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_ssh.sh — SSH-обёртка для удалённого управления узлами кластера
# Все команды выполняются через SSH-ключ, сгенерированный install.sh
# =============================================================================

BCM_SSH_KEY="${BCM_SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}"
BCM_SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2
    -o LogLevel=ERROR
)

# ──── Базовое SSH-выполнение ──────────────────────────────────────────────────
# bcm_ssh_exec <ip> <command>
# Возвращает: stdout команды; exit code = код возврата SSH
bcm_ssh_exec() {
    local ip="$1"
    shift
    local cmd="$*"

    ssh "${BCM_SSH_OPTS[@]}" \
        -i "$BCM_SSH_KEY" \
        "root@${ip}" \
        "$cmd" 2>/dev/null
}

# С выводом stderr (для диагностики)
bcm_ssh_exec_verbose() {
    local ip="$1"
    shift
    local cmd="$*"

    ssh "${BCM_SSH_OPTS[@]}" \
        -i "$BCM_SSH_KEY" \
        "root@${ip}" \
        "$cmd"
}

# ──── Выполнить команду на узле с таймаутом ──────────────────────────────────
bcm_ssh_exec_timeout() {
    local ip="$1"
    local timeout="${2:-15}"
    shift 2
    local cmd="$*"

    timeout "$timeout" ssh "${BCM_SSH_OPTS[@]}" \
        -i "$BCM_SSH_KEY" \
        "root@${ip}" \
        "$cmd" 2>/dev/null
}

# ──── Проверить доступность узла ─────────────────────────────────────────────
# bcm_ssh_reachable <ip>  → 0 если доступен, 1 если нет
bcm_ssh_reachable() {
    local ip="$1"
    local timeout="${2:-5}"
    timeout "$timeout" ssh "${BCM_SSH_OPTS[@]}" \
        -o ConnectTimeout="$timeout" \
        -i "$BCM_SSH_KEY" \
        "root@${ip}" \
        "exit 0" 2>/dev/null
}

# ──── Получить статус сервиса на удалённом узле ──────────────────────────────
# bcm_ssh_service_status <ip> <service>
# Возвращает: "active" | "inactive" | "failed" | "unknown"
bcm_ssh_service_status() {
    local ip="$1"
    local service="$2"
    local status
    if [[ "$service" == "mysqld" || "$service" == "mysql" ]]; then
        status=$(bcm_ssh_exec_timeout "$ip" 8 \
            "systemctl is-active mysqld mysql mysql@bootstrap 2>/dev/null || true")
        if echo "$status" | grep -q "^active$"; then
            status="active"
        elif echo "$status" | grep -q "^activating$"; then
            status="activating"
        elif echo "$status" | grep -q "^failed$"; then
            status="failed"
        else
            status="inactive"
        fi
    else
        status=$(bcm_ssh_exec_timeout "$ip" 8 \
            "systemctl is-active ${service} 2>/dev/null || true")
        status=$(echo "$status" | tr -d '[:space:]')
    fi
    echo "${status:-unknown}"
}

# ──── Выполнить команду на всех узлах слоя параллельно ───────────────────────
# bcm_ssh_all_layer <layer_nodes_array_name> <command>
# Результат: выводит "nodename: output" для каждого узла
bcm_ssh_all_layer() {
    local -n _nodes_arr=$1
    shift
    local cmd="$*"

    declare -A _pids=()
    declare -A _tmpfiles=()

    for node in "${_nodes_arr[@]}"; do
        local ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        local tmpf
        tmpf=$(mktemp)
        _tmpfiles["$node"]="$tmpf"
        bcm_ssh_exec_timeout "$ip" 15 "$cmd" > "$tmpf" 2>&1 &
        _pids["$node"]=$!
    done

    # Дождаться всех
    for node in "${!_pids[@]}"; do
        wait "${_pids[$node]}" 2>/dev/null || true
        local output
        output=$(cat "${_tmpfiles[$node]}" 2>/dev/null)
        rm -f "${_tmpfiles[$node]}"
        echo "${node}: ${output}"
    done
}

# ──── Скопировать файл на удалённый узел ─────────────────────────────────────
bcm_ssh_copy_file() {
    local local_file="$1"
    local ip="$2"
    local remote_path="$3"

    scp -q "${BCM_SSH_OPTS[@]}" \
        -i "$BCM_SSH_KEY" \
        "$local_file" \
        "root@${ip}:${remote_path}" 2>/dev/null
}

# ──── Скопировать файл с удалённого узла ─────────────────────────────────────
bcm_ssh_fetch_file() {
    local ip="$1"
    local remote_path="$2"
    local local_path="$3"

    scp -q "${BCM_SSH_OPTS[@]}" \
        -i "$BCM_SSH_KEY" \
        "root@${ip}:${remote_path}" \
        "$local_path" 2>/dev/null
}

# ──── Раскатать BCM на удалённый узел ────────────────────────────────────────
# bcm_deploy_to_node <ip> <role: web|lb|pxc|s3>
bcm_deploy_to_node() {
    local ip="$1"
    local role="$2"
    local bcm_src="${BCM_INSTALL_SRC:-/opt/bcm}"

    bcm_log_info "Развёртывание BCM на ${ip} (роль: ${role})"

    # Создать директорию на удалённом узле
    bcm_ssh_exec "$ip" "mkdir -p /opt/bcm/bin/lib /opt/bcm/menu /opt/bcm/templates /var/log/bcm /etc/bitrix-cluster"

    # Скопировать SSH-ключи для межсерверного взаимодействия BCM
    bcm_ssh_copy_file "${BCM_SSH_KEY}" "$ip" "/etc/bitrix-cluster/cluster_id_rsa"
    bcm_ssh_copy_file "${BCM_SSH_KEY}.pub" "$ip" "/etc/bitrix-cluster/cluster_id_rsa.pub"
    bcm_ssh_exec "$ip" "chmod 600 /etc/bitrix-cluster/cluster_id_rsa && chmod 644 /etc/bitrix-cluster/cluster_id_rsa.pub"

    # Скопировать общие файлы (включая notify/health-скрипты для keepalived)
    for f in bin/bcm bin/lib/bcm_utils.sh bin/lib/bcm_config.sh \
              bin/lib/bcm_runtime.sh bin/lib/bcm_ssh.sh bin/lib/bcm_cluster_mode.sh \
              bin/lib/cron_notify.sh bin/lib/keepalived_notify.sh \
              bin/lib/redis_session_notify.sh bin/lib/redis_session_check.sh \
              bin/lib/pxc_autorecover.sh bin/lib/lsyncd_role.sh \
              bin/lib/ssl_certs.sh bin/lib/bcm_backup.sh \
              bin/lib/bcm_confedit.sh bin/lib/bcm_update.sh \
              bin/lib/transformer_notify.sh bin/lib/transformer_check.sh VERSION; do
        bcm_ssh_copy_file "${bcm_src}/${f}" "$ip" "/opt/bcm/${f}"
    done
    bcm_ssh_exec "$ip" "chmod +x /opt/bcm/bin/lib/*.sh 2>/dev/null || true"

    # Скопировать шаблоны
    bcm_ssh_exec "$ip" "mkdir -p /opt/bcm/templates"
    rsync -az -e "ssh ${BCM_SSH_OPTS[*]} -i ${BCM_SSH_KEY}" \
        "${bcm_src}/templates/" \
        "root@${ip}:/opt/bcm/templates/" 2>/dev/null || true

    # Скопировать доверенные публичные ключи релизов (для верификации bcm --update)
    if [[ -d "${bcm_src}/keys" ]]; then
        bcm_ssh_exec "$ip" "mkdir -p /opt/bcm/keys"
        rsync -az -e "ssh ${BCM_SSH_OPTS[*]} -i ${BCM_SSH_KEY}" \
            "${bcm_src}/keys/" \
            "root@${ip}:/opt/bcm/keys/" 2>/dev/null || true
    fi

    # Скопировать меню в зависимости от роли
    if [[ "$role" == "web" ]]; then
        # Полное меню — все файлы
        rsync -az -e "ssh ${BCM_SSH_OPTS[*]} -i ${BCM_SSH_KEY}" \
            "${bcm_src}/menu/" \
            "root@${ip}:/opt/bcm/menu/" 2>/dev/null || true
    else
        # Урезанное меню — только нужные модули. Само урезанное меню рисуется
        # bin/bcm инлайн (_show_limited_menu), отдельного файла-меню НЕТ.
        bcm_ssh_exec "$ip" "mkdir -p /opt/bcm/menu"
        bcm_ssh_copy_file "${bcm_src}/menu/02_local_host.sh" "$ip" "/opt/bcm/menu/"
        case "$role" in
            lb)  bcm_ssh_copy_file "${bcm_src}/menu/05_keepalived.sh" "$ip" "/opt/bcm/menu/" ;;
            pxc) bcm_ssh_copy_file "${bcm_src}/menu/03_pxc.sh"        "$ip" "/opt/bcm/menu/" ;;
            s3)  bcm_ssh_copy_file "${bcm_src}/menu/s3_minio.sh"      "$ip" "/opt/bcm/menu/" 2>/dev/null || true ;;
        esac
    fi

    # Права на исполнение
    bcm_ssh_exec "$ip" "chmod +x /opt/bcm/bin/bcm && \
        ln -sf /opt/bcm/bin/bcm /usr/local/bin/bcm 2>/dev/null || true"

    bcm_log_info "BCM развёрнут на ${ip}"
}

# ──── Выполнить несколько команд через here-doc на удалённом узле ─────────────
# bcm_ssh_script <ip> <<'SCRIPT'
# command1
# command2
# SCRIPT
bcm_ssh_script() {
    local ip="$1"
    ssh "${BCM_SSH_OPTS[@]}" \
        -i "$BCM_SSH_KEY" \
        "root@${ip}" \
        "bash -s" 2>/dev/null
}

# ──── Генерация SSH-ключа для кластера ───────────────────────────────────────
# Создаёт уникальную пару ключей, возвращает путь к публичному ключу
bcm_generate_cluster_key() {
    local key_dir="${BCM_CONF_DIR:-/etc/bitrix-cluster}"
    local key_path="${key_dir}/cluster_id_rsa"

    mkdir -p "$key_dir"
    chmod 700 "$key_dir"

    if [[ ! -f "$key_path" ]]; then
        ssh-keygen -t ed25519 \
            -C "bcm-cluster-$(date +%Y%m%d)" \
            -f "$key_path" \
            -N "" \
            -q
        chmod 600 "$key_path"
        chmod 644 "${key_path}.pub"
        bcm_log_info "Сгенерирован SSH-ключ кластера: ${key_path}"
    else
        bcm_log_info "SSH-ключ кластера уже существует: ${key_path}"
    fi

    echo "$key_path"
}

# ──── Раскатать публичный ключ на узел (с паролем) ───────────────────────────
# bcm_copy_key_to_node <ip> <password> <pubkey_path>
bcm_copy_key_to_node() {
    local ip="$1"
    local password="$2"
    local pubkey="${3:-${BCM_SSH_KEY}.pub}"

    # Используем sshpass для первоначальной раскатки
    if ! command -v sshpass &>/dev/null; then
        bcm_log_error "sshpass не установлен. Установите: yum install sshpass"
        return 1
    fi

    local pub_content
    pub_content=$(cat "$pubkey")

    sshpass -p "$password" ssh \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        "root@${ip}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
         echo '${pub_content}' >> ~/.ssh/authorized_keys && \
         chmod 600 ~/.ssh/authorized_keys && \
         sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys" 2>/dev/null
}

# ──── Проверить, что ключ уже раскатан ───────────────────────────────────────
bcm_key_already_deployed() {
    local ip="$1"
    bcm_ssh_reachable "$ip"
}

