#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 16_modules.sh — подключаемые модули BCM (установка, включение, раскатка).
#
# Ядро отвечает за кластер, модули — за всё, что вокруг него: веб-портал,
# интеграции, свои экспортёры. Контракт и оба каталога (источник в релизе и
# установленные вне /opt/bcm) описаны в шапке bin/lib/bcm_modules.sh.
# =============================================================================
set -euo pipefail

BCM_BASE_DIR="${BCM_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"

source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"
source "${BCM_LIB_DIR}/bcm_modules.sh"

if ! bcm_conf_exists; then
    bcm_error "cluster.conf не найден. Запустите install.sh."
    exit 1
fi
bcm_load_topology

# ──── Таблица модулей ────────────────────────────────────────────────────────
_mod_table() {
    # ⚠️ mapfile: health — чужой хук, он вправе читать stdin (см. bcm_mod_event).
    local -a mods=(); local n installed=0
    mapfile -t mods < <(bcm_mod_list)
    printf "  %-12s %-9s %-9s %-14s %s\n" "МОДУЛЬ" "ВЕРСИЯ" "СОСТОЯНИЕ" "СЛОИ" "СОСТОЯНИЕ МОДУЛЯ"
    # ⚠️ Константа именно BCM_LINE_H1 (H2 в bcm_utils.sh нет): под set -u ссылка на
    # несуществующую переменную роняет меню целиком, а не печатает кривую линию.
    bcm_divider "$BCM_LINE_H1"
    for n in "${mods[@]}"; do
        [[ -n "$n" ]] || continue
        installed=1
        if ! bcm_mod_load "$n"; then
            printf "  %-12s %s\n" "$n" "манифест нечитаем — модуль сломан"
            continue
        fi
        local state health
        if bcm_mod_enabled "$n"; then state="включён"; else state="выключен"; fi
        if bcm_mod_enabled "$n"; then health="$(bcm_mod_health_line "$n" 2>/dev/null || true)"; else health="—"; fi
        printf "  %-12s %-9s %-9s %-14s %s\n" "$MOD_NAME" "$MOD_VERSION" "$state" "${MOD_ROLES:-brain}" "${health:-—}"
    done
    [[ $installed -eq 0 ]] && bcm_info "  Установленных модулей нет."

    # Модули из состава релиза, которые ещё не установлены, — подсказка, что есть.
    local avail=""
    while read -r n; do
        [[ -n "$n" ]] || continue
        bcm_mod_dir "$n" >/dev/null 2>&1 || avail+="${n} "
    done < <(bcm_mod_list_src)
    [[ -n "$avail" ]] && { echo; bcm_info "  В составе BCM есть, но не установлены: ${avail}"; }
}

_mod_show() {
    bcm_section_header "Модули BCM"
    bcm_info "Установленные: ${BCM_MODULES_DIR}  ·  в составе релиза: ${BCM_MODULES_SRC_DIR}"
    echo
    _mod_table
    echo
}

# ──── Выбор модуля из списка ─────────────────────────────────────────────────
# Печатает имя в stdout; всё остальное — в stderr, иначе подсказки попали бы в
# возвращаемое значение (ловится не сразу: имя модуля приезжает с мусором).
_mod_pick() {
    # ⚠️ `local -a` — отдельным объявлением: в одной строке с присваиваниями bash
    # ругается «-a: недопустимый идентификатор» и молча оставляет массив пустым.
    local prompt="${1:-Модуль}" src="${2:-installed}"
    local -a list=()
    local n
    if [[ "$src" == "src" ]]; then
        while read -r n; do [[ -n "$n" ]] && list+=("$n"); done < <(bcm_mod_list_src)
    else
        while read -r n; do [[ -n "$n" ]] && list+=("$n"); done < <(bcm_mod_list)
    fi
    if [[ ${#list[@]} -eq 0 ]]; then echo "" ; return 1; fi
    local i
    for i in "${!list[@]}"; do printf "    %d. %s\n" "$((i+1))" "${list[$i]}" >&2; done
    printf "    0. Отмена\n" >&2
    local ch; bcm_read_choice "$prompt" ch >&2
    [[ "$ch" =~ ^[0-9]+$ ]] && [[ "$ch" -ge 1 && "$ch" -le ${#list[@]} ]] || { echo ""; return 1; }
    echo "${list[$((ch-1))]}"
}

# ──── Действия ───────────────────────────────────────────────────────────────
_mod_install() {
    bcm_section_header "Установить модуль"
    bcm_info "Источник: модуль из состава BCM, каталог с module.conf или tar.gz."
    bcm_info "Пакет со сторонним модулем проверяется перед установкой: <пакет>.sha256"
    bcm_info "сверяется обязательно, подпись <пакет>.asc — ключами поставщиков из"
    bcm_info "${BCM_MODULE_KEYS_DIR}. Подписанный пакет без ключа не ставится."
    echo
    local src=""
    local have_src=0; [[ -n "$(bcm_mod_list_src)" ]] && have_src=1
    if [[ $have_src -eq 1 ]]; then
        echo "    1. Из состава BCM"
        echo "    2. Свой каталог или tar.gz"
        echo "    0. Назад"
        echo
        local ch; bcm_read_choice "Ваш выбор" ch
        case "$ch" in
            1) src="$(_mod_pick "Какой модуль" src)" ;;
            2) bcm_read_choice "Путь к каталогу или tar.gz" src ;;
            *) return ;;
        esac
    else
        bcm_read_choice "Путь к каталогу или tar.gz (0 — отмена)" src
    fi
    [[ -z "$src" || "$src" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }

    bcm_mod_install "$src" || { bcm_any_key; return; }
    local name="$MOD_NAME"
    echo
    if bcm_confirm "Включить модуль ${name} и раскатать на узлы (${MOD_ROLES:-только эта нода})?"; then
        bcm_mod_set_enabled "$name" "Y"
        bcm_mod_deploy "$name" || bcm_warn "Раскатка прошла не полностью — повторите пункт «Раскатать»."
    else
        bcm_info "Модуль установлен, но выключен: пункт «Включить/выключить»."
    fi
    bcm_any_key
}

_mod_toggle() {
    bcm_section_header "Включить или выключить модуль"
    local name; name="$(_mod_pick "Модуль")" || { bcm_info "Модулей нет."; bcm_any_key; return; }
    [[ -z "$name" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    bcm_mod_load "$name" || { bcm_error "Манифест ${name} нечитаем."; bcm_any_key; return; }
    if bcm_mod_enabled "$name"; then
        bcm_warn "Модуль ${name} включён. Выключение убирает его пункт из меню и события ядра;"
        bcm_warn "файлы и его службы на узлах остаются — снять их можно пунктом «Удалить»."
        if bcm_confirm "Выключить ${name}?"; then
            bcm_mod_set_enabled "$name" "N"; bcm_ok "Модуль ${name} выключен."
        fi
    else
        if bcm_confirm "Включить ${name} ${MOD_VERSION}?"; then
            bcm_mod_set_enabled "$name" "Y"; bcm_ok "Модуль ${name} включён."
            bcm_confirm "Раскатать его на узлы (${MOD_ROLES:-только эта нода})?" && { bcm_mod_deploy "$name" || true; }
        fi
    fi
    bcm_any_key
}

_mod_deploy() {
    bcm_section_header "Раскатать модуль на узлы"
    local name; name="$(_mod_pick "Модуль")" || { bcm_info "Модулей нет."; bcm_any_key; return; }
    [[ -z "$name" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    bcm_mod_load "$name" || { bcm_error "Манифест ${name} нечитаем."; bcm_any_key; return; }
    bcm_info "Каталог модуля уедет на узлы слоёв: ${MOD_ROLES:-— (только эта нода)}"
    bcm_info "и на каждом отработает hooks/install."
    bcm_confirm "Продолжить?" || { bcm_info "Отменено."; bcm_any_key; return; }
    bcm_mod_deploy "$name" && bcm_ok "Готово." || bcm_warn "Раскатка прошла не полностью."
    bcm_any_key
}

_mod_status() {
    bcm_section_header "Состояние модуля"
    local name; name="$(_mod_pick "Модуль")" || { bcm_info "Модулей нет."; bcm_any_key; return; }
    [[ -z "$name" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    bcm_mod_load "$name" || { bcm_error "Манифест ${name} нечитаем."; bcm_any_key; return; }
    echo
    printf "  %s %s\n" "$(bcm_pad 'Модуль:' 16)"   "${MOD_NAME} ${MOD_VERSION}"
    printf "  %s %s\n" "$(bcm_pad 'Название:' 16)" "$MOD_TITLE"
    printf "  %s %s\n" "$(bcm_pad 'Слои:' 16)"     "${MOD_ROLES:-только эта нода}"
    printf "  %s %s\n" "$(bcm_pad 'Каталог:' 16)"  "$MOD_DIR"
    printf "  %s %s\n" "$(bcm_pad 'Контракт:' 16)" "версия ${MOD_API:-1} (ядро даёт ${BCM_MODULE_API})"
    [[ -n "$MOD_VENDOR"   ]] && printf "  %s %s\n" "$(bcm_pad 'Поставщик:' 16)"  "$MOD_VENDOR"
    [[ -n "$MOD_LICENSE"  ]] && printf "  %s %s\n" "$(bcm_pad 'Условия:' 16)"    "$MOD_LICENSE"
    [[ -n "$MOD_SUPPORT"  ]] && printf "  %s %s\n" "$(bcm_pad 'Поддержка:' 16)"  "$MOD_SUPPORT"
    [[ -n "$MOD_HOMEPAGE" ]] && printf "  %s %s\n" "$(bcm_pad 'Исходники:' 16)"  "$MOD_HOMEPAGE"
    printf "  %s %s\n" "$(bcm_pad 'Состояние:' 16)" "$(bcm_mod_enabled "$name" && echo включён || echo выключен)"
    echo
    local out
    out="$(bcm_mod_run "$name" status 2>&1)" || true
    if [[ -n "$out" ]]; then
        bcm_color "WHITE" "  ── что сообщает сам модуль ──"
        echo "$out" | sed 's/^/    /'
    else
        bcm_info "  Модуль не отдаёт status (хук hooks/status не задан)."
    fi
    echo
    bcm_any_key
}

_mod_remove() {
    bcm_section_header "Удалить модуль"
    local name; name="$(_mod_pick "Модуль")" || { bcm_info "Модулей нет."; bcm_any_key; return; }
    [[ -z "$name" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    bcm_warn "Модуль будет снят С ЭТОЙ ноды: отработает hooks/remove и каталог удалится."
    bcm_warn "На остальных узлах он останется — уберите его там тем же пунктом."
    bcm_confirm "Удалить ${name} с этой ноды?" || { bcm_info "Отменено."; bcm_any_key; return; }
    bcm_mod_remove "$name" || true
    bcm_any_key
}

# ──── Меню ───────────────────────────────────────────────────────────────────
_mod_menu() {
    while true; do
        _mod_show
        local items=(
            "1.  Установить модуль (из состава BCM, каталога или tar.gz)"
            "2.  Включить / выключить"
            "3.  Раскатать на узлы (по слоям из манифеста)"
            "4.  Состояние модуля"
            "5.  Удалить с этой ноды"
            "0.  Назад"
        )
        bcm_print_menu items
        local choice
        bcm_read_choice "Ваш выбор" choice
        case "$choice" in
            1) _mod_install ;;
            2) _mod_toggle  ;;
            3) _mod_deploy  ;;
            4) _mod_status  ;;
            5) _mod_remove  ;;
            0) return 0 ;;
            "") : ;;
            *) bcm_warn "Неверный выбор." ;;
        esac
    done
}

_mod_menu
