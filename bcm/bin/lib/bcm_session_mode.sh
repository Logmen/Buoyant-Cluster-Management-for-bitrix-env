#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181
# =============================================================================
# bcm_session_mode.sh — режим сессий Bitrix на всех web-нодах: default | separated.
#
#   bcm_session_mode.sh --status
#   bcm_session_mode.sh --set separated [--debug]   перевести кластер в separated
#   bcm_session_mode.sh --set default               вернуть default (crypto_key остаётся)
#   bcm_session_mode.sh --debug on|off              отладка режима (заголовки X-Session-*)
#   bcm_session_mode.sh --restore <метка>           вернуть файлы из бэкапа как были
#
# Зачем. В режиме default основная сессия лежит в redis с БЛОКИРОВКОЙ: запросы
# одной сессии выполняются строго по одному. А цикл ожидания блокировки в ядре
# (RedisSessionHandler::lock) удваивает паузу со 100 мкс, пока она не превысит
# секунду, — дальше ждущий проверяет замок раз в 1,64 с, даже если тот давно
# свободен. Клиент, пославший разом десятки запросов (десктоп-приложение
# открывает чат с картинками), получает очередь «один запрос в 1,6 с», а всё,
# что не дождалось 59 с, — «Unable to get session lock within 60 seconds» и 500.
# Ловили вживую на crm.onelab.kz 29.09.2026: 40 картинок, хвост из 8 ответов 500.
#
# В режиме separated авторизация живёт в зашифрованной cookie (kernel =>
# encrypted_cookies), а основная сессия стартует ЛЕНИВО — только когда код
# реально трогает $_SESSION. Запросам, которым нужна одна авторизация, очередь
# на замке больше не грозит.
#
# ⚠️⚠️ Почему это отдельная команда, а не правка .settings.php руками:
#   • кластерные секции (connections, cache, session, messenger, crypto) ДЕРЖИТ
#     bcm_settings_guard.sh: они продублированы в .settings_extra.php, который
#     Битрикс накладывает ПОВЕРХ .settings.php. Правка одного .settings.php не
#     меняет НИЧЕГО, пока страж не переснимет эталон (--install);
#   • эталон у стража СВОЙ на каждой ноде, а оба файла уезжают lsyncd'ом с
#     источника на остальные ноды. Переснять на одной ноде — получить ноды в
#     разных режимах: страж второй ноды вернёт ей старое наложение;
#   • без crypto_key encrypted_cookies бросает исключение на каждом хите —
#     сайт ложится целиком. Ключ создаётся здесь, если его нет, и тоже
#     охраняется стражем (секция crypto);
#   • crypto_key подмешивается в ключ подписи (Security\Sign\Signer): его
#     появление инвалидирует подписанные параметры в открытых вкладках —
#     пользователям нужно обновить страницу. Поэтому --set default ключ НЕ
#     удаляет: второй раз ломать вкладки незачем, в default он безвреден.
#
# Порядок: правка .settings.php на источнике lsyncd → ожидание доставки на
# остальные web-ноды → --install стража сначала на них, потом на источнике →
# сверка наложений на всех нодах и HTTP-проверка. Бэкапы — в
# /var/backups/bcm-session/<метка>/ на каждой ноде.
# =============================================================================
set -uo pipefail

BCM_BASE_DIR="${BCM_BASE_DIR:-/opt/bcm}"
BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"
source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"

SITE_ROOT="${SITE_ROOT:-/home/bitrix/www}"
SETTINGS="${SITE_ROOT}/bitrix/.settings.php"
EXTRA="${SITE_ROOT}/bitrix/.settings_extra.php"
GUARD="/opt/bcm/bin/lib/bcm_settings_guard.sh"
REFERENCE="/etc/bitrix-cluster/settings-cluster.php"
BACKUP_ROOT="/var/backups/bcm-session"
SYNC_TIMEOUT=120

_sm_die() { bcm_error "$*"; exit 1; }

# ──── Узлы ───────────────────────────────────────────────────────────────────
declare -a SM_WEB=()      # "имя ip" всех web-нод
SM_SRC_NAME=""; SM_SRC_IP=""

_sm_nodes() {
    bcm_load_topology || _sm_die "не удалось прочитать топологию"
    local n ip
    for n in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$n]:-}"; [[ -n "$ip" ]] || continue
        SM_WEB+=("$n $ip")
    done
    [[ ${#SM_WEB[@]} -gt 0 ]] || _sm_die "в топологии нет web-нод"
    # Источник lsyncd — та нода, где активен ОСНОВНОЙ lsyncd (код). Править
    # .settings.php можно только там: на остальных правку перетрёт синхронизация.
    local row cnt=0
    for row in "${SM_WEB[@]}"; do
        read -r n ip <<< "$row"
        if [[ "$(bcm_ssh_exec_timeout "$ip" 10 "systemctl is-active lsyncd 2>/dev/null" </dev/null)" == "active" ]]; then
            SM_SRC_NAME="$n"; SM_SRC_IP="$ip"; cnt=$((cnt+1))
        fi
    done
    [[ $cnt -eq 1 ]] || _sm_die "источник lsyncd не определён однозначно (активен на ${cnt} web-нодах) — правка небезопасна"
}

# md5 файла на ноде ('' — нет файла или нода не ответила)
_sm_md5() { bcm_ssh_exec_timeout "$1" 15 "md5sum '$2' 2>/dev/null | cut -d' ' -f1" </dev/null; }

# Разбор session/crypto из файла настроек на ноде: одна строка key=value.
_sm_describe() {
    local ip="$1" file="$2"
    bcm_ssh_exec_timeout "$ip" 20 "php -r '
        \$s = @include \$argv[1]; if (!is_array(\$s)) { echo \"нечитаем\"; exit; }
        \$v = \$s[\"session\"][\"value\"] ?? [];
        printf(\"mode=%s kernel=%s general=%s debug=%s crypto=%s\",
            \$v[\"mode\"] ?? \"-\", \$v[\"handlers\"][\"kernel\"] ?? \"-\",
            isset(\$v[\"handlers\"][\"general\"][\"host\"]) ? \$v[\"handlers\"][\"general\"][\"type\"].\"@\".\$v[\"handlers\"][\"general\"][\"host\"] : \"-\",
            \$v[\"debug\"] ?? \"-\", empty(\$s[\"crypto\"][\"value\"][\"crypto_key\"]) ? \"нет\" : \"есть\");
    ' '$file' 2>/dev/null" </dev/null
}

# ──── Состояние ──────────────────────────────────────────────────────────────
_sm_status() {
    _sm_nodes
    bcm_info "Источник lsyncd (здесь правится .settings.php): ${SM_SRC_NAME} (${SM_SRC_IP})"
    local row n ip
    for row in "${SM_WEB[@]}"; do
        read -r n ip <<< "$row"
        echo "  ── ${n} (${ip})"
        echo "     .settings.php:        $(_sm_describe "$ip" "$SETTINGS")"
        echo "     .settings_extra.php:  $(_sm_describe "$ip" "$EXTRA")   ← действует"
        echo "     наложение = эталон:   $(bcm_ssh_exec_timeout "$ip" 10 "cmp -s '$EXTRA' '$REFERENCE' && echo да || echo НЕТ" </dev/null)"
        echo "     страж охраняет crypto: $(bcm_ssh_exec_timeout "$ip" 10 "grep -qE '^GUARDED_SECTIONS=.*crypto' '$GUARD' && echo да || echo 'НЕТ — обновите BCM'" </dev/null)"
    done
}

# ──── Предпроверки ───────────────────────────────────────────────────────────
_sm_preflight() {
    local row n ip src_md5 md5 bad=0
    src_md5="$(_sm_md5 "$SM_SRC_IP" "$SETTINGS")"
    [[ -n "$src_md5" ]] || _sm_die "на ${SM_SRC_NAME} нет ${SETTINGS}"
    for row in "${SM_WEB[@]}"; do
        read -r n ip <<< "$row"
        bcm_ssh_exec_timeout "$ip" 10 "grep -qE '^GUARDED_SECTIONS=.*crypto' '$GUARD'" </dev/null \
            || { bcm_error "${n}: страж не охраняет crypto — сначала bcm --update"; bad=1; }
        md5="$(_sm_md5 "$ip" "$SETTINGS")"
        [[ "$md5" == "$src_md5" ]] || { bcm_error "${n}: .settings.php расходится с источником — lsyncd отстаёт или сломан"; bad=1; }
        bcm_ssh_exec_timeout "$ip" 10 "cmp -s '$EXTRA' '$REFERENCE'" </dev/null \
            || { bcm_error "${n}: наложение не совпадает с эталоном стража — сначала разберитесь с ним (--status)"; bad=1; }
    done
    [[ $bad -eq 0 ]] || _sm_die "предпроверки не пройдены — ничего не менял"
    bcm_ok "Предпроверки пройдены: страж свежий, файлы на всех web-нодах одинаковые."
}

# ──── Бэкап ──────────────────────────────────────────────────────────────────
SM_TS=""
_sm_backup() {
    SM_TS="$(date +%Y%m%d-%H%M%S)"
    local row n ip
    for row in "${SM_WEB[@]}"; do
        read -r n ip <<< "$row"
        bcm_ssh_exec_timeout "$ip" 20 "d='${BACKUP_ROOT}/${SM_TS}'; mkdir -p \"\$d\" && chmod 700 '${BACKUP_ROOT}' \"\$d\"
            cp -a '$SETTINGS' \"\$d/settings.php\" && cp -a '$EXTRA' \"\$d/settings_extra.php\" && cp -a '$REFERENCE' \"\$d/settings-cluster.php\"" </dev/null \
            || _sm_die "${n}: бэкап не удался — ничего не менял"
    done
    bcm_ok "Бэкап на всех web-нодах: ${BACKUP_ROOT}/${SM_TS}/"
}

# ──── Правка на источнике ────────────────────────────────────────────────────
# $1: separated|default|keep   $2: on|off|keep (отладка)
_sm_edit_source() {
    local mode="$1" debug="$2" php_tmp; php_tmp="$(mktemp)"
    cat > "$php_tmp" <<'PHP'
<?php
[$self, $file, $mode, $debug] = $argv;
$s = include $file;
if (!is_array($s) || empty($s['session']['value']['handlers']['general'])) { fwrite(STDERR, "нет секции session с обработчиком general\n"); exit(2); }
$v = &$s['session']['value'];
if ($mode === 'separated') {
    if (empty($s['crypto']['value']['crypto_key'])) {
        $s['crypto'] = ['value' => ['crypto_key' => bin2hex(random_bytes(16))], 'readonly' => true];
        echo "crypto_key создан\n";
    }
    $v['mode'] = 'separated';
    $v['handlers']['kernel'] = 'encrypted_cookies';
} elseif ($mode === 'default') {
    $v['mode'] = 'default';
    unset($v['handlers']['kernel']);   // crypto остаётся: см. шапку скрипта
}
if ($debug === 'on')  { $v['debug'] = 2; }          // Debugger::TO_HEADER — X-Session-Conf/Usage
if ($debug === 'off') { unset($v['debug']); }
unset($v);
$tmp = $file . '.bcm-new';
if (file_put_contents($tmp, "<?php\nreturn " . var_export($s, true) . ";\n", LOCK_EX) === false) { fwrite(STDERR, "запись не удалась\n"); exit(3); }
echo "ok\n";
PHP
    bcm_ssh_copy_file "$php_tmp" "$SM_SRC_IP" "/tmp/bcm-session-edit.php" || { rm -f "$php_tmp"; _sm_die "не скопировать правщик на ${SM_SRC_NAME}"; }
    rm -f "$php_tmp"
    local out
    # Временный файл → php -l → владелец/права как у оригинала → атомарная замена.
    out="$(bcm_ssh_exec_timeout "$SM_SRC_IP" 30 "php /tmp/bcm-session-edit.php '$SETTINGS' '$mode' '$debug' 2>&1 && php -l '${SETTINGS}.bcm-new' >/dev/null 2>&1 \
        && chown --reference='$SETTINGS' '${SETTINGS}.bcm-new' && chmod --reference='$SETTINGS' '${SETTINGS}.bcm-new' \
        && mv -f '${SETTINGS}.bcm-new' '$SETTINGS' && echo ЗАМЕНЁН; rc=\$?; rm -f /tmp/bcm-session-edit.php '${SETTINGS}.bcm-new'; exit \$rc" </dev/null)"
    printf '%s\n' "$out" | sed 's/^/    /'
    [[ "$out" == *ЗАМЕНЁН* ]] || _sm_die "правка .settings.php на ${SM_SRC_NAME} не прошла — файл не тронут"
}

# ──── Доставка и пересъёмка эталонов ─────────────────────────────────────────
_sm_propagate() {
    local src_md5 row n ip waited=0 pending
    src_md5="$(_sm_md5 "$SM_SRC_IP" "$SETTINGS")"
    bcm_info "Жду, пока lsyncd доставит .settings.php на остальные web-ноды…"
    while :; do
        pending=""
        for row in "${SM_WEB[@]}"; do
            read -r n ip <<< "$row"
            [[ "$n" == "$SM_SRC_NAME" ]] && continue
            [[ "$(_sm_md5 "$ip" "$SETTINGS")" == "$src_md5" ]] || pending+="${n} "
        done
        [[ -z "$pending" ]] && break
        (( waited >= SYNC_TIMEOUT )) && _sm_die "за ${SYNC_TIMEOUT} с не доехало до: ${pending}— эталоны НЕ переснимал, действует прежний режим. Откат файла: --restore ${SM_TS}"
        sleep 2; waited=$((waited+2))
    done
    bcm_ok "  доставлено (${waited} с)"

    # Сначала ноды-приёмники, источник последним: его новое наложение уедет
    # lsyncd'ом на приёмники, и там оно должно совпасть с УЖЕ новым эталоном —
    # иначе их страж откатит его к старому.
    local order=()
    for row in "${SM_WEB[@]}"; do read -r n ip <<< "$row"; [[ "$n" == "$SM_SRC_NAME" ]] || order+=("$row"); done
    order+=("${SM_SRC_NAME} ${SM_SRC_IP}")
    for row in "${order[@]}"; do
        read -r n ip <<< "$row"
        bcm_ssh_exec_timeout "$ip" 60 "'$GUARD' --install >/dev/null 2>&1" </dev/null \
            && bcm_ok "  ${n}: эталон стража переснят, наложение обновлено" \
            || _sm_die "${n}: --install стража не прошёл — ноды могут быть в разных режимах, откат: --restore ${SM_TS}"
    done
}

# ──── Проверка ───────────────────────────────────────────────────────────────
_sm_verify() {
    local want_mode="$1" row n ip md5 first="" desc dom code hdr bad=0
    sleep 3   # дать lsyncd довезти наложение с источника
    dom="$(bcm_conf_get network portal_domain 2>/dev/null || echo '')"
    for row in "${SM_WEB[@]}"; do
        read -r n ip <<< "$row"
        md5="$(_sm_md5 "$ip" "$EXTRA")"; [[ -z "$first" ]] && first="$md5"
        desc="$(_sm_describe "$ip" "$EXTRA")"
        [[ "$md5" == "$first" ]] || { bcm_error "${n}: наложение отличается от других нод"; bad=1; }
        [[ "$desc" == *"mode=${want_mode} "* ]] || { bcm_error "${n}: действует не тот режим: ${desc}"; bad=1; }
        if [[ -n "$dom" ]]; then
            code="$(bcm_ssh_exec_timeout "$ip" 20 "curl -sk -o /dev/null -w '%{http_code}' -m 15 --resolve '${dom}:443:127.0.0.1' 'https://${dom}/'" </dev/null)"
            hdr="$(bcm_ssh_exec_timeout "$ip" 20 "curl -sk -I -m 15 --resolve '${dom}:443:127.0.0.1' 'https://${dom}/' | grep -i '^x-session-conf' | tr -d '\r'" </dev/null)"
            [[ "$code" =~ ^[23] ]] || { bcm_error "${n}: сайт ответил HTTP ${code:-нет ответа}"; bad=1; }
        fi
        echo "  ${n}: ${desc}  · сайт HTTP ${code:-?}${hdr:+ · ${hdr}}"
    done
    [[ $bad -eq 0 ]] && bcm_ok "Режим ${want_mode} действует на всех web-нодах." \
                     || bcm_warn "Есть расхождения — смотрите выше; вернуть как было: --restore ${SM_TS}"
    [[ $bad -eq 0 ]]
}

# ──── Возврат файлов из бэкапа ───────────────────────────────────────────────
_sm_restore() {
    local ts="$1" row n ip
    [[ "$ts" =~ ^[0-9]{8}-[0-9]{6}$ ]] || _sm_die "метка бэкапа вида 20260929-203000"
    _sm_nodes
    bcm_ssh_exec_timeout "$SM_SRC_IP" 10 "test -f '${BACKUP_ROOT}/${ts}/settings.php'" </dev/null \
        || _sm_die "на ${SM_SRC_NAME} нет бэкапа ${BACKUP_ROOT}/${ts}/"
    bcm_ssh_exec_timeout "$SM_SRC_IP" 20 "cp -a '${BACKUP_ROOT}/${ts}/settings.php' '${SETTINGS}.bcm-new' && mv -f '${SETTINGS}.bcm-new' '$SETTINGS'" </dev/null \
        || _sm_die "не удалось вернуть .settings.php на ${SM_SRC_NAME}"
    bcm_ok ".settings.php на ${SM_SRC_NAME} возвращён из ${ts}"
    SM_TS="$ts"
    _sm_propagate
    local mode; mode="$(_sm_describe "$SM_SRC_IP" "$SETTINGS" | sed -n 's/^mode=\([a-z]*\).*/\1/p')"
    _sm_verify "${mode:-default}"
}

# ──── Точка входа ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || _sm_die "нужны права root"
case "${1:---status}" in
    --status) _sm_status ;;
    --set)
        mode="${2:-}"; dbg="keep"
        [[ "$mode" == "separated" || "$mode" == "default" ]] || _sm_die "--set separated|default"
        [[ "${3:-}" == "--debug" ]] && dbg="on"
        _sm_nodes; _sm_preflight; _sm_backup
        bcm_info "Правлю .settings.php на ${SM_SRC_NAME}: режим ${mode}$([[ $dbg == on ]] && echo ', отладка в заголовках')"
        _sm_edit_source "$mode" "$dbg"
        _sm_propagate
        _sm_verify "$mode"; rc=$?
        echo
        bcm_info "Вернуть как было: $(basename "$0") --restore ${SM_TS}"
        [[ "$mode" == "separated" ]] && bcm_warn "Открытые вкладки портала нужно обновить: crypto_key меняет ключ подписи параметров."
        exit $rc
        ;;
    --debug)
        dbg="${2:-}"; [[ "$dbg" == "on" || "$dbg" == "off" ]] || _sm_die "--debug on|off"
        _sm_nodes; _sm_preflight; _sm_backup
        _sm_edit_source keep "$dbg"
        _sm_propagate
        mode="$(_sm_describe "$SM_SRC_IP" "$SETTINGS" | sed -n 's/^mode=\([a-z]*\).*/\1/p')"
        _sm_verify "${mode:-default}"
        ;;
    --restore) _sm_restore "${2:-}" ;;
    *)
        echo "Использование: $(basename "$0") --status | --set separated [--debug] | --set default | --debug on|off | --restore <метка>"
        exit 1
        ;;
esac
