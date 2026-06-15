#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 13_backup.sh — Резервное копирование (HA-aware, MinIO S3)
#
# Исполнитель — bin/lib/bcm_backup.sh на нодах (таймеры + гейты по роли);
# меню — статус, ручной запуск, restore-подсказки. Схема:
#   conf  — каждая нода, шифрованный tar конфигов/состояния → conf/<нода>/<дата>
#   db    — Synced-реплика PXC (кандидаты с маркером в S3) → db/<дата>/
#   files — текущий источник lsyncd → mirror www/ (история = versioning бакета)
# Retention применяет lifecycle MinIO. Offsite-копия — пункт 6 (вторая линия).
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

BK_LIB="/opt/bcm/bin/lib/bcm_backup.sh"
BK_BUCKET="$(bcm_conf_get backup bucket 2>/dev/null || echo bitrix-backups)"
BK_RETENTION="$(bcm_conf_get backup retention_days 2>/dev/null || echo 14)"

# mc локально (мы на web-ноде; /usr/bin/mc — Midnight Commander, НЕ трогать).
# Авторизация — алиас в /root/.mc/config.json, ключи со stdin (НЕ MC_HOST: mc
# не URL-декодирует userinfo, секрет со спецсимволами ломает парсинг; не argv: ps).
_BK_MC_READY=0
_bk_mc() {
    if [[ $_BK_MC_READY -eq 0 ]]; then
        if ! /usr/local/bin/mc --quiet ls bcmbk/ >/dev/null 2>&1; then
            local ep ak sk
            ep="$(bcm_conf_get s3_upload endpoint 2>/dev/null || echo '')"
            ak="$(bcm_conf_get s3_upload access_key 2>/dev/null || echo '')"
            sk="$(bcm_conf_get s3_upload secret_key 2>/dev/null || echo '')"
            printf '%s\n%s\n' "$ak" "$sk" \
                | /usr/local/bin/mc --quiet alias set bcmbk "$ep" >/dev/null 2>&1 || true
        fi
        _BK_MC_READY=1
    fi
    /usr/local/bin/mc --quiet "$@"
}

# ──── 1. Статус ──────────────────────────────────────────────────────────────
_bk_show_status() {
    bcm_section_header "Бэкапы: статус (бакет ${BK_BUCKET}, retention ${BK_RETENTION}д)"

    bcm_color "WHITE" "  ── Конфиги нод (conf/<нода>/, шифрованные) ──"
    local node line
    for node in "${!BCM_NODE_IP[@]}"; do
        line=$(_bk_mc ls "bcmbk/${BK_BUCKET}/conf/${node}/" 2>/dev/null | tail -1 | tr -s ' ' || true)
        printf "    %-8s %s\n" "$node" "${line:-(нет копий)}"
    done
    echo
    bcm_color "WHITE" "  ── БД (db/<дата>/) ──"
    _bk_mc ls "bcmbk/${BK_BUCKET}/db/" 2>/dev/null | tail -5 | sed 's/^/    /' || echo "    (нет копий)"
    echo
    bcm_color "WHITE" "  ── Файлы портала (www/, история — versioning) ──"
    _bk_mc du "bcmbk/${BK_BUCKET}/www" 2>/dev/null | sed 's/^/    объём: /' || echo "    (нет копий)"
    _bk_mc ls "bcmbk/${BK_BUCKET}/files/" 2>/dev/null | tail -3 | sed 's/^/    маркер: /' || true
    echo
    bcm_color "WHITE" "  ── Таймеры по нодам ──"
    for node in "${!BCM_NODE_IP[@]}"; do
        local ip="${BCM_NODE_IP[$node]}"
        local t
        t=$(bcm_ssh_exec_timeout "$ip" 8 \
            "systemctl list-timers 'bcm-backup-*' --no-pager --no-legend 2>/dev/null | awk '{print \$NF}' | paste -sd, -" 2>/dev/null) || t="?"
        printf "    %-8s %s\n" "$node" "${t:-—}"
    done
    bcm_any_key
}

# ──── 2-4. Ручной запуск ─────────────────────────────────────────────────────
_bk_run_conf() {
    bcm_section_header "Бэкап конфигов: запустить на всех нодах"
    bcm_confirm "Запустить?" || { bcm_any_key; return; }
    local node ip
    for node in "${!BCM_NODE_IP[@]}"; do
        ip="${BCM_NODE_IP[$node]}"
        bcm_ssh_exec_timeout "$ip" 60 "${BK_LIB} --conf" >/dev/null 2>&1 \
            && bcm_ok "  ${node}: ок" || bcm_error "  ${node}: ошибка (см. /var/log/bcm/backup.log)"
    done
    bcm_any_key
}

_bk_run_db() {
    bcm_section_header "Бэкап БД: запустить сейчас (Synced-реплика)"
    bcm_info "Кандидаты пробуются по порядку (реплики раньше writer'а), бэкапит первый Synced."
    bcm_confirm "Запустить? (на время бэкапа нода в wsrep_desync)" || { bcm_any_key; return; }
    local node ip out
    for node in "${BCM_NODES_PXC[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        bcm_node_reachable "$ip" 5 2>/dev/null || { bcm_warn "  ${node}: недоступен."; continue; }
        bcm_info "  ${node}: пробую..."
        if out=$(bcm_ssh_exec_timeout "$ip" 1800 "${BK_LIB} --db --force" 2>&1); then
            echo "$out" | tail -2 | sed 's/^/    /'
            bcm_ok "  ${node}: бэкап БД выполнен."
            bcm_any_key; return
        else
            echo "$out" | tail -2 | sed 's/^/    /'
            bcm_warn "  ${node}: не получилось, пробую следующего кандидата."
        fi
    done
    bcm_error "Ни один PXC-кандидат не смог сделать бэкап."
    bcm_any_key
}

_bk_run_files() {
    bcm_section_header "Бэкап файлов портала: запустить сейчас (источник lsyncd)"
    bcm_confirm "Запустить?" || { bcm_any_key; return; }
    local node ip
    for node in "${BCM_NODES_WEB[@]}"; do
        ip="${BCM_NODE_IP[$node]:-}"
        [[ -z "$ip" ]] && continue
        if bcm_ssh_exec_timeout "$ip" 8 "systemctl is-active lsyncd" 2>/dev/null | grep -q active; then
            bcm_info "  Источник lsyncd: ${node} — запускаю mirror..."
            bcm_ssh_exec_timeout "$ip" 1800 "${BK_LIB} --files --force" 2>&1 | tail -2 | sed 's/^/    /'
            bcm_ok "  Готово."
            bcm_any_key; return
        fi
    done
    bcm_error "Источник lsyncd не найден (lsyncd нигде не active)."
    bcm_any_key
}

# ──── 5. Восстановление (копии + процедуры) ──────────────────────────────────
_bk_restore_help() {
    bcm_section_header "Восстановление из бэкапа"
    bcm_warn "Восстановление — ручная операция по процедуре. Команды ниже — готовые к копированию."
    echo
    bcm_color "WHITE" "  ── Конфиги ноды (расшифровать архив) ──"
    bcm_info '  enc_key — в cluster.conf [backup]; выполнять на ноде:'
    echo "    /usr/local/bin/mc cp bcmbk/${BK_BUCKET}/conf/<нода>/<дата>.tar.gz.enc /root/"
    echo "    openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:<enc_key> -in /root/<дата>.tar.gz.enc | tar -tzv   # просмотр"
    echo "    ... | tar -xz -C /   # восстановить (ОСТОРОЖНО: поверх текущих)"
    echo
    bcm_color "WHITE" "  ── Файл портала из истории версий www/ ──"
    echo "    /usr/local/bin/mc ls --versions bcmbk/${BK_BUCKET}/www/<путь>     # список версий"
    echo "    /usr/local/bin/mc cp --version-id <id> bcmbk/${BK_BUCKET}/www/<путь> /root/"
    echo
    bcm_color "WHITE" "  ── БД (DR: развернуть кластер из копии) ──"
    bcm_info "  На чистой PXC-ноде (или все лежат — на будущем writer'е):"
    echo "    systemctl stop mysql; rm -rf /var/lib/mysql/*"
    echo "    /usr/local/bin/mc cat bcmbk/${BK_BUCKET}/db/<дата>/<нода>.xbstream.gz | gunzip | xbstream -x -C /var/lib/mysql"
    echo "    xtrabackup --prepare --target-dir=/var/lib/mysql"
    echo "    chown -R mysql:mysql /var/lib/mysql"
    echo "    # выставить safe_to_bootstrap:1 в grastate.dat и: systemctl start mysql@bootstrap"
    echo "    # остальные ноды: rm -rf /var/lib/mysql/* && systemctl start mysql  (придут по SST)"
    echo
    bcm_info "  Доступные копии БД:"
    _bk_mc ls "bcmbk/${BK_BUCKET}/db/" 2>/dev/null | tail -7 | sed 's/^/    /' || echo "    (нет)"
    bcm_any_key
}

# ──── 6. Offsite (вторая линия) ──────────────────────────────────────────────
_bk_offsite_help() {
    bcm_section_header "Offsite-копия (вторая линия, 3-2-1)"
    bcm_warn "Бэкап в MinIO кластера защищает от ошибок оператора и отказа ноды,"
    bcm_warn "но НЕ от потери кластера целиком (пожар/гипервизор/шифровальщик)."
    echo
    bcm_info "Когда появится внешнее S3/MinIO-хранилище — на s3-ноде (источник зеркала):"
    echo "    mc alias set offsite https://<внешний-endpoint> <access> <secret>"
    echo "    mc mirror --overwrite --remove site1/${BK_BUCKET} offsite/${BK_BUCKET}"
    echo "    # повесить в cron/таймер после окна бэкапов (например, 06:00)"
    echo
    bcm_info "Я могу автоматизировать это (env + таймер), когда будет endpoint."
    bcm_any_key
}

# ──── Меню ───────────────────────────────────────────────────────────────────
_bk_menu() {
    while true; do
        bcm_section_header "Резервное копирование (S3/MinIO, HA-aware)"
        local menu_items=(
            "1.  Статус бэкапов (все типы, таймеры по нодам)"
            "2.  Бэкап конфигов сейчас (все ноды)"
            "3.  Бэкап БД сейчас (Synced-реплика PXC)"
            "4.  Бэкап файлов портала сейчас (источник lsyncd)"
            "5.  Восстановление (копии и процедуры)"
            "6.  Offsite-копия (вторая линия)"
            "0.  Назад"
        )
        bcm_print_menu menu_items

        local choice
        bcm_read_choice "Введите ваш выбор" choice
        case "$choice" in
            1) _bk_show_status ;;
            2) _bk_run_conf ;;
            3) _bk_run_db ;;
            4) _bk_run_files ;;
            5) _bk_restore_help ;;
            6) _bk_offsite_help ;;
            0) return 0 ;;
            *) bcm_warn "Неверный выбор." ;;
        esac
    done
}

_bk_menu
