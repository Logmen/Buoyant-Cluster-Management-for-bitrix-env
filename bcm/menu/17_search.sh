#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 17_search.sh — Поиск портала на кластере Manticore (оркестрация bcm_search.sh)
#
# Manticore на каждом web-узле, кластер репликации из них; кворум двух узлов держит
# контролёр search_role.sh (главный — master HA Cron). Битрикс — модуль bcm.search:
# наследник штатного CSearchSphinx, ядро не правится. Подробности — в шапке
# bin/lib/bcm_search.sh и в README («Поиск портала на Manticore»).
# =============================================================================
set -euo pipefail
BCM_BASE_DIR="${BCM_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"
source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"

SEARCH_TOOL="${BCM_LIB_DIR}/bcm_search.sh"

_srch_run() {
    echo
    bash "$SEARCH_TOOL" "$@" || bcm_warn "Команда завершилась с ошибкой — подробности выше и в /var/log/bcm/search.log."
    echo
    bcm_any_key
}

_srch_install() {
    bcm_section_header "Установка Manticore на web-узлы и сборка кластера"
    bcm_info "На каждом web: пакеты manticore-server и manticore-galera (официальный репозиторий),"
    bcm_info "конфиг, порты только между web-узлами, контролёр (таймер 15 с). Затем кластер и таблица"
    bcm_info "индекса по полям модуля поиска этой версии. Портал при этом НЕ переключается."
    echo
    bcm_confirm "Продолжить?" || { bcm_info "Отменено."; bcm_any_key; return; }
    _srch_run --install
}

_srch_enable() {
    bcm_section_header "Перевод поиска портала на Manticore"
    bcm_info "Модуль bcm.search и блок в init.php, опции модуля поиска, заливка индекса из"
    bcm_info "b_search_content (портал ищет по-старому, пока она идёт), затем переключение движка"
    bcm_info "и отложенная индексация через очередь. Заливка — минуты на десятки тысяч документов."
    bcm_warn "Страница настроек модуля поиска в админке после этого не сохраняется (её проверка"
    bcm_warn "написана под Sphinx) — настройки поиска меняются здесь."
    echo
    bcm_confirm "Перевести портал?" || { bcm_info "Отменено."; bcm_any_key; return; }
    _srch_run --enable
}

_srch_disable() {
    bcm_section_header "Возврат штатного поиска Битрикса"
    bcm_info "Движок модуля поиска → «bitrix» (MySQL). Кластер Manticore остаётся."
    bcm_warn "Индекс Битрикса в MySQL не обновлялся, пока работал Manticore — после возврата"
    bcm_warn "нужна переиндексация (Настройки → Поиск → Переиндексация)."
    echo
    bcm_confirm "Вернуть штатный поиск?" || { bcm_info "Отменено."; bcm_any_key; return; }
    _srch_run --disable
}

_srch_print_menu() {
    local -a items=(
        "1. Статус (узлы, контролёр, кластер, портал)"
        "2. Установить / обновить Manticore на web-узлах"
        "3. Перевести поиск портала на Manticore"
        "4. Досинхронизировать индекс из базы портала"
        "5. Синхронизировать схему таблицы с модулем поиска"
        "6. Восстановить: такт контролёра на всех узлах"
        "7. Вернуть штатный поиск Битрикса"
        "0. Назад"
    )
    bcm_print_menu items
}

main() {
    bcm_require_root
    bcm_load_topology || { bcm_error "Не удалось загрузить топологию."; exit 1; }

    local app_ver benv_ver current_role current_node
    app_ver=$(bcm_get_app_version)
    benv_ver=$(bcm_get_local_benv_version)
    current_role=$(bcm_get_current_role)
    current_node=$(bcm_get_current_node_name)

    while true; do
        bcm_print_header "$app_ver" "$benv_ver" "$current_role" "$current_node"
        bcm_color "WHITE" "  ═══ Поиск портала (Manticore) ═══"
        echo
        bcm_info "Установлен: $(bcm_conf_get search installed 2>/dev/null || echo no), портал: $(bcm_conf_get search portal 2>/dev/null || echo no)"
        echo
        _srch_print_menu
        local choice
        bcm_read_choice "Введите ваш выбор" choice
        case "$choice" in
            1) _srch_run --status ;;
            2) _srch_install ;;
            3) _srch_enable ;;
            4) _srch_run --repair ;;
            5) _srch_run --schema-sync ;;
            6) _srch_run --recover ;;
            7) _srch_disable ;;
            0) break ;;
            "") : ;;
            *) bcm_warn "Неверный выбор: '${choice}'. Введите число от 0 до 7." ;;
        esac
        bcm_clear_cache
        BCM_CONF_LOADED=0
        bcm_load_topology 2>/dev/null || true
    done
}

main "$@"
