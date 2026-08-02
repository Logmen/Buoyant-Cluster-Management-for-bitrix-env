#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_s3_external.sh — подключение ВНЕШНЕГО S3-хранилища к уже работающему кластеру.
#
# Отличие от слоя S3 (свои MinIO-ноды): хранилищем мы не управляем. Провайдер даёт
# бакет и ключи — всё. Поэтому здесь НЕТ установки MinIO, site replication,
# внутреннего CA, фронта :9000 на HAProxy и правок /etc/hosts: у внешнего провайдера
# публичный DNS и доверенный сертификат уже есть.
#
# Что делает: собирает параметры доступа, ПРОВЕРЯЕТ их против живого эндпоинта и
# записывает секцию [s3_upload] в cluster.conf. Дальше работают существующие
# механизмы: меню 11 регистрирует бакет в модуле «Облачные хранилища», а
# bcm_s3_storage_enabled разблокирует зависящие от хранилища пункты.
#
# ⚠️⚠️ Критичное требование к провайдеру — virtual-hosted-style (bucket.<host>).
# Модуль Bitrix clouds (CCloudStorageService_S3) строит адрес объекта ТОЛЬКО так и
# path-style не умеет. Провайдер, отдающий бакет исключительно по пути
# (<host>/bucket), для /upload не подойдёт — проверка это ловит до записи конфига.
#
# ⚠️ Ключи в argv не передаём (видны в ps) — mc получает их через stdin.
# =============================================================================

# Проба выполняется НА web-ноде: у неё есть mc и сетевой путь до провайдера, каким
# им будет пользоваться портал. Мозг-нода может иметь другой маршрут наружу.
_s3ext_web_ip() {
    local n
    for n in "${BCM_NODES_WEB[@]}"; do
        [[ -n "$n" ]] || continue
        local ip="${BCM_NODE_IP[$n]:-}"
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    done
    return 1
}

# MinIO Client. ⚠️ /usr/bin/mc на web-нодах — это Midnight Commander из bitrix-env,
# клиент S3 живёт ТОЛЬКО в /usr/local/bin/mc.
_S3EXT_MC="/usr/local/bin/mc"

_s3ext_ensure_mc() {
    local ip="$1"
    bcm_ssh_exec "$ip" "test -x ${_S3EXT_MC}" </dev/null && return 0
    bcm_warn "  На web-ноде нет ${_S3EXT_MC} — он нужен для проверки доступа и бэкапов."
    bcm_confirm "Скачать mc с dl.min.io на ноду?" || return 1
    bcm_ssh_exec_timeout "$ip" 120 \
        "curl -fsSL -o ${_S3EXT_MC} https://dl.min.io/client/mc/release/linux-amd64/mc && chmod +x ${_S3EXT_MC}" </dev/null
    bcm_ssh_exec "$ip" "test -x ${_S3EXT_MC}" </dev/null
}

# Полная проверка доступа. Печатает результат по шагам, возвращает 0, только если
# пройдено всё, без чего интеграция заведомо не заработает.
# Аргументы: ip endpoint region bucket access secret api_host
_s3ext_verify() {
    local ip="$1" endpoint="$2" region="$3" bucket="$4" access="$5" secret="$6" apihost="$7"
    local host="${apihost%%:*}"
    local fails=0

    # 1. TLS и доступность эндпоинта. Без -k: сертификат провайдера обязан быть
    # доверенным на ноде, иначе серверный прокси Bitrix не заберёт файл из облака.
    local code
    code=$(bcm_ssh_exec_timeout "$ip" 25 \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 15 '${endpoint}' 2>/dev/null || echo 000" </dev/null | tr -d '[:space:]')
    if [[ "$code" == "000" ]]; then
        bcm_error "  эндпоинт недоступен или сертификат не доверен: ${endpoint}"
        bcm_info  "    проверьте сеть с web-ноды и системные CA (update-ca-trust)"
        fails=$((fails+1))
    else
        bcm_ok "  эндпоинт отвечает (HTTP ${code}), TLS доверен"
    fi

    # 2. Ключи и бакет. ⚠️ Ключи НЕ передаём аргументами (видны в ps на ноде):
    # `mc alias set` без них запрашивает Access/Secret интерактивно — подаём со stdin.
    local alias_out
    alias_out=$(bcm_ssh_exec_timeout "$ip" 40 \
        "${_S3EXT_MC} alias set bcmext '${endpoint}' --api s3v4 >/dev/null 2>&1 \
         && ${_S3EXT_MC} ls 'bcmext/${bucket}' >/dev/null 2>&1 && echo LIST_OK || echo LIST_FAIL" \
        <<< "${access}
${secret}" | tr -d '[:space:]')
    if [[ "$alias_out" == *LIST_OK* ]]; then
        bcm_ok "  ключи приняты, бакет '${bucket}' читается"
    else
        bcm_error "  не удалось прочитать бакет '${bucket}' — проверьте ключи, имя бакета и регион"
        fails=$((fails+1))
    fi

    # 3. Запись/чтение/удаление: у Bitrix права только на чтение бессмысленны.
    local rw
    rw=$(bcm_ssh_exec_timeout "$ip" 60 \
        "t=/tmp/.bcm-s3probe.\$\$; echo bcm-probe > \$t
         ${_S3EXT_MC} cp -q \$t 'bcmext/${bucket}/.bcm-probe' >/dev/null 2>&1 || { echo PUT_FAIL; rm -f \$t; exit 0; }
         got=\$(${_S3EXT_MC} cat 'bcmext/${bucket}/.bcm-probe' 2>/dev/null)
         ${_S3EXT_MC} rm 'bcmext/${bucket}/.bcm-probe' >/dev/null 2>&1 || echo DEL_FAIL
         rm -f \$t
         [ \"\$got\" = 'bcm-probe' ] && echo RW_OK || echo GET_FAIL" </dev/null | tr -d '[:space:]')
    case "$rw" in
        *RW_OK*)    bcm_ok "  запись, чтение и удаление объекта работают" ;;
        *PUT_FAIL*) bcm_error "  нет прав на запись в бакет"; fails=$((fails+1)) ;;
        *)          bcm_error "  объект записан, но не прочитан/не удалён (${rw:-нет ответа})"; fails=$((fails+1)) ;;
    esac

    # 4. ⚠️ virtual-hosted-style — без него модуль clouds работать НЕ будет.
    # Достаточно, что имя резолвится и хост отвечает любым HTTP-статусом.
    local vh
    vh=$(bcm_ssh_exec_timeout "$ip" 25 \
        "getent hosts '${bucket}.${host}' >/dev/null 2>&1 && curl -s -o /dev/null -w '%{http_code}' --max-time 15 'https://${bucket}.${host}/' 2>/dev/null || echo 000" </dev/null | tr -d '[:space:]')
    if [[ "$vh" == "000" || -z "$vh" ]]; then
        bcm_error "  virtual-hosted-style НЕ работает: ${bucket}.${host} не резолвится или не отвечает"
        bcm_info  "    модуль Bitrix «Облачные хранилища» умеет ТОЛЬКО такой адрес —"
        bcm_info  "    с этим провайдером подключить /upload не получится"
        fails=$((fails+1))
    else
        bcm_ok "  virtual-hosted-style работает (${bucket}.${host} → HTTP ${vh})"
    fi

    # 5. Анонимное чтение — не блокирующее, но без него картинки в браузере не
    # откроются: clouds отдаёт прямые ссылки и подписанных URL не делает.
    local anon
    anon=$(bcm_ssh_exec_timeout "$ip" 40 \
        "t=/tmp/.bcm-s3anon.\$\$; echo anon > \$t
         ${_S3EXT_MC} cp -q \$t 'bcmext/${bucket}/.bcm-anon' >/dev/null 2>&1
         c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 'https://${bucket}.${host}/.bcm-anon' 2>/dev/null || echo 000)
         ${_S3EXT_MC} rm 'bcmext/${bucket}/.bcm-anon' >/dev/null 2>&1; rm -f \$t; echo \$c" </dev/null | tr -d '[:space:]')
    if [[ "$anon" == "200" ]]; then
        bcm_ok "  объекты читаются анонимно — браузер отдаст файлы из облака"
    else
        bcm_warn "  анонимное чтение недоступно (HTTP ${anon:-нет ответа})"
        bcm_info  "    попросите провайдера открыть бакету публичное чтение объектов,"
        bcm_info  "    иначе картинки и вложения не будут открываться в браузере"
    fi

    bcm_ssh_exec "$ip" "${_S3EXT_MC} alias rm bcmext >/dev/null 2>&1 || true" </dev/null
    [[ $fails -eq 0 ]]
}

# ──── Подключение внешнего хранилища ─────────────────────────────────────────
bcm_s3ext_setup() {
    bcm_section_header "Подключение внешнего S3-хранилища для /upload"

    if bcm_s3_enabled; then
        bcm_error "В кластере развёрнут собственный слой S3 — внешнее хранилище тут не нужно."
        bcm_any_key; return
    fi
    if bcm_s3_storage_enabled; then
        bcm_warn "Хранилище уже подключено: $(bcm_conf_get s3_upload endpoint) / $(bcm_conf_get s3_upload bucket)"
        bcm_confirm "Перенастроить?" || { bcm_info "Отменено."; bcm_any_key; return; }
    fi

    local ip
    ip=$(_s3ext_web_ip) || { bcm_error "Не найдена web-нода для проверки."; bcm_any_key; return; }
    _s3ext_ensure_mc "$ip" || { bcm_error "Без mc проверить доступ нельзя."; bcm_any_key; return; }

    bcm_info "Нужны данные от провайдера. Проверю их до записи в конфиг."
    echo
    local endpoint region bucket access secret apihost
    bcm_read_choice "Эндпоинт со схемой, например https://s3.provider.tld (0 — отмена)" endpoint
    [[ "${endpoint:-0}" == "0" || -z "${endpoint:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ "$endpoint" =~ ^https?:// ]] || { bcm_error "Эндпоинт должен начинаться с http:// или https://"; bcm_any_key; return; }
    if [[ "$endpoint" != https://* ]]; then
        bcm_warn "Эндпоинт без TLS: при https-портале серверная отдача облачных файлов сломается."
        bcm_confirm "Всё равно продолжить?" || { bcm_info "Отменено."; bcm_any_key; return; }
    fi
    bcm_read_choice "Имя бакета (0 — отмена)" bucket
    [[ "${bucket:-0}" == "0" || -z "${bucket:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    bcm_read_choice "Регион [us-east-1]" region; region="${region:-us-east-1}"
    bcm_read_choice "Access key (0 — отмена)" access
    [[ "${access:-0}" == "0" || -z "${access:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    # Скрытый ввод: секрет не должен остаться на экране и в истории терминала.
    printf "  %bSecret key:%b " "$BCM_COLOR_CYAN_BOLD" "$BCM_COLOR_RESET"
    read -r -s secret; echo
    [[ -z "${secret:-}" ]] && { bcm_error "Secret key пуст."; bcm_any_key; return; }

    # api_host — хост БЕЗ схемы, к нему модуль clouds приклеивает имя бакета слева.
    local defhost; defhost="$(printf '%s' "$endpoint" | sed -E 's#^https?://##; s#/.*$##')"
    bcm_read_choice "API host для админки, без схемы [${defhost}]" apihost
    apihost="${apihost:-$defhost}"

    echo
    bcm_info "Проверяю доступ с web-ноды (${ip})..."
    if ! _s3ext_verify "$ip" "$endpoint" "$region" "$bucket" "$access" "$secret" "$apihost"; then
        echo
        bcm_error "Проверка не пройдена — в конфиг ничего не записано."
        bcm_info "Исправьте замечания выше и повторите."
        bcm_any_key; return
    fi

    echo
    bcm_ok "Все обязательные проверки пройдены."
    bcm_confirm "Записать параметры в cluster.conf и включить облачное /upload?" \
        || { bcm_info "Отменено."; bcm_any_key; return; }

    local use_https="Y"; [[ "$endpoint" == http://* ]] && use_https="N"
    bcm_conf_set s3_upload bucket       "$bucket"
    bcm_conf_set s3_upload endpoint     "$endpoint"
    bcm_conf_set s3_upload region       "$region"
    bcm_conf_set s3_upload access_key   "$access"
    bcm_conf_set s3_upload secret_key   "$secret"
    bcm_conf_set s3_upload use_https    "$use_https"
    bcm_conf_set s3_upload api_host     "$apihost"
    bcm_conf_set s3_upload provider     "external"
    bcm_conf_sync 2>/dev/null || true
    bcm_ok "Параметры записаны и разосланы по узлам."

    echo
    bcm_info "Осталось два шага:"
    bcm_info "  1. Зарегистрировать бакет в портале — этот же раздел, пункт «Авто-регистрация»"
    bcm_info "     (или вручную по значениям из пункта «Показать значения для админки»)."
    bcm_info "  2. Снять зеркало /upload между web-нодами: меню 6 → 10. Оно нужно было только"
    bcm_info "     потому, что файлы лежали на дисках нод; с облаком оно лишь тратит место."
    bcm_warn "Зеркало снимайте ПОСЛЕ регистрации бакета и проверки загрузки файла в портале."
    bcm_any_key
}

# ──── Повторная проверка уже подключённого хранилища ─────────────────────────
bcm_s3ext_check() {
    bcm_section_header "Проверка доступа к S3-хранилищу"
    bcm_s3_storage_enabled || { bcm_error "Хранилище не подключено."; bcm_any_key; return; }

    local ip; ip=$(_s3ext_web_ip) || { bcm_error "Не найдена web-нода."; bcm_any_key; return; }
    _s3ext_ensure_mc "$ip" || { bcm_error "Нужен mc на web-ноде."; bcm_any_key; return; }

    local endpoint bucket region access secret apihost
    endpoint="$(bcm_conf_get s3_upload endpoint)"; bucket="$(bcm_conf_get s3_upload bucket)"
    region="$(bcm_conf_get s3_upload region)";     access="$(bcm_conf_get s3_upload access_key)"
    secret="$(bcm_conf_get s3_upload secret_key)"; apihost="$(bcm_conf_get s3_upload api_host)"
    [[ -z "$apihost" ]] && apihost="$(printf '%s' "$endpoint" | sed -E 's#^https?://##; s#/.*$##')"

    bcm_info "${endpoint} / бакет ${bucket} (регион ${region})"
    echo
    if _s3ext_verify "$ip" "$endpoint" "$region" "$bucket" "$access" "$secret" "$apihost"; then
        echo; bcm_ok "Хранилище доступно и пригодно для /upload."
    else
        echo; bcm_error "Есть проблемы — облачное /upload будет работать неверно."
    fi
    bcm_any_key
}
