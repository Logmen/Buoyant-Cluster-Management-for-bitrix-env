#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090,SC1091,SC2155,SC2015,SC2181,SC2016
# =============================================================================
# bcm_modules.sh — подключаемые модули BCM.
#
# Зачем. Вокруг кластера вырастают вещи, которым не место в ядре: веб-портал
# мониторинга, свои экспортёры, интеграции. Раньше их прикручивали мимо BCM —
# файлы руками в /usr/local/sbin, свои таймеры, патчи к bin/lib/*.sh. Итог
# предсказуемый: `bcm --update` затирает патч, на нодах разъезжаются версии, а
# кто и что положил — знает только автор.
#
# Контракт. Модуль — каталог с манифестом module.conf и (необязательно) меню и
# хуками. BCM берёт на себя то, что модулю пришлось бы писать заново: раскатку
# по ролям тем же ключом кластера, включение/выключение, хранение параметров в
# cluster.conf, пункт в главном меню, события ядра. Модуль взамен обязан лишь
# описать себя манифестом и не трогать файлы ядра.
#
# Модули пишет не только автор BCM: контракт ниже — ПУБЛИЧНЫЙ API для сторонних
# поставщиков, в том числе коммерческих. Отсюда три следствия, заложенные в код:
# версия контракта отдельно от версии ядра (MODULE_API), установка из подписанного
# архива с проверкой, и явные поля о происхождении модуля (VENDOR, LICENSE).
#
#   module.conf (KEY=VALUE, читается через source):
#     NAME=portal                 обязательное, [a-z0-9_-]
#     TITLE="Веб-портал BCM"      обязательное, человекочитаемое
#     VERSION=0.3.0               обязательное
#     MODULE_API=1                версия контракта, под который написан модуль
#     ROLES="web lb pxc"          на какие слои раскатывать (пусто — только brain)
#     REQUIRES_BCM=1.0.19         минимальная версия ядра
#     MENU_TITLE="Веб-портал"     если задано — пункт в главном меню bcm
#     MENU_SCRIPT=menu.sh         скрипт пункта (по умолчанию menu.sh)
#     VENDOR="ООО «Ромашка»"      кто выпустил (видно оператору в меню)
#     LICENSE="proprietary"       условия использования
#     SUPPORT=https://…           куда писать по проблемам модуля
#     HOMEPAGE=https://…          где живёт модуль
#
#   hooks/ (исполняемые, окружение BCM_MODULE_{NAME,DIR,ROLE}, BCM_CONF_FILE):
#     install  — после раскатки на ноду (роль в BCM_MODULE_ROLE)
#     remove   — снятие с ноды
#     status   — печатает key=value для меню и портала
#     health   — rc 0/1 + строка причины (главный экран bcm)
#     event    — точки расширения ядра: event <имя> [аргументы]
#
# ⚠️⚠️ ДВА каталога, и это осознанно:
#   /opt/bcm/modules/<name>     — модули В СОСТАВЕ релиза (источник). Обновляются
#                                 вместе с ядром, `bcm --update` их перезаписывает.
#   /opt/bcm-modules/<name>     — УСТАНОВЛЕННЫЕ модули. Лежат ВНЕ /opt/bcm, потому
#                                 что обновление ядра делает rsync --delete по
#                                 /opt/bcm: модуль оператора внутри был бы снесён
#                                 при первом же апдейте.
# Установка = копирование источника (или стороннего каталога/tar.gz) во второй
# каталог. Обновление ядра переустанавливает оттуда только те bundled-модули,
# которые уже установлены.
#
# ⚠️ Модули НЕ имеют права править файлы ядра. Всё, что им нужно от ядра, —
# либо событие (hooks/event), либо параметр в [module.<name>]. Если модулю не
# хватает точки расширения, её добавляют в ядро явным коммитом, а не патчем на
# ноде: патч не переживёт обновления и разъедется между узлами.
# =============================================================================

BCM_MODULES_DIR="${BCM_MODULES_DIR:-/opt/bcm-modules}"
BCM_MODULES_SRC_DIR="${BCM_MODULES_SRC_DIR:-${BCM_BASE_DIR:-/opt/bcm}/modules}"
# Пункты главного меню модулей нумеруются с этого числа: встроенные занимают
# 1..16, запас оставлен намеренно, чтобы новый раздел ядра не сдвигал модули.
BCM_MODULES_MENU_BASE="${BCM_MODULES_MENU_BASE:-20}"
# Версия контракта модулей, которую даёт ЭТО ядро. Растёт при несовместимых
# изменениях (переименование хуков, смена окружения, смена формата манифеста).
# ⚠️ Сторонний модуль пишется под номер контракта, а не под версию BCM: у платного
# модуля один пакет уезжает на кластеры с разными версиями ядра.
BCM_MODULE_API=1
# Доверенные ключи поставщиков модулей — по ним проверяется подпись пакета.
BCM_MODULE_KEYS_DIR="${BCM_MODULE_KEYS_DIR:-/etc/bitrix-cluster/module-keys}"

# ──── Манифест ───────────────────────────────────────────────────────────────
# Читаем в ПОДОБОЛОЧКЕ и забираем только известные ключи: module.conf — файл от
# третьей стороны, произвольный source в наш процесс затёр бы переменные меню.
_bcm_mod_manifest() {
    local dir="$1"
    [[ -f "${dir}/module.conf" ]] || return 1
    (
        set +u
        NAME=""; TITLE=""; VERSION=""; ROLES=""; REQUIRES_BCM=""
        MENU_TITLE=""; MENU_SCRIPT=""; HOMEPAGE=""
        MODULE_API=""; VENDOR=""; LICENSE=""; SUPPORT=""
        # shellcheck disable=SC1091
        source "${dir}/module.conf" 2>/dev/null || exit 1
        printf 'MOD_NAME=%q\nMOD_TITLE=%q\nMOD_VERSION=%q\nMOD_ROLES=%q\nMOD_REQUIRES=%q\nMOD_MENU_TITLE=%q\nMOD_MENU_SCRIPT=%q\nMOD_HOMEPAGE=%q\nMOD_API=%q\nMOD_VENDOR=%q\nMOD_LICENSE=%q\nMOD_SUPPORT=%q\n' \
            "$NAME" "$TITLE" "$VERSION" "$ROLES" "$REQUIRES_BCM" \
            "$MENU_TITLE" "${MENU_SCRIPT:-menu.sh}" "$HOMEPAGE" \
            "${MODULE_API:-1}" "$VENDOR" "$LICENSE" "$SUPPORT"
    )
}

# Загрузить манифест установленного модуля в MOD_* текущей оболочки.
bcm_mod_load() {
    local name="$1" dir out
    dir="$(bcm_mod_dir "$name")" || return 1
    out="$(_bcm_mod_manifest "$dir")" || return 1
    MOD_DIR="$dir"
    eval "$out"
    [[ -n "$MOD_NAME" && -n "$MOD_TITLE" && -n "$MOD_VERSION" ]]
}

bcm_mod_dir()     { local d="${BCM_MODULES_DIR}/$1";     [[ -f "${d}/module.conf" ]] && { echo "$d"; return 0; }; return 1; }
bcm_mod_src_dir() { local d="${BCM_MODULES_SRC_DIR}/$1"; [[ -f "${d}/module.conf" ]] && { echo "$d"; return 0; }; return 1; }

# Имена модулей: установленных / поставляемых с релизом.
bcm_mod_list()     { local d; for d in "${BCM_MODULES_DIR}"/*/;     do [[ -f "${d}module.conf" ]] && basename "$d"; done 2>/dev/null; }
bcm_mod_list_src() { local d; for d in "${BCM_MODULES_SRC_DIR}"/*/; do [[ -f "${d}module.conf" ]] && basename "$d"; done 2>/dev/null; }

# ──── Состояние в cluster.conf ───────────────────────────────────────────────
# [module.<name>] enabled = Y|N. Секция реплицируется bcm_conf_sync на все узлы,
# поэтому «включён ли модуль» одинаково видно и с brain-ноды, и с любой другой.
bcm_mod_enabled() {
    local v; v="$(bcm_conf_get "module.$1" enabled 2>/dev/null || echo '')"
    [[ "${v,,}" =~ ^(y|yes|1|on|true)$ ]]
}

bcm_mod_set_enabled() {
    local name="$1" val="$2"
    bcm_conf_set "module.${name}" enabled "$val"
    bcm_conf_sync 2>/dev/null || true
}

# Параметр модуля с значением по умолчанию: bcm_mod_get portal app_path /opt/bcm-portal
bcm_mod_get() {
    local v; v="$(bcm_conf_get "module.$1" "$2" 2>/dev/null || echo '')"
    [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "${3:-}"
}

# Включённые модули (установлен + enabled = Y).
bcm_mod_list_enabled() {
    local n; while read -r n; do [[ -n "$n" ]] && bcm_mod_enabled "$n" && echo "$n"; done < <(bcm_mod_list)
}

# ──── Версии ─────────────────────────────────────────────────────────────────
_bcm_mod_ver_ge() {
    [[ -z "$2" ]] && return 0
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

bcm_mod_core_version() { tr -d '[:space:]' < "${BCM_BASE_DIR:-/opt/bcm}/VERSION" 2>/dev/null || echo "0"; }

# ──── Запуск хуков ───────────────────────────────────────────────────────────
# Хук — обычный исполняемый файл. rc возвращается вызывающему; вывод не глотаем,
# его показывает меню. Нет хука — считаем, что делать нечего (rc 0).
bcm_mod_run() {
    local name="$1" hook="$2"; shift 2
    local dir; dir="$(bcm_mod_dir "$name")" || return 1
    local f="${dir}/hooks/${hook}"
    [[ -x "$f" ]] || { [[ -f "$f" ]] && bash "$f" "$@"; return $?; }
    BCM_MODULE_NAME="$name" BCM_MODULE_DIR="$dir" \
    BCM_MODULE_ROLE="${BCM_MODULE_ROLE:-$(bcm_get_current_role 2>/dev/null || echo unknown)}" \
    BCM_CONF_FILE="${BCM_CONF_FILE:-/etc/bitrix-cluster/cluster.conf}" \
        "$f" "$@"
}

# Событие ядра: прогнать hooks/event по всем ВКЛЮЧЁННЫМ модулям.
# ⚠️ Никогда не роняет вызывающего: ядро не должно падать из-за чужого хука.
# Вызовы расставлены в ядре точечно (см. grep bcm_mod_event) — это единственный
# санкционированный способ модулю вклиниться в работу BCM.
bcm_mod_event() {
    local event="$1"; shift
    # ⚠️ mapfile, а не while-read: хук модуля — чужой код, он вправе читать stdin,
    # и тогда цикл получил бы событие только для первого модуля.
    local -a mods=(); local n
    mapfile -t mods < <(bcm_mod_list_enabled 2>/dev/null)
    for n in "${mods[@]}"; do
        [[ -n "$n" ]] || continue
        bcm_mod_run "$n" event "$event" "$@" >/dev/null 2>&1 </dev/null || true
    done
    return 0
}

# ──── Проверка пакета модуля ─────────────────────────────────────────────────
# Платный модуль приезжает файлом со стороны, и оператор должен знать, что он
# ставит. Правила намеренно разные для «подписано» и «не подписано»:
#   • есть <пакет>.sha256 — сверяем ОБЯЗАТЕЛЬНО, расхождение = отказ;
#   • есть <пакет>.asc    — проверяем подпись ключами поставщиков из
#     BCM_MODULE_KEYS_DIR в ИЗОЛИРОВАННОМ homedir. Нет ключа или подпись не
#     сходится — отказ (fail-closed): подписанный пакет, который мы не смогли
#     проверить, опаснее неподписанного, его кто-то подменил или ключ не завезли;
#   • нет ни того ни другого — ставим, но громко предупреждаем. Запрещать нельзя:
#     свой модуль оператор собирает и ставит каталогом, без всякой подписи.
_bcm_mod_verify_pkg() {
    local pkg="$1" rc=0
    if [[ -f "${pkg}.sha256" ]]; then
        if ( cd "$(dirname "$pkg")" && sha256sum -c "$(basename "$pkg").sha256" >/dev/null 2>&1 ); then
            bcm_ok "  контрольная сумма пакета совпала"
        else
            bcm_error "  sha256 пакета НЕ совпал — файл повреждён или подменён."; return 1
        fi
    fi
    if [[ -f "${pkg}.asc" ]]; then
        command -v gpg >/dev/null 2>&1 || { bcm_error "  пакет подписан, но gpg не установлен — проверить нечем."; return 1; }
        shopt -s nullglob
        local keys=( "${BCM_MODULE_KEYS_DIR}"/*.asc "${BCM_MODULE_KEYS_DIR}"/*.gpg )
        shopt -u nullglob
        if [[ ${#keys[@]} -eq 0 ]]; then
            bcm_error "  пакет подписан, но в ${BCM_MODULE_KEYS_DIR} нет ключей поставщиков."
            bcm_info  "    положите открытый ключ поставщика туда и повторите."
            return 1
        fi
        local home; home="$(mktemp -d)"
        local k; for k in "${keys[@]}"; do gpg --homedir "$home" --batch --quiet --import "$k" 2>/dev/null || true; done
        if gpg --homedir "$home" --batch --verify "${pkg}.asc" "$pkg" >/dev/null 2>&1; then
            local signer; signer="$(gpg --homedir "$home" --batch --verify "${pkg}.asc" "$pkg" 2>&1 | sed -n 's/.*Good signature from "\([^"]*\)".*/\1/p' | head -1)"
            bcm_ok "  подпись верна${signer:+ (подписант: ${signer})}"
        else
            bcm_error "  подпись пакета НЕ прошла проверку доверенными ключами."; rc=1
        fi
        rm -rf "$home"
        [[ $rc -eq 0 ]] || return 1
    fi
    if [[ ! -f "${pkg}.sha256" && ! -f "${pkg}.asc" ]]; then
        bcm_warn "  пакет без подписи и контрольной суммы — проверить происхождение нечем."
    fi
    return 0
}

# ──── Установка / удаление ───────────────────────────────────────────────────
# Источник: имя bundled-модуля, каталог или tar.gz. Проверяем манифест и версию
# ядра ДО копирования — половинчато установленный модуль хуже отсутствующего.
bcm_mod_install() {
    local src="$1" tmp="" dir name out
    if [[ -d "$src" ]]; then dir="$src"
    elif [[ -f "$src" && "$src" == *.tar.gz ]]; then
        _bcm_mod_verify_pkg "$src" || return 1
        tmp="$(mktemp -d)"; tar -xzf "$src" -C "$tmp" || { rm -rf "$tmp"; bcm_error "не распаковать ${src}"; return 1; }
        dir="$(find "$tmp" -maxdepth 2 -name module.conf -printf '%h\n' | head -1)"
        [[ -n "$dir" ]] || { rm -rf "$tmp"; bcm_error "в архиве нет module.conf"; return 1; }
    elif dir="$(bcm_mod_src_dir "$src")"; then :
    else bcm_error "не найден модуль: ${src}"; return 1; fi

    out="$(_bcm_mod_manifest "$dir")" || { [[ -n "$tmp" ]] && rm -rf "$tmp"; bcm_error "нечитаемый module.conf в ${dir}"; return 1; }
    eval "$out"
    if [[ -z "$MOD_NAME" || -z "$MOD_TITLE" || -z "$MOD_VERSION" ]]; then
        [[ -n "$tmp" ]] && rm -rf "$tmp"
        bcm_error "манифест неполон: нужны NAME, TITLE, VERSION."; return 1
    fi
    if [[ ! "$MOD_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        [[ -n "$tmp" ]] && rm -rf "$tmp"
        bcm_error "NAME='${MOD_NAME}' — допустимы строчные буквы, цифры, дефис и подчёркивание."; return 1
    fi
    if ! _bcm_mod_ver_ge "$(bcm_mod_core_version)" "$MOD_REQUIRES"; then
        [[ -n "$tmp" ]] && rm -rf "$tmp"
        bcm_error "модулю нужен BCM ${MOD_REQUIRES}, установлен $(bcm_mod_core_version) — сначала обновите ядро."; return 1
    fi
    # Контракт важнее версии ядра: модуль под будущий API на этом ядре просто не
    # заработает, и лучше сказать об этом на установке, чем ловить странности потом.
    if [[ "${MOD_API:-1}" =~ ^[0-9]+$ ]] && [[ "${MOD_API:-1}" -gt "$BCM_MODULE_API" ]]; then
        [[ -n "$tmp" ]] && rm -rf "$tmp"
        bcm_error "модуль написан под контракт модулей версии ${MOD_API}, это ядро даёт ${BCM_MODULE_API} — обновите BCM."; return 1
    fi

    name="$MOD_NAME"
    mkdir -p "${BCM_MODULES_DIR}"
    # Каталог модуля заменяем целиком (rsync --delete): остатки прежней версии —
    # источник загадочных различий между узлами.
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "${dir%/}/" "${BCM_MODULES_DIR}/${name}/"
    else
        rm -rf "${BCM_MODULES_DIR:?}/${name}"; mkdir -p "${BCM_MODULES_DIR}/${name}"; cp -a "${dir%/}/." "${BCM_MODULES_DIR}/${name}/"
    fi
    chmod +x "${BCM_MODULES_DIR}/${name}"/hooks/* "${BCM_MODULES_DIR}/${name}"/*.sh 2>/dev/null || true
    [[ -n "$tmp" ]] && rm -rf "$tmp"
    bcm_conf_set "module.${name}" version "$MOD_VERSION"
    bcm_ok "Модуль ${name} ${MOD_VERSION}${MOD_VENDOR:+ (${MOD_VENDOR})} установлен в ${BCM_MODULES_DIR}/${name}."
    [[ -n "$MOD_LICENSE" ]] && bcm_info "Условия использования: ${MOD_LICENSE}${MOD_SUPPORT:+ · поддержка: ${MOD_SUPPORT}}"
}

bcm_mod_remove() {
    local name="$1" dir
    dir="$(bcm_mod_dir "$name")" || { bcm_error "модуль ${name} не установлен."; return 1; }
    bcm_mod_run "$name" remove >/dev/null 2>&1 || true
    rm -rf "${dir:?}"
    bcm_conf_set "module.${name}" enabled "N"
    bcm_conf_sync 2>/dev/null || true
    bcm_ok "Модуль ${name} снят с этого узла (на остальных — раскатка ещё раз или вручную)."
}

# ──── Раскатка по нодам ──────────────────────────────────────────────────────
# Каталог модуля уезжает на узлы тех ролей, что перечислены в ROLES, тем же
# ключом кластера, что и сам BCM. После копирования — hooks/install на узле, с
# ролью в BCM_MODULE_ROLE: один и тот же модуль на web и на pxc обычно ставит
# разное (портал: приложение на web, скрипты копий на узлы базы).
bcm_mod_deploy() {
    local name="$1"
    bcm_mod_load "$name" || { bcm_error "модуль ${name} не установлен."; return 1; }
    local roles="${MOD_ROLES:-}"
    if [[ -z "${roles// }" ]]; then
        bcm_info "  ${name}: ROLES пуст — модуль живёт только на этой ноде."
        BCM_MODULE_ROLE="$(bcm_get_current_role 2>/dev/null || echo unknown)" bcm_mod_run "$name" install || true
        return 0
    fi
    bcm_load_topology || true
    local node ip layer ok=0 fail=0
    for node in "${!BCM_NODE_IP[@]}"; do
        ip="${BCM_NODE_IP[$node]}"; layer="${BCM_NODE_LAYER[$node]:-}"
        [[ -z "$ip" || -z "$layer" ]] && continue
        [[ " $roles " == *" $layer "* ]] || continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "  ${node} (${ip}): недоступен — пропуск."; fail=$((fail+1)); continue
        fi
        bcm_ssh_exec "$ip" "mkdir -p ${BCM_MODULES_DIR}" </dev/null >/dev/null 2>&1
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete -e "ssh ${BCM_SSH_OPTS[*]} -i ${BCM_SSH_KEY}" \
                "${MOD_DIR%/}/" "root@${ip}:${BCM_MODULES_DIR}/${name}/" >/dev/null 2>&1 \
                || { bcm_error "  ${node}: rsync модуля не прошёл."; fail=$((fail+1)); continue; }
        else
            bcm_error "  ${node}: нет rsync на brain-ноде."; fail=$((fail+1)); continue
        fi
        bcm_ssh_exec "$ip" "chmod +x ${BCM_MODULES_DIR}/${name}/hooks/* ${BCM_MODULES_DIR}/${name}/*.sh 2>/dev/null; true" </dev/null >/dev/null 2>&1
        if bcm_ssh_exec_timeout "$ip" 600 \
            "BCM_MODULE_NAME='${name}' BCM_MODULE_DIR='${BCM_MODULES_DIR}/${name}' BCM_MODULE_ROLE='${layer}' \
             [ -x ${BCM_MODULES_DIR}/${name}/hooks/install ] && ${BCM_MODULES_DIR}/${name}/hooks/install || true" </dev/null >/dev/null 2>&1; then
            bcm_ok "  ${node} (${layer}): модуль раскатан."; ok=$((ok+1))
        else
            bcm_warn "  ${node} (${layer}): install-хук вернул ошибку (см. модуль)."; fail=$((fail+1))
        fi
    done
    [[ $fail -eq 0 ]]
}

bcm_mod_deploy_all() {
    # ⚠️ mapfile: bcm_mod_deploy ходит по узлам ssh'ем — в теле while-read
    # раскатался бы только первый модуль.
    local -a mods=(); local n
    mapfile -t mods < <(bcm_mod_list_enabled)
    for n in "${mods[@]}"; do
        [[ -n "$n" ]] || continue
        bcm_info "Модуль ${n}:"
        bcm_mod_deploy "$n" || true
    done
    return 0
}

# ──── Пункты главного меню ───────────────────────────────────────────────────
# Печатает строки «<номер>|<имя>|<заголовок>» для включённых модулей с MENU_TITLE.
bcm_mod_menu_entries() {
    local i="${BCM_MODULES_MENU_BASE}" n
    while read -r n; do
        [[ -n "$n" ]] || continue
        ( bcm_mod_load "$n" && [[ -n "$MOD_MENU_TITLE" && -f "${MOD_DIR}/${MOD_MENU_SCRIPT}" ]] \
            && printf '%s|%s|%s\n' "$i" "$n" "$MOD_MENU_TITLE" ) || true
        i=$((i+1))
    done < <(bcm_mod_list_enabled)
}

# Запустить меню модуля по номеру из bcm_mod_menu_entries. rc 1 — номер не наш.
bcm_mod_menu_run() {
    local want="$1" line num name
    while IFS='|' read -r num name _; do
        [[ "$num" == "$want" ]] || continue
        bcm_mod_load "$name" || return 1
        BCM_MODULE_NAME="$name" BCM_MODULE_DIR="$MOD_DIR" bash "${MOD_DIR}/${MOD_MENU_SCRIPT}"
        return 0
    done < <(bcm_mod_menu_entries)
    return 1
}

# Короткая сводка для главного экрана: «portal 0.3.0 ✓» либо причина из health.
bcm_mod_health_line() {
    local name="$1" out rc
    out="$(bcm_mod_run "$name" health 2>/dev/null)"; rc=$?
    [[ -z "$out" ]] && out="$([[ $rc -eq 0 ]] && echo "ок" || echo "ошибка")"
    printf '%s' "$out"
    return $rc
}
