#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155
# =============================================================================
# bcm_portal_hosts.sh — записи /etc/hosts, без которых портал работает неверно
#
# Держит на web-ноде две записи, которые обязаны существовать локально:
#
# 1) 127.0.0.1 <portal_domain>
#    Bitrix «Проверка системы» (site_check_exec и другие серверные self-запросы)
#    создаёт временный файл на ноде админ-сессии, а затем дёргает домен портала
#    серверным HTTP-запросом. Если домен резолвится в VIP, round-robin уводит
#    запрос на ДРУГУЮ web-ноду, где файла ещё нет (lsyncd не успел) → 404,
#    check_exec: Fail. Браузеров администраторов это не касается — они ходят
#    через реальный DNS на VIP.
#
# 2) <transformer_vip> default
#    Модуль transformercontroller и воркеры конвертации подключаются к RabbitMQ
#    по имени 'default' (так его прописывает bitrix-env). В кластере это имя
#    указывает на плавающий TRANSFORMER_VIP, чтобы клиенты всегда приходили к
#    брокеру текущего держателя VIP. Без записи генератор документов и просмотр
#    документов не работают вовсе — подключиться некуда.
#
# ⚠️⚠️ Записи затираются, и одной установки НЕ хватает:
#   * cloud-init переписывает /etc/hosts на КАЖДОЙ загрузке — модуль
#     update_etc_hosts входит в cloud_init_modules, файл возвращается к шаблону
#     (проверено вживую: mtime /etc/hosts совпадает со временем cloud-init.service);
#   * ansible bitrix-env перезаписывает свой блок, а при некоторых операциях и
#     весь файл целиком.
# Поэтому assert дёргается из ДВУХ мест: boot-юнит bcm-portal-hosts.service
# (сразу после cloud-init, до сервисов-потребителей) и guard
# /etc/cron.d/bcm-portal-hosts-guard раз в 10 минут. Только guard'а мало —
# после перезагрузки оставалось окно до 10 минут, в котором генератор
# документов не находил RabbitMQ. Записи ставятся ПЕРЕД маркером
# '# ANSIBLE MANAGED BLOCK', если он есть.
#
# Режимы:
#   assert  — дописать недостающие записи (идемпотентно); тихий, для cron
#   check   — только проверить: rc=0 всё на месте, rc=1 чего-то нет
#   show    — показать состояние по каждой записи для оператора
# =============================================================================
set -uo pipefail

MODE="${1:-assert}"
HOSTS_FILE="${BCM_HOSTS_FILE:-/etc/hosts}"
CONF_FILE="${BCM_CONF_FILE:-/etc/bitrix-cluster/cluster.conf}"
LOG_FILE="/var/log/bcm/portal_hosts.log"
ANSIBLE_MARK='# ANSIBLE MANAGED BLOCK'

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [${MODE}] $*" >> "$LOG_FILE" 2>/dev/null; }

# Значение ключа из секции cluster.conf. Отдельный парсер, а не bcm_config.sh:
# скрипт зовётся из cron и из notify, без окружения BCM.
_conf_get() {
    local want_section="$1" want_key="$2"
    [[ -r "$CONF_FILE" ]] || return 1
    awk -v s="$want_section" -v k="$want_key" -F= '
        /^[[:space:]]*\[/ { section = $0; gsub(/[][[:space:]]/, "", section); next }
        section == s {
            key = $1; gsub(/[[:space:]]/, "", key)
            if (key == k) { sub(/^[^=]*=/, "", $0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print; exit }
        }
    ' "$CONF_FILE"
}

# Есть ли запись «<ip> <name>» (имя как отдельное слово в нужной строке)
_entry_present() {
    local ip="$1" name="$2"
    grep -qE "^[[:space:]]*${ip//./\\.}[[:space:]]+([^#]*[[:space:]])?${name//./\\.}([[:space:]]|$)" \
        "$HOSTS_FILE" 2>/dev/null
}

_assert_entry() {
    local ip="$1" name="$2"
    _entry_present "$ip" "$name" && return 0

    cp -n "$HOSTS_FILE" "${HOSTS_FILE}.bcm-bak" 2>/dev/null
    # Прежние (неверные — например, на старый VIP) записи этого имени убираем,
    # иначе резолвер получит два конфликтующих ответа.
    sed -i "/[[:space:]]${name//./\\.}\([[:space:]]\|$\)/d" "$HOSTS_FILE" 2>/dev/null
    if grep -q "$ANSIBLE_MARK" "$HOSTS_FILE" 2>/dev/null; then
        sed -i "/${ANSIBLE_MARK}/i ${ip} ${name}" "$HOSTS_FILE"
    else
        echo "${ip} ${name}" >> "$HOSTS_FILE"
    fi

    if _entry_present "$ip" "$name"; then
        log "восстановлена запись ${ip} ${name}"
        return 0
    fi
    log "ОШИБКА: не удалось записать ${ip} ${name} в ${HOSTS_FILE}"
    return 1
}

# Набор обязательных записей: «ip имя описание»
_wanted_entries() {
    local dom vip
    dom="$(_conf_get network portal_domain)"
    [[ -n "${dom:-}" ]] && echo "127.0.0.1|${dom}|домен портала (self-check'и Bitrix)"
    # Транформер настраивается отдельным пунктом меню и есть не всегда.
    vip="$(_conf_get transformer vip)"
    [[ -n "${vip:-}" ]] && echo "${vip}|default|RabbitMQ генератора документов"
    return 0
}

rc=0
had_any=0
while IFS='|' read -r e_ip e_name e_desc; do
    [[ -z "${e_ip:-}" ]] && continue
    had_any=1
    case "$MODE" in
        assert)
            _assert_entry "$e_ip" "$e_name" || rc=1
            ;;
        check)
            _entry_present "$e_ip" "$e_name" || rc=1
            ;;
        show)
            if _entry_present "$e_ip" "$e_name"; then
                echo "OK: ${e_name} → ${e_ip}  (${e_desc})"
            else
                echo "ОТСУТСТВУЕТ: ${e_name} → ${e_ip}  (${e_desc})"
                rc=1
            fi
            ;;
        *)
            echo "Использование: $0 {assert|check|show}" >&2
            exit 2
            ;;
    esac
done < <(_wanted_entries)

if [[ "$had_any" -eq 0 ]]; then
    [[ "$MODE" == "assert" ]] || echo "В ${CONF_FILE} нет ни portal_domain, ни transformer.vip — проверять нечего"
    exit 0
fi

exit "$rc"
