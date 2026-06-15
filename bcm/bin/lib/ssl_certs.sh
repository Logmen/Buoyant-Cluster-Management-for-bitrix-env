#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181,SC2206
# =============================================================================
# ssl_certs.sh — централизованное управление SSL-сертификатами кластера (на LB).
#
# TLS терминируется ТОЛЬКО на HAProxy (LB): один pem на оба LB в /etc/haproxy/certs/,
# web-нодам публичный сертификат не нужен (бэкенды ходят по HTTP :80, Apache видит
# HTTPS=on через X-Forwarded-Proto). Запускается НА LB-ноде; с web-ноды вызывается
# по SSH из меню BCM (menu/12_ssl.sh).
#
# Действия:
#   --install-pem <file> [domain]  установить готовый pem (fullchain+key одним файлом)
#                                  локально: валидация → certs dir → reload haproxy
#   --issue [--force]              выпуск Let's Encrypt. Метод — ACME_METHOD в env:
#                                    http   — HTTP-01, acme.sh --standalone; challenge
#                                             маршрутизирует acme_backend HAProxy (нужен
#                                             публичный :80 на VIP)
#                                    dns_cf — DNS-01 через Cloudflare API (CF_Token с
#                                             правами Zone.DNS:Edit); публичный :80 не
#                                             нужен, поддерживает wildcard (*.домен)
#   --deploy                       reloadcmd acme.sh: собрать pem из выпущенного серта,
#                                  установить локально + разнести на peer-LB + синк
#                                  состояния acme (учётка/конфиг) на peer'ы
#   --renew [--force]              продление (systemd-timer на обоих LB): работает
#                                  только на держателе VIP — нет гонки двух выпусков
#   --status                       сертификаты в certs dir: subject/SAN/срок
#
# Параметры — из /etc/bitrix-cluster/ssl-renew.env (раскатывает install.sh / меню).
# Let's Encrypt невозможно проверить без публичного DNS/:80 — на закрытой лабе
# выпуск дойдёт до challenge и упадёт по таймауту валидации (это ожидаемо).
#
# НЕ ставить `set -e`: операции с peer'ами best-effort, а acme.sh использует
# exit 2 как штатный «продление не требуется».
# =============================================================================
set -uo pipefail

ENV_FILE="${SSL_RENEW_ENV:-/etc/bitrix-cluster/ssl-renew.env}"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SELF_NODE="${SELF_NODE:-$(hostname -s 2>/dev/null || echo '?')}"
SELF_IP="${SELF_IP:-}"
LB_PEERS="${LB_PEERS:-}"                  # пробел-разделённый список IP всех LB (включая себя)
WEB_PEERS="${WEB_PEERS:-}"                # IP web-нод: серт раздаётся и им — на ЛОКАЛЬНЫЙ
                                          # nginx :443. Клиентский TLS терминирует LB, но
                                          # self-check'и Bitrix (check_socket и др.) ходят на
                                          # ssl://домен:443 → 127.0.0.1 (hosts-фикс) → без
                                          # реального серта валидация падает (Socket error [0])
WEB_CERT="${WEB_CERT:-/etc/nginx/ssl/cert.pem}"   # bitrix-env: cert и key одним pem
DOMAIN="${DOMAIN:-}"
LE_EMAIL="${LE_EMAIL:-}"
VIP="${VIP:-}"
CERT_DIR="${CERT_DIR:-/etc/haproxy/certs}"
ACME_HOME="${ACME_HOME:-/etc/bitrix-cluster/acme}"
ACME_BIN="${ACME_BIN:-/opt/bcm/vendor/acme.sh}"
ACME_VERSION="${ACME_VERSION:-3.1.1}"     # тег acme.sh для автозагрузки (fallback master)
ACME_HTTP_PORT="${ACME_HTTP_PORT:-8402}"  # порт standalone-ответчика (= acme_backend HAProxy)
ACME_CA="${ACME_CA:-letsencrypt}"         # letsencrypt | letsencrypt_test (staging)
ACME_METHOD="${ACME_METHOD:-http}"        # http (standalone) | dns_cf (Cloudflare DNS-01)
CF_Token="${CF_Token:-}"                  # API-токен Cloudflare (Zone.DNS:Edit) для dns_cf;
                                          # после первого выпуска acme.sh сам хранит его в
                                          # account.conf (SAVED_CF_Token) — для продлений
SSH_KEY="${SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}"
LOG_FILE="${LOG_FILE:-/var/log/bcm/ssl-renew.log}"
HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=8
          -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR)

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${SELF_NODE}] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    echo "$msg" >&2
}

_other_peers() {
    local p
    for p in $LB_PEERS; do
        [[ "$p" == "$SELF_IP" ]] && continue
        echo "$p"
    done
}

_reachable() {
    timeout 8 ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "root@${1}" "exit 0" 2>/dev/null
}

# Держит ли этот узел VIP (= VRRP-master)
_holds_vip() {
    [[ -n "$VIP" ]] && ip -4 addr 2>/dev/null | grep -q "inet ${VIP}/"
}

# ──── Валидация pem (cert+chain+key одним файлом, формат HAProxy) ─────────────
# Проверяем: серт читается, ключ читается, публичные ключи совпадают, срок не вышел.
_validate_pem() {
    local pem="$1"
    [[ -s "$pem" ]] || { log "ОШИБКА: pem пуст или не найден: $pem"; return 1; }
    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$pem" -noout -pubkey 2>/dev/null) \
        || { log "ОШИБКА: в $pem не найден сертификат."; return 1; }
    key_pub=$(openssl pkey -in "$pem" -pubout 2>/dev/null) \
        || { log "ОШИБКА: в $pem не найден приватный ключ."; return 1; }
    if [[ "$cert_pub" != "$key_pub" ]]; then
        log "ОШИБКА: ключ в $pem не соответствует сертификату."
        return 1
    fi
    if ! openssl x509 -in "$pem" -noout -checkend 0 >/dev/null 2>&1; then
        log "ОШИБКА: сертификат в $pem уже истёк."
        return 1
    fi
    return 0
}

# ──── Проверить конфиг и бесшовно перечитать HAProxy ─────────────────────────
_reload_haproxy() {
    if ! haproxy -c -f "$HAPROXY_CFG" -q 2>>"$LOG_FILE"; then
        log "ОШИБКА: haproxy -c не прошёл — reload отменён."
        return 1
    fi
    systemctl reload haproxy 2>>"$LOG_FILE" \
        && log "haproxy перечитан (seamless reload)." \
        || { log "ОШИБКА: systemctl reload haproxy."; return 1; }
}

# ──── Установить pem локально ────────────────────────────────────────────────
# install_pem <pem-файл> [domain]; domain по умолчанию — CN сертификата.
install_pem() {
    local pem="$1"
    local domain="${2:-}"
    _validate_pem "$pem" || return 1

    if [[ -z "$domain" ]]; then
        domain=$(openssl x509 -in "$pem" -noout -subject -nameopt RFC2253 2>/dev/null \
                 | sed -n 's/.*CN=\([^,]*\).*/\1/p')
        [[ -z "$domain" ]] && domain="cluster"
    fi
    # wildcard (*.домен при DNS-01) в имени файла неудобен — заменяем
    domain="${domain/\*/wildcard}"

    mkdir -p "$CERT_DIR"
    install -m 600 "$pem" "${CERT_DIR}/${domain}.pem" \
        || { log "ОШИБКА: не удалось записать ${CERT_DIR}/${domain}.pem"; return 1; }
    # Заглушку убираем: HAProxy берёт default-серт из crt-каталога по алфавиту,
    # и localhost.pem иначе остался бы default'ом для клиентов без SNI.
    [[ "$domain" != "localhost" ]] && rm -f "${CERT_DIR}/localhost.pem"
    log "Сертификат установлен: ${CERT_DIR}/${domain}.pem ($(openssl x509 -in "$pem" -noout -enddate 2>/dev/null))"
    _reload_haproxy
}

# ──── acme.sh: убедиться, что клиент на месте (одиночный shell-скрипт) ────────
# Загрузка одного файла из репо acme.sh: тег ACME_VERSION → fallback master.
_fetch_acme_file() {
    local rel="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if ! curl -fsSL "https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_VERSION}/${rel}" \
            -o "$dst" 2>>"$LOG_FILE"; then
        log "Тег ${ACME_VERSION} недоступен для ${rel}, пробую master..."
        curl -fsSL "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/${rel}" \
            -o "$dst" 2>>"$LOG_FILE" \
            || { log "ОШИБКА: не удалось загрузить ${rel} (нет интернета на LB?)."; return 1; }
    fi
    return 0
}

_ensure_acme() {
    [[ -x "$ACME_BIN" ]] && return 0
    log "acme.sh не найден — загружаю (тег ${ACME_VERSION})..."
    _fetch_acme_file "acme.sh" "$ACME_BIN" || return 1
    chmod +x "$ACME_BIN"
    log "acme.sh загружен: $ACME_BIN"
}

# DNS-хук Cloudflare: acme.sh ищет dnsapi/ рядом с самим скриптом (_SCRIPT_HOME)
_ensure_dnsapi_cf() {
    local hook="$(dirname "$ACME_BIN")/dnsapi/dns_cf.sh"
    [[ -s "$hook" ]] && return 0
    log "Загружаю DNS-хук Cloudflare (dnsapi/dns_cf.sh)..."
    _fetch_acme_file "dnsapi/dns_cf.sh" "$hook" || return 1
    chmod +x "$hook"
}

_acme() {
    "$ACME_BIN" --home "$ACME_HOME" "$@"
}

# ──── Выпуск Let's Encrypt (HTTP-01 standalone или DNS-01 Cloudflare) ─────────
issue() {
    local force="${1:-}"
    [[ -z "$DOMAIN" ]]   && { log "ОШИБКА: DOMAIN не задан в ${ENV_FILE}."; return 1; }
    [[ -z "$LE_EMAIL" ]] && { log "ОШИБКА: LE_EMAIL не задан в ${ENV_FILE}."; return 1; }
    _ensure_acme || return 1
    mkdir -p "$ACME_HOME"

    local args=(--issue -d "$DOMAIN" --server "$ACME_CA" --accountemail "$LE_EMAIL" --log "$LOG_FILE")
    if [[ "$ACME_METHOD" == "dns_cf" ]]; then
        _ensure_dnsapi_cf || return 1
        # Токен обязателен при первом выпуске; при повторных acme.sh берёт
        # SAVED_CF_Token из account.conf (синкается на peer'ы вместе с ACME_HOME).
        if [[ -z "$CF_Token" ]] && ! grep -q '^SAVED_CF_Token=' "${ACME_HOME}/account.conf" 2>/dev/null; then
            log "ОШИБКА: CF_Token не задан в ${ENV_FILE} и не сохранён в account.conf."
            log "Нужен API-токен Cloudflare с правами Zone.DNS:Edit на зону домена (меню 12 → 3)."
            return 1
        fi
        [[ -n "$CF_Token" ]] && export CF_Token
        args+=(--dns dns_cf)
        log "Выпуск сертификата ${DOMAIN} (CA: ${ACME_CA}, DNS-01 Cloudflare)..."
    else
        if ! command -v socat >/dev/null 2>&1; then
            log "ОШИБКА: socat не установлен (нужен acme.sh --standalone): dnf install -y socat"
            return 1
        fi
        args+=(--standalone --httpport "$ACME_HTTP_PORT")
        log "Выпуск сертификата ${DOMAIN} (CA: ${ACME_CA}, HTTP-01 standalone :${ACME_HTTP_PORT})..."
    fi
    [[ "$force" == "--force" ]] && args+=(--force)
    _acme "${args[@]}"
    local rc=$?
    if [[ $rc -eq 2 ]]; then
        log "Сертификат ещё действителен — выпуск пропущен acme.sh (это не ошибка)."
    elif [[ $rc -ne 0 ]]; then
        log "ОШИБКА: acme.sh --issue завершился с кодом ${rc} (см. ${LOG_FILE})."
        if [[ "$ACME_METHOD" == "dns_cf" ]]; then
            log "Частые причины: токен без прав Zone.DNS:Edit на зону; зона не в Cloudflare."
        else
            log "Частые причины: DNS ${DOMAIN} не указывает на VIP ${VIP:-?}; :80 закрыт снаружи."
        fi
        return 1
    fi

    # install-cert фиксирует пути + reloadcmd; acme.sh сам вызовет reloadcmd (--deploy)
    # сейчас и при каждом будущем продлении через --cron.
    # ⚠️ acme.sh НЕ создаёт каталоги под --*-file (touch падает) — создаём сами.
    mkdir -p "${ACME_HOME}/deploy"
    _acme --install-cert -d "$DOMAIN" \
        --fullchain-file "${ACME_HOME}/deploy/${DOMAIN}.fullchain.pem" \
        --key-file       "${ACME_HOME}/deploy/${DOMAIN}.key.pem" \
        --reloadcmd      "/opt/bcm/bin/lib/ssl_certs.sh --deploy" \
        || { log "ОШИБКА: acme.sh --install-cert."; return 1; }
    log "Выпуск ${DOMAIN} завершён."
}

# ──── Серт на web-ноды (локальный nginx :443 для self-check'ов Bitrix) ───────
# bitrix-env держит в /etc/nginx/ssl/cert.pem серт и ключ ОДНИМ файлом — наш pem
# подходит как есть. Откат при провале nginx -t.
_deploy_to_webs() {
    local pem="$1" ip
    for ip in $WEB_PEERS; do
        if ! _reachable "$ip"; then
            log "web ${ip} недоступен — серт для локального :443 не доставлен."
            continue
        fi
        scp -q "${SSH_OPTS[@]}" -i "$SSH_KEY" "$pem" "root@${ip}:/tmp/bcm-ssl-web.pem" \
            && ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "root@${ip}" "
                [ -f '$WEB_CERT' ] && cp -n '$WEB_CERT' '${WEB_CERT}.bcm-bak'
                cp /tmp/bcm-ssl-web.pem '$WEB_CERT' && chmod 600 '$WEB_CERT'
                if nginx -t 2>/dev/null; then
                    systemctl reload nginx
                else
                    [ -f '${WEB_CERT}.bcm-bak' ] && cp '${WEB_CERT}.bcm-bak' '$WEB_CERT' && systemctl reload nginx
                    exit 1
                fi
                rm -f /tmp/bcm-ssl-web.pem" \
            && log "web ${ip}: серт установлен в ${WEB_CERT}, nginx перечитан." \
            || log "web ${ip}: ОШИБКА установки серта (выполнен откат)."
    done
}

# ──── Деплой выпущенного серта: локально + на peer-LB + web-ноды ──────────────
deploy() {
    [[ -z "$DOMAIN" ]] && { log "ОШИБКА: DOMAIN не задан."; return 1; }
    local fc="${ACME_HOME}/deploy/${DOMAIN}.fullchain.pem"
    local key="${ACME_HOME}/deploy/${DOMAIN}.key.pem"
    [[ -s "$fc" && -s "$key" ]] || { log "ОШИБКА: нет ${fc} / ${key} (сначала --issue)."; return 1; }

    local pem
    pem=$(mktemp /tmp/bcm-ssl.XXXXXX)
    cat "$fc" "$key" > "$pem"
    chmod 600 "$pem"

    # Peer-LB первыми (на них трафика нет/меньше), локальный — последним.
    local ip
    for ip in $(_other_peers); do
        if ! _reachable "$ip"; then
            log "peer ${ip} недоступен — серт НЕ доставлен (повторится при следующем продлении)."
            continue
        fi
        scp -q "${SSH_OPTS[@]}" -i "$SSH_KEY" "$pem" "root@${ip}:/tmp/bcm-ssl-deploy.pem" \
            && ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "root@${ip}" \
                "/opt/bcm/bin/lib/ssl_certs.sh --install-pem /tmp/bcm-ssl-deploy.pem '${DOMAIN}'; rm -f /tmp/bcm-ssl-deploy.pem" \
            && log "peer ${ip}: серт установлен." \
            || log "peer ${ip}: ОШИБКА установки серта."
        # Синк состояния acme (учётка/конфиг/reloadcmd): при смене VRRP-master peer
        # продолжит продление той же учёткой, без повторной регистрации.
        tar -C "$ACME_HOME" -cf - . 2>/dev/null \
            | ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "root@${ip}" \
                "mkdir -p '$ACME_HOME' && tar -C '$ACME_HOME' -xf - && chmod 700 '$ACME_HOME'" \
            || log "peer ${ip}: не удалось синкнуть ${ACME_HOME}."
    done

    install_pem "$pem" "$DOMAIN"
    local rc=$?
    [[ $rc -eq 0 ]] && _deploy_to_webs "$pem"
    rm -f "$pem"
    return $rc
}

# ──── Продление (systemd-timer на обоих LB) ───────────────────────────────────
renew() {
    local force="${1:-}"
    [[ -z "$DOMAIN" ]] && { log "renew: DOMAIN не задан — нечего продлевать."; return 0; }
    # Только держатель VIP: challenge всё равно приходит на VIP, а так ещё и нет
    # гонки одновременного выпуска с двух LB. При смене master продление
    # продолжит новый держатель (состояние acme синкается в deploy()).
    if ! _holds_vip; then
        log "renew: VIP ${VIP:-?} не на этом узле — пропуск (продлевает VRRP-master)."
        return 0
    fi
    [[ -x "$ACME_BIN" ]] || { log "renew: acme.sh не установлен — пропуск (выпуска ещё не было?)."; return 0; }

    if [[ "$force" == "--force" ]]; then
        _acme --renew -d "$DOMAIN" --force --log "$LOG_FILE"
        local rc=$?
        [[ $rc -eq 0 ]] && log "Принудительное продление ${DOMAIN}: ок." \
                        || log "Принудительное продление ${DOMAIN}: код ${rc}."
        return $rc
    fi

    # --cron: продлит, только если пора; после продления сам запустит reloadcmd (--deploy).
    _acme --cron --log "$LOG_FILE" >/dev/null 2>&1
    local rc=$?
    [[ $rc -eq 0 ]] && log "renew (--cron): ок." || log "renew (--cron): код ${rc} (см. ${LOG_FILE})."
    return $rc
}

# ──── Статус сертификатов в certs dir ─────────────────────────────────────────
status() {
    local p found=0
    for p in "$CERT_DIR"/*.pem; do
        [[ -f "$p" ]] || continue
        found=1
        local end days
        end=$(openssl x509 -in "$p" -noout -enddate 2>/dev/null | cut -d= -f2)
        if openssl x509 -in "$p" -noout -checkend $((30*86400)) >/dev/null 2>&1; then
            days="ok"
        elif openssl x509 -in "$p" -noout -checkend 0 >/dev/null 2>&1; then
            days="<30d!"
        else
            days="ИСТЁК"
        fi
        echo "${p}|$(openssl x509 -in "$p" -noout -subject 2>/dev/null | sed 's/^subject=//')|${end}|${days}"
    done
    [[ $found -eq 0 ]] && echo "(в ${CERT_DIR} нет сертификатов)"
    return 0
}

case "${1:-}" in
    --install-pem) shift; install_pem "$@" ;;
    --issue)       shift; issue "${1:-}" ;;
    --deploy)      deploy ;;
    --renew)       shift; renew "${1:-}" ;;
    --status)      status ;;
    *) echo "usage: $0 {--install-pem <pem> [domain]|--issue [--force]|--deploy|--renew [--force]|--status}" >&2
       exit 2 ;;
esac
