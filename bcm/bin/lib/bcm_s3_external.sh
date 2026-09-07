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
# ⚠️⚠️ Критичное требование к провайдеру — стиль адресации бакета, и он зависит от
# ВЕРСИИ модуля Bitrix clouds (CCloudStorageService_S3):
#   • clouds ≥ 26.100 — path-style: и запрос, и ссылка на объект идут на
#     https://<host>/<bucket>/<key> (бакет уехал в путь, GetFileSRC/SendRequest);
#   • clouds <  26.100 — virtual-hosted-style: https://<bucket>.<host>/<key>,
#     path-style такой модуль не умеет вовсе.
# Проверка определяет, какие стили держит провайдер, читает версию модуля на
# web-ноде и отклоняет связку до записи конфига, если нужный стиль недоступен.
# Итог пишется в [s3_upload] addressing (path|vhost) — его показывает меню 11.
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

# Версия модуля «Облачные хранилища» на web-ноде ('' — портала/модуля нет).
# Строка version.php: 'VERSION' => '26.100.0' → tr оставляет только цифры и точки.
_S3EXT_DOCROOT="${_S3EXT_DOCROOT:-/home/bitrix/www}"
_s3ext_clouds_version() {
    local ip="$1"
    bcm_ssh_exec_timeout "$ip" 15 \
        "grep -m1 \"'VERSION'\" ${_S3EXT_DOCROOT}/bitrix/modules/clouds/install/version.php 2>/dev/null | tr -dc '0-9.'" \
        </dev/null 2>/dev/null | tr -d '[:space:]'
}

# Умеет ли эта версия модуля path-style (бакет в пути). Порог — 26.100.0.
_s3ext_clouds_is_path_style() {
    local ver="$1"
    [[ -n "$ver" ]] || return 2                      # версия неизвестна
    [[ "$(printf '%s\n%s\n' '26.100.0' "$ver" | sort -V | head -1)" == "26.100.0" ]]
}

# Стиль адресации, выбранный последней проверкой (path|vhost) — пишется в конфиг.
_S3EXT_ADDRESSING=""

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

    # 4. Стиль адресации бакета: провайдер обязан уметь ровно тот, который построит
    # УСТАНОВЛЕННЫЙ модуль clouds (path-style с 26.100, virtual-host до неё).
    local proto="https"; [[ "$endpoint" == http://* ]] && proto="http"
    # path-style: подписанный запрос с принудительным lookup=path — «endpoint
    # ответил» тут недостаточно, провайдер может отвергать бакет в пути.
    local pth
    pth=$(bcm_ssh_exec_timeout "$ip" 40 \
        "${_S3EXT_MC} alias set bcmpath '${endpoint}' --api s3v4 --path on >/dev/null 2>&1 || { echo PATH_SETFAIL; exit 0; }
         ${_S3EXT_MC} ls 'bcmpath/${bucket}' >/dev/null 2>&1 && echo PATH_OK || echo PATH_FAIL
         ${_S3EXT_MC} alias rm bcmpath >/dev/null 2>&1 || true" \
        <<< "${access}
${secret}" | tr -d '[:space:]')
    # virtual-hosted-style: достаточно, что имя резолвится и хост отвечает любым HTTP.
    local vh
    vh=$(bcm_ssh_exec_timeout "$ip" 25 \
        "getent hosts '${bucket}.${host}' >/dev/null 2>&1 && curl -s -o /dev/null -w '%{http_code}' --max-time 15 '${proto}://${bucket}.${host}/' 2>/dev/null || echo 000" </dev/null | tr -d '[:space:]')

    local has_path=0 has_vhost=0
    [[ "$pth" == *PATH_OK* ]] && has_path=1
    [[ "$vh" != "000" && -n "$vh" ]] && has_vhost=1
    if [[ $has_path -eq 1 ]]; then
        bcm_ok "  path-style работает (${apihost}/${bucket})"
    elif [[ "$pth" == *PATH_SETFAIL* ]]; then
        # Не путать «провайдер не умеет» с «нечем проверить»: старый mc не знает --path.
        bcm_warn "  path-style проверить нечем: mc на ноде не принял '--path on' (старый бинарь)"
    else
        bcm_warn "  path-style не работает (${apihost}/${bucket})"
    fi
    [[ $has_vhost -eq 1 ]] \
        && bcm_ok   "  virtual-hosted-style работает (${bucket}.${host} → HTTP ${vh})" \
        || bcm_warn "  virtual-hosted-style не работает: ${bucket}.${host} не резолвится или молчит"

    # Какой стиль нужен именно этому порталу — решает версия модуля на ноде.
    local clouds_ver need_style ver_rc=0
    clouds_ver="$(_s3ext_clouds_version "$ip")"
    # rc: 0 — path-style, 1 — virtual-host, 2 — версия неизвестна. Через переменную,
    # а не $? в elif: так намерение видно и не зависит от порядка проверок.
    _s3ext_clouds_is_path_style "$clouds_ver" || ver_rc=$?
    if [[ $ver_rc -eq 0 ]]; then
        need_style="path"
        bcm_info "  модуль clouds ${clouds_ver} → адрес объекта строится как path-style"
    elif [[ $ver_rc -eq 2 ]]; then
        # Портал ещё не развёрнут: жёстко требовать нечего, хватит любого стиля.
        need_style="any"
        bcm_warn "  версия модуля clouds не определена (портал ещё не развёрнут):"
        bcm_info  "    path-style нужен clouds ≥ 26.100, virtual-host — более старым"
    else
        need_style="vhost"
        bcm_info "  модуль clouds ${clouds_ver} → адрес объекта строится как virtual-host"
    fi

    _S3EXT_ADDRESSING=""
    case "$need_style" in
        path)
            if [[ $has_path -eq 1 ]]; then _S3EXT_ADDRESSING="path"; else
                bcm_error "  провайдер не отдаёт бакет по пути, а модуль clouds ${clouds_ver} умеет ТОЛЬКО так"
                bcm_info  "    с этим провайдером подключить /upload не получится"
                fails=$((fails+1))
            fi ;;
        vhost)
            if [[ $has_vhost -eq 1 ]]; then _S3EXT_ADDRESSING="vhost"; else
                bcm_error "  нет virtual-hosted-style, а модуль clouds ${clouds_ver} умеет ТОЛЬКО его"
                bcm_info  "    нужен wildcard-DNS на ${bucket}.${host} и сертификат под него,"
                bcm_info  "    иначе обновите портал до clouds ≥ 26.100 (там path-style)"
                fails=$((fails+1))
            fi ;;
        *)
            if   [[ $has_path  -eq 1 ]]; then _S3EXT_ADDRESSING="path"
            elif [[ $has_vhost -eq 1 ]]; then _S3EXT_ADDRESSING="vhost"
            else
                bcm_error "  провайдер не отдаёт бакет ни по пути, ни по поддомену — подключать нечего"
                fails=$((fails+1))
            fi ;;
    esac

    # 5. Анонимное чтение — не блокирующее, но без него картинки в браузере не
    # откроются: clouds отдаёт прямые ссылки и подписанных URL не делает.
    # URL строим тем же стилем, каким его построит модуль.
    local anon_url="${proto}://${bucket}.${host}/.bcm-anon"
    [[ "$_S3EXT_ADDRESSING" == "path" ]] && anon_url="${proto}://${apihost}/${bucket}/.bcm-anon"
    local anon
    anon=$(bcm_ssh_exec_timeout "$ip" 40 \
        "t=/tmp/.bcm-s3anon.\$\$; echo anon > \$t
         ${_S3EXT_MC} cp -q \$t 'bcmext/${bucket}/.bcm-anon' >/dev/null 2>&1
         c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 '${anon_url}' 2>/dev/null || echo 000)
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
    # Стиль адресации, который прошёл проверку: его показывает меню 11, по нему же
    # понятно, почему в админке достаточно «Имени сервера» без wildcard-DNS.
    bcm_conf_set s3_upload addressing   "${_S3EXT_ADDRESSING:-path}"
    bcm_conf_sync 2>/dev/null || true
    bcm_ok "Параметры записаны и разосланы по узлам (адресация: ${_S3EXT_ADDRESSING:-path})."

    echo
    bcm_info "Осталось два шага:"
    bcm_info "  1. Зарегистрировать бакет в портале — этот же раздел, пункт «Авто-регистрация»"
    bcm_info "     (или вручную по значениям из пункта «Показать значения для админки»)."
    bcm_info "  2. Решить, что делать с зеркалом /upload между web-нодами (меню 6 → 10)."
    bcm_info "     По умолчанию (режим auto) оно снимается: контент уходит в бакет."
    bcm_warn "     Если в бакет уходит НЕ ВСЁ — узкие FILE_RULES, файлы, залитые до"
    bcm_warn "     подключения хранилища, статика модулей — зеркало нужно ОСТАВИТЬ"
    bcm_warn "     (меню 6 → 10, режим on), иначе такие файлы видны лишь одной ноде."
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
    bcm_info "адресация в конфиге: $(bcm_conf_get s3_upload addressing 2>/dev/null || echo '—')"
    echo
    if _s3ext_verify "$ip" "$endpoint" "$region" "$bucket" "$access" "$secret" "$apihost"; then
        echo; bcm_ok "Хранилище доступно и пригодно для /upload."
    else
        echo; bcm_error "Есть проблемы — облачное /upload будет работать неверно."
    fi
    bcm_any_key
}
