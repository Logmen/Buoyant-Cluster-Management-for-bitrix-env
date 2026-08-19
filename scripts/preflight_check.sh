#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155
# =============================================================================
# preflight_check.sh — предстартовые проверки кластера ПЕРЕД запуском install.sh.
#
# Читает install_answers.conf (тем же литеральным KEY=VALUE-парсером, что и
# install.sh — без source) и проверяет то, что установщик считает данностью:
# топологию и адресацию, доступность узлов и метод входа root, ресурсы и ОС,
# занятость нужных портов, состояние firewalld, синхронизацию времени, DNS,
# доступ к внешним репозиториям и — по флагу --port-probe — реальную
# проходимость TCP между узлами.
#
# Ничего не меняет: только чтение (единственное исключение — --port-probe,
# который на несколько секунд поднимает временный слушатель на СВОБОДНОМ порту).
#
#   bash scripts/preflight_check.sh -f install_answers.conf
#   bash scripts/preflight_check.sh --port-probe --deep
#
# Код возврата: 0 — критичных проблем нет (предупреждения возможны), 1 — есть.
# =============================================================================
set -uo pipefail   # НЕ -e: прогоняем ВСЕ проверки и агрегируем результат

# ──── Вывод ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'
    C_B=$'\033[0;36m'; C_N=$'\033[0m'; C_BOLD=$'\033[1m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_N=""; C_BOLD=""
fi

FAILED=0; WARNED=0; PASSED=0
section() { printf '\n%s══ %s ══%s\n' "$C_BOLD" "$1" "$C_N"; }
pass()    { PASSED=$((PASSED+1)); printf '  %s✓%s %s\n' "$C_G" "$C_N" "$1"; }
warn()    { WARNED=$((WARNED+1)); printf '  %s⚠%s %s\n' "$C_Y" "$C_N" "$1"; }
fail()    { FAILED=$((FAILED+1)); printf '  %s✗%s %s\n' "$C_R" "$C_N" "$1"; }
info()    { printf '  %s·%s %s\n' "$C_B" "$C_N" "$1"; }

# ──── Аргументы ──────────────────────────────────────────────────────────────
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSWERS_FILE=""
LOCAL_ONLY=0
PORT_PROBE=0
DEEP=0
SSH_KEY=""

usage() {
    cat <<'USAGE'
preflight_check.sh — предстартовые проверки кластера BCM по файлу ответов.

  -f, --answers-file FILE   файл ответов (по умолчанию install_answers.conf
                            в текущем каталоге или в корне проекта)
      --local-only          только локальные проверки (без SSH на узлы)
      --port-probe          активная проверка проходимости TCP между узлами
                            (на приёмнике на ~8 с поднимается слушатель на
                            свободном порту, с источника делается коннект)
      --deep                дополнительно: dnf makecache на каждом узле (медленно)
      --ssh-key FILE        приватный ключ для входа root (иначе: агент/ключ по
                            умолчанию, при неудаче — ROOT_PASSWORD через sshpass)
  -h, --help                эта справка

Коды возврата: 0 — критичных проблем нет, 1 — есть (см. итоговую сводку).
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--answers-file) ANSWERS_FILE="${2:-}"; shift 2 ;;
        --local-only)      LOCAL_ONLY=1; shift ;;
        --port-probe)      PORT_PROBE=1; shift ;;
        --deep)            DEEP=1; shift ;;
        --ssh-key)         SSH_KEY="${2:-}"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$ANSWERS_FILE" ]]; then
    for c in "./install_answers.conf" "${SELF_DIR}/../install_answers.conf"; do
        [[ -f "$c" ]] && { ANSWERS_FILE="$c"; break; }
    done
fi
[[ -z "$ANSWERS_FILE" ]] && { echo "Файл ответов не найден: укажите -f FILE" >&2; exit 2; }
[[ -f "$ANSWERS_FILE" ]] || { echo "Файл ответов не найден: $ANSWERS_FILE" >&2; exit 2; }

# ──── Разбор файла ответов (литерально, как install.sh — без source) ─────────
declare -A LB_IPS=() WEB_IPS=() PXC_IPS=() S3_IPS=() S3_DATA_DISKS=()
declare -a LB_NODES=() WEB_NODES=() PXC_NODES=() S3_NODES=()

load_answers() {
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"; key="${key//[[:space:]]/}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        val="${line#*=}"
        val="${val#"${val%%[![:space:]]*}"}"
        if [[ "$val" == \"* ]]; then
            val="${val#\"}"; val="${val%%\"*}"
        elif [[ "$val" == \'* ]]; then
            val="${val#\'}"; val="${val%%\'*}"
        else
            val="${val%%#*}"; val="${val%"${val##*[![:space:]]}"}"
        fi
        printf -v "$key" '%s' "$val"
    done < "$ANSWERS_FILE"

    local IFS=','
    read -ra LB_NODES  <<< "${LB_NODES:-}"
    read -ra WEB_NODES <<< "${WEB_NODES:-}"
    read -ra PXC_NODES <<< "${PXC_NODES:-}"
    read -ra S3_NODES  <<< "${S3_NODES:-}"
    local pair
    for pair in ${LB_IPS_LIST:-};  do LB_IPS["${pair%%:*}"]="${pair#*:}";  done
    for pair in ${WEB_IPS_LIST:-}; do WEB_IPS["${pair%%:*}"]="${pair#*:}"; done
    for pair in ${PXC_IPS_LIST:-}; do PXC_IPS["${pair%%:*}"]="${pair#*:}"; done
    for pair in ${S3_IPS_LIST:-};  do S3_IPS["${pair%%:*}"]="${pair#*:}";  done
    for pair in ${S3_DATA_DISKS_LIST:-}; do S3_DATA_DISKS["${pair%%:*}"]="${pair#*:}"; done
}
load_answers

# Пустой элемент из "" в read -ra — убрать (S3_NODES="" даёт массив из одной пустой строки).
_compact() { local -n _a="$1"; local -a out=(); local x
             for x in "${_a[@]}"; do [[ -n "$x" ]] && out+=("$x"); done; _a=("${out[@]}"); }
_compact LB_NODES; _compact WEB_NODES; _compact PXC_NODES; _compact S3_NODES

S3_ENABLED=0; [[ ${#S3_NODES[@]} -gt 0 ]] && S3_ENABLED=1

# Единый реестр узлов: имя → IP, имя → роль (порядок обхода — ORDER).
declare -A NODE_IP=() NODE_ROLE=() NODE_AUTH=()
declare -a ORDER=()
_register() {
    local role="$1"; shift
    local -n _names="$1"; local -n _ips="$2"
    local n
    for n in "${_names[@]}"; do
        NODE_IP["$n"]="${_ips[$n]:-}"; NODE_ROLE["$n"]="$role"; ORDER+=("$n")
    done
}
_register lb  LB_NODES  LB_IPS
_register web WEB_NODES WEB_IPS
_register pxc PXC_NODES PXC_IPS
_register s3  S3_NODES  S3_IPS

valid_ip() {
    local ip="${1:-}" o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'; for o in $ip; do (( o <= 255 )) || return 1; done
    return 0
}

# Порты, которые займут сервисы соответствующего слоя (для проверки занятости).
role_ports() {
    case "$1" in
        lb)  echo "80 443 ${PROXYSQL_PORT:-6033} 8402$( ((S3_ENABLED)) && echo " ${S3_PORT:-9000}")" ;;
        web) echo "80 443 3306 ${PROXYSQL_ADMIN_PORT:-6032} ${PROXYSQL_PORT:-6033} ${SESSION_REDIS_PORT:-6380} ${PUSH_REDIS_PORT:-6381} ${CACHE_REDIS_PORT:-6382} 8010 8895 1337" ;;
        pxc) echo "3306 4567 4568 4444" ;;
        s3)  echo "${S3_PORT:-9000} 9001" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
section "1. Управляющая машина"
# ──────────────────────────────────────────────────────────────────────────────
for t in ssh scp rsync tar gzip awk sed sort; do
    command -v "$t" >/dev/null 2>&1 || fail "нет утилиты '$t' (нужна install.sh/BCM)"
done
command -v sshpass >/dev/null 2>&1 \
    && pass "sshpass есть (первичная раскатка SSH-ключа по паролю root)" \
    || fail "нет sshpass — install.sh обязателен к нему для раскатки ключа (dnf install sshpass)"
command -v gpg >/dev/null 2>&1 \
    && pass "gpg есть (проверка подписи релиза)" \
    || warn "нет gpg — не проверить подпись релизного tarball'а"
command -v curl >/dev/null 2>&1 || warn "нет curl (скачивание релиза, проверки доступности)"
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] \
    && pass "bash ${BASH_VERSION%%(*} (нужен >= 4: ассоциативные массивы)" \
    || fail "bash ${BASH_VERSION%%(*} слишком старый — нужен >= 4"

perm="$(stat -c '%a' "$ANSWERS_FILE" 2>/dev/null || echo '?')"
if [[ "$perm" =~ ^[0-7]00$ ]]; then
    pass "права на файл ответов $perm (пароли не читаются посторонними)"
else
    warn "права на файл ответов $perm — в нём пароли открытым текстом (chmod 600 $ANSWERS_FILE)"
fi

# ──────────────────────────────────────────────────────────────────────────────
section "2. Полнота и осмысленность ответов"
# ──────────────────────────────────────────────────────────────────────────────
ans_fail=$FAILED
for k in VIP LB_NODES LB_IPS_LIST WEB_NODES WEB_IPS_LIST PXC_NODES PXC_IPS_LIST \
         PXC_WRITER PROXYSQL_PORT PROXYSQL_ADMIN_PORT PROXYSQL_ADMIN_PASS \
         PROXYSQL_MONITOR_PASS BITRIX_DB_USER BITRIX_DB_PASS WEB_VRID ROOT_PASSWORD; do
    [[ -n "${!k:-}" ]] || fail "не задан обязательный параметр $k"
done
for k in PROXYSQL_ADMIN_PASS PROXYSQL_MONITOR_PASS BITRIX_DB_PASS ROOT_PASSWORD S3_SECRET_KEY; do
    v="${!k:-}"
    [[ -n "$v" && "$v" == CHANGE_ME* ]] && fail "$k остался плейсхолдером из example — задайте реальное значение"
done
# Пароли, ломающие литеральный парсер (одинарная кавычка внутри '...') и SQL-вставки.
for k in PROXYSQL_ADMIN_PASS PROXYSQL_MONITOR_PASS BITRIX_DB_PASS ROOT_PASSWORD S3_SECRET_KEY; do
    v="${!k:-}"
    [[ "$v" == *"'"* ]] && warn "$k содержит одинарную кавычку — парсер ответов и SQL-вставки с ней несовместимы"
done
[[ ${#PROXYSQL_ADMIN_PASS} -lt 12 || ${#BITRIX_DB_PASS} -lt 12 ]] 2>/dev/null \
    && warn "пароли БД/ProxySQL короче 12 символов"
(( FAILED == ans_fail )) && pass "обязательные параметры заданы и не похожи на плейсхолдеры"

# ──────────────────────────────────────────────────────────────────────────────
section "3. Топология слоёв"
# ──────────────────────────────────────────────────────────────────────────────
(( ${#LB_NODES[@]}  >= 2 )) && pass "LB: ${#LB_NODES[@]} узла (нужно >= 2)"  || fail "LB: ${#LB_NODES[@]} — нужно минимум 2 (HAProxy+VIP без резерва не отказоустойчив)"
(( ${#WEB_NODES[@]} >= 2 )) && pass "WEB: ${#WEB_NODES[@]} узла (нужно >= 2)" || fail "WEB: ${#WEB_NODES[@]} — нужно минимум 2"
if (( ${#PXC_NODES[@]} >= 3 && ${#PXC_NODES[@]} % 2 == 1 )); then
    pass "PXC: ${#PXC_NODES[@]} узла (>= 3 и нечётное — кворум Galera)"
else
    fail "PXC: ${#PXC_NODES[@]} — нужно >= 3 И нечётное число (кворум Galera)"
fi
if (( S3_ENABLED == 0 )); then
    warn "слой S3 не задан: /upload остаётся на дисках web-нод (зеркало lsyncd, меню 6→10), бэкапы в S3 не настраиваются"
elif (( ${#S3_NODES[@]} >= 2 )); then
    pass "S3: ${#S3_NODES[@]} узла (>= 2)"
else
    fail "S3: ровно 1 узел недопустим — либо 0 (слой не разворачивается), либо >= 2"
fi

writer_ok=0
for n in "${PXC_NODES[@]}"; do [[ "$n" == "${PXC_WRITER:-}" ]] && writer_ok=1; done
(( writer_ok )) && pass "PXC_WRITER=${PXC_WRITER:-} входит в PXC_NODES" \
                || fail "PXC_WRITER='${PXC_WRITER:-}' отсутствует в PXC_NODES"

# ──────────────────────────────────────────────────────────────────────────────
section "4. Адресация: IP, VIP, VRID, порты"
# ──────────────────────────────────────────────────────────────────────────────
declare -A SEEN_IP=()
addr_ok=1
for n in "${ORDER[@]}"; do
    ip="${NODE_IP[$n]:-}"
    if [[ -z "$ip" ]]; then
        fail "для узла '$n' нет IP в соответствующем *_IPS_LIST"; addr_ok=0; continue
    fi
    valid_ip "$ip" || { fail "узел '$n': некорректный IP '$ip'"; addr_ok=0; continue; }
    [[ -n "${SEEN_IP[$ip]:-}" ]] && { fail "IP $ip назначен двум узлам: ${SEEN_IP[$ip]} и $n"; addr_ok=0; }
    SEEN_IP["$ip"]="$n"
done
(( addr_ok )) && pass "IP всех ${#ORDER[@]} узлов заданы, корректны и уникальны"

declare -a VIPS=()
for v in VIP SESSION_VIP PUSH_REDIS_VIP CACHE_REDIS_VIP; do
    [[ -n "${!v:-}" ]] || { [[ "$v" == "VIP" ]] && fail "не задан кластерный VIP" || warn "$v не задан — соответствующий HA-компонент настроен не будет"; continue; }
    if ! valid_ip "${!v}"; then fail "$v='${!v}' — некорректный IP"; continue; fi
    [[ -n "${SEEN_IP[${!v}]:-}" ]] && fail "$v=${!v} совпадает с адресом узла ${SEEN_IP[${!v}]}"
    VIPS+=("${!v}")
done
_dupvip=()
(( ${#VIPS[@]} )) && mapfile -t _dupvip < <(printf '%s\n' "${VIPS[@]}" | sort | uniq -d)
(( ${#_dupvip[@]} )) && fail "VIP-адреса дублируются: ${_dupvip[*]}" \
                     || pass "VIP-адреса уникальны и не пересекаются с узлами (${#VIPS[@]} шт.)"

declare -A SEEN_VRID=()
for v in WEB_VRID SESSION_VRID PUSH_VRID CACHE_VRID; do
    r="${!v:-}"; [[ -z "$r" ]] && continue
    if [[ ! "$r" =~ ^[0-9]+$ ]] || (( r < 1 || r > 255 )); then fail "$v='$r' вне диапазона 1..255"; continue; fi
    [[ "$r" == "60" ]] && warn "$v=60 — VRID 60 зарезервирован под TRANSFORMER_VIP (меню 14)"
    [[ -n "${SEEN_VRID[$r]:-}" ]] && fail "VRID $r занят дважды: ${SEEN_VRID[$r]} и $v"
    SEEN_VRID["$r"]="$v"
done
(( ${#SEEN_VRID[@]} )) && pass "VRID keepalived уникальны: $(printf '%s ' "${!SEEN_VRID[@]}")"

declare -A SEEN_PORT=()
port_fail=$FAILED
for p in PROXYSQL_PORT PROXYSQL_ADMIN_PORT SESSION_REDIS_PORT PUSH_REDIS_PORT CACHE_REDIS_PORT S3_PORT; do
    v="${!p:-}"; [[ -z "$v" ]] && continue
    if [[ ! "$v" =~ ^[0-9]+$ ]] || (( v < 1 || v > 65535 )); then fail "$p='$v' — не порт"; continue; fi
    [[ -n "${SEEN_PORT[$v]:-}" ]] && fail "порт $v назначен дважды: ${SEEN_PORT[$v]} и $p"
    SEEN_PORT["$v"]="$p"
done
(( FAILED == port_fail )) && pass "порты сервисов заданы корректно и не конфликтуют между собой"

# Подсеть: VRRP требует общего L2-сегмента. Здесь — эвристика по /24; точная
# проверка по реальной маске интерфейса идёт ниже, на узлах.
_net24() { echo "${1%.*}"; }
base24="$(_net24 "${NODE_IP[${ORDER[0]}]}")"
mixed=0
for n in "${ORDER[@]}"; do [[ "$(_net24 "${NODE_IP[$n]}")" != "$base24" ]] && mixed=1; done
for v in "${VIPS[@]}"; do [[ "$(_net24 "$v")" != "$base24" ]] && mixed=1; done
(( mixed )) && warn "узлы/VIP лежат в разных /24 — VRRP (keepalived) требует одного L2-сегмента; проверьте маски" \
            || pass "узлы и VIP в одной сети ${base24}.0/24 (требование VRRP)"

[[ -n "${PORTAL_DOMAIN:-}" ]] || warn "PORTAL_DOMAIN не задан — self-check'и Bitrix пойдут через LB (возможны 404 на «Проверке системы»)"
if (( S3_ENABLED )) && [[ -z "${S3_VHOST_DOMAIN:-}" ]]; then
    fail "слой S3 задан, но пуст S3_VHOST_DOMAIN — модуль «Облачные хранилища» ходит virtual-hosted-style (bucket.<домен>)"
fi

# ──────────────────────────────────────────────────────────────────────────────
section "5. DNS и свободность VIP"
# ──────────────────────────────────────────────────────────────────────────────
if [[ -n "${PORTAL_DOMAIN:-}" ]]; then
    resolved="$(getent ahostsv4 "$PORTAL_DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
    if [[ -z "$resolved" ]]; then
        warn "домен портала $PORTAL_DOMAIN не резолвится (до боевого запуска должен указывать на VIP ${VIP})"
    elif [[ "$resolved" == "${VIP}" ]]; then
        pass "домен портала $PORTAL_DOMAIN → $resolved (кластерный VIP)"
    else
        warn "домен портала $PORTAL_DOMAIN → $resolved, а кластерный VIP — ${VIP}"
    fi
fi
if (( S3_ENABLED )) && [[ -n "${S3_VHOST_DOMAIN:-}" ]]; then
    getent ahostsv4 "$S3_VHOST_DOMAIN" >/dev/null 2>&1 \
        && info "S3-домен $S3_VHOST_DOMAIN резолвится публично" \
        || info "S3-домен $S3_VHOST_DOMAIN публично не резолвится — на web-нодах он прописывается в /etc/hosts (это штатно)"
fi
declare -A _vip_seen=()
for v in "${VIPS[@]}"; do
    [[ -n "${_vip_seen[$v]:-}" ]] && continue
    _vip_seen["$v"]=1
    if ping -c1 -W1 "$v" >/dev/null 2>&1; then
        warn "VIP $v уже отвечает на ping — либо кластер уже развёрнут, либо адрес занят чужим хостом"
    else
        pass "VIP $v свободен (не отвечает)"
    fi
done

if (( LOCAL_ONLY )); then
    section "Итог (локальные проверки)"
    printf '  успешно: %d   предупреждений: %d   ошибок: %d\n' "$PASSED" "$WARNED" "$FAILED"
    exit $(( FAILED > 0 ? 1 : 0 ))
fi

# ──────────────────────────────────────────────────────────────────────────────
section "6. Доступность узлов и вход root"
# ──────────────────────────────────────────────────────────────────────────────
SSH_BASE=(-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
SSH_KEY_OPTS=(-o BatchMode=yes -o PreferredAuthentications=publickey)
SSH_PASS_OPTS=(-o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1)

# Ключ кластера, если узлы уже развёрнуты и парольный вход закрыт.
[[ -z "$SSH_KEY" && -r /etc/bitrix-cluster/cluster_id_rsa ]] && SSH_KEY=/etc/bitrix-cluster/cluster_id_rsa

# ⚠️ Порядок методов: каждая НЕУДАЧНАЯ попытка входа считается sshd и pam_faillock, и
# несколько прогонов подряд способны заблокировать root на узле. Поэтому пробуем сначала
# тот метод, который реально может сработать: ключ — только если он у нас вообще есть
# (задан --ssh-key, лежит ключ кластера, есть ключи в агенте или в ~/.ssh); иначе сразу пароль.
PREFER_KEY=0
[[ -n "$SSH_KEY" ]] && PREFER_KEY=1
ssh-add -l >/dev/null 2>&1 && PREFER_KEY=1
for _k in "${HOME}/.ssh/id_rsa" "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_ecdsa"; do
    [[ -r "$_k" ]] && PREFER_KEY=1
done
(( PREFER_KEY )) || info "своих SSH-ключей нет — вход проверяется сразу паролем root из файла ответов (лишние неудачные попытки блокируют root через pam_faillock)"

pf_ssh() {   # выполнить команду на узле; stdin не читается (-n)
    local ip="$1"; shift
    case "${NODE_AUTH_BY_IP[$ip]:-none}" in
        key)  timeout 30 ssh -n "${SSH_BASE[@]}" "${SSH_KEY_OPTS[@]}" ${SSH_KEY:+-i "$SSH_KEY"} "root@${ip}" "$@" 2>/dev/null ;;
        pass) timeout 30 sshpass -p "$ROOT_PASSWORD" ssh -n "${SSH_BASE[@]}" "${SSH_PASS_OPTS[@]}" "root@${ip}" "$@" 2>/dev/null ;;
        *)    return 1 ;;
    esac
}
pf_ssh_script() {   # выполнить скрипт со stdin: pf_ssh_script <ip> <args...> < script
    local ip="$1"; shift
    case "${NODE_AUTH_BY_IP[$ip]:-none}" in
        key)  timeout 120 ssh "${SSH_BASE[@]}" "${SSH_KEY_OPTS[@]}" ${SSH_KEY:+-i "$SSH_KEY"} "root@${ip}" "bash -s -- $*" 2>/dev/null ;;
        pass) timeout 120 sshpass -p "$ROOT_PASSWORD" ssh "${SSH_BASE[@]}" "${SSH_PASS_OPTS[@]}" "root@${ip}" "bash -s -- $*" 2>/dev/null ;;
        *)    return 1 ;;
    esac
}

declare -A NODE_AUTH_BY_IP=()
declare -a REACHABLE=()
auth_key=0; auth_pass=0
for n in "${ORDER[@]}"; do
    ip="${NODE_IP[$n]:-}"; [[ -z "$ip" ]] && continue
    if ! timeout 4 bash -c "exec 3<>/dev/tcp/${ip}/22" 2>/dev/null; then
        fail "$n ($ip): порт 22/tcp недоступен"
        continue
    fi
    _try_key()  { timeout 10 ssh -n "${SSH_BASE[@]}" "${SSH_KEY_OPTS[@]}" ${SSH_KEY:+-i "$SSH_KEY"} "root@${ip}" true 2>/dev/null; }
    _try_pass() { command -v sshpass >/dev/null 2>&1 && [[ -n "${ROOT_PASSWORD:-}" ]] \
                  && timeout 10 sshpass -p "$ROOT_PASSWORD" ssh -n "${SSH_BASE[@]}" "${SSH_PASS_OPTS[@]}" "root@${ip}" true 2>/dev/null; }
    if (( PREFER_KEY )) && _try_key; then
        NODE_AUTH_BY_IP["$ip"]="key"; NODE_AUTH["$n"]="key"; auth_key=$((auth_key+1))
        pass "$n ($ip): вход root по ключу"
    elif _try_pass; then
        NODE_AUTH_BY_IP["$ip"]="pass"; NODE_AUTH["$n"]="pass"; auth_pass=$((auth_pass+1))
        pass "$n ($ip): вход root по паролю из файла ответов"
    elif (( PREFER_KEY == 0 )) && _try_key; then
        NODE_AUTH_BY_IP["$ip"]="key"; NODE_AUTH["$n"]="key"; auth_key=$((auth_key+1))
        pass "$n ($ip): вход root по ключу"
    else
        reason="$(timeout 10 ssh -n "${SSH_BASE[@]}" -o BatchMode=yes "root@${ip}" true 2>&1 \
                  | grep -iE 'denied|closed|refused|locked|too many' | head -1)"
        fail "$n ($ip): root не входит ни по ключу, ни по паролю ROOT_PASSWORD${reason:+ — $reason}"
        fail_hint=1
        continue
    fi
    REACHABLE+=("$n")
done
(( ${fail_hint:-0} )) && info "если пароль верен и вход просто «отваливается» — проверьте на узле: faillock --user root (сброс: faillock --user root --reset) и sshd -T | grep -iE 'permitrootlogin|passwordauthentication'"
(( auth_pass == 0 && auth_key > 0 )) && warn "вход по паролю нигде не подтверждён: install.sh раскатывает ключ через sshpass — временно разрешите PasswordAuthentication/PermitRootLogin для root"

(( ${#REACHABLE[@]} )) || { section "Итог"; fail "ни один узел недоступен — дальнейшие проверки невозможны"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
section "7. Состояние узлов (ОС, ресурсы, порты, время, сеть)"
# ──────────────────────────────────────────────────────────────────────────────
FACTS_SCRIPT=$(cat <<'RSCRIPT'
role="${1:-}"; expip="${2:-}"; deep="${3:-0}"
emit() { printf '%s=%s\n' "$1" "$2"; }
# shellcheck disable=SC1091
osid=$( . /etc/os-release 2>/dev/null; echo "${ID:-?}" )
osver=$( . /etc/os-release 2>/dev/null; echo "${VERSION_ID:-?}" )
emit OS_ID "$osid"; emit OS_VER "$osver"; emit ARCH "$(uname -m)"
emit HOSTNAME "$(hostname -s 2>/dev/null)"
emit CPU "$(nproc 2>/dev/null || echo 0)"
emit RAM_MB "$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
emit ROOT_FREE_GB "$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
case "$role" in
    web) emit DATA_FREE_GB "$(df -BG --output=avail /home 2>/dev/null | tail -1 | tr -dc '0-9')" ;;
    pxc) emit DATA_FREE_GB "$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc '0-9')" ;;
    s3)  emit DATA_FREE_GB "$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc '0-9')" ;;
esac
emit SELINUX "$(getenforce 2>/dev/null | head -1)"
emit FIREWALLD "$(systemctl is-active firewalld 2>/dev/null | head -1)"
emit FW_PORTS "$(firewall-cmd --list-ports 2>/dev/null | tr ' ' ',')"
emit FW_SERVICES "$(firewall-cmd --list-services 2>/dev/null | tr ' ' ',')"
emit NTP "$(timedatectl show -p NTPSynchronized --value 2>/dev/null | head -1)"
emit TZ "$(timedatectl show -p Timezone --value 2>/dev/null | head -1)"
emit IFACE "$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
emit CIDR "$(ip -4 -o addr show 2>/dev/null | awk -v ip="$expip" '$4 ~ "^"ip"/" {print $4; exit}')"
emit ADDRS "$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd, -)"
emit LISTEN "$(ss -H -ltnp 2>/dev/null | awk '{n=split($4,a,":"); p=a[n]; proc="?";
    if (match($0, /users:\(\("[^"]+/)) proc=substr($0, RSTART+9, RLENGTH-9); print p":"proc}' \
    | sort -u | paste -sd, -)"
emit BCM_VER "$(cat /opt/bcm/VERSION 2>/dev/null | tr -d '[:space:]')"
emit MYSQLD "$(systemctl is-active mysqld mysql mariadb 2>/dev/null | grep -c '^active$')"
emit PY3 "$(command -v python3 >/dev/null 2>&1 && echo yes || echo no)"
emit VIRT "$(systemd-detect-virt 2>/dev/null | head -1)"
for u in "GITHUB=https://api.github.com" "PERCONA=https://repo.percona.com" \
         "MINIO=https://dl.min.io" "BITRIX=https://repo.bitrix.info"; do
    tag="${u%%=*}"; url="${u#*=}"
    code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$url" 2>/dev/null | head -1)
    [ -n "$code" ] || code=000
    emit "NET_${tag}" "$code"
done
if [ "$deep" = "1" ]; then
    if timeout 180 dnf -q makecache >/dev/null 2>&1; then emit DNF ok; else emit DNF fail; fi
fi
RSCRIPT
)

declare -A F_CIDR=() F_LISTEN=() F_FWSTATE=() F_FWALLOW=() F_PY3=() F_BCM=()
declare -A SEEN_HOST=()
for n in "${REACHABLE[@]}"; do
    ip="${NODE_IP[$n]}"; role="${NODE_ROLE[$n]}"
    unset F; declare -A F=()
    while IFS='=' read -r k v; do [[ -n "$k" ]] && F["$k"]="$v"; done \
        < <(printf '%s\n' "$FACTS_SCRIPT" | pf_ssh_script "$ip" "$role" "$ip" "$DEEP")
    if [[ -z "${F[OS_ID]:-}" ]]; then
        fail "$n ($ip): не удалось собрать сведения по SSH"
        continue
    fi
    printf '\n  %s%s (%s, роль %s)%s\n' "$C_BOLD" "$n" "$ip" "$role" "$C_N"

    # ОС и архитектура
    case "${F[OS_ID]}:${F[OS_VER]%%.*}" in
        ol:9|almalinux:9|rocky:9|rhel:9|centos:9) pass "ОС ${F[OS_ID]} ${F[OS_VER]} (${F[ARCH]})" ;;
        *) fail "ОС ${F[OS_ID]} ${F[OS_VER]} — BCM рассчитан на RHEL-совместимую 9 (Oracle/Alma/Rocky)" ;;
    esac
    [[ "${F[ARCH]}" == "x86_64" ]] || fail "архитектура ${F[ARCH]} — поддерживается только x86_64"

    # Имя узла: коллизии ломают ansible bitrix-env и NODENAME rabbitmq
    h="${F[HOSTNAME]:-}"
    [[ -n "${SEEN_HOST[$h]:-}" ]] && fail "hostname '$h' совпадает с узлом ${SEEN_HOST[$h]}" || SEEN_HOST["$h"]="$n"
    [[ "$h" == "$n" ]] || warn "hostname узла — '$h', в файле ответов он назван '$n' (BCM ориентируется на имя из ответов)"

    # Ресурсы против минимумов DEPLOY_REQUIREMENTS
    case "$role" in
        lb)  min_cpu=2; min_ram=1024; min_disk=40 ;;
        web) min_cpu=4; min_ram=4096; min_disk=40 ;;
        pxc) min_cpu=4; min_ram=4096; min_disk=40 ;;
        s3)  min_cpu=4; min_ram=2048; min_disk=40 ;;
        *)   min_cpu=1; min_ram=512;  min_disk=10 ;;
    esac
    (( ${F[CPU]:-0} >= min_cpu ))  && pass "vCPU ${F[CPU]} (мин. $min_cpu)"      || warn "vCPU ${F[CPU]:-?} — минимум для слоя $role: $min_cpu"
    (( ${F[RAM_MB]:-0} >= min_ram )) && pass "RAM ${F[RAM_MB]} МБ (мин. $min_ram)" || warn "RAM ${F[RAM_MB]:-?} МБ — минимум для слоя $role: $min_ram МБ"
    (( ${F[ROOT_FREE_GB]:-0} >= min_disk )) && pass "свободно на / : ${F[ROOT_FREE_GB]} ГБ (мин. $min_disk)" \
        || warn "на / свободно ${F[ROOT_FREE_GB]:-?} ГБ — минимум $min_disk ГБ"
    [[ -n "${F[DATA_FREE_GB]:-}" ]] && info "свободно под данные слоя: ${F[DATA_FREE_GB]} ГБ"

    # Сеть: заявленный IP должен быть на узле; маска — для проверки L2-сегмента VRRP
    if [[ -n "${F[CIDR]:-}" ]]; then
        pass "адрес $ip поднят на ${F[IFACE]:-?} (${F[CIDR]})"
        F_CIDR["$n"]="${F[CIDR]}"
    else
        fail "адрес $ip НЕ найден на интерфейсах узла (есть: ${F[ADDRS]:-—}) — ошибка в *_IPS_LIST"
    fi

    # Время: расхождение часов ломает Galera, keepalived-логи и cron-агентов
    [[ "${F[NTP]:-}" == "yes" ]] && pass "время синхронизировано (NTP), TZ=${F[TZ]:-?}" \
                                 || warn "NTP не синхронизирован (timedatectl NTPSynchronized=${F[NTP]:-?}) — включите chronyd"

    # firewalld и SELinux
    [[ "${F[FIREWALLD]}" == "active" ]] && pass "firewalld активен (install.sh откроет нужные порты)" \
                                        || warn "firewalld не активен — правила BCM применены не будут, порты придётся закрывать внешним фильтром"
    F_FWSTATE["$n"]="${F[FIREWALLD]}"
    F_FWALLOW["$n"]="${F[FW_PORTS]:-},${F[FW_SERVICES]:-}"
    case "${F[SELINUX]:-none}" in
        Enforcing) warn "SELinux Enforcing — bitrix-env/MinIO/ProxySQL могут потребовать булевых разрешений; при проблемах смотрите audit.log" ;;
        Permissive|Disabled|none) info "SELinux: ${F[SELINUX]:-не установлен}" ;;
    esac

    # Занятые порты роли
    listen="${F[LISTEN]:-}"
    F_LISTEN["$n"]="$listen"
    busy=""
    for p in $(role_ports "$role"); do
        entry="$(printf '%s' "$listen" | tr ',' '\n' | awk -F: -v p="$p" '$1==p {print $2; exit}')"
        [[ -n "$entry" ]] && busy+=" ${p}(${entry})"
    done
    [[ -z "$busy" ]] && pass "порты слоя свободны: $(role_ports "$role" | tr '\n' ' ')" \
                     || warn "уже заняты порты:${busy} — install.sh поднимет на них свои сервисы, конфликт остановит установку"
    if [[ "$role" == "web" && "${F[MYSQLD]:-0}" != "0" ]]; then
        warn "на web работает локальный mysqld — он должен быть выключен (3306 занимает ProxySQL для self-check'ов bitrix-env)"
    fi

    # Внешние источники пакетов
    net_bad=""
    for tag in GITHUB PERCONA MINIO BITRIX; do
        code="${F[NET_${tag}]:-000}"
        [[ "$code" =~ ^[23] || "$code" == "403" || "$code" == "404" ]] || net_bad+=" ${tag}(${code})"
    done
    [[ -z "$net_bad" ]] && pass "внешние репозитории доступны (github/percona/min.io/bitrix)" \
                        || warn "недоступны:${net_bad} — установка пакетов слоя может не пройти (нужен прокси/зеркало)"
    [[ "${F[DNF]:-}" == "fail" ]] && fail "dnf makecache не проходит — репозитории ОС недоступны"
    [[ "${F[DNF]:-}" == "ok" ]]   && pass "dnf makecache проходит"

    # Уже установленный BCM: защита от даунгрейда сработает в install.sh
    F_BCM["$n"]="${F[BCM_VER]:-}"
    F_PY3["$n"]="${F[PY3]:-no}"
    unset F
done

# Версия BCM на узлах vs локальный источник — тот же инвариант, что check_bcm_no_downgrade
src_ver="$(tr -d '[:space:]' < "${SELF_DIR}/../bcm/VERSION" 2>/dev/null || true)"
if [[ -n "$src_ver" ]]; then
    newer=""
    for n in "${!F_BCM[@]}"; do
        v="${F_BCM[$n]}"; [[ -z "$v" || "$v" == "$src_ver" ]] && continue
        [[ "$(printf '%s\n%s\n' "$src_ver" "$v" | sort -V | tail -1)" == "$v" ]] && newer+=" ${n}(${v})"
    done
    if [[ -n "$newer" ]]; then
        fail "на узлах BCM новее источника ${src_ver}:${newer} — повторный install.sh откатил бы инструментарий (обновите копию или BCM_ALLOW_DOWNGRADE=1)"
    else
        pass "версия BCM в источнике (${src_ver}) не старше установленной на узлах"
    fi
fi

# ──────────────────────────────────────────────────────────────────────────────
section "8. Общий L2-сегмент (требование VRRP)"
# ──────────────────────────────────────────────────────────────────────────────
# Все узлы и VIP обязаны лежать в одной подсети: keepalived поднимает плавающий
# адрес на интерфейсе узла, а Galera/redis реплицируются внутри сегмента.
_ip2int() { local a b c d IFS='.'; read -r a b c d <<< "$1"; echo $(( (a<<24)|(b<<16)|(c<<8)|d )); }
declare -A NETS=()
for n in "${!F_CIDR[@]}"; do
    cidr="${F_CIDR[$n]}"; pfx="${cidr#*/}"; addr="${cidr%/*}"
    mask=$(( 0xFFFFFFFF << (32 - pfx) & 0xFFFFFFFF ))
    net=$(( $(_ip2int "$addr") & mask ))
    NETS["$n"]="${net}/${pfx}"
done
if (( ${#NETS[@]} )); then
    ref=""; ref_node=""
    for n in "${!NETS[@]}"; do [[ -z "$ref" ]] && { ref="${NETS[$n]}"; ref_node="$n"; }; done
    diff=""
    for n in "${!NETS[@]}"; do [[ "${NETS[$n]}" != "$ref" ]] && diff+=" ${n}(${F_CIDR[$n]})"; done
    [[ -z "$diff" ]] && pass "все узлы в одной подсети (${F_CIDR[$ref_node]} у $ref_node)" \
                     || fail "узлы в РАЗНЫХ подсетях:${diff} — VRRP/keepalived не будет работать между ними"
    # VIP в той же подсети
    pfx="${F_CIDR[$ref_node]#*/}"; mask=$(( 0xFFFFFFFF << (32 - pfx) & 0xFFFFFFFF ))
    refnet="${ref%/*}"
    for v in "${VIPS[@]}"; do
        (( ($(_ip2int "$v") & mask) == refnet )) || fail "VIP $v вне подсети узлов (${F_CIDR[$ref_node]}) — keepalived не сможет его анонсировать"
    done
fi

# ──────────────────────────────────────────────────────────────────────────────
if (( PORT_PROBE )); then
section "9. Проходимость TCP между узлами (временный слушатель)"
# ──────────────────────────────────────────────────────────────────────────────
# Проверяет только СВОБОДНЫЕ порты: на приёмнике поднимается слушатель на ~8 с,
# с источника делается коннект. Отказ трактуется по-разному: если порт закрыт
# локальным firewalld — это ожидаемо ДО install.sh (он откроет); если firewalld
# порт уже пропускает или выключен, значит режет внешний фильтр (гипервизор,
# security group, ACL) — install.sh это НЕ починит.
PYLISTEN='import socket,sys;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("",int(sys.argv[1])));s.listen(1);s.accept()'

_fw_allows() {   # $1=узел $2=порт → 0, если firewalld уже пропускает порт
    local allow="${F_FWALLOW[$1]:-}" p="$2"
    printf '%s' "$allow" | tr ',' '\n' | grep -qx "${p}/tcp" && return 0
    case "$p" in
        80)   printf '%s' "$allow" | tr ',' '\n' | grep -qx http  && return 0 ;;
        443)  printf '%s' "$allow" | tr ',' '\n' | grep -qx https && return 0 ;;
        3306) printf '%s' "$allow" | tr ',' '\n' | grep -qx mysql && return 0 ;;
    esac
    return 1
}
_port_busy() { printf '%s' "${F_LISTEN[$1]:-}" | tr ',' '\n' | awk -F: -v p="$2" '$1==p{f=1} END{exit !f}'; }

probe() {   # $1=узел-источник $2=узел-приёмник $3=порт
    local sn="$1" tn="$2" port="$3"
    local sip="${NODE_IP[$sn]}" tip="${NODE_IP[$tn]}"
    # недоступные узлы уже отмечены ошибкой в разделе 6 — не шумим повторно
    [[ -n "${NODE_AUTH_BY_IP[$sip]:-}" && -n "${NODE_AUTH_BY_IP[$tip]:-}" ]] || return
    [[ "${F_PY3[$tn]:-no}" == "yes" ]] || { info "$sn → $tn:$port — пропуск (на приёмнике нет python3)"; return; }
    if _port_busy "$tn" "$port"; then
        info "$sn → $tn:$port — пропуск (порт уже занят сервисом)"
        return
    fi
    pf_ssh "$tip" "nohup timeout 8 python3 -c '$PYLISTEN' $port >/dev/null 2>&1 & sleep 0.4" >/dev/null
    local res
    res="$(pf_ssh "$sip" "timeout 4 bash -c 'exec 3<>/dev/tcp/${tip}/${port}' >/dev/null 2>&1 && echo OK || echo NO")"
    if [[ "$res" == "OK" ]]; then
        pass "$sn → $tn:$port — проходит"
    elif [[ "${F_FWSTATE[$tn]:-}" == "active" ]] && ! _fw_allows "$tn" "$port"; then
        info "$sn → $tn:$port — закрыт локальным firewalld (ожидаемо, install.sh откроет)"
    else
        fail "$sn → $tn:$port — НЕ проходит, хотя локальный firewalld порт не режет (внешний фильтр/маршрутизация)"
    fi
}

# Матрица проверяется по одному представителю каждого направления — этого хватает,
# чтобы поймать внешний фильтр между слоями; внутрислойные — по всем парам.
for w in "${WEB_NODES[@]}"; do
    for d in "${PXC_NODES[@]}"; do probe "$w" "$d" 3306; done
done
for l in "${LB_NODES[@]}"; do
    for w in "${WEB_NODES[@]}"; do probe "$l" "$w" 80; done
done
for a in "${PXC_NODES[@]}"; do
    for b in "${PXC_NODES[@]}"; do
        [[ "$a" == "$b" ]] && continue
        probe "$a" "$b" 4567; probe "$a" "$b" 4444
    done
done
for a in "${WEB_NODES[@]}"; do
    for b in "${WEB_NODES[@]}"; do
        [[ "$a" == "$b" ]] && continue
        probe "$a" "$b" "${SESSION_REDIS_PORT:-6380}"
        probe "$a" "$b" "${PROXYSQL_ADMIN_PORT:-6032}"
    done
done
if (( S3_ENABLED )); then
    for w in "${WEB_NODES[@]}"; do probe "$w" "${S3_NODES[0]}" "${S3_PORT:-9000}"; done
    for a in "${S3_NODES[@]}"; do
        for b in "${S3_NODES[@]}"; do [[ "$a" == "$b" ]] || probe "$a" "$b" "${S3_PORT:-9000}"; done
    done
fi
info "VRRP (protocol 112) TCP-пробой не проверяется — убедитесь, что между LB и между WEB не режется протокол 112"
fi

# ──────────────────────────────────────────────────────────────────────────────
section "Итог"
# ──────────────────────────────────────────────────────────────────────────────
printf '  успешно: %s%d%s   предупреждений: %s%d%s   ошибок: %s%d%s\n' \
    "$C_G" "$PASSED" "$C_N" "$C_Y" "$WARNED" "$C_N" "$C_R" "$FAILED" "$C_N"
if (( FAILED > 0 )); then
    printf '  %sУстановку запускать рано — сначала устраните ошибки выше.%s\n' "$C_R" "$C_N"
    exit 1
fi
printf '  %sКритичных препятствий нет. Предупреждения прочитайте перед запуском install.sh.%s\n' "$C_G" "$C_N"
exit 0
