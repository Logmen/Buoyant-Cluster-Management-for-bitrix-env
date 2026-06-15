#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# s3_minio.sh — Управление MinIO S3 (локальный модуль для s3-ноды)
#
# Раньше bin/bcm и деплой ссылались на этот файл, но его не было в проекте,
# из-за чего пункт «MinIO S3» в урезанном меню всегда падал. Этот модуль
# закрывает пробел: статус, перезапуск, логи и состояние репликации MinIO.
#
# Все данные — из cluster.conf через bcm_config.sh / bcm_runtime.sh.
# Управляет ТОЛЬКО локальным узлом (через systemctl/mc).
# =============================================================================
set -euo pipefail

source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"
source "${BCM_LIB_DIR}/bcm_runtime.sh"

bcm_require_root

CURRENT_NODE="$(bcm_get_current_node_name 2>/dev/null || hostname -s)"
APP_VER="$(bcm_get_app_version)"
BENV_VER="$(bcm_get_local_benv_version)"

_s3_local_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

# ──── Статус MinIO ───────────────────────────────────────────────────────────
_s3_status() {
    bcm_section_header "MinIO S3 — Статус (${CURRENT_NODE})"

    local ip s3_port ver svc health
    ip="$(_s3_local_ip)"
    s3_port=$(bcm_get_s3_port 2>/dev/null || echo "9000")
    ver=$(bcm_get_minio_version "$ip")
    svc=$(systemctl is-active minio 2>/dev/null || echo "inactive")
    health=$(bcm_check_s3_health "$ip")

    echo
    printf "  %s: %s\n" "$(bcm_pad 'Узел' 20)" "$CURRENT_NODE ($ip)"
    printf "  %s: %s\n" "$(bcm_pad 'Версия' 20)" "${ver:-неизвестно}"
    printf "  %s: %s\n" "$(bcm_pad 'Порт API' 20)" "$s3_port"
    printf "  %s: %s\n" "$(bcm_pad 'systemd' 20)" "$svc"
    printf "  %s: " "$(bcm_pad 'Health' 20)"
    if [[ "$health" == "ok" ]]; then bcm_status_ok; else bcm_status_fail; fi
    echo
    echo
    bcm_info "Console: http://${ip}:9001"
    echo
    bcm_any_key
}

# ──── Перезапуск службы MinIO ────────────────────────────────────────────────
_s3_restart() {
    bcm_section_header "Перезапуск MinIO (${CURRENT_NODE})"
    if ! bcm_confirm "Перезапустить службу minio на этом узле?"; then
        bcm_info "Отменено."; bcm_any_key; return
    fi
    if systemctl restart minio 2>/dev/null; then
        sleep 2
        local health
        health=$(bcm_check_s3_health "$(_s3_local_ip)")
        if [[ "$health" == "ok" ]]; then
            bcm_ok "MinIO перезапущен и отвечает на health-check."
        else
            bcm_warn "MinIO перезапущен, но health-check пока не проходит. См. логи."
        fi
    else
        bcm_error "Не удалось перезапустить minio. Проверьте: systemctl status minio"
    fi
    echo
    bcm_any_key
}

# ──── Состояние Site Replication ─────────────────────────────────────────────
_s3_replication() {
    bcm_section_header "MinIO — Site Replication"
    if ! command -v mc &>/dev/null; then
        bcm_warn "Клиент mc не найден на узле."
        bcm_any_key; return
    fi
    echo
    # Алиас 'site1' создаётся install.sh на первом s3-узле.
    if mc admin replicate info site1 2>/dev/null; then
        :
    else
        bcm_info "Репликация не настроена на этом узле или алиас 'site1' отсутствует."
        bcm_info "Site Replication настраивается с первого s3-узла при установке."
    fi
    echo
    bcm_any_key
}

# ──── Логи MinIO ─────────────────────────────────────────────────────────────
_s3_logs() {
    bcm_section_header "MinIO — последние строки лога"
    echo
    if [[ -f /var/log/minio/minio.log ]]; then
        tail -n 40 /var/log/minio/minio.log
    else
        journalctl -u minio -n 40 --no-pager 2>/dev/null || bcm_warn "Логи MinIO не найдены."
    fi
    echo
    bcm_any_key
}

# ──── Главный цикл ───────────────────────────────────────────────────────────
main() {
    local choice
    while true; do
        bcm_print_header "$APP_VER" "$BENV_VER" "s3" "$CURRENT_NODE"
        local items=(
            "1.  Статус MinIO"
            "2.  Перезапустить службу MinIO"
            "3.  Состояние Site Replication"
            "4.  Показать логи MinIO"
            "0.  Назад"
        )
        bcm_print_menu items
        bcm_read_choice "Введите ваш выбор" choice
        case "$choice" in
            1) _s3_status ;;
            2) _s3_restart ;;
            3) _s3_replication ;;
            4) _s3_logs ;;
            0) exit 0 ;;
            "") : ;;
            *) bcm_warn "Неверный выбор." ;;
        esac
        bcm_clear_cache
    done
}

main "$@"
