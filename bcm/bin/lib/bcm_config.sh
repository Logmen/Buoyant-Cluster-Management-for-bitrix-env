#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_config.sh — Парсер конфигурационного файла кластера
# Читает /etc/bitrix-cluster/cluster.conf и предоставляет API для получения
# топологии. Никаких IP-адресов, имён узлов или версий в коде нет.
# =============================================================================

BCM_CONF_FILE="${BCM_CONF_FILE:-/etc/bitrix-cluster/cluster.conf}"
BCM_CONF_DIR="${BCM_CONF_DIR:-/etc/bitrix-cluster}"

# ──── Проверка наличия конфига ───────────────────────────────────────────────
bcm_conf_exists() {
    [[ -f "$BCM_CONF_FILE" ]]
}

# ──── Получить значение ключа из секции INI ───────────────────────────────────
# bcm_conf_get <section> <key>
# Формат файла: [section] / key = value
bcm_conf_get() {
    local section="$1"
    local key="$2"
    local in_section=0
    local value=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Пропускаем комментарии и пустые строки
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Определяем вход в нужную секцию
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=1
            else
                in_section=0
            fi
            continue
        fi

        # Читаем ключ только внутри нужной секции
        if [[ $in_section -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
                value="${BASH_REMATCH[1]}"
                # Inline-комментарий вырезаем ТОЛЬКО если '#' отделён пробелом/табом
                # (стандарт INI). Безусловный обрез (${value%%#*}) терял '#' внутри
                # значения — напр. admin_password=D8I#... → возвращался "D8I" →
                # ProxySQL Access denied, а single-pin молча «успешен». cluster.conf
                # генерируется install.sh без inline-комментариев на строках значений,
                # так что это лишь защита для ручных правок.
                value="${value%%[[:space:]]#*}"
                value="${value%"${value##*[![:space:]]}"}"
                echo "$value"
                return 0
            fi
        fi
    done < "$BCM_CONF_FILE"

    return 1
}

# ──── Перечислить ключи секции ───────────────────────────────────────────────
# bcm_conf_keys <section> → имена ключей секции, по одному в строке.
# Нужна там, где секция заранее не известна целиком: параметры модуля
# [module.<name>] пишет сам модуль, и ядро обязано отдать хуку всё, что там есть,
# не зная имён. Разбор — тот же, что в bcm_conf_get (комментарии, секции).
bcm_conf_keys() {
    local section="$1" line in_section=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            [[ "${BASH_REMATCH[1]}" == "$section" ]] && in_section=1 || in_section=0
            continue
        fi
        if [[ $in_section -eq 1 && "$line" =~ ^[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]*= ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    done < "$BCM_CONF_FILE"
    return 0
}

# ──── Получить список узлов слоя ─────────────────────────────────────────────
# bcm_get_nodes <layer>  → выводит имена через пробел
# layer: lb | web | pxc | s3
bcm_get_nodes() {
    local layer="$1"
    bcm_conf_get "layer.${layer}" "nodes" | tr ',' ' '
}

# ──── Получить IP узла ────────────────────────────────────────────────────────
# bcm_get_node_ip <layer> <nodename>
bcm_get_node_ip() {
    local layer="$1"
    local node="$2"
    bcm_conf_get "layer.${layer}" "${node}.ip"
}

# ──── Получить приоритет lb-узла ─────────────────────────────────────────────
bcm_get_node_priority() {
    local node="$1"
    bcm_conf_get "layer.lb" "${node}.priority"
}

# ──── Получить роль lb-узла ──────────────────────────────────────────────────
bcm_get_node_role_lb() {
    local node="$1"
    bcm_conf_get "layer.lb" "${node}.role"
}

# ──── Получить VIP ────────────────────────────────────────────────────────────
bcm_get_vip() {
    bcm_conf_get "network" "vip"
}

# ──── Режим кластера: normal | single ────────────────────────────────────────
# single = «режим единой ноды» (вся нагрузка закреплена на одной web-ноде).
bcm_get_cluster_mode() {
    local m
    m=$(bcm_conf_get "cluster" "mode" 2>/dev/null) || m=""
    echo "${m:-normal}"
}

# Активная нода в режиме single (имя web-ноды)
bcm_get_active_node() {
    bcm_conf_get "cluster" "active_node" 2>/dev/null || echo ""
}

# ──── Получить VRID для HA Cron (web Keepalived) ─────────────────────────────
bcm_get_web_vrid() {
    bcm_conf_get "layer.web" "keepalived_vrid"
}

# ──── Получить узел-писатель PXC ─────────────────────────────────────────────
bcm_get_pxc_writer() {
    bcm_conf_get "layer.pxc" "writer"
}

# ──── ProxySQL параметры ──────────────────────────────────────────────────────
bcm_get_proxysql_port()     { bcm_conf_get "proxysql" "port"; }
bcm_get_proxysql_hg_write() { bcm_conf_get "proxysql" "hg_write"; }
bcm_get_proxysql_hg_read()  { bcm_conf_get "proxysql" "hg_read"; }
bcm_get_proxysql_admin_port() { bcm_conf_get "proxysql" "admin_port"; }
bcm_get_proxysql_admin_user() { bcm_conf_get "proxysql" "admin_user"; }
bcm_get_proxysql_admin_pass() { bcm_conf_get "proxysql" "admin_password"; }

# ──── MinIO параметры ────────────────────────────────────────────────────────
bcm_get_s3_port() { bcm_conf_get "layer.s3" "port"; }

# Слой S3 опционален (install.sh допускает 0 нод): без него нет ни облачного
# /upload, ни цели для бэкапов. Меню, завязанные на S3, обязаны это проверять.
# Развёрнут ли СЛОЙ S3 (свои MinIO-ноды). Проверять этим только то, что относится к
# владению нодами: минимумы слоя, добавление/удаление узлов, обслуживание MinIO.
bcm_s3_enabled() {
    local n
    n="$(bcm_get_nodes "s3" 2>/dev/null || echo '')"
    [[ -n "${n// }" ]]
}

# ДОСТУПНО ли объектное хранилище для /upload — независимо от того, наше оно или
# внешнее. Кластеру для облачного /upload ноды не нужны: достаточно бакета, к
# которому дали доступ. Всё, что про использование хранилища (меню 11, решение о
# зеркале /upload в lsyncd, подсказки в меню 7), обязано опираться на этот предикат,
# иначе кластер с внешним бакетом будет считаться «без S3».
bcm_s3_storage_enabled() {
    local ep bk
    ep="$(bcm_conf_get s3_upload endpoint 2>/dev/null || echo '')"
    bk="$(bcm_conf_get s3_upload bucket   2>/dev/null || echo '')"
    [[ -n "${ep// }" && -n "${bk// }" ]]
}

# Хранилище внешнее (бакет провайдера, своих S3-нод нет).
bcm_s3_storage_external() {
    bcm_s3_storage_enabled && ! bcm_s3_enabled
}

# ──── Зеркало /upload между web-нодами ───────────────────────────────────────
# Режим из [lsyncd] upload_mirror: auto (умолчание) | on | off.
#   auto — зеркало держим, пока для /upload нет облачного хранилища;
#   on   — держим ВСЕГДА, в том числе вместе с S3;
#   off  — не держим.
bcm_upload_mirror_mode() {
    local m
    m="$(bcm_conf_get lsyncd upload_mirror 2>/dev/null || echo '')"
    m="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$m" in
        on|yes|y|1)  echo on  ;;
        off|no|n|0)  echo off ;;
        *)           echo auto ;;
    esac
}

# ⚠️ ЕДИНСТВЕННЫЙ источник правды о зеркале /upload. На него обязаны опираться и
# сам юнит lsyncd-upload (меню 6 → 10, install.sh), и блок /upload в ОСНОВНОМ
# конфиге lsyncd (меню 6 → 3, lsyncd_role.sh): одно дерево не должны толкать два
# инстанса разом. Поэтому «зеркало включено» ⇒ основной lsyncd /upload не трогает.
#
# Почему on имеет смысл вместе с S3: в бакет уходит только то, что попало под
# FILE_RULES (у существующих порталов правила часто узкие — крупные файлы, медиа),
# а статика модулей, resize_cache и всё, что осталось локально, обязано быть на
# ВСЕХ web-нодах — иначе round-robin отдаёт 404.
bcm_upload_mirror_wanted() {
    case "$(bcm_upload_mirror_mode)" in
        on)  return 0 ;;
        off) return 1 ;;
        *)   ! bcm_s3_storage_enabled ;;
    esac
}

# ──── Хост-маска для учёток MySQL (bitrix, bitrix_ro, monitor) ────────────────
# Все ноды в одной /24 → «a.b.c.%», иначе '%'. Логика — в bcm_pxc_harden.sh
# (её же зовёт install.sh со своими массивами IP).
bcm_mysql_host_pattern() {
    [[ -f "${BCM_LIB_DIR}/bcm_pxc_harden.sh" ]] && source "${BCM_LIB_DIR}/bcm_pxc_harden.sh"
    bcm_pxch_host_pattern "${BCM_NODE_IP[@]}"
}

# ──── Пароль БД портала: что РЕАЛЬНО использует приложение ───────────────────
# Источник правды — bitrix/.settings.php на web-ноде: именно с ним ходит портал,
# ProxySQL (mysql_users) и учётки PXC. [proxysql] bitrix_db_password в cluster.conf
# — копия с момента установки, и она ОТСТАЁТ, если пароль меняли мимо BCM (портал
# переехал со своим паролем; ловили вживую: selftest dbrouter и проверки из меню
# давали «Access denied» при рабочем кластере). Поэтому инструменты читают пароль
# отсюда, а cluster.conf — лишь фолбэк, когда .settings.php недоступен (brain-нода
# не web, портал ещё не развёрнут).
BCM_PORTAL_SETTINGS="${BCM_PORTAL_SETTINGS:-/home/bitrix/www/bitrix/.settings.php}"

bcm_portal_settings_db_password() {
    [[ -r "$BCM_PORTAL_SETTINGS" ]] && command -v php >/dev/null 2>&1 || return 1
    php -r '$s=include $argv[1]; $d=$s["connections"]["value"]["default"] ?? []; echo (string)($d["password"] ?? "");'         "$BCM_PORTAL_SETTINGS" 2>/dev/null
}

bcm_portal_db_password() {
    local p
    p="$(bcm_portal_settings_db_password 2>/dev/null || true)"
    [[ -n "$p" ]] && { printf '%s' "$p"; return 0; }
    bcm_conf_get proxysql bitrix_db_password 2>/dev/null
}

# 0 — cluster.conf расходится с .settings.php (оба прочитаны и различны).
bcm_portal_db_password_mismatch() {
    local a b
    a="$(bcm_portal_settings_db_password 2>/dev/null || true)"; [[ -n "$a" ]] || return 1
    b="$(bcm_conf_get proxysql bitrix_db_password 2>/dev/null || true)"; [[ -n "$b" ]] || return 1
    [[ "$a" != "$b" ]]
}

# ──── SSH ключ кластера ───────────────────────────────────────────────────────
bcm_get_ssh_key() {
    bcm_conf_get "ssh" "private_key"
}

# ──── Определить роль текущего узла в кластере ───────────────────────────────
# Сравниваем hostname и IP текущей машины со всеми записями конфига
# Возвращает: web | lb | pxc | s3 | unknown
bcm_get_current_role() {
    local current_hostname
    current_hostname=$(hostname -s 2>/dev/null || hostname)
    local current_ips
    current_ips=$(hostname -I 2>/dev/null || ip addr show | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

    local layer node nodes node_ip node_name
    for layer in lb web pxc s3; do
        nodes=$(bcm_get_nodes "$layer") || continue
        for node in $nodes; do
            node_ip=$(bcm_get_node_ip "$layer" "$node") || continue
            node_name=$(bcm_conf_get "layer.${layer}" "${node}.hostname" 2>/dev/null || echo "$node")

            # Совпадение по hostname или по IP
            if [[ "$current_hostname" == "$node" ]] || \
               [[ "$current_hostname" == "$node_name" ]] || \
               echo "$current_ips" | grep -qw "$node_ip"; then
                echo "$layer"
                return 0
            fi
        done
    done

    echo "unknown"
    return 1
}

# ──── Проверить, является ли текущий узел web-нодой (мозгом) ─────────────────
bcm_is_web_node() {
    local role
    role=$(bcm_get_current_role)
    [[ "$role" == "web" ]]
}

# ──── Получить имя текущего узла в кластере ──────────────────────────────────
bcm_get_current_node_name() {
    local current_hostname
    current_hostname=$(hostname -s 2>/dev/null || hostname)
    local current_ips
    current_ips=$(hostname -I 2>/dev/null)

    local layer node nodes node_ip
    for layer in lb web pxc s3; do
        nodes=$(bcm_get_nodes "$layer") || continue
        for node in $nodes; do
            node_ip=$(bcm_get_node_ip "$layer" "$node") || continue
            if [[ "$current_hostname" == "$node" ]] || \
               echo "$current_ips" | grep -qw "$node_ip"; then
                echo "$node"
                return 0
            fi
        done
    done

    hostname -s
}

# ──── Загрузить всю топологию в переменные (кэш для текущего запуска) ─────────
# После вызова доступны массивы BCM_NODES_LB, BCM_NODES_WEB, BCM_NODES_PXC, BCM_NODES_S3
# и ассоциативный массив BCM_NODE_IP[nodename]
declare -gA BCM_NODE_IP=()
declare -gA BCM_NODE_LAYER=()
declare -gA BCM_NODE_MAINT=()
declare -ga BCM_NODES_LB=()
declare -ga BCM_NODES_WEB=()
declare -ga BCM_NODES_PXC=()
declare -ga BCM_NODES_S3=()
declare -g  BCM_CONF_VIP=""
declare -g  BCM_CONF_LOADED=0

bcm_load_topology() {
    [[ $BCM_CONF_LOADED -eq 1 ]] && return 0
    bcm_conf_exists || return 1

    # ⚠️ Сброс ассоциативных массивов перед перезаливкой. Индексные BCM_NODES_*
    # ниже переприсваиваются целиком, а вот ассоциативные только ДОПОЛНЯЛИСЬ →
    # удалённый из nodes-списка узел оставался в BCM_NODE_LAYER/IP/MAINT после
    # reload (BCM_CONF_LOADED=0). Симптом: узел удалён (нет в таблице/обходе
    # nodes-списка), но _cn_add_node по BCM_NODE_LAYER считал его существующим
    # → «узел уже существует», повторно добавить нельзя.
    BCM_NODE_IP=()
    BCM_NODE_LAYER=()
    BCM_NODE_MAINT=()

    BCM_CONF_VIP=$(bcm_get_vip)

    # ⚠️ layer/node/nodes ОБЯЗАНЫ быть local: bash динамически скоупит, и без local
    # эта функция затирала бы одноимённые переменные ВЫЗЫВАЮЩЕЙ функции. Симптом
    # (ловили вживую): после bcm_load_topology у вызвавшего меню $layer становился
    # "s3" (последняя итерация) → «узел добавлен в слой 's3'» при выборе web; в
    # _cn_add_node это испортило бы и слой подсказки install_answers.conf.
    local layer node nodes nodes_str
    local layers=("lb" "web" "pxc" "s3")
    for layer in "${layers[@]}"; do
        nodes_str=$(bcm_get_nodes "$layer" 2>/dev/null) || continue
        read -ra nodes <<< "$nodes_str"
        for node in "${nodes[@]}"; do
            [[ -z "$node" ]] && continue
            local ip
            ip=$(bcm_get_node_ip "$layer" "$node") || continue
            BCM_NODE_IP["$node"]="$ip"
            BCM_NODE_LAYER["$node"]="$layer"
            local maint
            maint=$(bcm_conf_get "layer.${layer}" "${node}.maintenance" 2>/dev/null || echo "0")
            BCM_NODE_MAINT["$node"]="$maint"
        done

        case "$layer" in
            lb)  BCM_NODES_LB=("${nodes[@]}") ;;
            web) BCM_NODES_WEB=("${nodes[@]}") ;;
            pxc) BCM_NODES_PXC=("${nodes[@]}") ;;
            s3)  BCM_NODES_S3=("${nodes[@]}") ;;
        esac
    done

    BCM_CONF_LOADED=1
    return 0
}

# Проверить, находится ли узел в режиме обслуживания
bcm_node_in_maintenance() {
    local node="$1"
    [[ "${BCM_NODE_MAINT[$node]:-0}" == "1" ]]
}

# Синхронизировать cluster.conf на все остальные доступные узлы кластера
bcm_conf_sync() {
    bcm_load_topology
    local self_node
    self_node=$(bcm_get_current_node_name 2>/dev/null || hostname -s)
    # layer/node/nodes — local (см. примечание в bcm_load_topology про дин. скоуп).
    local layer node nodes nodes_str
    local layers=("lb" "web" "pxc" "s3")
    for layer in "${layers[@]}"; do
        nodes_str=$(bcm_get_nodes "$layer" 2>/dev/null) || continue
        read -ra nodes <<< "$nodes_str"
        for node in "${nodes[@]}"; do
            [[ -z "$node" ]] && continue
            [[ "$node" == "$self_node" ]] && continue
            local ip
            ip=$(bcm_get_node_ip "$layer" "$node") || continue
            
            # Проверить доступность узла и скопировать файл
            if bcm_node_reachable "$ip" 3 2>/dev/null; then
                if declare -f bcm_ssh_copy_file >/dev/null; then
                    bcm_ssh_copy_file "$BCM_CONF_FILE" "$ip" "$BCM_CONF_FILE"
                else
                    scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=3 \
                        -i "${BCM_SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}" \
                        "$BCM_CONF_FILE" "root@${ip}:${BCM_CONF_FILE}" 2>/dev/null || true
                fi
                # cluster.conf несёт пароли в открытом виде — закрыть права на ноде.
                if declare -f bcm_ssh_exec >/dev/null; then
                    # </dev/null — иначе ssh съест ввод оператора (см. bcm_node_reachable).
                    bcm_ssh_exec "$ip" "chmod 600 ${BCM_CONF_FILE}" </dev/null 2>/dev/null || true
                else
                    ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=3 \
                        -i "${BCM_SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}" \
                        "root@${ip}" "chmod 600 ${BCM_CONF_FILE}" 2>/dev/null || true
                fi
            fi
        done
    done
}

# ──── Сохранить изменение в конфиг ──────────────────────────────────────────
# bcm_conf_set <section> <key> <value>
bcm_conf_set() {
    local section="$1"
    local key="$2"
    local value="$3"
    local tmpfile
    tmpfile=$(mktemp)
    local in_section=0
    local key_updated=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            # Если мы выходим из нужной секции, а ключ не обновлён — добавляем
            if [[ $in_section -eq 1 && $key_updated -eq 0 ]]; then
                echo "${key} = ${value}" >> "$tmpfile"
                key_updated=1
            fi
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=1
            else
                in_section=0
            fi
            echo "$line" >> "$tmpfile"
            continue
        fi

        if [[ $in_section -eq 1 ]] && \
           [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
            echo "${key} = ${value}" >> "$tmpfile"
            key_updated=1
            continue
        fi

        echo "$line" >> "$tmpfile"
    done < "$BCM_CONF_FILE"

    # ⚠️ Целевая секция — ПОСЛЕДНЯЯ в файле и ключа в ней не было: на EOF мы всё ещё
    # внутри неё (нового заголовка, который дописал бы ключ, не встретилось). Добавляем
    # ключ в существующую секцию. БЕЗ этого создавался бы ДУБЛИКАТ [section] в конце
    # (ловили на новой [mail]: relay_host уезжал во вторую [mail]).
    if [[ $in_section -eq 1 && $key_updated -eq 0 ]]; then
        echo "${key} = ${value}" >> "$tmpfile"
        key_updated=1
    fi

    # Если секции вообще не было — создаём
    if [[ $key_updated -eq 0 ]]; then
        echo "" >> "$tmpfile"
        echo "[${section}]" >> "$tmpfile"
        echo "${key} = ${value}" >> "$tmpfile"
    fi

    cp "$tmpfile" "$BCM_CONF_FILE"
    rm -f "$tmpfile"
    BCM_CONF_LOADED=0   # сбросить кэш после изменения
}

# ──── Добавить узел в слой ────────────────────────────────────────────────────
# bcm_conf_add_node <layer> <nodename> <ip>
bcm_conf_add_node() {
    local layer="$1"
    local node="$2"
    local ip="$3"

    # Добавить в список nodes
    local current_nodes
    current_nodes=$(bcm_conf_get "layer.${layer}" "nodes" 2>/dev/null || echo "")
    if [[ -z "$current_nodes" ]]; then
        bcm_conf_set "layer.${layer}" "nodes" "$node"
    elif ! echo "$current_nodes" | grep -qw "$node"; then
        bcm_conf_set "layer.${layer}" "nodes" "${current_nodes},${node}"
    fi

    # Добавить IP
    bcm_conf_set "layer.${layer}" "${node}.ip" "$ip"
    BCM_CONF_LOADED=0
}

# ──── Удалить узел из слоя ────────────────────────────────────────────────────
bcm_conf_remove_node() {
    local layer="$1"
    local node="$2"

    local current_nodes
    current_nodes=$(bcm_conf_get "layer.${layer}" "nodes" 2>/dev/null || echo "")
    # Удалить из списка
    local new_nodes
    # ⚠️ pipefail: grep -v (rc1 если удаляем единственную ноду → пустой вывод) просочился
    # бы через | tr | sed (rc0) → присваивание rc1 → set -e. Пустой список здесь валиден.
    new_nodes=$(echo "$current_nodes" | tr ',' '\n' | grep -v "^${node}$" | tr '\n' ',' | sed 's/,$//' || true)
    bcm_conf_set "layer.${layer}" "nodes" "$new_nodes"

    # Удалить осиротевшие пер-нодовые ключи (иначе `<node>.ip` и пр. остаются в
    # cluster.conf мусором; при повторном добавлении узла с тем же именем они бы
    # «всплыли»). Все возможные пер-нодовые ключи слоёв.
    local k
    for k in ip maintenance priority role; do
        bcm_conf_delete_key "layer.${layer}" "${node}.${k}"
    done
    BCM_CONF_LOADED=0
}

# ──── Удалить ключ из секции ──────────────────────────────────────────────────
# bcm_conf_delete_key <section> <key> — no-op, если секции/ключа нет.
bcm_conf_delete_key() {
    local section="$1"
    local key="$2"
    local tmpfile
    tmpfile=$(mktemp)
    local in_section=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=1
            else
                in_section=0
            fi
            echo "$line" >> "$tmpfile"
            continue
        fi
        # Внутри нужной секции пропускаем (удаляем) точное совпадение ключа.
        if [[ $in_section -eq 1 ]] && \
           [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
            continue
        fi
        echo "$line" >> "$tmpfile"
    done < "$BCM_CONF_FILE"

    cp "$tmpfile" "$BCM_CONF_FILE"
    rm -f "$tmpfile"
    BCM_CONF_LOADED=0
}

# ──── Сгенерировать шаблон cluster.conf ──────────────────────────────────────
# Используется install.sh
# bcm_generate_conf <vip> <lb_nodes_csv> <web_nodes_csv> <pxc_nodes_csv> <s3_nodes_csv>
# Узлы задаются через ассоциативный массив, вызывающий скрипт сам формирует контент
bcm_write_conf_header() {
    local conf_file="$1"
    cat > "$conf_file" << 'CONF_HEADER'
# /etc/bitrix-cluster/cluster.conf
# Сгенерировано bcm install.sh
# НЕ редактировать вручную без необходимости.
# Все IP-адреса, имена узлов, порты задаются здесь.
# Версии компонентов определяются в рантайме опросом узлов.

[meta]
app_version_source = runtime
benv_version_source = runtime
generated_by = bcm-install

CONF_HEADER
}

