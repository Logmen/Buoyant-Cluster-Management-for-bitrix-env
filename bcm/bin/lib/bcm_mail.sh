#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_mail.sh — Postfix smarthost-релей для исходящей почты (CLI, на web-ноде)
#
# Зачем: bitrix-env шлёт почту через msmtp (sendmail_path=msmtp), у которого НЕТ
# локальной очереди/ретраев. В кластере прямая отправка с каждой ноды плоха:
# N исходящих IP → хрупкие SPF/PTR/DKIM, нет буфера при сбое релея. Решение —
# Postfix как smarthost на КАЖДОЙ web-ноде: единый внешний SMTP (релей), локальная
# очередь + ретраи, node-agnostic конфиг. VIP не нужен — отправка per-node,
# stateless к кластеру; единая идентичность задаётся внешним релеем.
#
# Что делает --configure (идемпотентно):
#   • dnf install postfix cyrus-sasl-plain
#   • postconf -e: relayhost=[HOST]:PORT, SASL-auth, TLS, inet_interfaces=loopback-only
#   • /etc/postfix/sasl_passwd ([HOST]:PORT user:pass) + postmap, 0600
#   • sender_canonical: envelope-from → FROM_ADDRESS (по умолчанию RELAY_USER).
#     Переписывание ВСЕГДА включено: без него envelope-from = <систюзер>@$myhostname
#     (напр. bitrix@web01.crm.onelab.kz), а такой домен обычно не резолвится, и релей
#     с проверкой отправителя (cPanel senderverify, verify=sender) режет письмо
#     на RCPT TO: "550 Sender verify failed". Затрагивается только конверт —
#     заголовок From: приложения сохраняется (sender_canonical_classes).
#   • alternatives mta → postfix; php.d drop-in zz-bcm-mail.ini (sendmail_path → postfix)
#   • enable --now postfix; restart httpd (mod_php перечитывает sendmail_path)
#
# Конфиг (пишет меню 15): /etc/bitrix-cluster/mail.env (не-секрет, KEY='value'),
# пароль релея — отдельный raw-файл /etc/bitrix-cluster/.mail_relay_pass (0600).
# Парсим mail.env построчно (НЕ source — пароля там нет, но единый стиль).
#
# Команды: --configure | --status | --test <addr> | --queue | --flush | --disable
# =============================================================================
set -uo pipefail

MAIL_ENV="/etc/bitrix-cluster/mail.env"
MAIL_PASS_FILE="/etc/bitrix-cluster/.mail_relay_pass"
PHP_DROPIN="/etc/php.d/zz-bcm-mail.ini"
SASL_PASSWD="/etc/postfix/sasl_passwd"
SENDER_CANON="/etc/postfix/sender_canonical"
MAIL_LOG="/var/log/bcm/mail.log"

_m_log() { mkdir -p /var/log/bcm 2>/dev/null || true; echo "$(date '+%F %T') $*" >>"$MAIL_LOG" 2>/dev/null || true; }
_m_err() { echo "ОШИБКА: $*" >&2; _m_log "ERROR: $*"; }
_m_info(){ echo "$*"; }

# Прочитать значение из mail.env (формат KEY='value'); пусто, если нет.
_m_env() {
    local key="$1"
    [[ -r "$MAIL_ENV" ]] || { echo ""; return; }
    sed -n "s/^${key}='\(.*\)'\$/\1/p" "$MAIL_ENV" | head -1
}

# Путь к sendmail от Postfix (а не msmtp-шиму).
_m_postfix_sendmail() {
    # Предпочитаем /usr/sbin (канонический путь); /usr/lib/sendmail.postfix тоже рабочий,
    # но даём один путь на всех нодах (без разнобоя в sendmail_path).
    [[ -x /usr/sbin/sendmail.postfix ]] && { echo "/usr/sbin/sendmail.postfix"; return; }
    local p
    p=$(rpm -ql postfix 2>/dev/null | grep -m1 '/sendmail\.postfix$') || p=""
    [[ -n "$p" ]] && { echo "$p"; return; }
    echo "/usr/sbin/sendmail.postfix"
}

_m_require_root() { [[ "$(id -u)" -eq 0 ]] || { _m_err "нужен root."; exit 1; }; }

# Нормализовать значение в имя хоста для HELO: если задан адрес (user@dom) — берём dom.
# smtp_helo_name обязан быть FQDN (RFC 5321); адрес там ломает HELO у строгих релеев.
_m_helo_from() {
    local v="${1:-}"
    v="${v##*@}"
    [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || v=""
    echo "$v"
}

# ──── --configure ────────────────────────────────────────────────────────────
_mail_configure() {
    _m_require_root
    local host port user tls from_addr from_dom helo
    host=$(_m_env RELAY_HOST); port=$(_m_env RELAY_PORT); user=$(_m_env RELAY_USER)
    tls=$(_m_env RELAY_TLS);   from_addr=$(_m_env FROM_ADDRESS); from_dom=$(_m_env FROM_DOMAIN)
    [[ -z "$port" ]] && port="587"
    [[ -z "$tls"  ]] && tls="starttls"

    if [[ -z "$host" ]]; then
        _m_err "RELAY_HOST не задан в ${MAIL_ENV}. Сначала настройте через меню 15."
        exit 1
    fi
    local pass=""
    [[ -r "$MAIL_PASS_FILE" ]] && pass=$(cat "$MAIL_PASS_FILE")
    if [[ -z "$pass" || -z "$user" ]]; then
        _m_err "RELAY_USER/пароль не заданы (нужны для SASL-auth к релею)."
        exit 1
    fi

    _m_info "→ Установка postfix + cyrus-sasl-plain..."
    if ! rpm -q postfix >/dev/null 2>&1; then
        dnf -y install postfix cyrus-sasl-plain >/dev/null 2>&1 || { _m_err "dnf install postfix не удался."; exit 1; }
    else
        rpm -q cyrus-sasl-plain >/dev/null 2>&1 || dnf -y install cyrus-sasl-plain >/dev/null 2>&1 || true
    fi

    helo=$(_m_helo_from "$from_dom")
    [[ -z "$helo" ]] && helo="$(hostname -f 2>/dev/null || hostname)"

    # envelope-from обязателен. Пусто → берём RELAY_USER: он заведомо существует
    # на релее (под ним же идёт SASL-auth), значит пройдёт verify=sender и SPF.
    if [[ -z "$from_addr" ]]; then
        from_addr="$user"
        _m_info "→ FROM_ADDRESS не задан — envelope-from берём из RELAY_USER (${from_addr})."
    fi

    _m_info "→ postconf (relayhost=[${host}]:${port}, TLS=${tls})..."
    postconf -e \
        "relayhost = [${host}]:${port}" \
        "smtp_sasl_auth_enable = yes" \
        "smtp_sasl_password_maps = hash:${SASL_PASSWD}" \
        "smtp_sasl_security_options = noanonymous" \
        "smtp_sasl_mechanism_filter = plain, login" \
        "smtp_use_tls = yes" \
        "inet_interfaces = loopback-only" \
        "inet_protocols = all" \
        "myhostname = $(hostname -f 2>/dev/null || hostname)" \
        "smtp_helo_name = ${helo}" \
        || { _m_err "postconf -e не удался."; exit 1; }

    # TLS-режим по порту/настройке
    case "$tls" in
        wrapper) postconf -e "smtp_tls_security_level = encrypt" "smtp_tls_wrappermode = yes" ;;
        none)    postconf -e "smtp_tls_security_level = may"     "smtp_tls_wrappermode = no"  ;;
        *)       postconf -e "smtp_tls_security_level = encrypt" "smtp_tls_wrappermode = no"  ;;  # starttls
    esac

    # SASL-пароль
    umask 077
    printf '[%s]:%s %s:%s\n' "$host" "$port" "$user" "$pass" > "$SASL_PASSWD"
    chmod 600 "$SASL_PASSWD"
    postmap "$SASL_PASSWD" || { _m_err "postmap sasl_passwd не удался."; exit 1; }
    chmod 600 "${SASL_PASSWD}.db" 2>/dev/null || true

    # Переписать envelope-from (Return-Path) на единый адрес → verify=sender + SPF-alignment.
    # sender_canonical_classes ограничиваем конвертом: дефолт "envelope_sender, header_sender"
    # переписал бы и заголовок From:, а Bitrix ставит там адрес конкретного ящика
    # (b24sales@…, sales@… и т.д.) — его затирать нельзя.
    postconf -e \
        "sender_canonical_classes = envelope_sender" \
        "sender_canonical_maps = regexp:${SENDER_CANON}" \
        || { _m_err "postconf -e (sender_canonical) не удался."; exit 1; }
    printf '/.+/    %s\n' "$from_addr" > "$SENDER_CANON"
    chmod 644 "$SENDER_CANON"
    _m_info "→ envelope-from переписывается на ${from_addr} (заголовок From: не трогаем)."

    systemctl enable postfix >/dev/null 2>&1 || true
    if systemctl is-active --quiet postfix; then
        systemctl reload postfix 2>/dev/null || systemctl restart postfix
    else
        systemctl restart postfix || { _m_err "postfix не стартовал."; exit 1; }
    fi

    # MTA-альтернатива и PHP → postfix sendmail
    local pf_sm; pf_sm=$(_m_postfix_sendmail)
    alternatives --set mta "$pf_sm" >/dev/null 2>&1 || true
    printf '; BCM: исходящая почта через Postfix-smarthost (перекрывает bitrixenv.ini)\nsendmail_path = %s -t -i\n' "$pf_sm" > "$PHP_DROPIN"
    chmod 644 "$PHP_DROPIN"

    # mod_php перечитывает sendmail_path только при рестарте httpd
    systemctl is-active --quiet httpd && systemctl restart httpd 2>/dev/null || true
    systemctl is-active --quiet php-fpm && systemctl restart php-fpm 2>/dev/null || true

    _m_log "configured relay [${host}]:${port} user=${user} tls=${tls} from=${from_addr:-—}"
    _m_info "✓ Postfix-smarthost настроен: релей [${host}]:${port}, sendmail → postfix."
}

# ──── --status ─────────────────────────────────────────────────────────────────
_mail_status() {
    local act relay tls sm qn
    act=$(systemctl is-active postfix 2>/dev/null || true); [[ -z "$act" ]] && act="inactive"
    relay=$(postconf -h relayhost 2>/dev/null || echo "—")
    tls=$(postconf -h smtp_tls_security_level 2>/dev/null || echo "—")
    sm=$(php -r 'echo ini_get("sendmail_path");' 2>/dev/null || echo "?")
    qn=$(mailq 2>/dev/null | grep -c '^[A-F0-9]' 2>/dev/null); [[ "$qn" =~ ^[0-9]+$ ]] || qn=0
    local canon canon_cls
    canon=$(postconf -h sender_canonical_maps 2>/dev/null || echo "")
    canon_cls=$(postconf -h sender_canonical_classes 2>/dev/null || echo "")
    echo "postfix=${act} relayhost=${relay} tls=${tls} queue=${qn}"
    if [[ -z "$canon" ]]; then
        echo "envelope-from=НЕ переписывается (<систюзер>@$(postconf -h myhostname 2>/dev/null)) ⚠ релей с verify=sender отобьёт письма"
    else
        # Значение достаём по ТИПУ карты: BCM пишет regexp-файл, но оператор мог
        # поставить static: руками (так чинили инцидент 09.09 до патча) — читать
        # в этом случае $SENDER_CANON бессмысленно, файла нет, и строка выходила пустой.
        local canon_val=""
        case "$canon" in
            static:*)                    canon_val="${canon#static:}" ;;
            regexp:*|hash:*|texthash:*)  canon_val=$(sed -n 's|^/\.+/[[:space:]]*||p' "${canon#*:}" 2>/dev/null | head -1) ;;
        esac
        echo "envelope-from=${canon_val:-?} (${canon}, classes=${canon_cls})"
    fi
    echo "sendmail_path=${sm}"
    if [[ -r /var/log/maillog ]]; then
        echo "-- последние записи maillog --"
        tail -n 4 /var/log/maillog 2>/dev/null | sed 's/^/   /'
    fi
}

# ──── --test <addr> ────────────────────────────────────────────────────────────
_mail_test() {
    local to="$1"
    [[ -z "$to" ]] && { _m_err "укажите адрес получателя."; exit 1; }
    local from_addr; from_addr=$(_m_env FROM_ADDRESS)
    # Fallback-цепочка: RELAY_USER → bcm-test@<нормализованный FROM_DOMAIN> → bcm-test@<FQDN>.
    # Раньше здесь клеилось "bcm-test@" + FROM_DOMAIN без нормализации: при FROM_DOMAIN
    # вида 'crm@onelab.kz' получался невалидный 'bcm-test@crm@onelab.kz'.
    if [[ -z "$from_addr" ]]; then
        from_addr=$(_m_env RELAY_USER)
    fi
    if [[ -z "$from_addr" ]]; then
        local _d; _d=$(_m_helo_from "$(_m_env FROM_DOMAIN)")
        [[ -z "$_d" ]] && _d="$(hostname -f 2>/dev/null || hostname)"
        from_addr="bcm-test@${_d}"
    fi
    local pf_sm; pf_sm=$(_m_postfix_sendmail)
    # ⚠️ MIME-заголовки обязательны: тело на кириллице (UTF-8). Без charset=UTF-8 клиент
    # читает байты как Latin-1 → мохибейк (Subject ASCII — без encoded-word достаточно).
    printf 'From: %s\nTo: %s\nSubject: BCM mail test (%s)\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\nТест отправки через Postfix-smarthost.\nНода: %s\nВремя: %s\n' \
        "$from_addr" "$to" "$(hostname)" "$(hostname -f 2>/dev/null || hostname)" "$(date '+%F %T')" \
        | "$pf_sm" -t -i
    local rc=$?
    _m_log "test → ${to} (rc=${rc})"
    if [[ $rc -eq 0 ]]; then
        echo "✓ Письмо принято в очередь Postfix (получатель: ${to})."
        echo "  Проверьте доставку и /var/log/maillog. Очередь:"
        mailq 2>/dev/null | tail -n 5 | sed 's/^/   /'
    else
        _m_err "sendmail вернул rc=${rc}."
        exit "$rc"
    fi
}

# ──── --disable (вернуть msmtp) ────────────────────────────────────────────────
_mail_disable() {
    _m_require_root
    systemctl disable --now postfix >/dev/null 2>&1 || true
    rm -f "$PHP_DROPIN" 2>/dev/null || true
    alternatives --set mta /usr/bin/msmtp >/dev/null 2>&1 || true
    systemctl is-active --quiet httpd && systemctl restart httpd 2>/dev/null || true
    _m_log "disabled (откат на msmtp)"
    echo "✓ Postfix-релей отключён, отправка возвращена на msmtp (по умолчанию bitrix-env)."
}

# ──── Диспетчер ────────────────────────────────────────────────────────────────
case "${1:-}" in
    --configure) _mail_configure ;;
    --status)    _mail_status ;;
    --test)      _mail_test "${2:-}" ;;
    --queue)     mailq 2>/dev/null || echo "mailq недоступен (postfix не настроен?)" ;;
    --flush)     postqueue -f 2>/dev/null && echo "✓ Очередь Postfix вытолкнута (flush)." || { echo "postqueue недоступен."; exit 1; } ;;
    --disable)   _mail_disable ;;
    *) echo "Использование: $0 --configure|--status|--test <addr>|--queue|--flush|--disable" >&2; exit 2 ;;
esac
