#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# install.sh — Скрипт автоматического развёртывания HA-кластера Bitrix
# =============================================================================
set -euo pipefail

# ──── Определение путей ──────────────────────────────────────────────────────
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BCM_BASE_DIR="${INSTALL_DIR}/bcm"
export BCM_LIB_DIR="${BCM_BASE_DIR}/bin/lib"
export BCM_CONF_DIR="/tmp/bcm-install-conf"
export BCM_SSH_KEY="${BCM_CONF_DIR}/cluster_id_rsa"
export BCM_CONF_FILE="${BCM_CONF_DIR}/cluster.conf"
export BCM_INSTALL_SRC="${INSTALL_DIR}/bcm"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: Этот скрипт должен быть запущен от root." >&2
    exit 1
fi

# Инициализация логирования
LOG_FILE="/var/log/bcm/install.log"
mkdir -p "$(dirname "$LOG_FILE")"
echo "=== Начало установки $(date) ===" >> "$LOG_FILE"

# Логирование на экран и в файл
log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $*"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

log_ok() {
    echo -e "\033[1;32m[ OK ]\033[0m $*"
    echo "[OK] $(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*"
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

log_error() {
    echo -e "\033[1;31m[FAIL]\033[0m $*" >&2
    echo "[FAIL] $(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# Инициализация каталога логирования каждой ноды
NODE_LOGS_DIR="/bcm/logs"

bcm_ssh_exec_logged() {
    local node_name="$1"
    local ip="$2"
    shift 2
    local cmd="$*"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "[DRY RUN] ssh root@$ip '$cmd'"
        return 0
    fi

    mkdir -p "$NODE_LOGS_DIR" 2>/dev/null || true
    local log_file="${NODE_LOGS_DIR}/${node_name}.log"

    echo -e "\n=== CMD EXEC AT $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$log_file"
    echo "Command: $cmd" >> "$log_file"
    echo "===============================================" >> "$log_file"

    local exit_code=0
    bcm_ssh_exec "$ip" "$cmd" >> "$log_file" 2>&1 || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo -e "=== ERROR: exit code $exit_code at $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$log_file"
        log_warn "Ошибка при выполнении на $node_name ($ip). См. подробности: ${log_file}"
        return $exit_code
    fi
    return 0
}

# Подключить утилиты, если доступны
if [[ -f "${BCM_LIB_DIR}/bcm_utils.sh" ]]; then
    # shellcheck disable=SC1091
    source "${BCM_LIB_DIR}/bcm_utils.sh"
    # shellcheck disable=SC1091
    source "${BCM_LIB_DIR}/bcm_ssh.sh"
fi

# ──── Аргументы командной строки ─────────────────────────────────────────────
ANSWERS_FILE=""
DRY_RUN=0

_print_usage() {
    echo "Использование: $0 [ОПЦИИ]"
    echo "  -a, --answers-file <путь>   Установка в неинтерактивном режиме с файлом ответов"
    echo "  -d, --dry-run               Показать шаги без выполнения реальных изменений"
    echo "  -h, --help                  Справка"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --answers-file|-a)
            ANSWERS_FILE="$2"
            shift 2
            ;;
        --dry-run|-d)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            _print_usage
            exit 0
            ;;
        *)
            log_error "Неизвестный параметр: $1"
            _print_usage
            exit 1
            ;;
    esac
done

# Переменные для топологии
VIP=""
declare -A LB_IPS=()
declare -A WEB_IPS=()
declare -A PXC_IPS=()
declare -A S3_IPS=()
PXC_WRITER=""
S3_PORT="9000"
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_UPLOAD_BUCKET="bitrix-upload"
# Домен virtual-host для S3: модуль Bitrix «Облачные хранилища» обращается к
# bucket.<домен>; <домен> и bucket.<домен> резолвятся на web-нодах в /etc/hosts на
# S3-VIP, MinIO получает MINIO_DOMAIN=<домен>. По умолчанию не-маршрутизируемый .lab.
S3_VHOST_DOMAIN="s3.bitrix.lab"
# Опционально: выделенный диск под хранилище MinIO на S3-нодах.
# S3_DATA_DISK — одно блочное устройство для ВСЕХ S3-нод (напр. /dev/sdb);
# S3_DATA_DISKS_LIST — пер-нодовые устройства "имя:устройство,..." (приоритет выше).
# Если ничего не задано — данные MinIO лежат на корневой ФС (как раньше).
# S3_DATA_MOUNT — точка монтирования диска (данные в <mount>/data).
# S3_DATA_FS — xfs (рекомендация MinIO) или ext4. S3_DATA_DISK_FORCE=1 — форматировать,
# даже если на устройстве уже есть ФС (⚠️ УНИЧТОЖАЕТ данные).
S3_DATA_DISK=""
S3_DATA_DISKS_LIST=""
declare -A S3_DATA_DISKS=()
S3_DATA_MOUNT="/var/lib/minio"
S3_DATA_FS="xfs"
S3_DATA_DISK_FORCE="0"
PROXYSQL_PORT="6033"
PROXYSQL_ADMIN_PORT="6032"
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="admin"
PROXYSQL_MONITOR_USER="monitor"
PROXYSQL_MONITOR_PASS="monitorpass"
BITRIX_DB_USER="bitrix"
BITRIX_DB_PASS="bitrixpass"
WEB_VRID="56"
# Redis-хранилище сессий (HA: master-replica + плавающий VIP)
SESSION_VIP=""
SESSION_REDIS_PORT="6380"
SESSION_VRID="57"
SESSION_REDIS_MAXMEM="256mb"
# Общий Redis для каналов Push&Pull (HA: master-replica + плавающий PUSH_VIP) —
# чтобы push работал active-active (сообщение с любой ноды доходит до подписчика на
# любой). Пусто PUSH_REDIS_VIP → шаг пропускается.
PUSH_REDIS_VIP=""
PUSH_REDIS_PORT="6381"
PUSH_VRID="58"
PUSH_REDIS_MAXMEM="512mb"
# Общий Redis под кэш Bitrix (managed_cache + cache) — HA master-replica + плавающий
# CACHE_VIP. Делает кэш общим между web-нодами (консистентная инвалидация по тегам).
# Пусто CACHE_REDIS_VIP → шаг пропускается.
CACHE_REDIS_VIP=""
CACHE_REDIS_PORT="6382"
CACHE_VRID="59"
CACHE_REDIS_MAXMEM="1024mb"
# Домен портала — на web-нодах резолвится в 127.0.0.1, чтобы серверные self-запросы
# (Bitrix «Проверка системы»: site_check_exec и т.п.) шли на ЛОКАЛЬНУЮ ноду, а не
# через VIP/LB на случайную (где временного файла нет → 404). Пусто → шаг пропускается.
PORTAL_DOMAIN=""
# SSL: TLS терминируется на HAProxy (LB), серт — /etc/haproxy/certs/ на обоих LB.
# LE_EMAIL — учётка Let's Encrypt (пусто → выпуск только вручную из меню 12);
# FORCE_HTTPS=1 — сразу включить редирект 80→443 (нужен реальный серт, иначе
# браузеры упрутся в self-signed заглушку — обычно включают позже из меню 12).
LE_EMAIL=""
FORCE_HTTPS="0"
ACME_HTTP_PORT="8402"   # порт standalone-ответчика acme.sh на LB (acme_backend)
# Резервное копирование в MinIO кластера (бакет с versioning + lifecycle).
# Первая линия — свой S3 (защита от ошибок оператора/отказа ноды); offsite-копия
# на внешний сервер — отдельным шагом (см. CLAUDE.md / меню 13).
BACKUP_BUCKET="bitrix-backups"
BACKUP_RETENTION_DAYS="14"
BACKUP_ENC_KEY=""
ROOT_PASSWORD=""

# Списки имен узлов
LB_NODES=()
WEB_NODES=()
PXC_NODES=()
S3_NODES=()

# ──── Утилиты валидации ──────────────────────────────────────────────────────
valid_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra parts <<< "$ip"
        for part in "${parts[@]}"; do
            if [[ "$part" -lt 0 || "$part" -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

check_port22() {
    local ip="$1"
    timeout 3 bash -c "</dev/tcp/${ip}/22" &>/dev/null
}

# ──── Подстановка многострочного блока в шаблон ──────────────────────────────
# render_multiline <file> <placeholder> <value>
# value может содержать экранированные \n (как в исходных backend-списках).
# Реализовано на awk через index/substr — не интерпретирует спецсимволы
# (в отличие от sub/python с конкатенацией строк), поэтому безопасно для любых
# имён узлов и IP.
render_multiline() {
    local file="$1"
    local placeholder="$2"
    local value="$3"
    local tmp valf
    tmp=$(mktemp)
    valf=$(mktemp)
    # Превратить литералы \n в реальные переводы строк
    printf '%b' "$value" > "$valf"
    awk -v ph="$placeholder" -v vf="$valf" '
        BEGIN { n = 0; while ((getline l < vf) > 0) lines[n++] = l }
        {
            p = index($0, ph)
            if (p > 0) {
                pre = substr($0, 1, p - 1)
                suf = substr($0, p + length(ph))
                if (n == 0) { print pre suf; next }
                for (i = 0; i < n; i++)
                    print (i == 0 ? pre : "") lines[i] (i == n - 1 ? suf : "")
            } else {
                print
            }
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    rm -f "$valf"
}

# ──── Подстановка одиночного значения в шаблон ───────────────────────────────
# render_value <file> <placeholder> <value>
# Литеральная замена: значение НЕ интерпретируется как regex/замена sed, поэтому
# безопасно для паролей и ключей с любыми символами (/, &, \, $, кавычки и т.п.).
# В отличие от sed "s/.../$val/g" (ломается на '/', '&', '\') и awk -v (обрабатывает
# escape-последовательности) — значение передаётся через ENVIRON литерально.
render_value() {
    local file="$1"
    local placeholder="$2"
    local tmp
    tmp=$(mktemp)
    BCM_RV_VAL="$3" awk -v ph="$placeholder" '
        BEGIN { val = ENVIRON["BCM_RV_VAL"] }
        {
            out = ""; line = $0; plen = length(ph)
            while ((p = index(line, ph)) > 0) {
                out = out substr(line, 1, p - 1) val
                line = substr(line, p + plen)
            }
            print out line
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# ──── Криптослучайная hex-строка ─────────────────────────────────────────────
# _bcm_rand_hex <nbytes> → 2*nbytes hex-символов из CSPRNG.
# Никогда не возвращает предсказуемую константу: openssl → /dev/urandom →
# (крайний резерв) sha256 от энтропии процесса. Прежние fallback'и вида
# "minio$(date +%s)"/"sessvrrp" были угадываемыми и одинаковыми между установками.
_bcm_rand_hex() {
    local n="${1:-16}" hex=""
    hex=$(openssl rand -hex "$n" 2>/dev/null) || hex=""
    if [[ -z "$hex" ]]; then
        hex=$(head -c "$n" /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    fi
    if [[ -z "$hex" ]]; then
        hex=$(printf '%s' "${RANDOM}${RANDOM}$(date +%s%N)$$" \
              | sha256sum 2>/dev/null | cut -c1-$((n * 2)))
    fi
    printf '%s' "$hex"
}

# ──── Ограничение порта password-less redis файрволом ────────────────────────
# _bcm_redis_firewall <ip> <port> <label>
# Инстансы redis (сессии/push/cache) слушают bind 0.0.0.0 БЕЗ пароля (VIP плавающий,
# его нельзя перечислить в bind). Единственная защита — firewalld до web-пиров.
# Если firewalld неактивен — инстанс открыт без аутентификации: НЕ молчим, а громко
# предупреждаем (раньше блок просто пропускался и redis оставался публичным).
_bcm_redis_firewall() {
    local ip="$1" port="$2" label="$3"
    if bcm_ssh_exec "$ip" "systemctl is-active firewalld &>/dev/null"; then
        local peer pip
        for peer in "${WEB_NODES[@]}"; do
            pip="${WEB_IPS[$peer]}"
            if ! bcm_ssh_exec "$ip" "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${pip} port port=${port} protocol=tcp accept'" >/dev/null 2>&1; then
                log_warn "  ${label}: не удалось добавить firewall-правило для пира ${pip} на ${ip}."
            fi
        done
        bcm_ssh_exec "$ip" "firewall-cmd --reload" >/dev/null 2>&1 || true
    else
        log_warn "  ⚠ ${label} на ${ip}: firewalld НЕ активен. Redis слушает 0.0.0.0 БЕЗ пароля и"
        log_warn "    сейчас доступен любому, кто дотянется до порта ${port}. Включите firewalld"
        log_warn "    (или ограничьте порт ${port} до web-узлов внешним МСЭ) перед эксплуатацией."
    fi
}

# ──── Проверка надёжности секретов ───────────────────────────────────────────
# Блокирует установку с пустыми/дефолтными паролями (admin/monitorpass/bitrixpass/
# плейсхолдеры CHANGE_ME_*). Для лаборатории осознанно обходится через
# BCM_ALLOW_WEAK_PASSWORDS=1. Так прод по умолчанию защищён, а лаба не заблокирована.
validate_secrets() {
    local weak=0 v label
    _check_secret() {
        local val="$1"; label="$2"; shift 2
        if [[ -z "$val" ]]; then
            log_error "Пароль «${label}» пустой — задайте надёжное значение."
            return 1
        fi
        local w
        for w in "$@"; do
            if [[ "$val" == "$w" ]]; then
                log_error "Пароль «${label}» = небезопасное значение по умолчанию ('${w}')."
                return 1
            fi
        done
        [[ ${#val} -lt 8 ]] && log_warn "Пароль «${label}» короче 8 символов — рекомендуется длиннее."
        return 0
    }
    _check_secret "$PROXYSQL_ADMIN_PASS"   "ProxySQL admin"   admin CHANGE_ME_ADMIN_PASS   || weak=1
    _check_secret "$PROXYSQL_MONITOR_PASS" "ProxySQL monitor" monitorpass CHANGE_ME_MONITOR_PASS || weak=1
    _check_secret "$BITRIX_DB_PASS"        "Bitrix DB"        bitrixpass CHANGE_ME_DB_PASS || weak=1

    if [[ $weak -eq 1 ]]; then
        if [[ "${BCM_ALLOW_WEAK_PASSWORDS:-0}" == "1" ]]; then
            log_warn "BCM_ALLOW_WEAK_PASSWORDS=1 — продолжаю несмотря на слабые пароли (НЕ для прод!)."
        else
            log_error "Обнаружены слабые/дефолтные пароли. Укажите надёжные значения в файле ответов."
            log_error "Осознанно обойти (только лаборатория): BCM_ALLOW_WEAK_PASSWORDS=1 bash install.sh ..."
            exit 1
        fi
    fi
}

# ──── Таймзона web-нод для MySQL/ProxySQL ────────────────────────────────────
# Bitrix требует совпадения времени БД и web-сервера. Берём смещение первой web-ноды
# (источник портала) через `date +%z` (напр. +0500) и приводим к формату MySQL
# '+05:00'. При недоступности — fallback '+00:00'. Так PXC/ProxySQL выставляются
# под web автоматически, без хардкода и без правок OS-таймзоны db-нод.
_bcm_web_timezone() {
    local tz=""
    if [[ ${#WEB_NODES[@]} -gt 0 ]]; then
        tz=$(bcm_ssh_exec "${WEB_IPS[${WEB_NODES[0]}]}" "date +%z" 2>/dev/null | tr -d '[:space:]')
    fi
    if [[ "$tz" =~ ^[+-][0-9]{4}$ ]]; then
        printf '%s:%s' "${tz:0:3}" "${tz:3:2}"
    else
        printf '+00:00'
    fi
}

# ──── Состояние узла Galera/PXC ──────────────────────────────────────────────
# Запрос выполняется локально на узле через сокет (root без пароля),
# поэтому пароли в командной строке/логах не светятся.
pxc_wsrep_var() {
    local ip="$1"
    local var="$2"
    bcm_ssh_exec "$ip" \
        "mysql -N -e \"SHOW STATUS LIKE '${var}'\" 2>/dev/null | awk '{print \$2}'" \
        | tr -d '[:space:]'
}

# Узел является рабочим первичным компонентом кластера?
pxc_is_primary() {
    local ip="$1"
    [[ "$(pxc_wsrep_var "$ip" wsrep_cluster_status)" == "Primary" \
       && "$(pxc_wsrep_var "$ip" wsrep_ready)" == "ON" ]]
}

# Дождаться, пока узел войдёт в кластер и синхронизируется (Synced).
# pxc_wait_synced <ip> [timeout_sec]
pxc_wait_synced() {
    local ip="$1"
    local timeout="${2:-300}"
    local waited=0
    while (( waited < timeout )); do
        if [[ "$(pxc_wsrep_var "$ip" wsrep_local_state_comment)" == "Synced" ]]; then
            return 0
        fi
        sleep 5
        (( waited += 5 ))
    done
    return 1
}

# ──── Интерактивный сбор топологии ───────────────────────────────────────────
collect_topology_interactive() {
    echo -e "\033[1;36m=================================================="
    echo "  Buoyant Cluster Management for bitrix-env — Интерактивная настройка"
    echo -e "==================================================\033[0m"
    echo

    # 1. VIP
    while true; do
        read -r -p "Введите виртуальный IP (VIP) кластера: " VIP
        if valid_ip "$VIP"; then
            break
        else
            log_warn "Неверный формат IP-адреса. Попробуйте еще раз."
        fi
    done

    # 2. LB ноды
    local count_lb=0
    while true; do
        read -r -p "Введите количество LB-нод (минимум 2): " count_lb
        if [[ "$count_lb" =~ ^[0-9]+$ && "$count_lb" -ge 2 ]]; then
            break
        else
            log_warn "Минимум 2 LB-ноды необходимы для отказоустойчивости."
        fi
    done
    for ((i=1; i<=count_lb; i++)); do
        local name ip
        read -r -p "Введите имя для LB-ноды #$i (например, lb0$i): " name
        while true; do
            read -r -p "Введите IP для LB-ноды $name: " ip
            if valid_ip "$ip"; then
                LB_IPS["$name"]="$ip"
                LB_NODES+=("$name")
                break
            else
                log_warn "Неверный формат IP-адреса."
            fi
        done
    done

    # 3. WEB ноды
    local count_web=0
    while true; do
        read -r -p "Введите количество WEB-нод (минимум 2): " count_web
        if [[ "$count_web" =~ ^[0-9]+$ && "$count_web" -ge 2 ]]; then
            break
        else
            log_warn "Минимум 2 WEB-ноды необходимы для отказоустойчивости."
        fi
    done
    for ((i=1; i<=count_web; i++)); do
        local name ip
        read -r -p "Введите имя для WEB-ноды #$i (например, web0$i): " name
        while true; do
            read -r -p "Введите IP для WEB-ноды $name: " ip
            if valid_ip "$ip"; then
                WEB_IPS["$name"]="$ip"
                WEB_NODES+=("$name")
                break
            else
                log_warn "Неверный формат IP-адреса."
            fi
        done
    done

    # 4. PXC ноды
    local count_pxc=0
    while true; do
        read -r -p "Введите количество PXC-нод (минимум 3, должно быть нечетным): " count_pxc
        if [[ "$count_pxc" =~ ^[0-9]+$ && "$count_pxc" -ge 3 ]]; then
            if (( count_pxc % 2 != 0 )); then
                break
            else
                log_warn "Количество узлов PXC должно быть нечетным для кворума Galera."
            fi
        else
            log_warn "Минимум 3 PXC-ноды необходимы для кворума."
        fi
    done
    for ((i=1; i<=count_pxc; i++)); do
        local name ip
        read -r -p "Введите имя для PXC-ноды #$i (например, db0$i): " name
        while true; do
            read -r -p "Введите IP для PXC-ноды $name: " ip
            if valid_ip "$ip"; then
                PXC_IPS["$name"]="$ip"
                PXC_NODES+=("$name")
                break
            else
                log_warn "Неверный формат IP-адреса."
            fi
        done
    done

    # Выбор писателя
    while true; do
        read -r -p "Какой узел будет основным писателем (initial writer)? Выберите из [ ${PXC_NODES[*]} ]: " PXC_WRITER
        local found=0
        for node in "${PXC_NODES[@]}"; do
            if [[ "$node" == "$PXC_WRITER" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 1 ]]; then
            break
        else
            log_warn "Имя узла не найдено в списке PXC нод."
        fi
    done

    # 5. S3 ноды
    local count_s3=0
    while true; do
        read -r -p "Введите количество S3-нод (минимум 2): " count_s3
        if [[ "$count_s3" =~ ^[0-9]+$ && "$count_s3" -ge 2 ]]; then
            break
        else
            log_warn "Минимум 2 S3-ноды необходимы для отказоустойчивости."
        fi
    done
    for ((i=1; i<=count_s3; i++)); do
        local name ip
        read -r -p "Введите имя для S3-ноды #$i (например, s3-0$i): " name
        while true; do
            read -r -p "Введите IP для S3-ноды $name: " ip
            if valid_ip "$ip"; then
                S3_IPS["$name"]="$ip"
                S3_NODES+=("$name")
                break
            else
                log_warn "Неверный формат IP-адреса."
            fi
        done
    done

    read -r -p "Введите порт MinIO (по умолчанию 9000): " S3_PORT
    S3_PORT="${S3_PORT:-9000}"

    read -r -p "Введите access key MinIO (root user, по умолчанию minioadmin): " S3_ACCESS_KEY
    S3_ACCESS_KEY="${S3_ACCESS_KEY:-minioadmin}"

    read -r -s -p "Введите secret key MinIO (Enter — сгенерировать случайный): " S3_SECRET_KEY
    echo
    if [[ -z "$S3_SECRET_KEY" ]]; then
        S3_SECRET_KEY="$(_bcm_rand_hex 16)"
        log_info "Сгенерирован случайный secret key MinIO."
    fi

    read -r -p "Введите S3 vhost-домен для модуля «Облачные хранилища» (по умолчанию ${S3_VHOST_DOMAIN}): " _s3_vh
    S3_VHOST_DOMAIN="${_s3_vh:-$S3_VHOST_DOMAIN}"

    # Опционально: выделенный диск под хранилище MinIO (общий для всех S3-нод).
    read -r -p "Выделенный диск под хранилище MinIO на S3-нодах (напр. /dev/sdb; Enter — корневая ФС): " S3_DATA_DISK
    if [[ -n "$S3_DATA_DISK" ]]; then
        read -r -p "  Точка монтирования (по умолчанию ${S3_DATA_MOUNT}): " _s3_mnt
        S3_DATA_MOUNT="${_s3_mnt:-$S3_DATA_MOUNT}"
        read -r -p "  Файловая система xfs|ext4 (по умолчанию ${S3_DATA_FS}): " _s3_fs
        S3_DATA_FS="${_s3_fs:-$S3_DATA_FS}"
        read -r -p "  Форматировать, даже если на диске уже есть ФС? (УНИЧТОЖИТ данные) [y/N]: " _s3_force
        [[ "$_s3_force" =~ ^[Yy]$ ]] && S3_DATA_DISK_FORCE="1" || S3_DATA_DISK_FORCE="0"
    fi

    read -r -p "Введите порт ProxySQL (по умолчанию 6033): " PROXYSQL_PORT
    PROXYSQL_PORT="${PROXYSQL_PORT:-6033}"

    read -r -p "Введите порт администрирования ProxySQL (по умолчанию 6032): " PROXYSQL_ADMIN_PORT
    PROXYSQL_ADMIN_PORT="${PROXYSQL_ADMIN_PORT:-6032}"

    read -r -s -p "Введите пароль администратора ProxySQL (HG_ADMIN): " PROXYSQL_ADMIN_PASS
    echo
    PROXYSQL_ADMIN_PASS="${PROXYSQL_ADMIN_PASS:-admin}"

    read -r -s -p "Введите пароль пользователя мониторинга ProxySQL: " PROXYSQL_MONITOR_PASS
    echo
    PROXYSQL_MONITOR_PASS="${PROXYSQL_MONITOR_PASS:-monitorpass}"

    read -r -p "Введите имя пользователя БД Bitrix (по умолчанию bitrix): " BITRIX_DB_USER
    BITRIX_DB_USER="${BITRIX_DB_USER:-bitrix}"

    read -r -s -p "Введите пароль пользователя БД Bitrix: " BITRIX_DB_PASS
    echo

    read -r -p "Введите Keepalived VRID для WEB-нод (по умолчанию 56): " WEB_VRID
    WEB_VRID="${WEB_VRID:-56}"

    # Redis-хранилище сессий: общий стор, чтобы сессии переживали переключение web-нод
    echo
    log_info "Redis-хранилище сессий (клиенты не теряют сессию при переключении нод)."
    while true; do
        read -r -p "VIP для redis-сессий (свободный IP; пусто — пропустить настройку): " SESSION_VIP
        if [[ -z "$SESSION_VIP" ]]; then
            log_warn "Настройка redis-сессий будет пропущена."
            break
        elif valid_ip "$SESSION_VIP"; then
            break
        else
            log_warn "Неверный формат IP."
        fi
    done
    if [[ -n "$SESSION_VIP" ]]; then
        read -r -p "Порт redis-сессий (по умолчанию 6380): " SESSION_REDIS_PORT
        SESSION_REDIS_PORT="${SESSION_REDIS_PORT:-6380}"
        read -r -p "Keepalived VRID для VIP сессий (по умолчанию 57): " SESSION_VRID
        SESSION_VRID="${SESSION_VRID:-57}"
        read -r -p "maxmemory redis-сессий (по умолчанию 256mb): " SESSION_REDIS_MAXMEM
        SESSION_REDIS_MAXMEM="${SESSION_REDIS_MAXMEM:-256mb}"
    fi

    while true; do
        read -r -s -p "Введите общий пароль root для подключения к узлам: " ROOT_PASSWORD
        echo
        if [[ -n "$ROOT_PASSWORD" ]]; then
            break
        else
            log_warn "Пароль root не может быть пустым."
        fi
    done
}

# ──── Загрузка файла ответов ─────────────────────────────────────────────────
load_answers_file() {
    log_info "Загрузка ответов из файла $ANSWERS_FILE..."
    if [[ ! -f "$ANSWERS_FILE" ]]; then
        log_error "Файл ответов не найден: $ANSWERS_FILE"
        exit 1
    fi
    # Безопасный разбор KEY=VALUE без source: значения берутся литерально, bash их
    # НЕ выполняет и НЕ раскрывает — пароли с $, {}, бэктиками, ! и т.п. работают.
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        key="${key//[[:space:]]/}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        val="${line#*=}"
        val="${val#"${val%%[![:space:]]*}"}"             # ltrim значения
        if [[ "$val" == \"* ]]; then
            val="${val#\"}"; val="${val%%\"*}"           # содержимое первой пары "..."
        elif [[ "$val" == \'* ]]; then
            val="${val#\'}"; val="${val%%\'*}"           # содержимое первой пары '...'
        else
            val="${val%%#*}"                              # отрезать inline-комментарий
            val="${val%"${val##*[![:space:]]}"}"         # rtrim
        fi
        printf -v "$key" '%s' "$val"
    done < "$ANSWERS_FILE"

    # Преобразование списков
    local IFS=','
    read -ra LB_NODES <<< "${LB_NODES:-}"
    read -ra WEB_NODES <<< "${WEB_NODES:-}"
    read -ra PXC_NODES <<< "${PXC_NODES:-}"
    read -ra S3_NODES <<< "${S3_NODES:-}"

    # Парсинг пар Name:IP
    local pair
    for pair in ${LB_IPS_LIST:-}; do
        LB_IPS["${pair%%:*}"]="${pair#*:}"
    done
    for pair in ${WEB_IPS_LIST:-}; do
        WEB_IPS["${pair%%:*}"]="${pair#*:}"
    done
    for pair in ${PXC_IPS_LIST:-}; do
        PXC_IPS["${pair%%:*}"]="${pair#*:}"
    done
    for pair in ${S3_IPS_LIST:-}; do
        S3_IPS["${pair%%:*}"]="${pair#*:}"
    done
    # Пер-нодовые выделенные диски MinIO (опционально): "имя:устройство,..."
    for pair in ${S3_DATA_DISKS_LIST:-}; do
        S3_DATA_DISKS["${pair%%:*}"]="${pair#*:}"
    done
}

# ──── Проверка связи ─────────────────────────────────────────────────────────
validate_connectivity() {
    log_info "Проверка доступности узлов и пароля root..."
    local all_nodes=()
    for name in "${LB_NODES[@]}" "${WEB_NODES[@]}" "${PXC_NODES[@]}" "${S3_NODES[@]}"; do
        all_nodes+=("$name")
    done

    # Установить sshpass, если не установлен — он обязателен для первичной раскатки ключей
    if ! command -v sshpass &>/dev/null; then
        dnf install -y sshpass || yum install -y sshpass || apt-get install -y sshpass || true
    fi
    if ! command -v sshpass &>/dev/null; then
        log_error "Не удалось установить sshpass. Он обязателен для проверки пароля root и раскатки SSH-ключей."
        log_error "Установите его вручную и повторите запуск."
        exit 1
    fi

    for name in "${all_nodes[@]}"; do
        local ip=""
        if [[ -n "${LB_IPS[$name]:-}" ]]; then ip="${LB_IPS[$name]}"; fi
        if [[ -n "${WEB_IPS[$name]:-}" ]]; then ip="${WEB_IPS[$name]}"; fi
        if [[ -n "${PXC_IPS[$name]:-}" ]]; then ip="${PXC_IPS[$name]}"; fi
        if [[ -n "${S3_IPS[$name]:-}" ]]; then ip="${S3_IPS[$name]}"; fi

        log_info "Проверка связи с $name ($ip)..."
        if ! check_port22 "$ip"; then
            log_error "Узел $name ($ip) недоступен по порту 22 (SSH). Проверьте сеть."
            exit 1
        fi

        # accept-new: host-ключ принимается при ПЕРВОМ контакте (TOFU) и запоминается;
        # при последующих запусках подменённый ключ уже будет отвергнут (защита от MITM
        # при повторной раскатке). ⚠️ Остаточный риск: на самом первом подключении пароль
        # root уходит на непроверенный хост — для гарантии сверяйте отпечаток узла
        # out-of-band перед первым install в недоверенной сети.
        if ! timeout 5 sshpass -p "$ROOT_PASSWORD" ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "root@${ip}" "echo 1" &>/dev/null; then
            log_error "Не удалось подключиться к $name ($ip) с указанным паролем root."
            exit 1
        fi
    done
    log_ok "Связь со всеми узлами успешно проверена."
}

# ──── Защита от даунгрейда BCM ────────────────────────────────────────────────
# install.sh раскатывает bcm/ из ЛОКАЛЬНОЙ копии (BCM_INSTALL_SRC). Если на нодах
# уже стоит БОЛЕЕ НОВЫЙ BCM (например, после `bcm --update`), повторный install из
# старой копии ОТКАТИЛ БЫ инструментарий. Проверяем РАНО — до любых изменений
# (до write_conf) — и фейлимся, если хоть одна нода новее источника.
# Осознанный откат: BCM_ALLOW_DOWNGRADE=1.
check_bcm_no_downgrade() {
    local src_ver
    src_ver="$(tr -d '[:space:]' < "${BCM_INSTALL_SRC}/VERSION" 2>/dev/null || true)"
    [[ -z "$src_ver" ]] && return 0   # в источнике нет VERSION — сравнивать не с чем

    local name ip node_ver newer found_newer=0
    for name in "${LB_NODES[@]}" "${WEB_NODES[@]}" "${PXC_NODES[@]}" "${S3_NODES[@]}"; do
        ip=""
        [[ -n "${LB_IPS[$name]:-}" ]]  && ip="${LB_IPS[$name]}"
        [[ -n "${WEB_IPS[$name]:-}" ]] && ip="${WEB_IPS[$name]}"
        [[ -n "${PXC_IPS[$name]:-}" ]] && ip="${PXC_IPS[$name]}"
        [[ -n "${S3_IPS[$name]:-}" ]]  && ip="${S3_IPS[$name]}"
        [[ -z "$ip" ]] && continue
        node_ver="$(timeout 8 sshpass -p "$ROOT_PASSWORD" ssh -o ConnectTimeout=4 \
            -o StrictHostKeyChecking=accept-new "root@${ip}" \
            "cat /opt/bcm/VERSION 2>/dev/null" 2>/dev/null | tr -d '[:space:]')"
        [[ -z "$node_ver" || "$node_ver" == "$src_ver" ]] && continue
        newer="$(printf '%s\n%s\n' "$src_ver" "$node_ver" | sort -V | tail -1)"
        if [[ "$newer" == "$node_ver" ]]; then
            found_newer=1
            log_warn "На ${name} (${ip}) установлен BCM ${node_ver} — НОВЕЕ раскатываемого ${src_ver}."
        fi
    done

    if [[ "$found_newer" -eq 1 ]]; then
        if [[ "${BCM_ALLOW_DOWNGRADE:-0}" == "1" ]]; then
            log_warn "BCM_ALLOW_DOWNGRADE=1 — продолжаю, ИНСТРУМЕНТАРИЙ BCM будет ОТКАЧЕН до ${src_ver}."
        else
            log_error "Повторный install ОТКАТИЛ БЫ инструментарий BCM на более старую версию (${src_ver})."
            log_error "Обновите управляющую копию до актуального релиза (скачайте tarball релиза или 'git pull') и повторите."
            log_error "Если откат осознанный — запустите с BCM_ALLOW_DOWNGRADE=1."
            exit 1
        fi
    fi
}

# ──── Запись cluster.conf ────────────────────────────────────────────────────
write_conf() {
    local target_conf="${BCM_CONF_FILE}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY RUN] Запись конфигурации в $target_conf"
        return
    fi
    mkdir -p "$(dirname "$target_conf")"
    cat > "$target_conf" <<EOF
# /etc/bitrix-cluster/cluster.conf
# Сгенерировано bcm install.sh
# $(date)

[meta]
app_version_source = runtime
benv_version_source = runtime
generated_by = bcm-install

[layer.lb]
nodes = $(IFS=,; echo "${LB_NODES[*]}")
EOF
    for name in "${LB_NODES[@]}"; do
        local ip="${LB_IPS[$name]}"
        local priority="100"
        local role="BACKUP"
        if [[ "$name" == "${LB_NODES[0]}" ]]; then
            priority="110"
            role="MASTER"
        fi
        cat >> "$target_conf" <<EOF
${name}.ip = ${ip}
${name}.priority = ${priority}
${name}.role = ${role}
EOF
    done

    cat >> "$target_conf" <<EOF

[layer.web]
nodes = $(IFS=,; echo "${WEB_NODES[*]}")
keepalived_vrid = ${WEB_VRID}
EOF
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        cat >> "$target_conf" <<EOF
${name}.ip = ${ip}
EOF
    done

    cat >> "$target_conf" <<EOF

[layer.pxc]
nodes = $(IFS=,; echo "${PXC_NODES[*]}")
writer = ${PXC_WRITER}
EOF
    for name in "${PXC_NODES[@]}"; do
        local ip="${PXC_IPS[$name]}"
        cat >> "$target_conf" <<EOF
${name}.ip = ${ip}
EOF
    done

    cat >> "$target_conf" <<EOF

[layer.s3]
nodes = $(IFS=,; echo "${S3_NODES[*]}")
port = ${S3_PORT}
EOF
    for name in "${S3_NODES[@]}"; do
        local ip="${S3_IPS[$name]}"
        cat >> "$target_conf" <<EOF
${name}.ip = ${ip}
EOF
    done

    cat >> "$target_conf" <<EOF

[network]
vip = ${VIP}
portal_domain = ${PORTAL_DOMAIN}

[cluster]
mode = normal
active_node = ${WEB_NODES[0]}

[session]
redis_vip = ${SESSION_VIP}
redis_port = ${SESSION_REDIS_PORT}
keepalived_vrid = ${SESSION_VRID}
maxmemory = ${SESSION_REDIS_MAXMEM}

[push]
redis_vip = ${PUSH_REDIS_VIP}
redis_port = ${PUSH_REDIS_PORT}
keepalived_vrid = ${PUSH_VRID}
maxmemory = ${PUSH_REDIS_MAXMEM}

[cache]
redis_vip = ${CACHE_REDIS_VIP}
redis_port = ${CACHE_REDIS_PORT}
keepalived_vrid = ${CACHE_VRID}
maxmemory = ${CACHE_REDIS_MAXMEM}

[proxysql]
port = ${PROXYSQL_PORT}
admin_port = ${PROXYSQL_ADMIN_PORT}
admin_user = ${PROXYSQL_ADMIN_USER}
admin_password = ${PROXYSQL_ADMIN_PASS}
monitor_user = ${PROXYSQL_MONITOR_USER}
monitor_password = ${PROXYSQL_MONITOR_PASS}
bitrix_db_user = ${BITRIX_DB_USER}
bitrix_db_password = ${BITRIX_DB_PASS}
hg_write = 10
hg_read = 20
hg_backup_write = 11
hg_offline = 30

[s3_upload]
# Бакет MinIO для пользовательских файлов Bitrix (/upload). Регистрируется в
# модуле «Облачные хранилища» сидером BCM (меню 7 → Облачное хранилище /upload).
bucket = ${S3_UPLOAD_BUCKET}
endpoint = https://${VIP}:${S3_PORT}
region = us-east-1
access_key = ${S3_ACCESS_KEY:-minioadmin}
secret_key = ${S3_SECRET_KEY}
# ⚠️ MinIO работает по HTTPS (TLS терминирует САМ MinIO, см. configure_s3_tls) —
# обязательно для отдачи облачных файлов через серверный прокси Bitrix при https-портале
# (иначе ERR_HTTP2_PROTOCOL_ERROR на просмотре/скачивании). use_https=Y → бакет в модуле
# clouds регистрируется с USE_HTTPS=Y (сидер 11→3 читает это).
use_https = Y
# ⚠️ Модуль Bitrix clouds (CCloudStorageService_S3) использует ТОЛЬКО
# virtual-hosted-style (bucket.api_host) и подпись AWS V4 (region обязателен).
# В админке: «Имя сервера (API host)» = api_host (БЕЗ схемы), Регион = region, HTTPS = вкл.
# api_host резолвится на web-нодах в /etc/hosts на S3-VIP, MinIO MINIO_DOMAIN=vhost_domain.
# endpoint (с https://) — path-style для mc/бэкапов; серт доверен через CA (configure_s3_tls).
vhost_domain = ${S3_VHOST_DOMAIN}
api_host = ${S3_VHOST_DOMAIN}:${S3_PORT}

[ssl]
# TLS терминируется на HAProxy (LB): один pem на оба LB в /etc/haproxy/certs/.
# mode: none | custom | letsencrypt (меняется меню 12). domain по умолчанию = домен портала.
mode = none
domain = ${PORTAL_DOMAIN}
le_email = ${LE_EMAIL}
force_https = ${FORCE_HTTPS}
acme_http_port = ${ACME_HTTP_PORT}
acme_ca = letsencrypt
# acme_method: http (HTTP-01 через acme_backend) | dns_cf (DNS-01 Cloudflare, токен из меню 12)
acme_method = http

[backup]
# Бэкапы в MinIO кластера (versioning + lifecycle). Креды/endpoint — из [s3_upload].
# enc_key — шифрование conf-архивов (внутри пароли/ключи); retention применяет MinIO.
bucket = ${BACKUP_BUCKET}
retention_days = ${BACKUP_RETENTION_DAYS}
enc_key = ${BACKUP_ENC_KEY}

[ssh]
private_key = /etc/bitrix-cluster/cluster_id_rsa
EOF
    chmod 600 "$target_conf"   # содержит пароли БД/ProxySQL/MinIO открытым текстом
    log_ok "Конфигурационный файл $target_conf успешно создан."
}

# ──── Настройка SSH-ключей ───────────────────────────────────────────────────
deploy_ssh_keys() {
    log_info "Настройка беспарольного SSH доступа..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY RUN] Генерация ключа и раскатка на узлы"
        return
    fi

    # Сгенерировать ключ
    bcm_generate_cluster_key >/dev/null

    local pubkey="${BCM_SSH_KEY}.pub"
    if [[ ! -f "$pubkey" ]]; then
        log_error "Не найден публичный ключ: $pubkey"
        exit 1
    fi

    local all_ips=()
    for ip in "${LB_IPS[@]}" "${WEB_IPS[@]}" "${PXC_IPS[@]}" "${S3_IPS[@]}"; do
        all_ips+=("$ip")
    done

    for ip in "${all_ips[@]}"; do
        if bcm_key_already_deployed "$ip"; then
            log_ok "SSH-ключ уже раскатан на $ip"
        else
            log_info "Копирование SSH-ключа на $ip..."
            if bcm_copy_key_to_node "$ip" "$ROOT_PASSWORD" "$pubkey"; then
                log_ok "SSH-ключ успешно раскатан на $ip"
            else
                log_error "Не удалось скопировать SSH-ключ на $ip. Проверьте пароль."
                exit 1
            fi
        fi
    done
}

# ──── Установка пакетов ──────────────────────────────────────────────────────
install_packages() {
    log_info "Установка пакетов на узлах кластера..."

    for name in "${PXC_NODES[@]}"; do
        local ip="${PXC_IPS[$name]}"
        log_info "Установка Percona XtraDB Cluster на $name ($ip)..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Установка PXC на $name"
        else
            bcm_ssh_exec_logged "$name" "$ip" "dnf install -y curl wget rsync || yum install -y curl wget rsync"
            
            # Проверяем и устанавливаем PXC
            if ! bcm_ssh_exec "$ip" "rpm -q percona-xtradb-cluster-server" | grep -q 'percona'; then
                bcm_ssh_exec_logged "$name" "$ip" "dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm || yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm"
                # PXC 8.4 LTS (репо pxc-84-lts). ⚠️ В 8.4: mysql_native_password по
                # умолчанию выключен (включаем в pxc.cnf.tmpl — нужен ProxySQL),
                # expire_logs_days удалена (в шаблоне binlog_expire_logs_seconds).
                bcm_ssh_exec_logged "$name" "$ip" "percona-release enable pxc-84-lts release"
                bcm_ssh_exec_logged "$name" "$ip" "dnf install -y percona-xtradb-cluster-server || yum install -y percona-xtradb-cluster-server"
            else
                log_ok "  PXC уже установлен на $name"
            fi

            # Проверяем и устанавливаем Percona XtraBackup (необходим для SST)
            if ! bcm_ssh_exec "$ip" "rpm -q percona-xtrabackup-84" | grep -q 'xtrabackup'; then
                if ! bcm_ssh_exec "$ip" "rpm -q percona-release" | grep -q 'percona-release'; then
                    bcm_ssh_exec_logged "$name" "$ip" "dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm || yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm"
                fi
                # PXB 8.4 (репо pxb-84-lts) — PXB 8.0 не умеет datadir PXC 8.4
                bcm_ssh_exec_logged "$name" "$ip" "percona-release enable pxb-84-lts release"
                bcm_ssh_exec_logged "$name" "$ip" "dnf install -y percona-xtrabackup-84 || yum install -y percona-xtrabackup-84"
            else
                log_ok "  XtraBackup уже установлен на $name"
            fi
        fi
    done

    # LB ноды
    for name in "${LB_NODES[@]}"; do
        local ip="${LB_IPS[$name]}"
        log_info "Установка HAProxy и Keepalived на $name ($ip)..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] ssh root@$ip 'dnf install -y haproxy keepalived'"
        else
            bcm_ssh_exec_logged "$name" "$ip" "dnf install -y haproxy keepalived || yum install -y haproxy keepalived"
            # socat нужен для управления HAProxy через admin-сокет (режим единой ноды)
            bcm_ssh_exec_logged "$name" "$ip" "dnf install -y curl wget rsync socat || yum install -y curl wget rsync socat"
        fi
    done

    # S3 ноды
    for name in "${S3_NODES[@]}"; do
        local ip="${S3_IPS[$name]}"
        log_info "Установка MinIO на $name ($ip)..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Установка MinIO на $name"
        else
            bcm_ssh_exec_logged "$name" "$ip" "dnf install -y curl wget rsync || yum install -y curl wget rsync"
            if bcm_ssh_exec "$ip" "[ -x /usr/local/bin/minio ] && echo 'exists'" | grep -q 'exists'; then
                log_ok "  MinIO уже установлен на $name"
            else
                bcm_ssh_exec_logged "$name" "$ip" "wget -qO /usr/local/bin/minio https://dl.min.io/server/minio/release/linux-amd64/minio"
                bcm_ssh_exec_logged "$name" "$ip" "chmod +x /usr/local/bin/minio"
                bcm_ssh_exec_logged "$name" "$ip" "wget -qO /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc"
                bcm_ssh_exec_logged "$name" "$ip" "chmod +x /usr/local/bin/mc"
            fi
        fi
    done

    # WEB ноды
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        log_info "Установка bitrix-env, lsyncd и ProxySQL на $name ($ip)..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Установка пакетов web на $name"
        else
            bcm_ssh_exec_logged "$name" "$ip" "dnf install -y curl wget rsync || yum install -y curl wget rsync"

            if bcm_ssh_exec "$ip" "[ -f /opt/webdir/bin/bitrix_menu.sh ] && echo 'installed'" | grep -q 'installed'; then
                log_ok "  bitrix-env уже установлен на $name"
            else
                log_info "  Скачивание и запуск bitrix-env-9.sh на $name (это займет некоторое время)..."
                bcm_ssh_exec_logged "$name" "$ip" "wget -qO /tmp/bitrix-env-9.sh https://repos.1c-bitrix.ru/dnf/bitrix-env-9.sh || wget -qO /tmp/bitrix-env-9.sh https://repo.bitrix.info/dnf/bitrix-env-9.sh"
                bcm_ssh_exec_logged "$name" "$ip" "chmod +x /tmp/bitrix-env-9.sh"
                bcm_ssh_exec_logged "$name" "$ip" "bash /tmp/bitrix-env-9.sh -s -p"
            fi

            # Репозиторий ProxySQL
            bcm_ssh_exec_logged "$name" "$ip" "cat <<'EOF' > /etc/yum.repos.d/proxysql.repo
[proxysql]
name=ProxySQL YUM repository
baseurl=https://repo.proxysql.com/ProxySQL/proxysql-2.6.x/centos/\$releasever/
gpgcheck=1
gpgkey=https://repo.proxysql.com/ProxySQL/repo_pub_key
enabled=1
EOF"
            bcm_ssh_exec_logged "$name" "$ip" "dnf install -y proxysql lsyncd keepalived || yum install -y proxysql lsyncd keepalived"
        fi
    done
}

# ──── Настройка фаервола на узлах ─────────────────────────────────────────────
configure_firewall_for_node() {
    local node_name="$1"
    local ip="$2"
    local role="$3"

    if bcm_ssh_exec "$ip" "systemctl is-active firewalld &>/dev/null"; then
        log_info "Настройка firewalld на $node_name ($ip)..."
        case "$role" in
            lb)
                # 8402 — ответчик ACME HTTP-01 (acme.sh --standalone): на него ходит
                # HAProxy соседнего LB; наружу отдаёт только challenge-токены (безвредно).
                bcm_ssh_exec_logged "$node_name" "$ip" "firewall-cmd --permanent --add-service=http; firewall-cmd --permanent --add-service=https; firewall-cmd --permanent --add-port=9000/tcp; firewall-cmd --permanent --add-port=6033/tcp; firewall-cmd --permanent --add-port=${ACME_HTTP_PORT}/tcp; firewall-cmd --permanent --add-protocol=vrrp; firewall-cmd --reload"
                ;;
            web)
                bcm_ssh_exec_logged "$node_name" "$ip" "firewall-cmd --permanent --add-service=http; firewall-cmd --permanent --add-service=https; firewall-cmd --permanent --add-port=6032-6033/tcp; firewall-cmd --permanent --add-port=8010-8015/tcp; firewall-cmd --permanent --add-protocol=vrrp; firewall-cmd --reload"
                ;;
            pxc)
                bcm_ssh_exec_logged "$node_name" "$ip" "firewall-cmd --permanent --add-service=mysql; firewall-cmd --permanent --add-port=4567/tcp; firewall-cmd --permanent --add-port=4567/udp; firewall-cmd --permanent --add-port=4568/tcp; firewall-cmd --permanent --add-port=4444/tcp; firewall-cmd --reload"
                ;;
            s3)
                bcm_ssh_exec_logged "$node_name" "$ip" "firewall-cmd --permanent --add-port=9000/tcp; firewall-cmd --permanent --add-port=9001/tcp; firewall-cmd --reload"
                ;;
        esac
    fi
}

# ──── Подготовка выделенного диска под хранилище MinIO (опционально) ─────────
# Если для S3-ноды задано блочное устройство (S3_DATA_DISKS_LIST или общий S3_DATA_DISK),
# форматирует его (по умолчанию xfs — рекомендация MinIO) и монтирует в S3_DATA_MOUNT,
# чтобы данные MinIO жили на отдельном диске, а не на корневой ФС.
# ⚠️ Форматирование УНИЧТОЖАЕТ данные на устройстве: пропускается, если на нём уже есть
# ФС (кроме S3_DATA_DISK_FORCE=1). Идемпотентно: запись в /etc/fstab по UUID.
# Если устройство не задано — возвращает 0 (данные на корневой ФС, как раньше).
# ──── TLS для S3 (MinIO) ─────────────────────────────────────────────────────
# ⚠️⚠️ MinIO ОБЯЗАН отвечать по HTTPS. Причина (диагностировано вживую, июнь 2026):
# при https-портале Bitrix формирует URL облачного файла со схемой https:// (ИГНОРИРУЯ
# USE_HTTPS бакета — берёт схему текущего запроса), а disk.api.file.download — серверный
# прокси: PHP сам качает объект из S3 и стримит клиенту, заранее выставив Content-Length.
# Если MinIO слушает только http (а :9000 был mode tcp без TLS), фетч https://…:9000 падает
# на TLS-handshake → тело пустое при заявленной длине → HAProxy рвёт H2-поток → браузерный
# ERR_HTTP2_PROTOCOL_ERROR на просмотре/скачивании ЛЮБОГО облачного файла. Фикс: TLS
# терминирует САМ MinIO (S3-фронт HAProxy остаётся mode tcp passthrough — подпись AWS v4
# цела end-to-end, mc/бэкапы/site-replication не ломаются). Свой CA + серт (SAN: vhost-домен,
# *.vhost, IP всех S3-нод и VIP, localhost); CA — в доверенные на web+s3 (mc/php/curl
# верифицируют без --insecure). Идемпотентно: CA/серт создаются один раз и переиспользуются.
_bcm_s3_tls_dir="/etc/bitrix-cluster/s3-tls"
configure_s3_tls() {
    [[ "$DRY_RUN" -eq 1 ]] && { log_info "[DRY RUN] Генерация серта S3 (MinIO TLS)"; return 0; }
    command -v openssl >/dev/null 2>&1 || { log_error "Нужен openssl для генерации серта S3 (MinIO TLS)."; exit 1; }
    local d="$_bcm_s3_tls_dir"
    mkdir -p "$d"; chmod 700 "$d"
    if [[ -f "$d/public.crt" && -f "$d/private.key" && -f "$d/ca.crt" ]]; then
        log_info "Серт S3 TLS уже существует — переиспользую (${d})."
        return 0
    fi
    log_info "Генерация внутреннего CA и серта S3 (MinIO TLS)..."
    # SAN: vhost-домен + wildcard + localhost + VIP + IP всех S3-нод.
    local alt="" i=1 j=1 n nip
    alt+="DNS.${j}=${S3_VHOST_DOMAIN}\n"; ((j++))
    alt+="DNS.${j}=*.${S3_VHOST_DOMAIN}\n"; ((j++))
    alt+="DNS.${j}=localhost\n"
    alt+="IP.${i}=${VIP}\n"; ((i++))
    alt+="IP.${i}=127.0.0.1\n"; ((i++))
    for n in "${S3_NODES[@]}"; do nip="${S3_IPS[$n]}"; alt+="IP.${i}=${nip}\n"; ((i++)); done
    {
        printf '[req]\ndistinguished_name=dn\nreq_extensions=v3\nprompt=no\n'
        printf '[dn]\nO=BCM Cluster\nCN=%s\n[v3]\nsubjectAltName=@alt\n[alt]\n' "$S3_VHOST_DOMAIN"
        printf '%b' "$alt"
    } > "$d/san.cnf"
    openssl genrsa -out "$d/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "$d/ca.key" -sha256 -days 3650 \
        -out "$d/ca.crt" -subj "/O=BCM Cluster/CN=BCM S3 Internal CA" 2>/dev/null
    openssl genrsa -out "$d/private.key" 2048 2>/dev/null
    openssl req -new -key "$d/private.key" -out "$d/s3.csr" -config "$d/san.cnf" 2>/dev/null
    openssl x509 -req -in "$d/s3.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial \
        -out "$d/s3.crt" -days 1825 -sha256 -extensions v3 -extfile "$d/san.cnf" 2>/dev/null
    cat "$d/s3.crt" "$d/ca.crt" > "$d/public.crt"
    chmod 600 "$d/private.key" "$d/ca.key"
    log_ok "  Серт S3 сгенерирован (SAN: ${S3_VHOST_DOMAIN}, *.${S3_VHOST_DOMAIN}, VIP, S3-IP)."
}

# Раскатать доверенный CA серта S3 на ноду (web/s3) — чтобы mc/php-curl верифицировали
# https://<S3-VIP>:9000 без --insecure. Идемпотентно (фикс. имя в anchors).
_bcm_install_s3_ca() {
    local ip="$1"
    [[ -f "${_bcm_s3_tls_dir}/ca.crt" ]] || return 0
    bcm_ssh_copy_file "${_bcm_s3_tls_dir}/ca.crt" "$ip" "/etc/pki/ca-trust/source/anchors/bcm-s3-ca.crt"
    bcm_ssh_exec "$ip" "command -v update-ca-trust >/dev/null 2>&1 && update-ca-trust extract || true"
}

# Положить серт MinIO в certs-dir ноды (MinIO авто-включает TLS при наличии
# /root/.minio/certs/{public.crt,private.key}). Вызывать ДО старта minio.
_bcm_deploy_s3_cert() {
    local ip="$1"
    bcm_ssh_exec "$ip" "mkdir -p /root/.minio/certs"
    bcm_ssh_copy_file "${_bcm_s3_tls_dir}/public.crt"  "$ip" "/root/.minio/certs/public.crt"
    bcm_ssh_copy_file "${_bcm_s3_tls_dir}/private.key" "$ip" "/root/.minio/certs/private.key"
    bcm_ssh_exec "$ip" "chmod 600 /root/.minio/certs/private.key && chmod 644 /root/.minio/certs/public.crt"
}

prepare_s3_data_disk() {
    local name="$1" ip="$2"
    local dev="${S3_DATA_DISKS[$name]:-$S3_DATA_DISK}"
    [[ -z "$dev" ]] && return 0   # выделенный диск не задан — используем корневую ФС

    local mount="${S3_DATA_MOUNT:-/var/lib/minio}"
    local fs="${S3_DATA_FS:-xfs}"
    local force="${S3_DATA_DISK_FORCE:-0}"

    log_info "Подготовка выделенного диска $dev под MinIO на $name (монтирование в $mount)..."

    # Скрипт выполняется на ноде: проверка устройства, формат при необходимости, fstab+mount.
    # Install-side значения подставляются heredoc'ом, remote-переменные экранированы (\$).
    local script
    script=$(cat <<REMOTE
set -euo pipefail
dev="$dev"; mount="$mount"; fs="$fs"; force="$force"

if [ ! -b "\$dev" ]; then
    echo "BCM_ERR: устройство \$dev не найдено или не является блочным" >&2
    exit 10
fi

# Уже смонтировано в целевую точку → ничего не делаем (идемпотентность).
if findmnt -rno TARGET "\$dev" 2>/dev/null | grep -qx "\$mount"; then
    echo "уже смонтировано: \$dev -> \$mount"
else
    existing_fs="\$(blkid -o value -s TYPE "\$dev" 2>/dev/null || true)"
    if [ -n "\$existing_fs" ] && [ "\$force" != "1" ]; then
        echo "на \$dev уже есть ФС (\$existing_fs) — форматирование пропущено, монтируем как есть"
    else
        echo "форматирование \$dev в \$fs..."
        case "\$fs" in
            xfs)  mkfs.xfs -f "\$dev" ;;
            ext4) mkfs.ext4 -F "\$dev" ;;
            *)    echo "BCM_ERR: неподдерживаемая ФС '\$fs' (xfs|ext4)" >&2; exit 11 ;;
        esac
    fi
    mkdir -p "\$mount"
    uuid="\$(blkid -o value -s UUID "\$dev")"
    [ -n "\$uuid" ] || { echo "BCM_ERR: не удалось получить UUID \$dev" >&2; exit 12; }
    # Монтирование по UUID (устойчиво к перенумерации устройств при перезагрузке).
    if ! grep -q "UUID=\$uuid[[:space:]]" /etc/fstab; then
        echo "UUID=\$uuid \$mount \$fs defaults,noatime 0 2" >> /etc/fstab
    fi
    mountpoint -q "\$mount" || mount "\$mount"
fi
echo "MinIO data dir: \$mount/data (диск \$dev)"
REMOTE
)
    if ! bcm_ssh_exec_logged "$name" "$ip" "$script"; then
        log_error "Не удалось подготовить диск $dev на $name (см. лог ноды). Установка прервана."
        exit 1
    fi
}

# ──── Конфигурация сервисов ──────────────────────────────────────────────────
configure_services() {
    log_info "Конфигурация сервисов на узлах..."

    # 1. PXC Настройка

    local galera_nodes=""
    for name in "${PXC_NODES[@]}"; do
        galera_nodes="${galera_nodes}${PXC_IPS[$name]},"
    done
    galera_nodes="${galera_nodes%,}"

    # Таймзона БД = таймзона web-нод (требование Bitrix «время БД == время web»).
    local db_tz; db_tz=$(_bcm_web_timezone)
    log_info "Таймзона БД будет выставлена под web-ноды: ${db_tz}"

    local server_id=1
    for name in "${PXC_NODES[@]}"; do
        local ip="${PXC_IPS[$name]}"
        log_info "Настройка PXC на $name ($ip)..."

        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Настройка PXC $name"
            ((server_id++))
            continue
        fi

        configure_firewall_for_node "$name" "$ip" "pxc"

        local local_pxc_cfg="/tmp/pxc.cnf"
        cp "${BCM_BASE_DIR}/templates/pxc.cnf.tmpl" "$local_pxc_cfg"

        sed -i "s/__SERVER_ID__/${server_id}/g" "$local_pxc_cfg"
        sed -i "s/__NODE_NAME__/${name}/g" "$local_pxc_cfg"
        sed -i "s/__NODE_IP__/${ip}/g" "$local_pxc_cfg"
        sed -i "s/__CLUSTER_NAME__/bitrix_pxc/g" "$local_pxc_cfg"
        sed -i "s/__GALERA_NODES_LIST__/${galera_nodes}/g" "$local_pxc_cfg"
        # innodb_buffer_pool_size — авто-подбор от RAM ноды под бюджет памяти Bitrix:
        # global_buffers + conn_buffers(~2M) * max_connections(500) ≤ ~75% RAM.
        # → pool = 0.75*RAM − 500*2M − 128M (прочие global). Floor 256M; fallback 1024M.
        # max_connections=500 задан в pxc.cnf.tmpl — при его изменении поправить и тут.
        local node_mem_mb pool_mb
        node_mem_mb=$(bcm_ssh_exec "$ip" "awk '/MemTotal/{print int(\$2/1024)}' /proc/meminfo" 2>/dev/null | tr -d '[:space:]')
        if [[ "$node_mem_mb" =~ ^[0-9]+$ && "$node_mem_mb" -ge 1024 ]]; then
            pool_mb=$(( node_mem_mb * 75 / 100 - 500 * 2 - 128 ))
            [[ "$pool_mb" -lt 256 ]] && pool_mb=256
        else
            pool_mb=1024
            log_warn "  Не удалось определить RAM ноды $name — innodb_buffer_pool_size=1024M (fallback)."
        fi
        log_info "  innodb_buffer_pool_size на $name: ${pool_mb}M (RAM: ${node_mem_mb:-?}M)"
        sed -i "s/__INNODB_BUFFER_SIZE__/${pool_mb}M/g" "$local_pxc_cfg"
        render_value "$local_pxc_cfg" "__DB_TIMEZONE__" "$db_tz"

        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /etc/mysql/conf.d /etc/mysql/mysql.conf.d /var/log/mysql"
        bcm_ssh_exec_logged "$name" "$ip" "chown -R mysql:mysql /var/log/mysql || true"
        bcm_ssh_copy_file "$local_pxc_cfg" "$ip" "/etc/my.cnf"
        # Инициализация datadir без пароля root, если он еще не инициализирован
        bcm_ssh_exec_logged "$name" "$ip" "[ ! -d /var/lib/mysql/mysql ] && mysqld --initialize-insecure --datadir=/var/lib/mysql --user=mysql || true"

        rm -f "$local_pxc_cfg"
        ((server_id++))
    done

    # Бутстрап базы данных
    if [[ "$DRY_RUN" -eq 0 ]]; then
        local writer_ip="${PXC_IPS[$PXC_WRITER]}"

        # Идемпотентность: не трогаем уже работающий первичный компонент кластера.
        # Принудительный bootstrap здорового узла мог бы привести к split-brain.
        if pxc_is_primary "$writer_ip"; then
            log_ok "Узел-writer $PXC_WRITER уже работает как Primary — бутстрап пропущен."
            bcm_ssh_exec_logged "$PXC_WRITER" "$writer_ip" "systemctl enable mysql"
        else
            log_info "Бутстрап первого PXC узла (writer: $PXC_WRITER, IP: $writer_ip)..."
            bcm_ssh_exec_logged "$PXC_WRITER" "$writer_ip" "systemctl stop mysqld 2>/dev/null || systemctl stop mysql 2>/dev/null || true"
            # safe_to_bootstrap: 1 нужен только при первичной инициализации/повторном
            # запуске на уже остановленном узле. Выполняется только когда узел НЕ Primary.
            bcm_ssh_exec_logged "$PXC_WRITER" "$writer_ip" "[ -f /var/lib/mysql/grastate.dat ] && sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /var/lib/mysql/grastate.dat || true"
            bcm_ssh_exec_logged "$PXC_WRITER" "$writer_ip" "systemctl start mysql@bootstrap"
            bcm_ssh_exec_logged "$PXC_WRITER" "$writer_ip" "systemctl enable mysql"

            log_info "Ожидание готовности writer-узла (Synced)..."
            if ! pxc_wait_synced "$writer_ip" 180; then
                log_error "Узел-writer $PXC_WRITER не вошёл в состояние Synced за отведённое время."
                log_error "Проверьте журнал MySQL на $writer_ip перед повторным запуском."
                exit 1
            fi
            log_ok "Writer-узел $PXC_WRITER синхронизирован."
        fi

        # Создание служебных пользователей (идемпотентно).
        # SQL передаётся в mysql через stdin: пароли не попадают ни в список процессов
        # (ps), ни в логи нод (используем bcm_ssh_exec без логирования команды).
        # ВАЖНО: mysql_native_password обязателен — PXC 8 по умолчанию caching_sha2,
        # а ProxySQL ходит на backend по native; иначе ProxySQL не подключится к PXC.
        log_info "Создание пользователей monitor/${BITRIX_DB_USER} на $PXC_WRITER (native auth)..."
        bcm_ssh_exec "$writer_ip" "mysql" <<SQL || log_warn "Не удалось создать пользователей БД (см. состояние кластера)."
CREATE USER IF NOT EXISTS '${PROXYSQL_MONITOR_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${PROXYSQL_MONITOR_PASS}';
ALTER USER '${PROXYSQL_MONITOR_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${PROXYSQL_MONITOR_PASS}';
GRANT USAGE, REPLICATION CLIENT ON *.* TO '${PROXYSQL_MONITOR_USER}'@'%';
CREATE USER IF NOT EXISTS '${BITRIX_DB_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${BITRIX_DB_PASS}';
ALTER USER '${BITRIX_DB_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${BITRIX_DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${BITRIX_DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

        # Запуск остальных PXC узлов
        # Сначала скопируем SSL-сертификаты с бутстрап-узла на остальные, чтобы Galera SSL соединение работало
        local temp_ssl_dir="/tmp/bcm-ssl-temp"
        mkdir -p "$temp_ssl_dir"
        for f in ca.pem ca-key.pem server-cert.pem server-key.pem client-cert.pem client-key.pem; do
            bcm_ssh_fetch_file "$writer_ip" "/var/lib/mysql/$f" "${temp_ssl_dir}/$f" || true
        done

        for name in "${PXC_NODES[@]}"; do
            [[ "$name" == "$PXC_WRITER" ]] && continue
            local ip="${PXC_IPS[$name]}"

            # Узел уже в кластере — не перезапускаем без необходимости
            if pxc_is_primary "$ip"; then
                log_ok "Узел $name ($ip) уже в кластере (Primary) — пропускаем присоединение."
                bcm_ssh_exec_logged "$name" "$ip" "systemctl enable mysql"
                continue
            fi

            # Копируем сертификаты на присоединяемый узел
            for f in ca.pem ca-key.pem server-cert.pem server-key.pem client-cert.pem client-key.pem; do
                if [[ -f "${temp_ssl_dir}/$f" ]]; then
                    bcm_ssh_copy_file "${temp_ssl_dir}/$f" "$ip" "/var/lib/mysql/$f"
                    bcm_ssh_exec "$ip" "chown mysql:mysql /var/lib/mysql/$f && chmod 640 /var/lib/mysql/$f"
                fi
            done

            log_info "Присоединение $name ($ip) к PXC кластеру (выполняется SST, может занять время)..."
            bcm_ssh_exec_logged "$name" "$ip" "systemctl stop mysqld 2>/dev/null || systemctl stop mysql 2>/dev/null || true"
            bcm_ssh_exec_logged "$name" "$ip" "systemctl enable mysql && systemctl restart mysql"

            # Дожидаемся фактического вхождения в кластер, прежде чем идти дальше
            if pxc_wait_synced "$ip" 600; then
                log_ok "Узел $name ($ip) синхронизирован с кластером."
            else
                log_warn "Узел $name ($ip) не достиг состояния Synced за 10 минут. Проверьте журнал MySQL/SST."
            fi
        done
        rm -rf "$temp_ssl_dir"
    fi

    # 2. HAProxy конфигурация
    local stats_pass
    stats_pass=$(_bcm_rand_hex 8)
    local local_haproxy_cfg="/tmp/haproxy.cfg"
    cp "${BCM_BASE_DIR}/templates/haproxy.cfg.tmpl" "$local_haproxy_cfg"
    render_value "$local_haproxy_cfg" "__BCM_STATS_PASSWORD__" "$stats_pass"

    local web_backends=""
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        web_backends="${web_backends}    server ${name} ${ip}:80 check inter 2s fall 3 rise 2\n"
    done
    render_multiline "$local_haproxy_cfg" "__BCM_WEB_NODES_BACKENDS__" "$web_backends"
    # web_cache_backend (CSS/JS-кэш, retry-on 404) — те же web-ноды, что и публичный.
    render_multiline "$local_haproxy_cfg" "__BCM_WEB_CACHE_BACKENDS__" "$web_backends"

    # Admin/запись (/bitrix/admin) — только на источник lsyncd (первый web),
    # остальные ноды как backup (берутся лишь при падении источника). Так
    # обновления модулей и правки файлов всегда пишутся на одну ноду и затем
    # расходятся по lsyncd, а не теряются на round-robin.
    local admin_src="${WEB_NODES[0]}"
    local web_admin_backends=""
    web_admin_backends="${web_admin_backends}    server ${admin_src} ${WEB_IPS[$admin_src]}:80 check inter 2s fall 3 rise 2\n"
    for name in "${WEB_NODES[@]}"; do
        [[ "$name" == "$admin_src" ]] && continue
        local ip="${WEB_IPS[$name]}"
        web_admin_backends="${web_admin_backends}    server ${name} ${ip}:80 check inter 2s fall 3 rise 2 backup\n"
    done
    render_multiline "$local_haproxy_cfg" "__BCM_WEB_ADMIN_BACKENDS__" "$web_admin_backends"

    local s3_backends=""
    for name in "${S3_NODES[@]}"; do
        local ip="${S3_IPS[$name]}"
        s3_backends="${s3_backends}    server ${name} ${ip}:${S3_PORT} check inter 5s fall 3 rise 2\n"
    done
    render_multiline "$local_haproxy_cfg" "__BCM_S3_NODES_BACKENDS__" "$s3_backends"

    # ACME-бэкенд (Let's Encrypt HTTP-01): по серверу на каждый LB, БЕЗ check —
    # ответчик acme.sh живёт только на время выпуска, redispatch найдёт живого.
    local acme_backends=""
    for name in "${LB_NODES[@]}"; do
        local ip="${LB_IPS[$name]}"
        acme_backends="${acme_backends}    server ${name} ${ip}:${ACME_HTTP_PORT}\n"
    done
    render_multiline "$local_haproxy_cfg" "__BCM_ACME_BACKENDS__" "$acme_backends"

    # Принудительный HTTPS: в шаблоне строка с маркером bcm:force_https закомментирована;
    # при FORCE_HTTPS=1 раскомментируем (тем же sed, что и переключатель в меню 12).
    if [[ "${FORCE_HTTPS}" == "1" ]]; then
        sed -i 's|^\([[:space:]]*\)# \(http-request redirect scheme https[^#]*# bcm:force_https\)$|\1\2|' "$local_haproxy_cfg"
    fi

    # Накатить HAProxy и Keepalived на LB
    local auth_pass_lb
    auth_pass_lb=$(_bcm_rand_hex 4)

    for name in "${LB_NODES[@]}"; do
        local ip="${LB_IPS[$name]}"
        log_info "Настройка LB на $name ($ip)..."

        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Настройка LB $name"
            continue
        fi

        configure_firewall_for_node "$name" "$ip" "lb"

        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /etc/haproxy /etc/haproxy/certs"
        bcm_ssh_exec_logged "$name" "$ip" "[ -f /etc/haproxy/certs/localhost.pem ] || (openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -subj '/C=US/ST=State/L=City/O=Organization/CN=localhost' -keyout /tmp/localhost.key -out /tmp/localhost.crt && cat /tmp/localhost.key /tmp/localhost.crt > /etc/haproxy/certs/localhost.pem && rm -f /tmp/localhost.key /tmp/localhost.crt)"
        bcm_ssh_copy_file "$local_haproxy_cfg" "$ip" "/etc/haproxy/haproxy.cfg"

        local local_keepalived_cfg="/tmp/keepalived_lb.conf"
        cp "${BCM_BASE_DIR}/templates/keepalived_lb.conf.tmpl" "$local_keepalived_cfg"

        local state="BACKUP"
        local priority="100"
        local peer_ip="${LB_IPS[${LB_NODES[0]}]}"
        if [[ "$name" == "${LB_NODES[0]}" ]]; then
            state="MASTER"
            priority="110"
            peer_ip="${LB_IPS[${LB_NODES[1]}]}"
        fi

        local iface
        iface=$(bcm_ssh_exec "$ip" "ip route | grep default | awk '{print \$5}' | head -1" | tr -d '[:space:]')
        [[ -z "$iface" ]] && iface="eth0"

        sed -i "s/__NODE_NAME__/${name}/g" "$local_keepalived_cfg"
        sed -i "s/__VRRP_STATE__/${state}/g" "$local_keepalived_cfg"
        sed -i "s/__NODE_IFACE__/${iface}/g" "$local_keepalived_cfg"
        sed -i "s/__PRIORITY__/${priority}/g" "$local_keepalived_cfg"
        render_value "$local_keepalived_cfg" "__VRRP_AUTH_PASS__" "$auth_pass_lb"
        sed -i "s/__VIP__/${VIP}/g" "$local_keepalived_cfg"
        sed -i "s/__NODE_IP__/${ip}/g" "$local_keepalived_cfg"
        sed -i "s/__PEER_IP__/${peer_ip}/g" "$local_keepalived_cfg"

        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /etc/keepalived"
        bcm_ssh_copy_file "$local_keepalived_cfg" "$ip" "/etc/keepalived/keepalived.conf"

        bcm_ssh_exec_logged "$name" "$ip" "systemctl daemon-reload && systemctl enable haproxy keepalived && systemctl restart haproxy keepalived"
    done
    rm -f "$local_haproxy_cfg" "$local_keepalived_cfg" 2>/dev/null

    # 3. S3 Настройка
    # Креды берём из конфига/файла ответов. Если secret не задан — генерируем случайный,
    # чтобы не оставлять общеизвестный пароль minioadminpassword.
    local s3_access_key="${S3_ACCESS_KEY:-minioadmin}"
    local s3_secret_key="${S3_SECRET_KEY:-}"
    if [[ -z "$s3_secret_key" ]]; then
        s3_secret_key="$(_bcm_rand_hex 16)"
        log_warn "Secret key MinIO не задан в конфиге — сгенерирован случайный."
    fi

    # TLS для MinIO (серт + доверенный CA) — ОБЯЗАТЕЛЬНО до старта MinIO.
    configure_s3_tls

    for name in "${S3_NODES[@]}"; do
        local ip="${S3_IPS[$name]}"
        log_info "Настройка MinIO на $name ($ip)..."

        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Настройка MinIO $name"
            continue
        fi

        configure_firewall_for_node "$name" "$ip" "s3"

        # Опционально: вынести хранилище MinIO на выделенный диск (если задан).
        prepare_s3_data_disk "$name" "$ip"
        local s3_data_dir="${S3_DATA_MOUNT:-/var/lib/minio}/data"

        local local_minio_cfg="/tmp/minio.env"
        cp "${BCM_BASE_DIR}/templates/minio.env.tmpl" "$local_minio_cfg"

        sed -i "s|__MINIO_VOLUMES__|${s3_data_dir}|g" "$local_minio_cfg"
        render_value "$local_minio_cfg" "__MINIO_ROOT_USER__" "$s3_access_key"
        render_value "$local_minio_cfg" "__MINIO_ROOT_PASSWORD__" "$s3_secret_key"
        sed -i "s/__MINIO_SITE_NAME__/${name}/g" "$local_minio_cfg"
        sed -i "s/__MINIO_SITE_REGION__/us-east-1/g" "$local_minio_cfg"
        sed -i "s/__MINIO_DOMAIN__/${S3_VHOST_DOMAIN}/g" "$local_minio_cfg"

        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /etc/default '${s3_data_dir}' /var/log/minio"
        bcm_ssh_copy_file "$local_minio_cfg" "$ip" "/etc/default/minio"

        local local_minio_svc="/tmp/minio.service"
        cat > "$local_minio_svc" <<'EOF'
[Unit]
Description=MinIO
Documentation=https://docs.min.io
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
WorkingDirectory=/usr/local
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server $MINIO_OPTS
Restart=always
LimitNOFILE=65536
TasksMax=infinity
TimeoutStopSec=infinity
SendSIGKILL=no
StandardOutput=append:/var/log/minio/minio.log
StandardError=append:/var/log/minio/minio.log

[Install]
WantedBy=multi-user.target
EOF
        bcm_ssh_copy_file "$local_minio_svc" "$ip" "/etc/systemd/system/minio.service"

        # TLS: серт в certs-dir (MinIO авто-включает https) + доверенный CA на ноде.
        _bcm_deploy_s3_cert "$ip"
        _bcm_install_s3_ca "$ip"

        bcm_ssh_exec_logged "$name" "$ip" "systemctl daemon-reload && systemctl enable minio && systemctl restart minio"
        rm -f "$local_minio_cfg" "$local_minio_svc"
    done

    # Site Replication для MinIO
    if [[ "$DRY_RUN" -eq 0 && ${#S3_NODES[@]} -ge 2 ]]; then
        log_info "Настройка Site Replication для S3..."
        local s3_01_ip="${S3_IPS[${S3_NODES[0]}]}"
        local s3_02_ip="${S3_IPS[${S3_NODES[1]}]}"
        local s3_01_name="${S3_NODES[0]}"

        # Креды могут содержать спецсимволы (;, &, $, пробелы) — для удалённого
        # шелла обязательно одинарное квотирование (с экранированием самих '): иначе
        # команда обрывается на ';'/'&', а '$VAR' раскрывается на стороне ноды.
        local s3_ak_q s3_sk_q
        printf -v s3_ak_q "'%s'" "${s3_access_key//\'/\'\\\'\'}"
        printf -v s3_sk_q "'%s'" "${s3_secret_key//\'/\'\\\'\'}"

        # ⚠️ alias site1 — ТОЛЬКО реальный IP, НЕ localhost: `mc admin replicate add`
        # записывает URL алиаса как endpoint сайта в конфиг репликации. С localhost
        # site2 реплицировал бы «на site1» В САМОГО СЕБЯ → репликация site2→site1
        # мертва (массовые ошибки), а всё залитое через VIP на site2 (round-robin —
        # половина PUT'ов!) на site1 не попадает. Ловили вживую.
        # https: MinIO слушает TLS, серт SAN включает IP S3-нод, CA доверен на ноде →
        # верификация проходит без --insecure. http://…:9000 теперь вернул бы 400.
        bcm_ssh_exec_logged "$s3_01_name" "$s3_01_ip" "mc alias set site1 https://${s3_01_ip}:9000 ${s3_ak_q} ${s3_sk_q}"
        bcm_ssh_exec_logged "$s3_01_name" "$s3_01_ip" "mc alias set site2 https://${s3_02_ip}:9000 ${s3_ak_q} ${s3_sk_q}"
        bcm_ssh_exec_logged "$s3_01_name" "$s3_01_ip" "mc admin replicate add site1 site2 || true"

        # Бакет для пользовательских файлов Bitrix (/upload → S3, общий для web-нод).
        # Реплицируется на site2 благодаря Site Replication. Политика download —
        # файлы /upload в Bitrix и так веб-доступны (public-read статика).
        log_info "Создание бакета '${S3_UPLOAD_BUCKET}' для загрузок Bitrix..."
        bcm_ssh_exec_logged "$s3_01_name" "$s3_01_ip" "mc mb --ignore-existing site1/${S3_UPLOAD_BUCKET}"
        bcm_ssh_exec_logged "$s3_01_name" "$s3_01_ip" "mc anonymous set download site1/${S3_UPLOAD_BUCKET} || true"
    fi

    # 4. WEB Настройка
    local auth_pass_web
    auth_pass_web=$(_bcm_rand_hex 4)

    local local_proxysql_cfg="/tmp/proxysql.cnf"
    cp "${BCM_BASE_DIR}/templates/proxysql.cnf.tmpl" "$local_proxysql_cfg"

    # ⚠️⚠️ ВСЕ PXC-ноды сидят в HG_WRITE (writer_hostgroup), а НЕ writer→HG10 /
    # остальные→HG20. С mysql_galera_hostgroups galera-checker оставляет активным
    # writer'ом (HG_WRITE ONLINE) ноду с наибольшим weight ТОЛЬКО СРЕДИ нод,
    # СКОНФИГУРИРОВАННЫХ в writer_hostgroup; остальных он сам раскидывает в
    # backup_writer (HG11, failover-пул) и reader (HG20, writer_is_also_reader=2).
    # Нода, ЗАХАРДКоженная в HG_READ, для checker'а «выделенный reader» и НЕ
    # повышается в writer'ы НИКАКИМ весом → меню «Сменить Writer» (через вес) на ней
    # молча не срабатывало (db02 weight=1000 в HG20 → writer оставался db03; ловили
    # вживую, ProxySQL 2.6.6 + PXC 8.4, июнь 2026). Поэтому ВСЕ → HG_WRITE, writer
    # получает вес 1000, остальные 100. Проверено вживую: writer следует за весом,
    # HG11 заполнен (failover работает). См. _pxc_build_writer_sql в menu/03_pxc.sh.
    local mysql_servers=""
    for name in "${PXC_NODES[@]}"; do
        local ip="${PXC_IPS[$name]}"
        local weight="100"
        [[ "$name" == "$PXC_WRITER" ]] && weight="1000"
        mysql_servers="${mysql_servers}    { address=\"${ip}\", port=3306, hostgroup=__HG_WRITE__, max_connections=200, weight=${weight} },\n"
    done
    render_multiline "$local_proxysql_cfg" "__MYSQL_SERVERS__" "$mysql_servers"

    sed -i "s/__ADMIN_USER__/${PROXYSQL_ADMIN_USER}/g" "$local_proxysql_cfg"
    render_value "$local_proxysql_cfg" "__ADMIN_PASSWORD__" "$PROXYSQL_ADMIN_PASS"
    render_value "$local_proxysql_cfg" "__RADMIN_PASSWORD__" "$PROXYSQL_ADMIN_PASS"
    sed -i "s/__PROXY_PORT__/${PROXYSQL_PORT}/g" "$local_proxysql_cfg"
    sed -i "s/__ADMIN_PORT__/${PROXYSQL_ADMIN_PORT}/g" "$local_proxysql_cfg"
    sed -i "s/__HG_WRITE__/10/g" "$local_proxysql_cfg"
    sed -i "s/__HG_READ__/20/g" "$local_proxysql_cfg"
    sed -i "s/__HG_BACKUP_WRITE__/11/g" "$local_proxysql_cfg"
    sed -i "s/__HG_OFFLINE__/30/g" "$local_proxysql_cfg"
    sed -i "s/__MONITOR_USER__/${PROXYSQL_MONITOR_USER}/g" "$local_proxysql_cfg"
    render_value "$local_proxysql_cfg" "__MONITOR_PASS__" "$PROXYSQL_MONITOR_PASS"
    sed -i "s/__BITRIX_DB_USER__/${BITRIX_DB_USER}/g" "$local_proxysql_cfg"
    render_value "$local_proxysql_cfg" "__BITRIX_DB_PASS__" "$BITRIX_DB_PASS"
    # Bitrix ходит через ProxySQL → sql_mode/time_zone сессии задаёт ProxySQL.
    # Время БД = время web (требование Bitrix), sql_mode пустой (требование Bitrix).
    render_value "$local_proxysql_cfg" "__DB_TIMEZONE__" "$(_bcm_web_timezone)"

    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        log_info "Настройка WEB-ноды на $name ($ip)..."

        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Настройка ProxySQL и Keepalived (HA Cron) на $name"
            continue
        fi

        configure_firewall_for_node "$name" "$ip" "web"

        bcm_ssh_copy_file "$local_proxysql_cfg" "$ip" "/etc/proxysql.cnf"

        local local_keepalived_web="/tmp/keepalived_web.conf"
        cp "${BCM_BASE_DIR}/templates/keepalived_web.conf.tmpl" "$local_keepalived_web"

        local state="BACKUP"
        local priority="100"
        local peer_ip="${WEB_IPS[${WEB_NODES[0]}]}"
        if [[ "$name" == "${WEB_NODES[0]}" ]]; then
            state="MASTER"
            priority="110"
            peer_ip="${WEB_IPS[${WEB_NODES[1]}]}"
        fi

        local iface
        iface=$(bcm_ssh_exec "$ip" "ip route | grep default | awk '{print \$5}' | head -1" | tr -d '[:space:]')
        [[ -z "$iface" ]] && iface="eth0"

        sed -i "s/__NODE_NAME__/${name}/g" "$local_keepalived_web"
        sed -i "s/__VRRP_STATE__/${state}/g" "$local_keepalived_web"
        sed -i "s/__NODE_IFACE__/${iface}/g" "$local_keepalived_web"
        sed -i "s/__VRID__/${WEB_VRID}/g" "$local_keepalived_web"
        sed -i "s/__PRIORITY__/${priority}/g" "$local_keepalived_web"
        render_value "$local_keepalived_web" "__VRRP_CRON_PASS__" "$auth_pass_web"
        sed -i "s/__NODE_IP__/${ip}/g" "$local_keepalived_web"
        sed -i "s/__PEER_IP__/${peer_ip}/g" "$local_keepalived_web"

        # ⚠️ cron_notify.sh ДОЛЖЕН быть на ноде ДО старта keepalived: при
        # enable_script_security keepalived проверяет notify-скрипты на этапе
        # парсинга конфига и НАВСЕГДА отключает недоступный notify (для текущей
        # загрузки). deploy_bcm раскатывает lib-скрипты позже в main(), поэтому
        # без этой копии notify_master/backup для HA-Cron (VI_56) не запускались
        # бы → начальная роль не применялась, cron_events.php тикал на ОБЕИХ
        # нодах. Копируем явно, как configure_*_redis для redis_session_notify.sh.
        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /opt/bcm/bin/lib"
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/cron_notify.sh" "$ip" "/opt/bcm/bin/lib/cron_notify.sh"
        bcm_ssh_exec "$ip" "chmod +x /opt/bcm/bin/lib/cron_notify.sh"

        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /etc/keepalived"
        bcm_ssh_copy_file "$local_keepalived_web" "$ip" "/etc/keepalived/keepalived.conf"

        # Guard HA Cron: ansible bitrix-env может перезаписать /etc/crontab свежей
        # (раскомментированной) строкой cron_events, пока нода — BACKUP → агенты
        # задублируются. Раз в 10 минут переприменяем сохранённую VRRP-роль.
        bcm_ssh_exec_logged "$name" "$ip" "printf '*/10 * * * * root /opt/bcm/bin/lib/cron_notify.sh assert >/dev/null 2>&1\n' > /etc/cron.d/bcm-ha-cron-guard && chmod 644 /etc/cron.d/bcm-ha-cron-guard"

        bcm_ssh_exec_logged "$name" "$ip" "systemctl daemon-reload && systemctl enable proxysql keepalived && systemctl restart proxysql keepalived"
    done
    rm -f "$local_proxysql_cfg" "$local_keepalived_web" 2>/dev/null
}

# ──── Подключение Push & Pull (NodeJS RTC) на web-нодах ──────────────────────
# В bitrix-env 9.x+ push-сервер устанавливается, но НЕ подключается к пулу
# автоматически. Подключение делается командой:
#   /opt/webdir/bin/bx-sites -a push_configure_nodejs -H <pool_hostname>
# которая запускает ansible-задачу (id вида pushserver_<n>): ставит пакеты,
# поднимает redis, запускает nodejs (sub-порты 8010-8015, pub 9010-9011),
# добавляет хост в группу bitrix-push и прописывает настройки модуля Bitrix.
# Каждая web-нода — отдельный single-host пул bitrix-env (ansible_connection=local),
# поэтому команда выполняется НА самой ноде. Операция идемпотентна: если хост
# уже в группе push — пропускаем.
configure_push_service() {
    log_info "Подключение Push & Pull (NodeJS RTC) на web-нодах..."

    # Скрипт, выполняемый на web-ноде: определяет pool-hostname, проверяет
    # идемпотентность и дожидается завершения ansible-задачи.
    local remote_script
    remote_script=$(cat <<'PUSH_SCRIPT'
BX=/opt/webdir/bin
WRAP="$BX/wrapper_ansible_conf"
SITES="$BX/bx-sites"
PROC="$BX/bx-process"

# bitrix-env установлен?
if [[ ! -x "$SITES" || ! -x "$WRAP" ]]; then
    echo "PUSH_SKIP: bitrix-env не установлен на ноде"
    exit 0
fi

# Имя хоста в пуле (строка host:<name>:<ip>:<groups>:...)
host_line=$("$WRAP" 2>/dev/null | grep '^host:' | head -1)
pool_host=$(echo "$host_line" | awk -F: '{print $2}')
[[ -z "$pool_host" ]] && pool_host=$(hostname -s)

# Уже подключён? (хост в группе push)
groups=$(echo "$host_line" | awk -F: '{print $4}')
if echo "$groups" | tr ',' '\n' | grep -qx push; then
    echo "PUSH_ALREADY_ENABLED host=$pool_host"
    exit 0
fi

out=$("$SITES" -a push_configure_nodejs -H "$pool_host" 2>&1)
task=$(echo "$out" | grep -Eo 'pushserver_[0-9]+' | head -1)
if [[ -z "$task" ]]; then
    echo "PUSH_NO_TASK host=$pool_host out=$out"
    exit 1
fi
echo "PUSH_TASK=$task host=$pool_host"

# Ждём завершения ansible-задачи (роль ставит redis/nodejs — это небыстро)
for _i in $(seq 1 90); do
    st=$("$PROC" -a status -t "$task" 2>&1)
    if echo "$st" | grep -q ':finished:'; then
        rc=$(echo "$st" | sed -nE 's/.*:finished:([0-9]+).*/\1/p' | head -1)
        if [[ "${rc:-1}" == "0" ]]; then echo "PUSH_OK"; exit 0; fi
        echo "PUSH_FAIL rc=${rc}: $st"; exit 1
    fi
    if echo "$st" | grep -qE ':(error|failed):'; then
        echo "PUSH_FAIL: $st"; exit 1
    fi
    sleep 5
done
echo "PUSH_TIMEOUT task=$task"
exit 1
PUSH_SCRIPT
)

    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Подключение push на $name ($ip): bx-sites -a push_configure_nodejs"
            continue
        fi

        log_info "Настройка push на $name ($ip) (установка пакетов/redis/nodejs — может занять пару минут)..."
        local result
        result=$(printf '%s\n' "$remote_script" | bcm_ssh_script "$ip" 2>/dev/null)

        # Логируем подробности на узловой лог
        mkdir -p "$NODE_LOGS_DIR" 2>/dev/null || true
        echo -e "\n=== PUSH CONFIGURE $(date '+%Y-%m-%d %H:%M:%S') ===\n${result}" \
            >> "${NODE_LOGS_DIR}/${name}.log" 2>/dev/null || true

        if echo "$result" | grep -q 'PUSH_OK'; then
            log_ok "  $name: Push & Pull подключён (sub 8010-8015, pub 9010-9011)."
        elif echo "$result" | grep -q 'PUSH_ALREADY_ENABLED'; then
            log_ok "  $name: Push & Pull уже подключён — пропуск."
        elif echo "$result" | grep -q 'PUSH_SKIP'; then
            log_warn "  $name: bitrix-env не найден, push пропущен."
        else
            log_warn "  $name: не удалось подключить push. Подробности: ${NODE_LOGS_DIR}/${name}.log"
        fi
    done
}

# ──── Redis-хранилище сессий (master-replica + плавающий VIP) ─────────────────
# Поднимает отдельный redis-инстанс под сессии Bitrix на каждой web-ноде,
# настраивает репликацию (первая web-нода — master), добавляет VRRP-инстанс
# keepalived с VIP, который «следует» за текущим master, и прописывает блок
# 'session' в bitrix/.settings.php (host=VIP). Цель: при переключении web-ноды
# клиентская сессия не теряется.
configure_session_redis() {
    if [[ -z "$SESSION_VIP" ]]; then
        log_info "SESSION_VIP не задан — настройка redis-сессий пропущена."
        return 0
    fi
    log_info "Настройка Redis-хранилища сессий (VIP ${SESSION_VIP}:${SESSION_REDIS_PORT}, master-replica)..."

    local master_node="${WEB_NODES[0]}"
    local master_ip="${WEB_IPS[$master_node]}"
    local docroot="/home/bitrix/www"
    local sess_auth_pass
    sess_auth_pass=$(_bcm_rand_hex 4)

    # systemd-юнит (одинаковый на всех узлах)
    local local_unit="/tmp/redis-session.service"
    cat > "$local_unit" <<'UNIT'
[Unit]
Description=Redis (Bitrix sessions, BCM)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/redis-server /etc/redis/redis-session.conf
User=redis
Group=bitrix
RuntimeDirectory=redis-session
RuntimeDirectoryMode=0755
LimitNOFILE=65536
Restart=always
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
UNIT

    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] redis-сессии на $name ($ip): инстанс ${SESSION_REDIS_PORT}, keepalived VRID ${SESSION_VRID}"
            continue
        fi

        log_info "  $name ($ip): разворачивание redis-инстанса сессий..."

        # 1. Конфиг redis-инстанса
        local local_redis_cfg="/tmp/redis-session-${name}.conf"
        cp "${BCM_BASE_DIR}/templates/redis-session.conf.tmpl" "$local_redis_cfg"
        sed -i "s/__NODE_IP__/${ip}/g" "$local_redis_cfg"
        sed -i "s/__SESSION_PORT__/${SESSION_REDIS_PORT}/g" "$local_redis_cfg"
        sed -i "s/__SESSION_MAXMEM__/${SESSION_REDIS_MAXMEM}/g" "$local_redis_cfg"
        # Реплики стартуют как replica от master; master — без replicaof
        if [[ "$name" != "$master_node" ]]; then
            echo "replicaof ${master_ip} ${SESSION_REDIS_PORT}" >> "$local_redis_cfg"
        fi

        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /var/lib/redis-session /var/log/redis && chown redis:bitrix /var/lib/redis-session && chmod 750 /var/lib/redis-session"
        bcm_ssh_copy_file "$local_redis_cfg" "$ip" "/etc/redis/redis-session.conf"
        bcm_ssh_exec "$ip" "chown redis:root /etc/redis/redis-session.conf && chmod 640 /etc/redis/redis-session.conf"
        bcm_ssh_copy_file "$local_unit" "$ip" "/etc/systemd/system/redis-session.service"
        bcm_ssh_exec_logged "$name" "$ip" "systemctl daemon-reload && systemctl enable --now redis-session"
        rm -f "$local_redis_cfg"

        # 2. Firewall: порт сессий доступен только web-узлам
        _bcm_redis_firewall "$ip" "$SESSION_REDIS_PORT" "redis-session"

        # 3. Notify/health-скрипты для keepalived (нужны до deploy_bcm)
        bcm_ssh_exec "$ip" "mkdir -p /opt/bcm/bin/lib"
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/redis_session_notify.sh" "$ip" "/opt/bcm/bin/lib/redis_session_notify.sh"
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/redis_session_check.sh"  "$ip" "/opt/bcm/bin/lib/redis_session_check.sh"
        bcm_ssh_exec "$ip" "chmod +x /opt/bcm/bin/lib/redis_session_*.sh"

        # 4. VRRP-инстанс keepalived для VIP сессий (добавляем к keepalived.conf)
        local iface
        iface=$(bcm_ssh_exec "$ip" "ip route | grep default | awk '{print \$5}' | head -1" | tr -d '[:space:]')
        [[ -z "$iface" ]] && iface="eth0"

        local state="BACKUP" priority="100" peer_ip=""
        if [[ "$name" == "$master_node" ]]; then
            state="MASTER"; priority="110"
        fi
        # Первый web-узел, отличный от текущего — как unicast-пир
        for peer in "${WEB_NODES[@]}"; do
            if [[ "$peer" != "$name" ]]; then peer_ip="${WEB_IPS[$peer]}"; break; fi
        done

        local local_sess_ka="/tmp/keepalived-session-${name}.conf"
        cp "${BCM_BASE_DIR}/templates/keepalived_session.conf.tmpl" "$local_sess_ka"
        sed -i "s/__SESSION_VRID__/${SESSION_VRID}/g" "$local_sess_ka"
        sed -i "s/__VRRP_STATE__/${state}/g" "$local_sess_ka"
        sed -i "s/__NODE_IFACE__/${iface}/g" "$local_sess_ka"
        sed -i "s/__PRIORITY__/${priority}/g" "$local_sess_ka"
        render_value "$local_sess_ka" "__VRRP_AUTH_PASS__" "$sess_auth_pass"
        sed -i "s/__SESSION_VIP__/${SESSION_VIP}/g" "$local_sess_ka"
        sed -i "s/__SESSION_PORT__/${SESSION_REDIS_PORT}/g" "$local_sess_ka"
        sed -i "s/__NODE_IP__/${ip}/g" "$local_sess_ka"
        sed -i "s/__PEER_IP__/${peer_ip}/g" "$local_sess_ka"

        # Идемпотентно: добавляем блок, только если этого VRID ещё нет в конфиге
        if ! bcm_ssh_exec "$ip" "grep -q 'virtual_router_id ${SESSION_VRID}' /etc/keepalived/keepalived.conf 2>/dev/null"; then
            bcm_ssh_exec "$ip" "cat >> /etc/keepalived/keepalived.conf" < "$local_sess_ka"
        fi
        bcm_ssh_exec_logged "$name" "$ip" "systemctl reload keepalived 2>/dev/null || systemctl restart keepalived"
        rm -f "$local_sess_ka"

        # 5. Прописать блок 'session' в bitrix/.settings.php (если есть docroot)
        local local_php="/tmp/bcm-session-settings-${name}.php"
        cat > "$local_php" <<'PHPSNIP'
<?php
$docroot = '__DOCROOT__';
$file = $docroot . '/bitrix/.settings.php';
if (!is_file($file)) { fwrite(STDERR, "NO_SETTINGS:$file\n"); exit(2); }
$cfg = include $file;
if (!is_array($cfg)) { fwrite(STDERR, "BAD_SETTINGS\n"); exit(2); }
$cfg['session'] = array(
    'value' => array(
        'mode' => 'default',
        'handlers' => array(
            'general' => array(
                'type' => 'redis',
                'host' => '__VIP__',
                'port' => __PORT__,
            ),
        ),
    ),
    'readonly' => false,
);
$bak = $file . '.bcm-bak';
if (!is_file($bak)) { @copy($file, $bak); }
$out = "<?php\nreturn " . var_export($cfg, true) . ";\n";
if (file_put_contents($file, $out, LOCK_EX) === false) { fwrite(STDERR, "WRITE_FAIL\n"); exit(3); }
echo "SETTINGS_OK\n";
PHPSNIP
        sed -i "s#__DOCROOT__#${docroot}#g" "$local_php"
        sed -i "s/__VIP__/${SESSION_VIP}/g" "$local_php"
        sed -i "s/__PORT__/${SESSION_REDIS_PORT}/g" "$local_php"
        bcm_ssh_copy_file "$local_php" "$ip" "/tmp/bcm-session-settings.php"
        rm -f "$local_php"

        local php_res
        php_res=$(bcm_ssh_exec "$ip" "php /tmp/bcm-session-settings.php 2>&1; rm -f /tmp/bcm-session-settings.php")
        if echo "$php_res" | grep -q 'SETTINGS_OK'; then
            bcm_ssh_exec "$ip" "chown bitrix:bitrix ${docroot}/bitrix/.settings.php 2>/dev/null || true"
            log_ok "  $name: redis-сессии настроены, .settings.php обновлён."
        else
            log_warn "  $name: redis-инстанс поднят, но .settings.php не обновлён ($(echo "$php_res" | tr '\n' ' '))."
        fi
    done

    rm -f "$local_unit"
    log_ok "Redis-хранилище сессий настроено. Master: ${master_node}, VIP: ${SESSION_VIP}:${SESSION_REDIS_PORT}."
}

# ──── Подключение портала к БД через ProxySQL/PXC ────────────────────────────
# bitrix-env создаёт «скелет» подключения (БД sitemanager, host=localhost) в
# bitrix/.settings.php сразу при установке. Здесь автоматически: переносим эту БД
# в PXC и перенаправляем .settings.php на локальный ProxySQL (127.0.0.1:PROXY_PORT)
# с пользователем кластера. Идемпотентно. Если портал ещё не развёрнут (нет
# .settings.php) — мягко пропускаем с подсказкой.
configure_portal_db() {
    log_info "Настройка подключения портала к БД (ProxySQL/PXC)..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY RUN] Перенос БД портала в PXC + .settings.php → ProxySQL на web-нодах"
        return 0
    fi

    local repoint_php="${BCM_BASE_DIR}/templates/db_repoint.php"
    local docroot="/home/bitrix/www"
    local proxy_host="127.0.0.1:${PROXYSQL_PORT}"
    local writer_ip="${PXC_IPS[$PXC_WRITER]}"
    local src="${WEB_NODES[0]}"
    local src_ip="${WEB_IPS[$src]}"

    if [[ ! -f "$repoint_php" ]]; then
        log_warn "Не найден ${repoint_php} — авто-настройка БД портала пропущена."
        return 0
    fi

    # 1. Прочитать подключение скелета bitrix-env на источнике
    bcm_ssh_copy_file "$repoint_php" "$src_ip" "/tmp/bcm_db_repoint.php"
    local rd db_name db_host res
    rd=$(bcm_ssh_exec "$src_ip" "BX_DOCROOT='${docroot}' BX_MODE=read php /tmp/bcm_db_repoint.php 2>&1")
    db_name=$(echo "$rd" | sed -n 's/^DB_NAME=//p' | head -1)
    db_host=$(echo "$rd" | sed -n 's/^DB_HOST=//p' | head -1)
    res=$(echo "$rd" | sed -n 's/^RESULT=//p' | head -1)

    if [[ "$res" != "OK" || -z "$db_name" ]]; then
        log_warn "Портал не развёрнут на $src (нет .settings.php) — авто-настройка БД пропущена."
        log_warn "После деплоя портала: restore сохранит .settings.php; либо в web-инсталляторе укажите host=${proxy_host}, user=${BITRIX_DB_USER}."
        return 0
    fi
    if [[ "$db_host" == "$proxy_host" ]]; then
        log_ok "Портал уже подключён через ProxySQL (host=${db_host}) — пропуск."
        return 0
    fi

    log_info "БД портала '${db_name}' (host ${db_host}) → перенос в PXC (writer ${PXC_WRITER})..."

    # 2. Создать/наполнить БД в PXC (идемпотентно) и проверить ProxySQL-роутинг
    local rscript result mig pt
    rscript=$(cat <<RS
DB='${db_name}'; WIP='${writer_ip}'; U='${BITRIX_DB_USER}'; PP='${PROXYSQL_PORT}'
# Пароль ТОЛЬКО как -p<pass> (MYSQL_PWD/defaults-file отвергаются клиентом MySQL 8
# при коннекте к PXC/ProxySQL). native auth обязателен для PXC 8 по сети. Значение
# пароля подставлено при генерации скрипта; в одинарных кавычках для remote-runtime.
# Локальные команды (mysqldump, чтение schemata) идут через сокет root — без пароля.
# PXC-safe дамп: без LOCK TABLES/FLUSH (strict mode ENFORCING), без GTID/tablespaces
DUMP_OPTS='--single-transaction --quick --skip-add-locks --skip-lock-tables --routines --triggers --events --set-gtid-purged=OFF --no-tablespaces'
EXIST=\$(mysql --default-auth=mysql_native_password -p'${BITRIX_DB_PASS}' -h"\$WIP" -u"\$U" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='\$DB'" 2>/dev/null || echo 0)
if [ "\${EXIST:-0}" -gt 0 ]; then
    echo "MIG=ALREADY_IN_PXC:\$EXIST"
elif mysql -N -e "SELECT 1 FROM information_schema.schemata WHERE schema_name='\$DB'" 2>/dev/null | grep -q 1; then
    CS=\$(mysql -N -e "SELECT default_character_set_name FROM information_schema.SCHEMATA WHERE schema_name='\$DB'" 2>/dev/null); [ -z "\$CS" ] && CS=utf8mb4
    if mysqldump \$DUMP_OPTS --default-character-set=\$CS "\$DB" > /tmp/bcm_portal.sql 2>/dev/null \
       && mysql --default-auth=mysql_native_password -p'${BITRIX_DB_PASS}' -h"\$WIP" -u"\$U" -e "CREATE DATABASE IF NOT EXISTS \$DB CHARACTER SET \$CS" 2>/dev/null \
       && mysql --default-auth=mysql_native_password -p'${BITRIX_DB_PASS}' -h"\$WIP" -u"\$U" --default-character-set=\$CS "\$DB" < /tmp/bcm_portal.sql 2>/dev/null; then
        echo "MIG=IMPORTED"
    else
        echo "MIG=IMPORT_FAIL"
    fi
    rm -f /tmp/bcm_portal.sql
else
    mysql --default-auth=mysql_native_password -p'${BITRIX_DB_PASS}' -h"\$WIP" -u"\$U" -e "CREATE DATABASE IF NOT EXISTS \$DB CHARACTER SET utf8mb4" 2>/dev/null && echo "MIG=CREATED_EMPTY" || echo "MIG=CREATE_FAIL"
fi
PT=\$(mysql --default-auth=mysql_native_password -p'${BITRIX_DB_PASS}' -h127.0.0.1 -P"\$PP" -u"\$U" "\$DB" -N -e "SELECT 1" 2>/dev/null || echo ERR)
echo "PROXY_OK=\$PT"
RS
)
    result=$(printf '%s\n' "$rscript" | bcm_ssh_script "$src_ip" 2>/dev/null)
    mig=$(echo "$result" | sed -n 's/^MIG=//p' | head -1)
    pt=$(echo "$result" | sed -n 's/^PROXY_OK=//p' | head -1)
    log_info "  Миграция: ${mig:-?}; ProxySQL-роутинг: ${pt:-?}"

    if [[ "$pt" != "1" ]]; then
        log_error "ProxySQL не маршрутизирует к БД '${db_name}'. .settings.php НЕ изменён (портал не сломан)."
        log_error "Проверьте mysql_servers/mysql_users ProxySQL и пользователя ${BITRIX_DB_USER} в PXC."
        return 0
    fi

    # 3. Перенаправить .settings.php на ProxySQL на всех web-нодах (единая БД)
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        bcm_ssh_copy_file "$repoint_php" "$ip" "/tmp/bcm_db_repoint.php"
        local w
        w=$(bcm_ssh_exec "$ip" "BX_DOCROOT='${docroot}' BX_MODE=write BX_DB_HOST='${proxy_host}' BX_DB_LOGIN='${BITRIX_DB_USER}' BX_DB_PASS='${BITRIX_DB_PASS}' BX_DB_NAME='${db_name}' php /tmp/bcm_db_repoint.php 2>&1; chown bitrix:bitrix '${docroot}/bitrix/.settings.php' 2>/dev/null; rm -f /tmp/bcm_db_repoint.php")
        if echo "$w" | grep -q 'RESULT=OK'; then
            log_ok "  $name: .settings.php → ProxySQL (${proxy_host}, user ${BITRIX_DB_USER}, db ${db_name})."
        elif echo "$w" | grep -q 'RESULT=NO_SETTINGS'; then
            log_info "  $name: .settings.php пока нет — будет разнесён lsyncd с источника."
        else
            log_warn "  $name: не удалось переписать .settings.php (${w})."
        fi
    done

    # 4. Локальный MySQL на web-нодах больше не нужен (БД живёт в PXC). После его
    #    остановки рестартим ProxySQL: при первом старте он не смог занять
    #    127.0.0.1:3306 (порт держал локальный mysqld), а этот интерфейс нужен
    #    management-проверкам bitrix-env (bx_test_mysql_opts хардкодит 127.0.0.1:3306;
    #    без него сайт висит в статусе error и bitrix-env не видит модули, в т.ч.
    #    transformer). Порядок: stop mysqld → restart proxysql → 3306 за ProxySQL.
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        bcm_ssh_exec "$ip" "systemctl disable --now mysqld 2>/dev/null || systemctl disable --now mariadb 2>/dev/null || true" >/dev/null 2>&1
        bcm_ssh_exec "$ip" "systemctl restart proxysql 2>/dev/null || true" >/dev/null 2>&1
    done

    log_ok "Подключение портала к БД настроено: ProxySQL → PXC (БД ${db_name}); ProxySQL слушает 6033+3306."
}

# ──── Деплой BCM ─────────────────────────────────────────────────────────────
deploy_bcm() {
    log_info "Развёртывание BCM на всех узлах кластера..."
    local all_nodes=()
    for name in "${LB_NODES[@]}" "${WEB_NODES[@]}" "${PXC_NODES[@]}" "${S3_NODES[@]}"; do
        all_nodes+=("$name")
    done

    for name in "${all_nodes[@]}"; do
        local ip=""
        local role=""
        if [[ -n "${LB_IPS[$name]:-}" ]]; then
            ip="${LB_IPS[$name]}"
            role="lb"
        elif [[ -n "${WEB_IPS[$name]:-}" ]]; then
            ip="${WEB_IPS[$name]}"
            role="web"
        elif [[ -n "${PXC_IPS[$name]:-}" ]]; then
            ip="${PXC_IPS[$name]}"
            role="pxc"
        elif [[ -n "${S3_IPS[$name]:-}" ]]; then
            ip="${S3_IPS[$name]}"
            role="s3"
        fi

        log_info "Копирование BCM на $name ($ip), роль: $role..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Развёртывание BCM на $name"
            continue
        fi

        bcm_deploy_to_node "$ip" "$role"

        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /etc/bitrix-cluster && chmod 700 /etc/bitrix-cluster"
        bcm_ssh_copy_file "$BCM_CONF_FILE" "$ip" "/etc/bitrix-cluster/cluster.conf"
        # cluster.conf содержит пароли БД/ProxySQL/MinIO в открытом виде — закрываем от
        # непривилегированных пользователей ноды (scp приносит ~644 по umask).
        bcm_ssh_exec "$ip" "chmod 600 /etc/bitrix-cluster/cluster.conf"
    done
}

# ──── Логирование и ротация ──────────────────────────────────────────────────
configure_local_logrotate() {
    log_info "Настройка локальной ротации логов установки..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY RUN] Настройка /etc/logrotate.d/bcm-install"
        return
    fi

    mkdir -p "$NODE_LOGS_DIR" "/var/log/bcm"

    cat << 'EOF' > /etc/logrotate.d/bcm-install
/bcm/logs/*.log /var/log/bcm/*.log {
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
    log_ok "Локальная ротация логов установки настроена."
}

configure_remote_logging() {
    log_info "Настройка локального логирования и ротации на узлах кластера..."
    local all_nodes=()
    for name in "${LB_NODES[@]}" "${WEB_NODES[@]}" "${PXC_NODES[@]}" "${S3_NODES[@]}"; do
        all_nodes+=("$name")
    done

    for name in "${all_nodes[@]}"; do
        local ip=""
        local role=""
        if [[ -n "${LB_IPS[$name]:-}" ]]; then
            ip="${LB_IPS[$name]}"
            role="lb"
        elif [[ -n "${WEB_IPS[$name]:-}" ]]; then
            ip="${WEB_IPS[$name]}"
            role="web"
        elif [[ -n "${PXC_IPS[$name]:-}" ]]; then
            ip="${PXC_IPS[$name]}"
            role="pxc"
        elif [[ -n "${S3_IPS[$name]:-}" ]]; then
            ip="${S3_IPS[$name]}"
            role="s3"
        fi

        log_info "Настройка логирования на $name ($ip), роль: $role..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Настройка /etc/logrotate.d/bcm-node на $name"
            continue
        fi

        # Создаем директории для логов BCM на удаленном узле
        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /var/log/bcm"

        # Базовый блок для BCM логов (есть на всех нодах)
        local lr_cfg="/tmp/bcm-node-lr-${name}"
        cat << 'EOF' > "$lr_cfg"
# Настройки ротации логов BCM (на всех узлах)
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

        # Ролевые блоки
        if [[ "$role" == "lb" ]]; then
            # HAProxy, Keepalived
            cat << 'EOF' >> "$lr_cfg"

# HAProxy & Keepalived
/var/log/haproxy.log /var/log/keepalived.log {
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
        elif [[ "$role" == "web" ]]; then
            # Nginx, Apache (httpd), ProxySQL, lsyncd
            cat << 'EOF' >> "$lr_cfg"

# Nginx, Apache (httpd), ProxySQL, lsyncd
/var/log/nginx/*.log /var/log/httpd/*.log /var/log/proxysql/*.log /var/lib/proxysql/proxysql.log /var/log/lsyncd/*.log {
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
            bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /var/log/nginx /var/log/httpd /var/log/proxysql /var/log/lsyncd"
        elif [[ "$role" == "pxc" ]]; then
            # MySQL / Percona Galera logs
            cat << 'EOF' >> "$lr_cfg"

# MySQL / Percona Galera
/var/log/mysql/*.log /var/log/mysql/error.log /var/log/mysql/slow.log {
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
            bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /var/log/mysql && chown -R mysql:mysql /var/log/mysql || true"
        elif [[ "$role" == "s3" ]]; then
            # MinIO
            cat << 'EOF' >> "$lr_cfg"

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
            bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /var/log/minio"
        fi

        # Копируем конфигурационный файл на удаленный узел
        bcm_ssh_copy_file "$lr_cfg" "$ip" "/etc/logrotate.d/bcm-node"
        bcm_ssh_exec_logged "$name" "$ip" "chmod 644 /etc/logrotate.d/bcm-node"
        rm -f "$lr_cfg"
    done
    log_ok "Локальная ротация логов на всех узлах успешно настроена."
}

# ──── Авто-восстановление PXC после полного обесточивания ────────────────────
# Раскатывает на каждую PXC-ноду агент pxc_autorecover.sh + env + systemd-юнит.
# После полной остановки кластера (отключение питания) Galera не стартует сама —
# агент при загрузке детерминированно выбирает ноду с самой свежей БД и поднимает
# кластер, соблюдая кворум. Старт mysql переходит под управление агента, поэтому
# автозапуск штатного mysql.service на PXC-нодах ОТКЛЮЧАЕТСЯ (его делает агент).
configure_pxc_autorecover() {
    log_info "Настройка авто-восстановления PXC (pxc-autorecover)..."

    # Список IP всех PXC-нод (пробел-разделённый) — общий для env всех нод.
    local pxc_ips_list="" name
    for name in "${PXC_NODES[@]}"; do
        pxc_ips_list="${pxc_ips_list}${PXC_IPS[$name]} "
    done
    pxc_ips_list="${pxc_ips_list% }"
    local writer_ip="${PXC_IPS[$PXC_WRITER]}"

    # systemd-юнит (одинаковый на всех PXC-нодах). Oneshot: агент сам стартует
    # mysql/mysql@bootstrap и держит сервис «выполненным». TimeoutStartSec — с
    # запасом над WAIT_MAJORITY(300) + BOOTSTRAP_WAIT(300).
    local local_unit="/tmp/pxc-autorecover.service"
    cat > "$local_unit" <<'UNIT'
[Unit]
Description=PXC (Galera) auto-recovery after full power loss (BCM)
After=network-online.target sshd.service
Wants=network-online.target
# ВАЖНО: НЕ ставить `Before=mysql.service`! Агент сам синхронно вызывает
# `systemctl start mysql`, а его собственный сервис ещё «activating» (oneshot).
# При ordering-зависимости mysql.service systemd ждёт завершения этого юнита →
# deadlock (mysqld на joiner'ах вообще не стартует). mysql.service всё равно
# disabled (автозапуска нет), стартом полностью владеет агент.

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/bcm/bin/lib/pxc_autorecover.sh --recover
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
UNIT

    for name in "${PXC_NODES[@]}"; do
        local ip="${PXC_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] pxc-autorecover на $name ($ip): env(peers=${pxc_ips_list}), юнит, disable mysql autostart"
            continue
        fi

        log_info "  $name ($ip): раскатка агента авто-восстановления..."

        # 1. env-файл с топологией и таймаутами (per-node SELF_IP)
        local local_env="/tmp/pxc-autorecover-${name}.env"
        cat > "$local_env" <<ENV
# Сгенерировано install.sh — параметры pxc_autorecover.sh
PXC_PEERS="${pxc_ips_list}"
SELF_IP="${ip}"
PXC_WRITER_IP="${writer_ip}"
SSH_KEY="/etc/bitrix-cluster/cluster_id_rsa"
GRASTATE="/var/lib/mysql/grastate.dat"
LOG_FILE="/var/log/bcm/pxc-autorecover.log"
POS_CACHE="/run/pxc-autorecover.pos"
WAIT_ALL="120"
WAIT_MAJORITY="300"
RETRY="5"
BOOTSTRAP_WAIT="300"
PEER_PROBE_TIMEOUT="10"
ENV

        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /opt/bcm/bin/lib /var/log/bcm /etc/bitrix-cluster"
        bcm_ssh_copy_file "$local_env" "$ip" "/etc/bitrix-cluster/pxc-autorecover.env"
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/pxc_autorecover.sh" "$ip" "/opt/bcm/bin/lib/pxc_autorecover.sh"
        bcm_ssh_exec "$ip" "chmod 600 /etc/bitrix-cluster/pxc-autorecover.env && chmod +x /opt/bcm/bin/lib/pxc_autorecover.sh"
        bcm_ssh_copy_file "$local_unit" "$ip" "/etc/systemd/system/pxc-autorecover.service"

        # 2. Старт mysql теперь у агента: отключаем автозапуск mysql.service,
        #    включаем pxc-autorecover. Сам mysql НЕ останавливаем (он уже Synced).
        bcm_ssh_exec_logged "$name" "$ip" "systemctl daemon-reload && systemctl disable mysql 2>/dev/null; systemctl enable pxc-autorecover"
        rm -f "$local_env"
    done
    rm -f "$local_unit"
    log_ok "Авто-восстановление PXC настроено на всех узлах."
}

# ──── Авто-роль источника lsyncd (failover за master web-VRRP) ────────────────
# Источник lsyncd (одностороннего) должен следовать за «первичной web-нодой»
# (master web-VRRP / HA-Cron). Раскатывает на каждую web-ноду lsyncd_role.sh +
# env. Стартом lsyncd теперь владеет keepalived-notify (cron_notify.sh:
# MASTER→promote, BACKUP→demote), поэтому автозапуск штатного lsyncd.service
# ОТКЛЮЧАЕТСЯ. promote делает catch-up (rsync --update без --delete) с пиров —
# вернувшийся/перехватывающий узел не затирает наработки, сделанные на пире.
configure_lsyncd_role() {
    log_info "Настройка авто-роли источника lsyncd (следует за master web-VRRP)..."

    local web_ips_list="" name
    for name in "${WEB_NODES[@]}"; do
        web_ips_list="${web_ips_list}${WEB_IPS[$name]} "
    done
    web_ips_list="${web_ips_list% }"
    local site_path="/home/bitrix/www"
    local primary="${WEB_NODES[0]}"

    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] lsyncd-role на $name ($ip): env(peers=${web_ips_list}), disable lsyncd autostart"
            continue
        fi
        log_info "  $name ($ip): раскатка lsyncd_role..."
        local local_env="/tmp/lsyncd-role-${name}.env"
        cat > "$local_env" <<ENV
# Сгенерировано install.sh — параметры lsyncd_role.sh
SELF_NODE="${name}"
SELF_IP="${ip}"
WEB_PEERS="${web_ips_list}"
SITE_PATH="${site_path}"
SSH_KEY="/etc/bitrix-cluster/cluster_id_rsa"
LSYNCD_CONF="/etc/lsyncd/lsyncd.conf"
CLUSTER_CONF="/etc/bitrix-cluster/cluster.conf"
LOG_FILE="/var/log/bcm/lsyncd-role.log"
ENV
        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /opt/bcm/bin/lib /var/log/bcm /etc/lsyncd /var/log/lsyncd /etc/bitrix-cluster"
        bcm_ssh_copy_file "$local_env" "$ip" "/etc/bitrix-cluster/lsyncd-role.env"
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/lsyncd_role.sh" "$ip" "/opt/bcm/bin/lib/lsyncd_role.sh"
        bcm_ssh_exec "$ip" "chmod 600 /etc/bitrix-cluster/lsyncd-role.env && chmod +x /opt/bcm/bin/lib/lsyncd_role.sh"
        # Стартом lsyncd владеет keepalived-notify — снимаем автозапуск штатного юнита.
        bcm_ssh_exec_logged "$name" "$ip" "systemctl disable lsyncd 2>/dev/null; true"
        rm -f "$local_env"
    done

    # Начальная роль: первичная web-нода (она же web-VRRP MASTER) — источник.
    if [[ "$DRY_RUN" -eq 0 ]]; then
        log_info "  Начальный источник lsyncd: ${primary} (${WEB_IPS[$primary]})."
        for name in "${WEB_NODES[@]}"; do
            local ip="${WEB_IPS[$name]}"
            if [[ "$name" == "$primary" ]]; then
                bcm_ssh_exec "$ip" "/opt/bcm/bin/lib/lsyncd_role.sh promote" >/dev/null 2>&1 || true
            else
                bcm_ssh_exec "$ip" "/opt/bcm/bin/lib/lsyncd_role.sh demote" >/dev/null 2>&1 || true
            fi
        done
    fi
    log_ok "Авто-роль источника lsyncd настроена."
}

# ──── Общий HA push-redis (active-active Push&Pull) ──────────────────────────
# Выделенный redis-инстанс для каналов bx-push-server, ОБЩИЙ для всех web-нод
# через плавающий PUSH_VIP (master-replica + keepalived), по образцу session-redis.
# Без этого push-серверы хранят каналы в ЛОКАЛЬНОМ redis → сообщение с одной ноды
# не доходит до подписчика на другой. Также переводит path_to_publish на node-local
# (.settings.php синкается lsyncd → путь обязан быть нод-агностичным).
configure_push_redis() {
    if [[ -z "$PUSH_REDIS_VIP" ]]; then
        log_info "PUSH_REDIS_VIP не задан — настройка общего push-redis пропущена."
        return 0
    fi
    log_info "Настройка общего push-redis (active-active, VIP ${PUSH_REDIS_VIP}:${PUSH_REDIS_PORT})..."

    local master_node="${WEB_NODES[0]}"
    local master_ip="${WEB_IPS[$master_node]}"
    local push_auth_pass
    push_auth_pass=$(_bcm_rand_hex 4)

    # КАНОНИЧЕСКИЙ signature_key — берём с источника lsyncd (WEB_NODES[0]) ОДИН раз и
    # ставим его как security.key на ВСЕХ нодах. Иначе при свежей установке bitrix-env
    # генерит свой signature_key на каждой ноде, lsyncd ещё не успел унифицировать
    # .settings.php, и репойнт по локальному ключу даст РАЗНЫЕ security.key → клиент на
    # «чужой» sub-сервер получит 4010 Wrong Channel Id.
    local push_sig=""
    if [[ "$DRY_RUN" -eq 0 ]]; then
        cat > /tmp/bcm-push-getsig.php <<'PHPSNIP'
<?php
$s=@include '/home/bitrix/www/bitrix/.settings.php';
echo is_array($s) ? ($s['pull']['value']['signature_key'] ?? '') : '';
PHPSNIP
        bcm_ssh_copy_file /tmp/bcm-push-getsig.php "$master_ip" /tmp/bcm-push-getsig.php
        push_sig=$(bcm_ssh_exec "$master_ip" "php /tmp/bcm-push-getsig.php 2>/dev/null; rm -f /tmp/bcm-push-getsig.php")
        rm -f /tmp/bcm-push-getsig.php
    fi

    # systemd-юнит redis-push (одинаковый на всех web)
    local local_unit="/tmp/redis-push.service"
    cat > "$local_unit" <<'UNIT'
[Unit]
Description=Redis (Bitrix push channels, BCM)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/redis-server /etc/redis/redis-push.conf
User=redis
Group=bitrix
RuntimeDirectory=redis-push
RuntimeDirectoryMode=0755
LimitNOFILE=65536
Restart=always
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
UNIT

    local name
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] push-redis на $name ($ip): инстанс ${PUSH_REDIS_PORT}, keepalived VRID ${PUSH_VRID}, репойнт push-server → VIP"
            continue
        fi
        log_info "  $name ($ip): разворачивание push-redis..."

        # 1. Конфиг redis-инстанса (replicaof master для не-master)
        local local_redis_cfg="/tmp/redis-push-${name}.conf"
        cp "${BCM_BASE_DIR}/templates/redis-push.conf.tmpl" "$local_redis_cfg"
        sed -i "s/__NODE_IP__/${ip}/g" "$local_redis_cfg"
        sed -i "s/__PUSH_PORT__/${PUSH_REDIS_PORT}/g" "$local_redis_cfg"
        sed -i "s/__PUSH_MAXMEM__/${PUSH_REDIS_MAXMEM}/g" "$local_redis_cfg"
        if [[ "$name" != "$master_node" ]]; then
            echo "replicaof ${master_ip} ${PUSH_REDIS_PORT}" >> "$local_redis_cfg"
        fi
        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /var/lib/redis-push /var/log/redis && chown redis:bitrix /var/lib/redis-push && chmod 750 /var/lib/redis-push"
        bcm_ssh_copy_file "$local_redis_cfg" "$ip" "/etc/redis/redis-push.conf"
        bcm_ssh_exec "$ip" "chown redis:root /etc/redis/redis-push.conf && chmod 640 /etc/redis/redis-push.conf"
        bcm_ssh_copy_file "$local_unit" "$ip" "/etc/systemd/system/redis-push.service"
        bcm_ssh_exec_logged "$name" "$ip" "systemctl daemon-reload && systemctl enable --now redis-push"
        rm -f "$local_redis_cfg"

        # 2. Firewall: порт push-redis доступен только web-узлам
        _bcm_redis_firewall "$ip" "$PUSH_REDIS_PORT" "redis-push"

        # 3. Notify/health-скрипты для keepalived (reuse session — общие для push)
        bcm_ssh_exec "$ip" "mkdir -p /opt/bcm/bin/lib"
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/redis_session_notify.sh" "$ip" "/opt/bcm/bin/lib/redis_session_notify.sh"
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/redis_session_check.sh"  "$ip" "/opt/bcm/bin/lib/redis_session_check.sh"
        bcm_ssh_exec "$ip" "chmod +x /opt/bcm/bin/lib/redis_session_notify.sh /opt/bcm/bin/lib/redis_session_check.sh"

        # 4. keepalived push-инстанс (добавить идемпотентно по VRID)
        local iface peer_ip="" state="BACKUP" priority="100"
        iface=$(bcm_ssh_exec "$ip" "ip route | awk '/default/{print \$5; exit}'" | tr -d '[:space:]')
        [[ -z "$iface" ]] && iface="ens18"
        if [[ "$name" == "$master_node" ]]; then state="MASTER"; priority="110"; fi
        local peer
        for peer in "${WEB_NODES[@]}"; do
            if [[ "$peer" != "$name" ]]; then peer_ip="${WEB_IPS[$peer]}"; break; fi
        done
        local local_push_ka="/tmp/keepalived-push-${name}.conf"
        cp "${BCM_BASE_DIR}/templates/keepalived_push.conf.tmpl" "$local_push_ka"
        sed -i "s/__PUSH_VRID__/${PUSH_VRID}/g" "$local_push_ka"
        sed -i "s/__VRRP_STATE__/${state}/g" "$local_push_ka"
        sed -i "s/__NODE_IFACE__/${iface}/g" "$local_push_ka"
        sed -i "s/__PRIORITY__/${priority}/g" "$local_push_ka"
        render_value "$local_push_ka" "__VRRP_AUTH_PASS__" "$push_auth_pass"
        sed -i "s/__PUSH_VIP__/${PUSH_REDIS_VIP}/g" "$local_push_ka"
        sed -i "s/__PUSH_PORT__/${PUSH_REDIS_PORT}/g" "$local_push_ka"
        sed -i "s/__NODE_IP__/${ip}/g" "$local_push_ka"
        sed -i "s/__PEER_IP__/${peer_ip}/g" "$local_push_ka"
        if ! bcm_ssh_exec "$ip" "grep -q 'virtual_router_id ${PUSH_VRID}' /etc/keepalived/keepalived.conf 2>/dev/null"; then
            bcm_ssh_exec "$ip" "cat >> /etc/keepalived/keepalived.conf" < "$local_push_ka"
        fi
        bcm_ssh_exec_logged "$name" "$ip" "systemctl reload keepalived 2>/dev/null || systemctl restart keepalived"
        rm -f "$local_push_ka"

        # 5. Репойнт push-server: storage → PUSH_VIP:PUSH_PORT (убрать socket) И
        #    унификация security.key = pull.signature_key из .settings.php.
        #    ⚠️ Без единого ключа на ВСЕХ нодах клиент, балансируемый LB на чужой
        #    sub-сервер, получает «4010 Wrong Channel Id» (push-сервер проверяет
        #    подпись канала своим security.key; PHP подписывает signature_key —
        #    они обязаны совпадать). bitrix-env генерит свой security.key на каждой
        #    ноде → рассинхрон; выравниваем по signature_key (его уже знают клиенты).
        #    VIP/PORT передаём аргументами (НЕ sed): в php есть литерал '__PORT__'
        #    для пропуска шаблонных конфигов — его трогать нельзя.
        local local_repoint="/tmp/bcm-push-repoint.php"
        cat > "$local_repoint" <<'PHPSNIP'
<?php
$vip=$argv[1]??''; $port=(int)($argv[2]??0);
if($vip===''||$port<=0){fwrite(STDERR,"BAD_ARGS\n");exit(2);}
// Канонический signature_key передаётся аргументом (с источника lsyncd, единый для
// всех нод); фоллбэк — локальный .settings.php.
$sig=$argv[3]??'';
if($sig===''){ $sf='/home/bitrix/www/bitrix/.settings.php'; if(is_file($sf)){ $s=@include $sf; $sig=$s['pull']['value']['signature_key']??''; } }
$changed=0;
foreach (glob('/etc/push-server/push-server-{sub,pub}-*.json', GLOB_BRACE) as $f) {
    if (strpos($f,'__PORT__')!==false) continue; // пропустить шаблоны
    $j=json_decode(@file_get_contents($f),true);
    if(!is_array($j)||!isset($j['storage'])) continue;
    unset($j['storage']['socket']);
    $j['storage']['host']=$vip;
    $j['storage']['port']=$port;
    if($sig!==''){ if(!isset($j['security'])||!is_array($j['security'])) $j['security']=array(); $j['security']['key']=$sig; }
    file_put_contents($f, json_encode($j, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n");
    $changed++;
}
echo "REPOINT_OK changed=$changed sig=".($sig!==''?substr($sig,0,8):'NONE')."\n";
PHPSNIP
        bcm_ssh_copy_file "$local_repoint" "$ip" "/tmp/bcm-push-repoint.php"
        local rp
        rp=$(bcm_ssh_exec "$ip" "php /tmp/bcm-push-repoint.php '${PUSH_REDIS_VIP}' '${PUSH_REDIS_PORT}' '${push_sig}' 2>&1; rm -f /tmp/bcm-push-repoint.php")
        rm -f "$local_repoint"   # после exec: на src-ноде local==remote путь (см. cache/pubpath)
        bcm_ssh_exec_logged "$name" "$ip" "systemctl restart push-server 2>/dev/null || true"
        log_info "  $name: push-server storage → ${PUSH_REDIS_VIP}:${PUSH_REDIS_PORT} (${rp})"
    done
    rm -f "$local_unit"

    # 6. path_to_publish → node-local на источнике lsyncd (разъедется на остальные).
    if [[ "$DRY_RUN" -eq 0 ]]; then
        local src="${WEB_NODES[0]}"; local src_ip="${WEB_IPS[$src]}"
        local local_pub="/tmp/bcm-push-pubpath.php"
        cat > "$local_pub" <<'PHPSNIP'
<?php
$f='/home/bitrix/www/bitrix/.settings.php';
if(!is_file($f)){fwrite(STDERR,"NO_SETTINGS\n");exit(2);}
$s=include $f;
if(!isset($s['pull']['value']['path_to_publish'])){fwrite(STDERR,"NO_PULL\n");exit(2);}
$new='http://127.0.0.1:8895/bitrix/pub/';
if($s['pull']['value']['path_to_publish']===$new){echo "PUB_ALREADY\n";exit(0);}
if(!is_file($f.'.bcm-bak-push')) @copy($f,$f.'.bcm-bak-push');
$s['pull']['value']['path_to_publish']=$new;
file_put_contents($f,"<?php\nreturn ".var_export($s,true).";\n",LOCK_EX);
echo "PUB_OK\n";
PHPSNIP
        bcm_ssh_copy_file "$local_pub" "$src_ip" "/tmp/bcm-push-pubpath.php"
        local pubres
        pubres=$(bcm_ssh_exec "$src_ip" "php /tmp/bcm-push-pubpath.php 2>&1; rm -f /tmp/bcm-push-pubpath.php")
        log_info "  path_to_publish (node-local) на ${src}: ${pubres}"
        rm -f "$local_pub"
    fi

    log_ok "Общий push-redis настроен. Master: ${master_node}, VIP: ${PUSH_REDIS_VIP}:${PUSH_REDIS_PORT}."
}

# ──── Общий HA cache-redis (общий кэш Bitrix для active-active) ──────────────
# Выделенный redis-инстанс под кэш Bitrix (managed_cache + cache), ОБЩИЙ для всех
# web-нод через плавающий CACHE_VIP (master-replica + keepalived), по образцу
# session/push-redis. Делает кэш общим → инвалидация по тегам консистентна между
# нодами (иначе файловый per-node кэш: инвалидация на одной ноде не видна другой).
# В .settings.php пишется секция `cache` → CacheEngineRedis на CACHE_VIP.
configure_cache_redis() {
    if [[ -z "$CACHE_REDIS_VIP" ]]; then
        log_info "CACHE_REDIS_VIP не задан — настройка общего cache-redis пропущена."
        return 0
    fi
    log_info "Настройка общего cache-redis (VIP ${CACHE_REDIS_VIP}:${CACHE_REDIS_PORT}, master-replica)..."

    local master_node="${WEB_NODES[0]}"
    local master_ip="${WEB_IPS[$master_node]}"
    local docroot="/home/bitrix/www"
    local cache_auth_pass
    cache_auth_pass=$(_bcm_rand_hex 4)

    # systemd-юнит redis-cache (одинаковый на всех web)
    local local_unit="/tmp/redis-cache.service"
    cat > "$local_unit" <<'UNIT'
[Unit]
Description=Redis (Bitrix cache, BCM)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/redis-server /etc/redis/redis-cache.conf
User=redis
Group=bitrix
RuntimeDirectory=redis-cache
RuntimeDirectoryMode=0755
LimitNOFILE=65536
Restart=always
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
UNIT

    local name
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] cache-redis на $name ($ip): инстанс ${CACHE_REDIS_PORT}, keepalived VRID ${CACHE_VRID}"
            continue
        fi
        log_info "  $name ($ip): разворачивание cache-redis..."

        # 1. Конфиг redis-инстанса (replicaof master для не-master)
        local local_redis_cfg="/tmp/redis-cache-${name}.conf"
        cp "${BCM_BASE_DIR}/templates/redis-cache.conf.tmpl" "$local_redis_cfg"
        sed -i "s/__NODE_IP__/${ip}/g" "$local_redis_cfg"
        sed -i "s/__CACHE_PORT__/${CACHE_REDIS_PORT}/g" "$local_redis_cfg"
        sed -i "s/__CACHE_MAXMEM__/${CACHE_REDIS_MAXMEM}/g" "$local_redis_cfg"
        if [[ "$name" != "$master_node" ]]; then
            echo "replicaof ${master_ip} ${CACHE_REDIS_PORT}" >> "$local_redis_cfg"
        fi
        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /var/lib/redis-cache /var/log/redis && chown redis:bitrix /var/lib/redis-cache && chmod 750 /var/lib/redis-cache"
        bcm_ssh_copy_file "$local_redis_cfg" "$ip" "/etc/redis/redis-cache.conf"
        bcm_ssh_exec "$ip" "chown redis:root /etc/redis/redis-cache.conf && chmod 640 /etc/redis/redis-cache.conf"
        bcm_ssh_copy_file "$local_unit" "$ip" "/etc/systemd/system/redis-cache.service"
        bcm_ssh_exec_logged "$name" "$ip" "systemctl daemon-reload && systemctl enable --now redis-cache"
        rm -f "$local_redis_cfg"

        # 2. Firewall: порт cache-redis доступен только web-узлам
        _bcm_redis_firewall "$ip" "$CACHE_REDIS_PORT" "redis-cache"

        # 3. Notify/health-скрипты (reuse session — общие)
        bcm_ssh_exec "$ip" "mkdir -p /opt/bcm/bin/lib"
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/redis_session_notify.sh" "$ip" "/opt/bcm/bin/lib/redis_session_notify.sh"
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/redis_session_check.sh"  "$ip" "/opt/bcm/bin/lib/redis_session_check.sh"
        bcm_ssh_exec "$ip" "chmod +x /opt/bcm/bin/lib/redis_session_notify.sh /opt/bcm/bin/lib/redis_session_check.sh"

        # 4. keepalived cache-инстанс (добавить идемпотентно по VRID)
        local iface peer_ip="" state="BACKUP" priority="100"
        iface=$(bcm_ssh_exec "$ip" "ip route | awk '/default/{print \$5; exit}'" | tr -d '[:space:]')
        [[ -z "$iface" ]] && iface="ens18"
        if [[ "$name" == "$master_node" ]]; then state="MASTER"; priority="110"; fi
        local peer
        for peer in "${WEB_NODES[@]}"; do
            if [[ "$peer" != "$name" ]]; then peer_ip="${WEB_IPS[$peer]}"; break; fi
        done
        local local_cache_ka="/tmp/keepalived-cache-${name}.conf"
        cp "${BCM_BASE_DIR}/templates/keepalived_cache.conf.tmpl" "$local_cache_ka"
        sed -i "s/__CACHE_VRID__/${CACHE_VRID}/g" "$local_cache_ka"
        sed -i "s/__VRRP_STATE__/${state}/g" "$local_cache_ka"
        sed -i "s/__NODE_IFACE__/${iface}/g" "$local_cache_ka"
        sed -i "s/__PRIORITY__/${priority}/g" "$local_cache_ka"
        render_value "$local_cache_ka" "__VRRP_AUTH_PASS__" "$cache_auth_pass"
        sed -i "s/__CACHE_VIP__/${CACHE_REDIS_VIP}/g" "$local_cache_ka"
        sed -i "s/__CACHE_PORT__/${CACHE_REDIS_PORT}/g" "$local_cache_ka"
        sed -i "s/__NODE_IP__/${ip}/g" "$local_cache_ka"
        sed -i "s/__PEER_IP__/${peer_ip}/g" "$local_cache_ka"
        if ! bcm_ssh_exec "$ip" "grep -q 'virtual_router_id ${CACHE_VRID}' /etc/keepalived/keepalived.conf 2>/dev/null"; then
            bcm_ssh_exec "$ip" "cat >> /etc/keepalived/keepalived.conf" < "$local_cache_ka"
        fi
        bcm_ssh_exec_logged "$name" "$ip" "systemctl reload keepalived 2>/dev/null || systemctl restart keepalived"
        rm -f "$local_cache_ka"
    done
    rm -f "$local_unit"

    # 5. Прописать секцию 'cache' в .settings.php на источнике lsyncd (разъедется
    #    на остальные; sid фиксированный → единый неймспейс кэша на всех нодах).
    if [[ "$DRY_RUN" -eq 0 ]]; then
        local src_ip="$master_ip"
        local local_php="/tmp/bcm-cache-settings.php"
        cat > "$local_php" <<'PHPSNIP'
<?php
$f='/home/bitrix/www/bitrix/.settings.php';
if(!is_file($f)){fwrite(STDERR,"NO_SETTINGS\n");exit(2);}
$s=include $f;
if(!is_array($s)){fwrite(STDERR,"BAD_SETTINGS\n");exit(2);}
$vip=$argv[1]??''; $port=$argv[2]??'';
$s['cache']=array(
  'value'=>array(
    'type'=>array(
      'class_name'=>'\\Bitrix\\Main\\Data\\CacheEngineRedis',
      'extension'=>'redis',
    ),
    'redis'=>array(
      'host'=>$vip,
      'port'=>$port,
      'scale_mode'=>'single',
    ),
    'sid'=>'/home/bitrix/www#bcmcache01',
  ),
  'readonly'=>false,
);
if(!is_file($f.'.bcm-bak-cache')) @copy($f,$f.'.bcm-bak-cache');
file_put_contents($f,"<?php\nreturn ".var_export($s,true).";\n",LOCK_EX);
echo "CACHE_OK\n";
PHPSNIP
        bcm_ssh_copy_file "$local_php" "$src_ip" "/tmp/bcm-cache-settings.php"
        local cres
        cres=$(bcm_ssh_exec "$src_ip" "php /tmp/bcm-cache-settings.php '${CACHE_REDIS_VIP}' '${CACHE_REDIS_PORT}' 2>&1; rm -f /tmp/bcm-cache-settings.php")
        # rm локального файла ТОЛЬКО после exec: при запуске install с самой src-ноды
        # локальный и удалённый путь совпадают (scp сам-в-себя), и ранний rm удалил бы
        # файл до php → «Could not open input file» (как в push-pubpath ниже).
        rm -f "$local_php"
        if echo "$cres" | grep -q 'CACHE_OK'; then
            bcm_ssh_exec "$src_ip" "chown bitrix:bitrix ${docroot}/bitrix/.settings.php 2>/dev/null || true"
            log_ok "  ${master_node}: .settings.php → кэш в Redis (${CACHE_REDIS_VIP}:${CACHE_REDIS_PORT})."
        else
            log_warn "  ${master_node}: cache-redis поднят, но .settings.php не обновлён ($(echo "$cres" | tr '\n' ' '))."
        fi
    fi

    log_ok "Общий cache-redis настроен. Master: ${master_node}, VIP: ${CACHE_REDIS_VIP}:${CACHE_REDIS_PORT}."
}

# ──── Домен портала → 127.0.0.1 на web-нодах (для self-check'ов) ─────────────
# Bitrix «Проверка системы» создаёт временный файл на ноде, где идёт админ-сессия,
# затем делает серверный HTTP-запрос к домену портала. Если домен резолвится в
# VIP/LB — запрос round-robin может попасть на ДРУГУЮ ноду (файла там нет) → 404
# (check_exec: Fail). Резолвим домен локально на каждой web-ноде. Клиентов (браузер
# админа) это не касается — они ходят через реальный DNS → VIP.
configure_portal_hosts() {
    if [[ -z "$PORTAL_DOMAIN" ]]; then
        log_info "PORTAL_DOMAIN не задан — /etc/hosts на web-нодах не правится."
        return 0
    fi
    log_info "Прописываю домен портала ${PORTAL_DOMAIN} → 127.0.0.1 на web-нодах (self-check'и)..."
    local dom_re="${PORTAL_DOMAIN//./\\.}"   # экранируем точки для sed
    local name
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] $name ($ip): 127.0.0.1 ${PORTAL_DOMAIN} в /etc/hosts"
            continue
        fi
        # Идемпотентно: удалить прежние записи домена, вставить 127.0.0.1 ПЕРЕД
        # ANSIBLE-блоком (иначе ansible bitrix-env затрёт запись после маркера).
        bcm_ssh_exec "$ip" "cp -n /etc/hosts /etc/hosts.bcm-bak 2>/dev/null; \
            sed -i '/${dom_re}/d' /etc/hosts; \
            if grep -q '# ANSIBLE MANAGED BLOCK' /etc/hosts; then \
                sed -i '/# ANSIBLE MANAGED BLOCK/i 127.0.0.1 ${PORTAL_DOMAIN}' /etc/hosts; \
            else echo '127.0.0.1 ${PORTAL_DOMAIN}' >> /etc/hosts; fi"
        log_ok "  $name: ${PORTAL_DOMAIN} → 127.0.0.1"
    done
}

# ──── S3 virtual-host домен → S3-VIP на web-нодах (для модуля clouds) ────────
# Модуль Bitrix «Облачные хранилища» ходит на bucket.<api_host> (virtual-hosted-
# style). Чтобы серверные вызовы PHP резолвили это имя, прописываем <vhost_domain>
# и <bucket>.<vhost_domain> → S3-VIP в /etc/hosts на каждой web-ноде (перед ANSIBLE-
# блоком). MinIO при этом поднят с MINIO_DOMAIN=<vhost_domain> (см. minio.env.tmpl).
# ⚠️ Публичная отдача файлов клиентам требует НАСТОЯЩЕГО DNS (*.<vhost_domain> →
# S3-VIP) и доступного endpoint — /etc/hosts чинит только серверную сторону.
configure_s3_vhost_hosts() {
    if [[ -z "${S3_VHOST_DOMAIN}" || ${#S3_NODES[@]} -eq 0 ]]; then
        log_info "S3 vhost: пропуск (нет S3-слоя или S3_VHOST_DOMAIN пуст)."
        return 0
    fi
    local vh="${S3_VHOST_DOMAIN}" bvh="${S3_UPLOAD_BUCKET}.${S3_VHOST_DOMAIN}"
    log_info "Прописываю S3 vhost ${vh} → ${VIP} на web-нодах (модуль clouds)..."
    local name
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] $name ($ip): ${VIP} ${vh} ${bvh} в /etc/hosts"
            continue
        fi
        bcm_ssh_exec "$ip" "cp -n /etc/hosts /etc/hosts.bcm-bak 2>/dev/null; \
            sed -i '/#bcm-s3-vhost#/d' /etc/hosts; \
            if grep -q '# ANSIBLE MANAGED BLOCK' /etc/hosts; then \
                sed -i '/# ANSIBLE MANAGED BLOCK/i ${VIP} ${vh} ${bvh} #bcm-s3-vhost#' /etc/hosts; \
            else echo '${VIP} ${vh} ${bvh} #bcm-s3-vhost#' >> /etc/hosts; fi"
        log_ok "  $name: ${vh}, ${bvh} → ${VIP}"
    done
}

# ──── Web-ноды за TLS-терминатором (HAProxy) ─────────────────────────────────
# Серт на web-ноды НЕ ставится: TLS терминируется на LB, бэкенды ходят по :80.
# Чтобы Bitrix корректно жил за терминатором, на каждой web-ноде нужно:
#  1) HTTPS=on для PHP — уже работает из коробки: HAProxy шлёт X-Forwarded-Proto,
#     nginx пропускает заголовок насквозь, Apache bitrix-env имеет
#     `SetEnvIf X-Forwarded-Proto https HTTPS=on` (проверено вживую на web01);
#  2) порт в Host-заголовке к Apache: штатный vhost шлёт жёстко `Host $host:80` →
#     при https-схеме Bitrix строил бы ссылки https://домен:80. Фикс: map по
#     X-Forwarded-Proto (80/443) + sed vhost'а на $host:$bcm_backend_port —
#     повторяет логику самого bitrix-env (его ssl-vhost шлёт $host:443).
#     ⚠️ Дублировать proxy_set_header Host из site_settings НЕЛЬЗЯ — nginx шлёт
#     ОБА заголовка → Apache 400 (проверено вживую), поэтому именно sed.
#  3) реальный IP клиента: real_ip из X-Forwarded-For, доверяем только LB-нодам
#     (иначе во всех логах/защите Bitrix будет IP балансера).
# map и real_ip — в /etc/nginx/bx/settings/ (включается в http{}, апдейтами
# bitrix-env не затирается); sed vhost'а ansible может откатить при обновлении
# bitrix-env — шаг идемпотентен, повторный install.sh вернёт правку.
configure_web_behind_lb() {
    log_info "Настройка web-нод за TLS-терминатором (X-Forwarded-Proto/Host/real_ip)..."

    # nginx-сниппет один для всех web-нод
    local local_snippet="/tmp/zz-bcm-lb.conf"
    {
        cat <<'NGX'
# Сгенерировано BCM install.sh — web-нода за HAProxy (TLS терминируется на LB).
# НЕ редактировать вручную.

# Порт для Host-заголовка к Apache: 443, если клиент пришёл на LB по https
# (используется в bx/site_enabled/*.conf: proxy_set_header Host $host:$bcm_backend_port).
map $http_x_forwarded_proto $bcm_backend_port {
    default 80;
    https   443;
}

# Реальный IP клиента из X-Forwarded-For — доверяем только LB-нодам.
real_ip_header X-Forwarded-For;
real_ip_recursive on;
NGX
        local lb_name
        for lb_name in "${LB_NODES[@]}"; do
            echo "set_real_ip_from ${LB_IPS[$lb_name]};"
        done
    } > "$local_snippet"

    local name
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] $name ($ip): zz-bcm-lb.conf + Host \$host:\$bcm_backend_port в vhost"
            continue
        fi

        bcm_ssh_copy_file "$local_snippet" "$ip" "/etc/nginx/bx/settings/zz-bcm-lb.conf"

        # vhost'ы (кроме ssl.*): $host:80 → $host:$bcm_backend_port (идемпотентно).
        # Бэкап единожды (.bcm-bak-lb). При провале nginx -t — полный откат.
        bcm_ssh_exec_logged "$name" "$ip" "
            for f in /etc/nginx/bx/site_enabled/*.conf; do
                case \"\$(basename \"\$f\")\" in ssl.*) continue ;; esac
                grep -q 'proxy_set_header Host \$host:80;' \"\$f\" || continue
                cp -n \"\$f\" \"\$f.bcm-bak-lb\"
                sed -i 's|proxy_set_header Host \$host:80;|proxy_set_header Host \$host:\$bcm_backend_port;|' \"\$f\"
            done
            if nginx -t 2>/dev/null; then
                systemctl reload nginx
            else
                rm -f /etc/nginx/bx/settings/zz-bcm-lb.conf
                for f in /etc/nginx/bx/site_enabled/*.conf.bcm-bak-lb; do
                    [ -f \"\$f\" ] && cp \"\$f\" \"\${f%.bcm-bak-lb}\"
                done
                nginx -t && systemctl reload nginx
                echo 'BCM_NGINX_ROLLBACK'
            fi"
        log_ok "  $name: nginx настроен для работы за LB."
    done
    rm -f "$local_snippet"
}

# ──── Продление SSL-сертификата (Let's Encrypt) на LB ────────────────────────
# env для ssl_certs.sh + systemd-timer на ОБА LB; реально продлевает только
# держатель VIP (защита от двойного выпуска), состояние acme синкается на peer
# при каждом деплое серта — смена VRRP-master продлению не мешает.
# Сам ВЫПУСК при install НЕ запускается (DNS домена может ещё не указывать на
# VIP) — выпуск из BCM: меню 12 → «Выпустить сертификат Let's Encrypt».
# Вызывать ПОСЛЕ deploy_bcm (нужен /opt/bcm/bin/lib/ssl_certs.sh на LB).
configure_ssl_renew() {
    log_info "Настройка авто-продления SSL (bcm-cert-renew) на LB-нодах..."

    local lb_ips_list="" name
    for name in "${LB_NODES[@]}"; do
        lb_ips_list="${lb_ips_list}${LB_IPS[$name]} "
    done
    lb_ips_list="${lb_ips_list% }"

    # web-ноды тоже получают серт (локальный nginx :443): self-check'и Bitrix идут
    # на ssl://домен:443 → 127.0.0.1 (hosts-фикс) и падают на self-signed заглушке.
    local web_ips_list=""
    for name in "${WEB_NODES[@]}"; do
        web_ips_list="${web_ips_list}${WEB_IPS[$name]} "
    done
    web_ips_list="${web_ips_list% }"

    local local_service="/tmp/bcm-cert-renew.service"
    cat > "$local_service" <<'UNIT'
[Unit]
Description=BCM: renew cluster SSL certificate (Let's Encrypt)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/bcm/bin/lib/ssl_certs.sh --renew
UNIT

    local local_timer="/tmp/bcm-cert-renew.timer"
    cat > "$local_timer" <<'UNIT'
[Unit]
Description=BCM: daily SSL certificate renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    for name in "${LB_NODES[@]}"; do
        local ip="${LB_IPS[$name]}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] $name ($ip): ssl-renew.env + bcm-cert-renew.timer"
            continue
        fi

        local local_env="/tmp/ssl-renew-${name}.env"
        cat > "$local_env" <<ENV
# Сгенерировано install.sh — параметры ssl_certs.sh
SELF_NODE="${name}"
SELF_IP="${ip}"
LB_PEERS="${lb_ips_list}"
WEB_PEERS="${web_ips_list}"
DOMAIN="${PORTAL_DOMAIN}"
LE_EMAIL="${LE_EMAIL}"
VIP="${VIP}"
ACME_HTTP_PORT="${ACME_HTTP_PORT}"
ACME_CA="letsencrypt"
# Метод валидации LE: http (standalone через acme_backend) | dns_cf (Cloudflare).
# Токен CF задаётся из меню 12 → 3 (не в answers — секрет), тут только дефолты.
ACME_METHOD="http"
CF_Token=""
ENV

        bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /etc/bitrix-cluster /var/log/bcm"
        bcm_ssh_copy_file "$local_env" "$ip" "/etc/bitrix-cluster/ssl-renew.env"
        bcm_ssh_copy_file "$local_service" "$ip" "/etc/systemd/system/bcm-cert-renew.service"
        bcm_ssh_copy_file "$local_timer" "$ip" "/etc/systemd/system/bcm-cert-renew.timer"
        bcm_ssh_exec_logged "$name" "$ip" "chmod 600 /etc/bitrix-cluster/ssl-renew.env && \
            systemctl daemon-reload && systemctl enable --now bcm-cert-renew.timer"
        rm -f "$local_env"
        log_ok "  $name: таймер продления включён."
    done
    rm -f "$local_service" "$local_timer"
}

# ──── Резервное копирование (HA-aware, в MinIO кластера) ─────────────────────
# Бакет с versioning (история www, защита от rm -rf) + lifecycle (retention —
# средствами MinIO, не скриптами). Таймеры на ВСЕХ кандидатах, гейты по роли в
# момент запуска (Synced-реплика для БД, источник lsyncd для файлов) — см.
# bcm_backup.sh. Вызывать ПОСЛЕ deploy_bcm (нужен /opt/bcm/bin/lib/bcm_backup.sh).
configure_backup() {
    log_info "Настройка резервного копирования (бакет ${BACKUP_BUCKET}, retention ${BACKUP_RETENTION_DAYS}д)..."

    local s3_ep="https://${VIP}:9000"
    local s3_ak="${S3_ACCESS_KEY:-minioadmin}"
    local s3_sk="${S3_SECRET_KEY}"

    # 1. Бакет: versioning + lifecycle (на первой s3-ноде, mc там уже есть)
    local s3_01_name="${S3_NODES[0]}"
    local s3_01_ip="${S3_IPS[$s3_01_name]}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY RUN] бакет ${BACKUP_BUCKET}: mb + versioning + ilm; env+таймеры на ноды"
        return 0
    fi
    bcm_ssh_exec_logged "$s3_01_name" "$s3_01_ip" "mc mb --ignore-existing site1/${BACKUP_BUCKET} && \
        mc version enable site1/${BACKUP_BUCKET}"
    # История версий www/ и срок жизни db/ и conf/ — чистится сам MinIO
    bcm_ssh_exec_logged "$s3_01_name" "$s3_01_ip" "mc ilm rule add --noncurrent-expire-days ${BACKUP_RETENTION_DAYS} site1/${BACKUP_BUCKET} 2>/dev/null; \
        mc ilm rule add --prefix 'db/' --expire-days ${BACKUP_RETENTION_DAYS} site1/${BACKUP_BUCKET} 2>/dev/null; \
        mc ilm rule add --prefix 'conf/' --expire-days ${BACKUP_RETENTION_DAYS} site1/${BACKUP_BUCKET} 2>/dev/null; true"
    # Versioning на бакете загрузок: site replication — это HA, а НЕ защита от
    # удаления/перезаписи; история версий + lifecycle закрывают эту дыру.
    bcm_ssh_exec_logged "$s3_01_name" "$s3_01_ip" "mc version enable site1/${S3_UPLOAD_BUCKET} && \
        mc ilm rule add --noncurrent-expire-days ${BACKUP_RETENTION_DAYS} site1/${S3_UPLOAD_BUCKET} 2>/dev/null; true"

    # 2. Порядок PXC-кандидатов: реплики (по возрастанию IP) раньше writer'а
    local db_candidates=() name
    for name in $(for n in "${PXC_NODES[@]}"; do [[ "$n" != "$PXC_WRITER" ]] && echo "${PXC_IPS[$n]} $n"; done | sort | awk '{print $2}'); do
        db_candidates+=("$name")
    done
    db_candidates+=("$PXC_WRITER")

    # 3. env + юниты на ноды (роль определяет таймеры)
    local local_svc="/tmp/bcm-backup.service" local_tmr="/tmp/bcm-backup.timer"
    local layer nodes_var
    for layer in lb web pxc s3; do
        case "$layer" in
            lb)  nodes_var=("${LB_NODES[@]}") ;;
            web) nodes_var=("${WEB_NODES[@]}") ;;
            pxc) nodes_var=("${PXC_NODES[@]}") ;;
            s3)  nodes_var=("${S3_NODES[@]}") ;;
        esac
        for name in "${nodes_var[@]}"; do
            local ip=""
            case "$layer" in
                lb)  ip="${LB_IPS[$name]}" ;;
                web) ip="${WEB_IPS[$name]}" ;;
                pxc) ip="${PXC_IPS[$name]}" ;;
                s3)  ip="${S3_IPS[$name]}" ;;
            esac

            # mc нужен всем (на s3 уже есть); ⚠️ /usr/local/bin/mc — на web
            # /usr/bin/mc занят Midnight Commander'ом из bitrix-env!
            bcm_ssh_exec_logged "$name" "$ip" "[ -x /usr/local/bin/mc ] || (wget -qO /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc && chmod +x /usr/local/bin/mc) || true"
            # Доверенный CA серта MinIO (S3 теперь по https) — чтобы mc верифицировал
            # S3_ENDPOINT без --insecure; на web заодно чинит php-curl облачной отдачи.
            _bcm_install_s3_ca "$ip"
            # xtrabackup — только PXC
            if [[ "$layer" == "pxc" ]]; then
                bcm_ssh_exec_logged "$name" "$ip" "rpm -q percona-xtrabackup-84 >/dev/null 2>&1 || (percona-release enable pxb-84-lts release; dnf install -y percona-xtrabackup-84)"
            fi

            # ранг PXC-кандидата
            local db_rank=0 i
            for i in "${!db_candidates[@]}"; do
                [[ "${db_candidates[$i]}" == "$name" ]] && db_rank="$i"
            done

            # ⚠️ Значения — в ОДИНАРНЫХ кавычках: секрет MinIO может содержать
            # '$' и т.п. — в двойных кавычках source раскрыл бы его как
            # переменную (ловили вживую: «OfTX: unbound variable»).
            local s3_ak_esc="${s3_ak//\'/\'\\\'\'}"
            local s3_sk_esc="${s3_sk//\'/\'\\\'\'}"
            local local_env="/tmp/backup-${name}.env"
            cat > "$local_env" <<ENV
# Сгенерировано install.sh — параметры bcm_backup.sh
SELF_NODE='${name}'
ROLE='${layer}'
S3_ENDPOINT='${s3_ep}'
S3_ACCESS='${s3_ak_esc}'
S3_SECRET='${s3_sk_esc}'
BUCKET='${BACKUP_BUCKET}'
ENC_KEY='${BACKUP_ENC_KEY}'
RETENTION_DAYS='${BACKUP_RETENTION_DAYS}'
DB_RANK='${db_rank}'
DB_STAGGER='180'
SITE_PATH='/home/bitrix/www'
MC_BIN='/usr/local/bin/mc'
LOG_FILE='/var/log/bcm/backup.log'
ENV
            bcm_ssh_exec_logged "$name" "$ip" "mkdir -p /etc/bitrix-cluster /var/log/bcm"
            bcm_ssh_copy_file "$local_env" "$ip" "/etc/bitrix-cluster/backup.env"
            bcm_ssh_exec "$ip" "chmod 600 /etc/bitrix-cluster/backup.env"
            rm -f "$local_env"

            # Таймеры: conf — все ноды; db — pxc; files — web. Окна разнесены,
            # Persistent=true догоняет пропущенное после простоя.
            local types=("conf:02:10") t
            [[ "$layer" == "pxc" ]] && types+=("db:03:10")
            [[ "$layer" == "web" ]] && types+=("files:04:30")
            for t in "${types[@]}"; do
                local typ="${t%%:*}" at="${t#*:}"
                cat > "$local_svc" <<UNIT
[Unit]
Description=BCM backup: ${typ}
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/bcm/bin/lib/bcm_backup.sh --${typ}
UNIT
                cat > "$local_tmr" <<UNIT
[Unit]
Description=BCM backup timer: ${typ}

[Timer]
OnCalendar=*-*-* ${at}:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
UNIT
                bcm_ssh_copy_file "$local_svc" "$ip" "/etc/systemd/system/bcm-backup-${typ}.service"
                bcm_ssh_copy_file "$local_tmr" "$ip" "/etc/systemd/system/bcm-backup-${typ}.timer"
            done
            bcm_ssh_exec_logged "$name" "$ip" "systemctl daemon-reload && for u in /etc/systemd/system/bcm-backup-*.timer; do systemctl enable --now \"\$(basename \"\$u\")\"; done"
            log_ok "  $name (${layer}): бэкап настроен (rank=${db_rank})."
        done
    done
    rm -f "$local_svc" "$local_tmr"
    log_ok "Резервное копирование настроено. Offsite-копию настройте отдельно (меню 13)."
}

# Проверить, является ли локальный хост частью кластера
is_local_node_part_of_cluster() {
    local local_ips
    local_ips=$(hostname -I 2>/dev/null || echo "")
    for ip in $local_ips; do
        for node in "${!LB_IPS[@]}"; do
            [[ "${LB_IPS[$node]}" == "$ip" ]] && return 0
        done
        for node in "${!WEB_IPS[@]}"; do
            [[ "${WEB_IPS[$node]}" == "$ip" ]] && return 0
        done
        for node in "${!PXC_IPS[@]}"; do
            [[ "${PXC_IPS[$node]}" == "$ip" ]] && return 0
        done
        for node in "${!S3_IPS[@]}"; do
            [[ "${S3_IPS[$node]}" == "$ip" ]] && return 0
        done
    done
    return 1
}

# ──── Финальная фиксация состояния web-нод ───────────────────────────────────
# ⚠️ Выполняется ПОСЛЕДНИМ шагом — после того, как осела фоновая активность
# bitrix-env/ansible. Идемпотентно приводит web-ноды к нужному финальному виду:
#   1) Локальный mysqld выключен (БД живёт в PXC через ProxySQL). configure_portal_db
#      уже гасит его, но bitrix-env-ansible (особенно асинхронный хвост push на
#      host_not_in_pool — ловили на web02) повторно ВКЛЮЧАЕТ и СТАРТУЕТ mysqld
#      ПОСЛЕ него → он падает на занятом ProxySQL'ем 127.0.0.1:3306 (failed+enabled).
#      Переприменяем disable/stop + reset-failed в самом конце, затем restart
#      proxysql (interfaces биндятся только при старте → так 3306 гарантированно
#      за ProxySQL для management-проверок bitrix-env).
#   2) HA-Cron: переприменяем сохранённую VRRP-роль (cron_notify.sh assert) — тот
#      же ansible-хвост мог перезаписать /etc/crontab свежей раскомментированной
#      строкой cron_events на BACKUP-ноде. Роль уже записана notify'ем (cron_notify.sh
#      раскатан до старта keepalived в configure_services), поэтому assert сходится
#      сразу, не дожидаясь 10-минутного guard'а.
finalize_web_nodes() {
    log_info "Финальная фиксация состояния web-нод (локальный mysqld выключен, HA-Cron роль)..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY RUN] disable+stop+reset-failed mysqld, restart proxysql, cron_notify.sh assert на web-нодах"
        return 0
    fi
    for name in "${WEB_NODES[@]}"; do
        local ip="${WEB_IPS[$name]}"
        bcm_ssh_exec "$ip" "systemctl disable --now mysqld 2>/dev/null || systemctl disable --now mariadb 2>/dev/null || true; systemctl reset-failed mysqld 2>/dev/null || true" >/dev/null 2>&1
        bcm_ssh_exec "$ip" "systemctl restart proxysql 2>/dev/null || true" >/dev/null 2>&1
        bcm_ssh_exec "$ip" "[ -x /opt/bcm/bin/lib/cron_notify.sh ] && /opt/bcm/bin/lib/cron_notify.sh assert 2>/dev/null || true" >/dev/null 2>&1
        log_ok "  $name: локальный mysqld выключен, ProxySQL перезапущен, HA-Cron роль переприменена."
    done
}

# ──── Главная функция ────────────────────────────────────────────────────────
main() {
    if [[ -n "$ANSWERS_FILE" ]]; then
        load_answers_file
    else
        collect_topology_interactive
    fi

    # Валидация
    if [[ ${#LB_NODES[@]} -lt 2 ]]; then
        log_error "Количество LB-нод должно быть не менее 2."
        exit 1
    fi
    if [[ ${#WEB_NODES[@]} -lt 2 ]]; then
        log_error "Количество WEB-нод должно быть не менее 2."
        exit 1
    fi
    if [[ ${#PXC_NODES[@]} -lt 3 ]]; then
        log_error "Количество PXC-нод должно быть не менее 3."
        exit 1
    fi
    if [[ $(( ${#PXC_NODES[@]} % 2 )) -eq 0 ]]; then
        log_error "Количество PXC-нод должно быть нечетным (для кворума)."
        exit 1
    fi
    if [[ ${#S3_NODES[@]} -lt 2 ]]; then
        log_error "Количество S3-нод должно быть не менее 2."
        exit 1
    fi

    validate_secrets

    validate_connectivity

    # Защита от отката инструментария BCM (до любых изменений на кластере).
    check_bcm_no_downgrade

    # Ключ шифрования conf-бэкапов: при повторном install сохраняем существующий
    # (новый ключ сделал бы старые архивы нерасшифровываемыми).
    if [[ -z "$BACKUP_ENC_KEY" ]]; then
        BACKUP_ENC_KEY=$(sed -n 's/^enc_key = //p' /etc/bitrix-cluster/cluster.conf 2>/dev/null | head -1)
    fi
    [[ -z "$BACKUP_ENC_KEY" ]] && BACKUP_ENC_KEY=$(_bcm_rand_hex 16)

    # Создаём временную директорию для конфигурации локально
    mkdir -p "$BCM_CONF_DIR"
    chmod 700 "$BCM_CONF_DIR"

    write_conf

    configure_local_logrotate

    deploy_ssh_keys

    install_packages

    configure_services

    configure_portal_hosts
    configure_s3_vhost_hosts

    configure_web_behind_lb

    configure_pxc_autorecover

    configure_push_service

    configure_session_redis

    configure_portal_db

    deploy_bcm

    configure_ssl_renew

    configure_backup

    configure_lsyncd_role

    configure_push_redis

    configure_cache_redis

    configure_remote_logging

    # Финальная фиксация web-нод — ПОСЛЕДНИМ шагом (после оседания bitrix-env-ansible)
    finalize_web_nodes

    # Создать маркер установки и перенести конфигурацию локально, если хост в кластере
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if is_local_node_part_of_cluster; then
            log_info "Копирование конфигурации в системный каталог /etc/bitrix-cluster (так как локальный хост входит в кластер)..."
            mkdir -p /etc/bitrix-cluster
            chmod 700 /etc/bitrix-cluster
            cp "$BCM_CONF_FILE" "/etc/bitrix-cluster/cluster.conf"
            chmod 600 "/etc/bitrix-cluster/cluster.conf"
            cp "$BCM_SSH_KEY" "/etc/bitrix-cluster/cluster_id_rsa"
            cp "${BCM_SSH_KEY}.pub" "/etc/bitrix-cluster/cluster_id_rsa.pub"
            chmod 600 "/etc/bitrix-cluster/cluster_id_rsa"
            chmod 644 "/etc/bitrix-cluster/cluster_id_rsa.pub"
            touch /etc/bitrix-cluster/.cluster_installed
        fi
        # Удаляем локальные временные файлы с машины управления
        rm -rf "$BCM_CONF_DIR"
    fi

    log_ok "Установка кластера Bitrix завершена успешно!"
}

main "$@"
