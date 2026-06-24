#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 11_cloud_storage.sh — Облачное хранилище /upload (MinIO S3)
#
# Уводит пользовательские файлы Bitrix (/upload) в общий MinIO S3 через модуль
# «Облачные хранилища», чтобы файлы не расходились между web-нодами (см. также
# харднинг lsyncd: код синкается, /upload — нет). Параметры — из [s3_upload]
# в cluster.conf (заполняется install.sh).
#
# Надёжная часть (всегда работает): проверка связи + готовые значения для
# админки. Авто-регистрация бакета — best-effort (cloud_seeder.php), т.к. точная
# структура настроек модуля зависит от редакции Bitrix.
# =============================================================================
set -euo pipefail

BCM_BASE_DIR="${BCM_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"

source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"

if ! bcm_conf_exists; then
    bcm_error "cluster.conf не найден. Запустите install.sh."
    exit 1
fi
bcm_load_topology

# ──── Параметры из [s3_upload] ───────────────────────────────────────────────
S3U_BUCKET="$(bcm_conf_get s3_upload bucket 2>/dev/null || echo bitrix-upload)"
S3U_ENDPOINT="$(bcm_conf_get s3_upload endpoint 2>/dev/null || echo '')"
S3U_REGION="$(bcm_conf_get s3_upload region 2>/dev/null || echo us-east-1)"
S3U_ACCESS="$(bcm_conf_get s3_upload access_key 2>/dev/null || echo '')"
S3U_SECRET="$(bcm_conf_get s3_upload secret_key 2>/dev/null || echo '')"
# api_host — virtual-host имя для модуля clouds (bucket.<api_host>); БЕЗ http://.
# Падать назад на хост из endpoint, если api_host не задан (старые конфиги).
S3U_APIHOST="$(bcm_conf_get s3_upload api_host 2>/dev/null || echo '')"
[[ -z "$S3U_APIHOST" ]] && S3U_APIHOST="$(printf '%s' "$S3U_ENDPOINT" | sed -E 's#^https?://##')"
# MinIO работает по HTTPS (TLS терминирует сам MinIO; серт доверен через CA) — иначе
# серверный прокси Bitrix при https-портале не отдаёт облачные файлы (ERR_HTTP2_PROTOCOL_ERROR).
# По умолчанию Y (включая старые конфиги без ключа).
S3U_USE_HTTPS="$(bcm_conf_get s3_upload use_https 2>/dev/null || echo Y)"
[[ -z "$S3U_USE_HTTPS" ]] && S3U_USE_HTTPS="Y"
S3U_DOCROOT="/home/bitrix/www"

# Активная нода (single-active) или первый web
_cs_target_node() {
    local a
    a=$(bcm_get_active_node 2>/dev/null || echo '')
    if [[ -n "$a" && -n "${BCM_NODE_IP[$a]:-}" ]]; then echo "$a"; else echo "${BCM_NODES_WEB[0]:-}"; fi
}

# ──── Готовые значения для ручной настройки ──────────────────────────────────
_cs_print_values() {
    bcm_section_header "Облачное хранилище — значения для админки Bitrix"
    bcm_info "Настройки → Облачные хранилища → Добавить хранилище → Amazon S3 (S3-совместимое):"
    echo
    printf "  %s %s\n" "$(bcm_pad 'Провайдер:' 22)"         "S3 compatible storage"
    printf "  %s %s\n" "$(bcm_pad 'Контейнер (Bucket):' 22)" "$S3U_BUCKET"
    printf "  %s %s\n" "$(bcm_pad 'Имя сервера (API):' 22)"  "$S3U_APIHOST"
    printf "  %s %s\n" "$(bcm_pad 'Регион (Location):' 22)" "$S3U_REGION"
    printf "  %s %s\n" "$(bcm_pad 'Ключ доступа:' 22)"      "$S3U_ACCESS"
    printf "  %s %s\n" "$(bcm_pad 'Секретный ключ:' 22)"    "${S3U_SECRET:0:4}••••(скрыт)"
    printf "  %s %s\n" "$(bcm_pad 'HTTPS:' 22)"             "$([[ "$S3U_USE_HTTPS" == Y ]] && echo 'Да (MinIO TLS, серт доверен через CA)' || echo 'Нет')"
    printf "  %s %s\n" "$(bcm_pad 'CNAME:' 22)"             "(пусто)"
    echo
    bcm_warn "«Имя сервера» — БЕЗ http:// и без бакета (модуль сам строит bucket.<API>)."
    bcm_warn "Модуль clouds работает ТОЛЬКО virtual-host + подпись V4 → Регион обязателен."
    bcm_warn "Во вкладке «Правила» — хранить ВСЕ файлы (пустой модуль). Иначе Disk-файлы"
    bcm_warn "(.docx/.pdf) осядут локально → генератор документов/просмотр выдаст 404."
    bcm_info "Это имя резолвится на web-нодах в /etc/hosts на S3-VIP; MinIO MINIO_DOMAIN совпадает."
    bcm_info "После добавления: отметьте хранилище активным и включите перенос новых файлов."
    bcm_info "resize_cache оставьте локальным (не переносить в облако)."
    echo
    bcm_any_key
}

# ──── Проверка связи с MinIO с целевой web-ноды ──────────────────────────────
_cs_test_conn() {
    bcm_section_header "Проверка связи web-ноды с MinIO"
    local node ip
    node=$(_cs_target_node); ip="${BCM_NODE_IP[$node]:-}"
    if [[ -z "$ip" ]]; then bcm_error "Не найдена web-нода."; bcm_any_key; return; fi

    bcm_info "Нода: ${node} (${ip}), endpoint: ${S3U_ENDPOINT}"
    echo
    local health
    health=$(bcm_ssh_exec_timeout "$ip" 10 \
        "curl -sf -o /dev/null -w '%{http_code}' '${S3U_ENDPOINT}/minio/health/live' 2>/dev/null || echo 000" \
        2>/dev/null | tr -d '[:space:]')
    if [[ "$health" == "200" ]]; then
        bcm_ok "MinIO health-endpoint доступен (HTTP 200)."
    else
        bcm_warn "MinIO health-endpoint недоступен (код: ${health}). Проверьте VIP/HAProxy S3 и firewall."
    fi
    echo
    bcm_any_key
}

# ──── Авто-регистрация бакета (best-effort) ──────────────────────────────────
_cs_register() {
    bcm_section_header "Регистрация бакета как облачного хранилища (авто)"
    local node ip
    node=$(_cs_target_node); ip="${BCM_NODE_IP[$node]:-}"
    if [[ -z "$ip" ]]; then bcm_error "Не найдена web-нода."; bcm_any_key; return; fi

    if [[ -z "$S3U_ENDPOINT" || -z "$S3U_ACCESS" || -z "$S3U_SECRET" ]]; then
        bcm_error "Не заданы параметры [s3_upload] в cluster.conf (endpoint/access/secret)."
        bcm_any_key; return
    fi

    bcm_warn "Точная структура настроек модуля зависит от редакции Bitrix — это best-effort."
    bcm_info "Цель: ${node} (${ip}), docroot ${S3U_DOCROOT}, бакет ${S3U_BUCKET}."
    if ! bcm_confirm "Запустить авто-регистрацию на ${node}?"; then
        bcm_info "Отменено."; bcm_any_key; return
    fi

    bcm_ssh_copy_file "${BCM_BASE_DIR}/templates/cloud_seeder.php" "$ip" "/tmp/bcm_cloud_seeder.php"
    local out
    out=$(bcm_ssh_exec_timeout "$ip" 60 \
        "BX_DOCROOT='${S3U_DOCROOT}' BX_S3_APIHOST='${S3U_APIHOST}' BX_S3_BUCKET='${S3U_BUCKET}' \
         BX_S3_REGION='${S3U_REGION}' BX_S3_ACCESS='${S3U_ACCESS}' BX_S3_SECRET='${S3U_SECRET}' \
         BX_S3_USE_HTTPS='${S3U_USE_HTTPS}' \
         php /tmp/bcm_cloud_seeder.php 2>&1; rm -f /tmp/bcm_cloud_seeder.php" \
        2>/dev/null)

    echo
    echo "$out" | while IFS= read -r line; do echo "    $line"; done
    echo
    case "$out" in
        *RESULT=OK*)                   bcm_ok "Бакет зарегистрирован и проверен записью. /upload будет уходить в S3." ;;
        *RESULT=ALREADY_EXISTS*)       bcm_ok "Бакет уже зарегистрирован — ок." ;;
        *RESULT=ADDED_BUT_TEST_FAILED*) bcm_warn "Бакет добавлен, но тестовая запись не прошла. Проверьте endpoint/ключи (см. ручные значения)." ;;
        *RESULT=NO_KERNEL*)            bcm_warn "На ноде нет ядра Bitrix (портал ещё не развёрнут). Сначала перенесите портал." ;;
        *RESULT=NO_CLOUDS_MODULE*)     bcm_warn "Модуль 'clouds' недоступен/не ставится. Установите модуль и повторите, либо настройте вручную." ;;
        *)                             bcm_warn "Не удалось автоматически. Используйте ручные значения (пункт 1)." ;;
    esac
    echo
    bcm_info "Если авто не сработало — пункт «Показать значения для админки» даёт всё для ручной настройки."
    bcm_any_key
}

# ──── Меню ───────────────────────────────────────────────────────────────────
_cs_menu() {
    while true; do
        bcm_section_header "Облачное хранилище /upload (MinIO S3)"
        bcm_info "Бакет: ${S3U_BUCKET}  Endpoint: ${S3U_ENDPOINT}"
        local items=(
            "1.  Показать значения для админки (надёжно)"
            "2.  Проверить связь web→MinIO"
            "3.  Авто-регистрация бакета (best-effort, нужен портал)"
            "0.  Назад"
        )
        bcm_print_menu items
        local choice
        bcm_read_choice "Ваш выбор" choice
        case "$choice" in
            1) _cs_print_values ;;
            2) _cs_test_conn ;;
            3) _cs_register ;;
            0) return 0 ;;
            "") : ;;
            *) bcm_warn "Неверный выбор." ;;
        esac
    done
}

_cs_menu
