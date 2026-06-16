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

# ──── Перенос хранилища MinIO на выделенный диск ─────────────────────────────
# Для УЖЕ развёрнутой ноды: форматирует выбранное блочное устройство (xfs/ext4),
# монтирует его в /var/lib/minio (fstab по UUID) и ПЕРЕНОСИТ существующие данные
# MinIO на новый диск. Алгоритм формата/монтирования совпадает с install.sh
# (prepare_s3_data_disk) — здесь добавлены stop/preserve/restore и откат при сбое.
# ⚠️ Делать ПО ОДНОЙ ноде: реплика-пир продолжает обслуживать запросы, а нода
# до-синхронизируется через Site Replication. Форматирование УНИЧТОЖАЕТ данные на
# устройстве; данные MinIO сохраняются (переносятся), при сбое — откат на исходное.
_s3_migrate_disk() {
    local mount="/var/lib/minio"
    local bak="/var/lib/minio.bcm-migrate-bak"
    bcm_section_header "MinIO — перенос хранилища на выделенный диск (${CURRENT_NODE})"
    echo

    # Уже на выделенном диске? (точка монтирования /var/lib/minio существует)
    local cur_src
    cur_src="$(findmnt -rno SOURCE "$mount" 2>/dev/null || true)"
    if [[ -n "$cur_src" ]]; then
        bcm_ok "Хранилище уже на выделенном диске: ${cur_src} → ${mount}"
        bcm_info "Перенос не требуется."
        bcm_any_key; return
    fi

    local cur_fs cur_used
    cur_fs="$(findmnt -T "$mount" -no SOURCE 2>/dev/null || true)"
    cur_used="$(du -sh "${mount}/data" 2>/dev/null | awk '{print $1}' || true)"
    bcm_info "Сейчас данные MinIO на корневой ФС (${cur_fs:-?}), объём данных: ${cur_used:-?}."
    echo

    echo "  Доступные блочные устройства:"
    echo
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/    /'
    echo
    bcm_warn "Выберите ПУСТОЙ диск без точек монтирования. Системный/корневой диск выбирать НЕЛЬЗЯ."
    echo

    local dev
    read -r -p "  Устройство под хранилище (напр. /dev/sdb; 0 — отмена): " dev
    [[ "$dev" == "0" || -z "$dev" ]] && { bcm_info "Отменено."; bcm_any_key; return; }

    if [[ ! -b "$dev" ]]; then
        bcm_error "Устройство $dev не найдено или не является блочным."
        bcm_any_key; return
    fi
    # Устройство и его разделы не должны быть смонтированы (это отсекает системный диск).
    # ⚠️ НЕ `grep -c` (печатает 0 и выходит rc=1 при нуле → под set -e/pipefail убивает
    # скрипт именно на валидном ПУСТОМ диске). Берём непустые строки точек монтирования.
    local inuse
    inuse="$(lsblk -nro MOUNTPOINT "$dev" 2>/dev/null | grep -v '^[[:space:]]*$' || true)"
    if [[ -n "$inuse" ]]; then
        bcm_error "На $dev есть смонтированные разделы — это системный/занятый диск. Выбор отклонён."
        lsblk "$dev" 2>/dev/null | sed 's/^/    /'
        bcm_any_key; return
    fi

    local fs
    read -r -p "  Файловая система xfs|ext4 (Enter — xfs): " fs
    fs="${fs:-xfs}"
    if [[ "$fs" != "xfs" && "$fs" != "ext4" ]]; then
        bcm_error "Неподдерживаемая ФС '$fs' (поддерживаются xfs|ext4)."
        bcm_any_key; return
    fi

    # Существующая ФС на устройстве → отдельное подтверждение (на диске будут стёрты данные).
    local existing_fs
    existing_fs="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    if [[ -n "$existing_fs" ]]; then
        bcm_warn "На $dev уже есть ФС ($existing_fs) — при переносе она будет УНИЧТОЖЕНА."
        if ! bcm_confirm "Точно отформатировать $dev и стереть его текущее содержимое?"; then
            bcm_info "Отменено."; bcm_any_key; return
        fi
    fi

    echo
    bcm_warn "Будет выполнено: stop minio → mkfs.${fs} ${dev} → монтирование в ${mount} → перенос данных (${cur_used:-?}) → start minio."
    bcm_warn "Выполняйте ПО ОДНОЙ ноде — пир продолжит обслуживать запросы."
    if ! bcm_confirm "Продолжить перенос на ${dev}?"; then
        bcm_info "Отменено."; bcm_any_key; return
    fi

    # ── Критическая секция: ошибки обрабатываем вручную, с откатом на исходное ──
    set +e
    local rc=0

    bcm_info "Остановка minio..."
    systemctl stop minio; rc=$?
    if [[ $rc -ne 0 ]]; then bcm_error "Не удалось остановить minio."; set -e; bcm_any_key; return; fi

    if [[ -e "$bak" ]]; then
        bcm_error "Каталог $bak уже существует (остаток прошлой попытки) — разберите вручную перед повтором."
        systemctl start minio; set -e; bcm_any_key; return
    fi

    bcm_info "Откладывание текущих данных ($mount → $bak)..."
    mv "$mount" "$bak"; rc=$?
    if [[ $rc -ne 0 ]]; then bcm_error "Не удалось отложить $mount."; systemctl start minio; set -e; bcm_any_key; return; fi
    mkdir -p "$mount"

    bcm_info "Форматирование $dev в $fs..."
    if [[ "$fs" == "xfs" ]]; then mkfs.xfs -f "$dev"; else mkfs.ext4 -F "$dev"; fi
    rc=$?
    if [[ $rc -ne 0 ]]; then
        bcm_error "mkfs не удался — откат на исходное расположение."
        rmdir "$mount" 2>/dev/null; mv "$bak" "$mount"; systemctl start minio
        set -e; bcm_any_key; return
    fi

    local uuid
    uuid="$(blkid -o value -s UUID "$dev")"
    if [[ -z "$uuid" ]]; then
        bcm_error "Не удалось получить UUID $dev — откат."
        rmdir "$mount" 2>/dev/null; mv "$bak" "$mount"; systemctl start minio
        set -e; bcm_any_key; return
    fi

    # Монтирование по UUID (устойчиво к перенумерации устройств при перезагрузке).
    if ! grep -q "UUID=${uuid}[[:space:]]" /etc/fstab; then
        echo "UUID=$uuid $mount $fs defaults,noatime 0 2" >> /etc/fstab
    fi

    bcm_info "Монтирование $dev в $mount..."
    mount "$mount"; rc=$?
    if [[ $rc -ne 0 ]]; then
        bcm_error "mount не удался — откат."
        sed -i "\|UUID=${uuid}[[:space:]]|d" /etc/fstab
        rmdir "$mount" 2>/dev/null; mv "$bak" "$mount"; systemctl start minio
        set -e; bcm_any_key; return
    fi

    bcm_info "Перенос данных на диск (это может занять время)..."
    if command -v rsync &>/dev/null; then
        rsync -aHAX "${bak}/" "${mount}/"; rc=$?
    else
        cp -a "${bak}/." "${mount}/"; rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        bcm_error "Перенос данных не удался — откат на исходное расположение."
        umount "$mount" 2>/dev/null
        sed -i "\|UUID=${uuid}[[:space:]]|d" /etc/fstab
        rmdir "$mount" 2>/dev/null; mv "$bak" "$mount"; systemctl start minio
        set -e; bcm_any_key; return
    fi

    bcm_info "Запуск minio..."
    systemctl start minio
    sleep 4
    local health
    health="$(bcm_check_s3_health "$(_s3_local_ip)")"
    set -e

    echo
    if [[ "$health" == "ok" ]]; then
        bcm_ok "Перенос завершён. Хранилище MinIO теперь на ${dev} (${fs}), смонтировано в ${mount}."
        bcm_info "fstab: UUID=${uuid} ${mount} ${fs} defaults,noatime 0 2 (переживёт перезагрузку)."
        rm -rf "$bak"
        bcm_info "Временная копия ${bak} удалена."
        echo
        df -h "$mount" 2>/dev/null | sed 's/^/    /'
    else
        bcm_warn "Данные перенесены и смонтированы на ${dev}, но health-check MinIO пока не проходит."
        bcm_warn "Исходная копия СОХРАНЕНА в ${bak}. Проверьте: systemctl status minio; /var/log/minio/minio.log"
        bcm_warn "Ручной откат: systemctl stop minio; umount ${mount}; убрать строку 'UUID=${uuid}' из /etc/fstab; rmdir ${mount}; mv ${bak} ${mount}; systemctl start minio"
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
            "5.  Перенести хранилище на выделенный диск"
            "0.  Назад"
        )
        bcm_print_menu items
        bcm_read_choice "Введите ваш выбор" choice
        case "$choice" in
            1) _s3_status ;;
            2) _s3_restart ;;
            3) _s3_replication ;;
            4) _s3_logs ;;
            5) _s3_migrate_disk ;;
            0) exit 0 ;;
            "") : ;;
            *) bcm_warn "Неверный выбор." ;;
        esac
        bcm_clear_cache
    done
}

main "$@"
