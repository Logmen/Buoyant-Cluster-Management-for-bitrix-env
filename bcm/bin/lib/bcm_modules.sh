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
#     STATE_DIRS="payload"        каталоги, которые модуль создаёт НА УЗЛЕ сам
#     VENDOR="ООО «Ромашка»"      кто выпустил (видно оператору в меню)
#     LICENSE="proprietary"       условия использования
#     SUPPORT=https://…           куда писать по проблемам модуля
#     HOMEPAGE=https://…          где живёт модуль
#
#   hooks/ (исполняемые, окружение BCM_MODULE_{NAME,DIR,ROLE}, BCM_CONF_FILE и
#   BCM_MODCFG_<ключ> на каждый ключ секции [module.<name>]):
#     install  — после раскатки на ноду (роль в BCM_MODULE_ROLE)
#     remove   — снятие с ноды (ядро зовёт его и удалённо: bcm_mod_undeploy)
#     status   — печатает key=value для меню и портала
#     health   — rc 0/1 + строка причины (главный экран bcm)
#     event    — точки расширения ядра: event <имя> [аргументы]
#
# ⚠️ STATE_DIRS — про право собственности на файлы. Каталог модуля ядро копирует
# только целиком (rsync --delete): и при установке новой версии, и при раскатке.
# Модулю при этом часто нужно место под то, что рождается уже НА КЛАСТЕРЕ и в
# пакет поставщика не входит: портал собирает payload/ из установленного на web
# приложения. Две операции обходятся с таким каталогом ПО-РАЗНОМУ, и это важно:
#   • установка новой версии модуля — каталог НЕ трогаем: пакет поставщика приносит
#     его пустым, и без исключения обновление модуля стирало бы собранное на
#     кластере (а следующая раскатка разносила бы пустоту по узлам, рапортуя успех);
#   • раскатка на узлы — каталог едет как все: собран он ровно на одной ноде, а
#     нужен на остальных (портал собирает на web, а скрипты нужны на pxc и lb).
# Исключение при установке снимается для ПЕРВОЙ установки: если каталога ещё нет,
# содержимое из пакета поставщика кладётся как есть.
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
        MENU_TITLE=""; MENU_SCRIPT=""; HOMEPAGE=""; STATE_DIRS=""
        MODULE_API=""; VENDOR=""; LICENSE=""; SUPPORT=""
        # shellcheck disable=SC1091
        source "${dir}/module.conf" 2>/dev/null || exit 1
        printf 'MOD_NAME=%q\nMOD_TITLE=%q\nMOD_VERSION=%q\nMOD_ROLES=%q\nMOD_REQUIRES=%q\nMOD_MENU_TITLE=%q\nMOD_MENU_SCRIPT=%q\nMOD_HOMEPAGE=%q\nMOD_API=%q\nMOD_VENDOR=%q\nMOD_LICENSE=%q\nMOD_SUPPORT=%q\nMOD_STATE_DIRS=%q\n' \
            "$NAME" "$TITLE" "$VERSION" "$ROLES" "$REQUIRES_BCM" \
            "$MENU_TITLE" "${MENU_SCRIPT:-menu.sh}" "$HOMEPAGE" \
            "${MODULE_API:-1}" "$VENDOR" "$LICENSE" "$SUPPORT" "$STATE_DIRS"
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

# ──── Окружение хука ─────────────────────────────────────────────────────────
# Параметры модуля из [module.<name>] уезжают в хук как BCM_MODCFG_<ключ>.
# ⚠️ Зачем: хук выполняется НА УЗЛЕ, где нет ни функций ядра, ни знания о том,
# как устроен cluster.conf. Без этого каждый модуль пишет свой разбор INI (и
# пишет его неправильно: ловили awk без учёта секции — он брал первый ключ с
# таким именем из всего файла, а секций [module.*] у нас теперь много).
# Точки в имени ключа (app.path) заменяем на подчёркивание: имя переменной
# окружения — [A-Za-z0-9_]. Ключи не из этого алфавита пропускаем молча.
_bcm_mod_cfg_env() {
    local name="$1" k v var
    local -a seen=()
    while read -r k; do
        [[ -n "$k" ]] || continue
        [[ "$k" =~ ^(enabled|version)$ ]] && continue    # служебные поля ядра
        var="BCM_MODCFG_${k//./_}"
        [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ " ${seen[*]:-} " == *" $var "* ]] && continue
        seen+=("$var")
        v="$(bcm_conf_get "module.${name}" "$k" 2>/dev/null || echo '')"
        printf '%s=%s\n' "$var" "$v"
    done < <(bcm_conf_keys "module.${name}" 2>/dev/null)
    return 0
}

# Строка присваиваний для запуска хука ЧЕРЕЗ SSH: KEY=значение через printf %q.
_bcm_mod_hook_env_str() {
    local name="$1" dir="$2" role="$3" line k v out=""
    out+="BCM_MODULE_NAME=$(printf '%q' "$name") "
    out+="BCM_MODULE_DIR=$(printf '%q' "$dir") "
    out+="BCM_MODULE_ROLE=$(printf '%q' "$role") "
    out+="BCM_CONF_FILE=$(printf '%q' "${BCM_CONF_FILE:-/etc/bitrix-cluster/cluster.conf}") "
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        k="${line%%=*}"; v="${line#*=}"
        out+="${k}=$(printf '%q' "$v") "
    done < <(_bcm_mod_cfg_env "$name")
    printf '%s' "$out"
}

# ──── Каталоги состояния (STATE_DIRS манифеста) ──────────────────────────────
# Печатает вычищенные относительные пути; вызывать ПОСЛЕ bcm_mod_load.
# ⚠️ Пути проверяем: значение приходит из чужого манифеста, а подставляется в
# --exclude и в rm/mv. Абсолютный путь и '..' отбрасываем молча.
_bcm_mod_state_list() {
    local d
    for d in ${MOD_STATE_DIRS:-}; do
        d="${d#/}"; d="${d%/}"
        [[ -z "$d" ]] && continue
        [[ "$d" == *".."* ]] && continue
        [[ "$d" =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*$ ]] || continue
        echo "$d"
    done
    return 0
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
    # Хука нет — делать нечего, это не ошибка (модуль объявляет только нужные ему).
    [[ -e "$f" ]] || return 0
    # ⚠️ env со списком, а не префикс присваиваний: параметров модуля произвольное
    # число, массив в префикс не подставить. Заодно окружение достаётся и
    # неисполняемому хуку (ветка с bash) — раньше он стартовал вообще без переменных.
    local -a envv=()
    mapfile -t envv < <(_bcm_mod_cfg_env "$name")
    local -a cmd=( env
        "BCM_MODULE_NAME=${name}" "BCM_MODULE_DIR=${dir}"
        "BCM_MODULE_ROLE=${BCM_MODULE_ROLE:-$(bcm_get_current_role 2>/dev/null || echo unknown)}"
        "BCM_CONF_FILE=${BCM_CONF_FILE:-/etc/bitrix-cluster/cluster.conf}" )
    [[ ${#envv[@]} -gt 0 ]] && cmd+=( "${envv[@]}" )
    if [[ -x "$f" ]]; then cmd+=( "$f" ); else cmd+=( bash "$f" ); fi
    "${cmd[@]}" "$@"
}

# ──── Хук на УДАЛЁННОМ узле ──────────────────────────────────────────────────
# bcm_mod_run_remote <name> <ip> <role> <hook> <таймаут> [аргументы хука…]
# Один вход для всех удалённых хуков: раскатка, снятие, состояние. Раньше его не
# было, и каждый модуль писал свой обход узлов по ssh — вместе со всеми граблями
# (окружение перед хуком, </dev/null, таймаут). Хука на узле нет → rc 0 и тишина.
bcm_mod_run_remote() {
    [[ $# -ge 5 ]] || { bcm_error "bcm_mod_run_remote: нужны name, ip, роль, хук, таймаут."; return 2; }
    local name="$1" ip="$2" role="$3" hook="$4" tmo="$5"; shift 5
    local rdir="${BCM_MODULES_DIR}/${name}"
    local f="${rdir}/hooks/${hook}"
    local envs; envs="$(_bcm_mod_hook_env_str "$name" "$rdir" "$role")"
    local args=""
    local a; for a in "$@"; do args+=" $(printf '%q' "$a")"; done
    # ⚠️⚠️ Присваивания окружения — ПЕРЕД САМИМ хуком, а не перед `[ -x … ]`:
    # в `VAR=x [ -x f ] && f` переменные достаются test, а хук стартует без них.
    bcm_ssh_exec_timeout "$ip" "$tmo" \
        "[ -x '${f}' ] || exit 0; ${envs} '${f}'${args}" </dev/null
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
    # Каталог ключей поставщиков создаём сами: на кластерах, поставленных до этого
    # релиза, install.sh его не заводил, а без каталога подписанный пакет получал
    # отказ «нет ключей» — при том что положить ключ было некуда.
    mkdir -p "${BCM_MODULE_KEYS_DIR}" 2>/dev/null || true
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
    # источник загадочных различий между узлами. Исключение — STATE_DIRS: то, что
    # модуль собирает уже на кластере, переживает установку новой версии.
    local -a state=() ex=(); local s
    mapfile -t state < <(_bcm_mod_state_list)
    # Исключаем только то, что на этой ноде УЖЕ собрано: первая установка должна
    # положить содержимое из пакета поставщика, если он что-то туда положил.
    for s in "${state[@]}"; do
        [[ -d "${BCM_MODULES_DIR}/${name}/${s}" ]] && ex+=( "--exclude=/${s}/" )
    done
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "${ex[@]}" "${dir%/}/" "${BCM_MODULES_DIR}/${name}/"
    else
        # Без rsync состояние сохраняем руками: отодвинуть, переложить, вернуть.
        local keep=""; [[ ${#state[@]} -gt 0 ]] && keep="$(mktemp -d)"
        for s in "${state[@]}"; do
            [[ -d "${BCM_MODULES_DIR}/${name}/${s}" ]] || continue
            mkdir -p "$(dirname "${keep}/${s}")"; mv "${BCM_MODULES_DIR}/${name}/${s}" "${keep}/${s}"
        done
        rm -rf "${BCM_MODULES_DIR:?}/${name}"; mkdir -p "${BCM_MODULES_DIR}/${name}"; cp -a "${dir%/}/." "${BCM_MODULES_DIR}/${name}/"
        for s in "${state[@]}"; do
            [[ -n "$keep" && -d "${keep}/${s}" ]] || continue
            rm -rf "${BCM_MODULES_DIR:?}/${name:?}/${s:?}"; mkdir -p "$(dirname "${BCM_MODULES_DIR}/${name}/${s}")"
            mv "${keep}/${s}" "${BCM_MODULES_DIR}/${name}/${s}"
        done
        [[ -n "$keep" ]] && rm -rf "$keep"
    fi
    # Каталог состояния должен существовать даже у свежей установки: пакет
    # поставщика его не несёт (нечего нести), а модуль на него рассчитывает.
    for s in "${state[@]}"; do mkdir -p "${BCM_MODULES_DIR}/${name}/${s}"; done
    # ⚠️ bin/ тоже: у модуля там свои утилиты (портал собирает payload сборщиком
    # из bin/), а права из tar.gz или чужого каталога могут приехать без +x.
    chmod +x "${BCM_MODULES_DIR}/${name}"/hooks/* "${BCM_MODULES_DIR}/${name}"/bin/* "${BCM_MODULES_DIR}/${name}"/*.sh 2>/dev/null || true
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
    bcm_ok "Модуль ${name} снят с этого узла (с остальных — bcm_mod_undeploy, меню 16 → «Удалить»)."
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
    # ⚠️ STATE_DIRS здесь, в отличие от установки, едут на узлы как всё остальное:
    # собраны они на одной ноде, а нужны на других. Но если каталог пуст — узлы
    # получат пустоту (--delete), и молчать об этом нельзя: именно так «раскатал
    # успешно» и «на узлах ничего не поменялось» уживались в одном отчёте.
    local -a state=(); local s
    mapfile -t state < <(_bcm_mod_state_list)
    for s in "${state[@]}"; do
        [[ -d "${MOD_DIR}/${s}" && -z "$(ls -A "${MOD_DIR}/${s}" 2>/dev/null)" ]] || continue
        bcm_warn "  ${name}: каталог ${s}/ на этой ноде пуст — узлы получат его пустым."
        bcm_warn "  ${name}: соберите его средствами модуля и повторите раскатку."
    done
    local node ip layer ok=0 fail=0 nver
    for node in "${!BCM_NODE_IP[@]}"; do
        ip="${BCM_NODE_IP[$node]}"; layer="${BCM_NODE_LAYER[$node]:-}"
        [[ -z "$ip" || -z "$layer" ]] && continue
        [[ " $roles " == *" $layer "* ]] || continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "  ${node} (${ip}): недоступен — пропуск."; fail=$((fail+1)); continue
        fi
        # Версию ядра сверяем НА КАЖДОМ узле: bcm_mod_install проверил только ту
        # ноду, где стоял оператор, а отставшая нода (не долетело обновление) молча
        # получила бы модуль, которому там не на что опереться.
        nver="$(bcm_ssh_exec_timeout "$ip" 10 "cat ${BCM_BASE_DIR:-/opt/bcm}/VERSION 2>/dev/null" </dev/null | tr -d '[:space:]')"
        if [[ -n "${MOD_REQUIRES:-}" && -n "$nver" ]] && ! _bcm_mod_ver_ge "$nver" "$MOD_REQUIRES"; then
            bcm_warn "  ${node} (${layer}): BCM ${nver} < ${MOD_REQUIRES} — пропуск, сначала обновите ядро там."
            fail=$((fail+1)); continue
        fi
        bcm_ssh_exec "$ip" "mkdir -p ${BCM_MODULES_DIR}" </dev/null >/dev/null 2>&1
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete -e "ssh ${BCM_SSH_OPTS[*]} -i ${BCM_SSH_KEY}" \
                "${MOD_DIR%/}/" "root@${ip}:${BCM_MODULES_DIR}/${name}/" >/dev/null 2>&1 \
                || { bcm_error "  ${node}: rsync модуля не прошёл."; fail=$((fail+1)); continue; }
        else
            bcm_error "  ${node}: нет rsync на brain-ноде."; fail=$((fail+1)); continue
        fi
        local mk=""; for s in "${state[@]}"; do mk+="mkdir -p ${BCM_MODULES_DIR}/${name}/${s}; "; done
        bcm_ssh_exec "$ip" "${mk}chmod +x ${BCM_MODULES_DIR}/${name}/hooks/* ${BCM_MODULES_DIR}/${name}/bin/* ${BCM_MODULES_DIR}/${name}/*.sh 2>/dev/null; true" </dev/null >/dev/null 2>&1
        # Окружение хука (роль, BCM_CONF_FILE, параметры [module.<name>]) собирает
        # bcm_mod_run_remote — он же держит и оба разбора граблей: env перед самим
        # хуком и </dev/null, чтобы хук не съел stdin вызывающего меню.
        if bcm_mod_run_remote "$name" "$ip" "$layer" install 600 >/dev/null 2>&1; then
            bcm_ok "  ${node} (${layer}): модуль раскатан."; ok=$((ok+1))
        else
            bcm_warn "  ${node} (${layer}): install-хук вернул ошибку (см. модуль)."; fail=$((fail+1))
        fi
    done
    [[ $fail -eq 0 ]]
}

# ──── Снятие с узлов ─────────────────────────────────────────────────────────
# Зеркало раскатки: hooks/remove на каждом узле ROLES и удаление каталога модуля
# там же. Без этого remove-хук на удалённых узлах не вызывался НИКОГДА (ядро
# звало его только локально), и после «удалить модуль» на нодах оставались чужие
# таймеры, юниты и фрагменты конфигов — снимать руками, зная, что искать.
# Текущую ноду не трогаем: с неё модуль снимает bcm_mod_remove.
bcm_mod_undeploy() {
    local name="$1"
    bcm_mod_load "$name" || { bcm_error "модуль ${name} не установлен."; return 1; }
    local roles="${MOD_ROLES:-}"
    [[ -z "${roles// }" ]] && { bcm_info "  ${name}: ROLES пуст — снимать с других узлов нечего."; return 0; }
    bcm_load_topology || true
    local self; self="$(bcm_get_current_node_name 2>/dev/null || hostname -s)"
    local node ip layer fail=0 out
    for node in "${!BCM_NODE_IP[@]}"; do
        ip="${BCM_NODE_IP[$node]}"; layer="${BCM_NODE_LAYER[$node]:-}"
        [[ -z "$ip" || -z "$layer" ]] && continue
        [[ " $roles " == *" $layer "* ]] || continue
        [[ "$node" == "$self" ]] && continue
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "  ${node} (${ip}): недоступен — модуль там остался."; fail=$((fail+1)); continue
        fi
        out="$(bcm_mod_run_remote "$name" "$ip" "$layer" remove 300 2>&1)" || \
            bcm_warn "  ${node}: remove-хук вернул ошибку — каталог всё равно убираю."
        [[ -n "$out" ]] && echo "$out" | sed 's/^/      /'
        if bcm_ssh_exec_timeout "$ip" 60 "rm -rf '${BCM_MODULES_DIR:?}/${name}'" </dev/null >/dev/null 2>&1; then
            bcm_ok "  ${node} (${layer}): модуль снят."
        else
            bcm_error "  ${node} (${layer}): каталог модуля не удалён."; fail=$((fail+1))
        fi
    done
    [[ $fail -eq 0 ]]
}

# ──── Состояние со всех узлов ────────────────────────────────────────────────
# hooks/status по узлам ROLES. Печатает «<нода> (<роль>, <ip>)» и вывод хука.
bcm_mod_status_all() {
    local name="$1"
    bcm_mod_load "$name" || { bcm_error "модуль ${name} не установлен."; return 1; }
    local roles="${MOD_ROLES:-}"
    [[ -z "${roles// }" ]] && { bcm_mod_run "$name" status; return 0; }
    bcm_load_topology || true
    # ⚠️ Список узлов СНАЧАЛА в массив: ниже на каждый узел идёт ssh, а в теле
    # `while read < <(…)` он съел бы остаток списка — обошёлся бы только первый.
    local -a rows=(); local row node ip layer out
    for node in "${!BCM_NODE_IP[@]}"; do
        layer="${BCM_NODE_LAYER[$node]:-}"
        [[ -n "$layer" && " $roles " == *" $layer "* ]] && rows+=("${node} ${BCM_NODE_IP[$node]} ${layer}")
    done
    mapfile -t rows < <(printf '%s\n' "${rows[@]}" | sort)
    for row in "${rows[@]}"; do
        read -r node ip layer <<< "$row"
        [[ -n "$node" ]] || continue
        bcm_color "WHITE" "  ── ${node} (${layer}, ${ip}) ──"
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            echo "      узел недоступен"; continue
        fi
        out="$(bcm_mod_run_remote "$name" "$ip" "$layer" status 30 2>/dev/null)" || true
        echo "${out:-модуль на узле не отвечает (хука status нет или он молчит)}" | sed 's/^/      /'
    done
    return 0
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
# ⚠️⚠️ Список СНАЧАЛА в массив, и только потом запуск меню. Внутри
# `while read … done < <(…)` у тела цикла stdin — это подстановка процесса, и
# запущенное там ИНТЕРАКТИВНОЕ меню читало бы ввод оператора оттуда: первый же
# bcm_read_choice получал EOF, меню закрывалось мгновенно, и со стороны выглядело
# как «пункт не открывается» (ловили вживую). Тот же корень, что у запрета ssh в
# теле while-read, только жертва другая — не ssh, а дочерний интерактивный процесс.
bcm_mod_menu_run() {
    local want="$1" line num name
    local -a entries=()
    mapfile -t entries < <(bcm_mod_menu_entries)
    for line in "${entries[@]}"; do
        IFS='|' read -r num name _ <<< "$line"
        [[ "$num" == "$want" ]] || continue
        bcm_mod_load "$name" || return 1
        BCM_MODULE_NAME="$name" BCM_MODULE_DIR="$MOD_DIR" bash "${MOD_DIR}/${MOD_MENU_SCRIPT}"
        return 0
    done
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
