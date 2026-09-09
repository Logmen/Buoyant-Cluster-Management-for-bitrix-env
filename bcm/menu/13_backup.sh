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
source "${BCM_LIB_DIR}/bcm_backup_setup.sh"

if ! bcm_conf_exists; then
    bcm_error "cluster.conf не найден. Запустите install.sh."
    exit 1
fi
bcm_load_topology

# ──── Настройка хранилища копий на NFS ──────────────────────────────────────
# Реквизиты внешнего хранилища в файле ответов не хранятся, поэтому цель nfs
# настраивается отсюда: пишем [backup] в cluster.conf, раскатываем backup.env,
# fstab и таймеры на все ноды. Проверка записи делается ДО раскатки — бессмысленно
# ставить таймеры на недоступный экспорт.
_bk_setup_nfs() {
    bcm_section_header "Хранилище резервных копий на NFS"

    local srv exp mnt sub ret
    read -r -p "  Сервер NFS (хост или IP, 0 — отмена): " srv
    [[ "$srv" == "0" || -z "$srv" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    read -r -p "  Экспортируемый путь (напр. /export/backup): " exp
    [[ "$exp" == "0" || -z "$exp" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    read -r -p "  Точка монтирования на нодах [/mnt/bcm-backup]: " mnt
    [[ "$mnt" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ -z "$mnt" ]] && mnt="/mnt/bcm-backup"
    read -r -p "  Подкаталог под этот кластер (пусто — корень экспорта): " sub
    [[ "$sub" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    read -r -p "  Хранить копий, дней [14]: " ret
    [[ "$ret" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ -z "$ret" ]] && ret=14

    echo
    bcm_info "Проверяю доступность экспорта с этой ноды..."
    local probe="/tmp/bcm-nfs-probe.$$"
    # ⚠️ soft+timeo здесь ОСОЗНАННО (в бэкапах — hard): проверка не должна
    # зависнуть навсегда на недоступном хранилище прямо в меню.
    # ⚠️ Подоболочка ( ), а НЕ группа { }: exit внутри группы завершил бы всё меню.
    if ! (
            rpm -q nfs-utils >/dev/null 2>&1 || dnf install -y -q nfs-utils >/dev/null 2>&1
            mkdir -p "$probe"
            mount -t nfs -o rw,soft,timeo=100,retrans=2 "${srv}:${exp}" "$probe" 2>/dev/null || exit 1
            r=1; ( : > "${probe}/.bcm-probe" ) 2>/dev/null && r=0
            rm -f "${probe}/.bcm-probe"
            umount "$probe" 2>/dev/null; rmdir "$probe" 2>/dev/null
            exit $r
        ) 2>/dev/null; then
        bcm_error "Экспорт ${srv}:${exp} недоступен или смонтирован только для чтения."
        bcm_info "Проверьте, что хранилище разрешает запись с адресов нод кластера."
        bcm_any_key; return
    fi
    bcm_ok "Экспорт доступен и пишется."

    echo
    bcm_warn "На все ноды будут раскатаны: запись в /etc/fstab, backup.env и таймеры."
    bcm_confirm "Продолжить?" || { bcm_info "Отменено."; bcm_any_key; return; }

    bcm_conf_set backup target "nfs"
    bcm_conf_set backup nfs_server "$srv"
    bcm_conf_set backup nfs_export "$exp"
    bcm_conf_set backup nfs_mount "$mnt"
    bcm_conf_set backup nfs_subdir "$sub"
    bcm_conf_set backup retention_days "$ret"

    bcm_info "Параметры записаны в cluster.conf."
    bcm_conf_sync 2>/dev/null || true
    echo
    if bcm_confirm "Раскатать на ноды сейчас (nfs-utils, fstab, env, таймеры)?"; then
        bcm_bk_deploy
    else
        bcm_info "Позже — пункт «Раскатать/переприменить бэкап на ноды»."
        bcm_any_key
    fi
}

# ──── Выбор и настройка цели ─────────────────────────────────────────────────
# ⚠️ После смены цели обновляем переменные меню и сбрасываем алиас mc: иначе
# статус и восстановление продолжили бы ходить в СТАРЫЙ бакет со старыми ключами.
_bk_setup_target() {
    bcm_section_header "Хранилище резервных копий"
    bcm_info "Текущая цель: ${BK_TARGET:-не настроена}$([[ "$BK_TARGET" == "s3" ]] && echo " (бакет ${BK_BUCKET}, retention ${BK_RETENTION}д)")"
    echo
    echo "    1. S3 — бакет объектного хранилища (свой MinIO или провайдер)"
    echo "    2. NFS — сетевой каталог"
    echo "    0. Назад"
    echo
    local ch
    bcm_read_choice "Ваш выбор" ch
    case "$ch" in
        1) bcm_bk_s3_setup ;;
        2) _bk_setup_nfs ;;
        *) return ;;
    esac
    BK_TARGET="$(bcm_bk_target)"
    BK_BUCKET="$(bcm_bk_bucket)"
    BK_RETENTION="$(bcm_bk_retention)"
    _BK_MC_READY=0
}

# Хранилище копий: бакет MinIO кластера ИЛИ сетевой каталог NFS.
# ⚠️ Раньше меню целиком блокировалось при отсутствии слоя S3. Это неверно для
# кластеров с внешним хранилищем: цель nfs своего S3 не требует вовсе. Блокируем
# только когда не настроено НИЧЕГО.
BK_TARGET="$(bcm_bk_target)"

if [[ -z "$BK_TARGET" ]]; then
    bcm_section_header "Резервное копирование"
    bcm_error "Хранилище копий не настроено."
    bcm_info "Доступны две цели:"
    bcm_info "  • S3 — бакет объектного хранилища: свой слой MinIO или бакет провайдера"
    bcm_info "    (ОТДЕЛЬНЫЙ от бакета /upload — у копий свои retention и versioning);"
    bcm_info "  • NFS — сетевой каталог внешнего хранилища (S3 не нужен вовсе)."
    bcm_info "Обе настраиваются прямо отсюда, повторный install.sh не требуется."
    echo
    echo "    1. Настроить S3 (бакет для копий)"
    echo "    2. Настроить NFS (сетевой каталог)"
    echo "    0. Выход"
    echo
    bcm_read_choice "Ваш выбор" _bk_first
    case "${_bk_first:-0}" in
        1) bcm_bk_s3_setup ;;
        2) _bk_setup_nfs ;;
        *) bcm_warn "До настройки копии портала и БД делайте внешними средствами."
           bcm_any_key; exit 0 ;;
    esac
    BK_TARGET="$(bcm_bk_target)"
    [[ -z "$BK_TARGET" ]] && exit 0
    bcm_load_topology
fi


BK_LIB="/opt/bcm/bin/lib/bcm_backup.sh"
BK_BUCKET="$(bcm_bk_bucket)"
BK_RETENTION="$(bcm_bk_retention)"

# mc локально (мы на web-ноде; /usr/bin/mc — Midnight Commander, НЕ трогать).
# Авторизация — алиас в /root/.mc/config.json, ключи со stdin (НЕ MC_HOST: mc
# не URL-декодирует userinfo, секрет со спецсимволами ломает парсинг; не argv: ps).
_BK_MC_READY=0
_bk_mc() {
    if [[ $_BK_MC_READY -eq 0 ]]; then
        if ! /usr/local/bin/mc --quiet ls bcmbk/ >/dev/null 2>&1; then
            # ⚠️ Ключи БАКЕТА КОПИЙ: у провайдера ключ обычно скоуплен на один
            # бакет, и ключ от /upload сюда не пустят (bcm_bk_s3_* учитывают это).
            local ep ak sk
            ep="$(bcm_bk_s3_endpoint)"
            ak="$(bcm_bk_s3_access)"
            sk="$(bcm_bk_s3_secret)"
            printf '%s\n%s\n' "$ak" "$sk" \
                | /usr/local/bin/mc --quiet alias set bcmbk "$ep" >/dev/null 2>&1 || true
        fi
        _BK_MC_READY=1
    fi
    /usr/local/bin/mc --quiet "$@"
}

# ⚠️ Всё, что показывает и восстанавливает копии, обязано ветвиться по цели: на S3
# это mc и префикс алиаса, на NFS — обычный путь на смонтированном хранилище.
# Без этого меню после настройки NFS показывало пустой статус и выдавало команды
# восстановления к несуществующему бакету.
_bk_store_root() {
    if [[ "$BK_TARGET" == "s3" ]]; then
        printf 'bcmbk/%s' "$BK_BUCKET"
    else
        local m s
        m="$(bcm_bk_get nfs_mount)"; s="$(bcm_bk_get nfs_subdir)"
        printf '%s%s' "${m:-/mnt/bcm-backup}" "${s:+/$s}"
    fi
}

# Содержимое каталога хранилища (путь — относительно его корня).
_bk_store_ls() {
    if [[ "$BK_TARGET" == "s3" ]]; then
        _bk_mc ls "$(_bk_store_root)/$1" 2>/dev/null
    else
        ls -lh --time-style=long-iso "$(_bk_store_root)/$1" 2>/dev/null \
            | tail -n +2 | awk '{printf "%s %s  %6s  %s\n", $6, $7, $5, $8}'
    fi
}

# Объём каталога хранилища.
_bk_store_du() {
    if [[ "$BK_TARGET" == "s3" ]]; then
        _bk_mc du "$(_bk_store_root)/$1" 2>/dev/null
    else
        du -sh "$(_bk_store_root)/$1" 2>/dev/null | awk '{print $1}'
    fi
}

# ──── 1. Статус ──────────────────────────────────────────────────────────────
_bk_show_status() {
    bcm_section_header "Бэкапы: статус ($([[ "$BK_TARGET" == "s3" ]] && echo "бакет ${BK_BUCKET}" || echo "каталог $(_bk_store_root)"), retention ${BK_RETENTION}д)"

    bcm_color "WHITE" "  ── Конфиги нод (conf/<нода>/, шифрованные) ──"
    local node line
    for node in "${!BCM_NODE_IP[@]}"; do
        line=$(_bk_store_ls "conf/${node}/" | tail -1 | tr -s ' ' || true)
        printf "    %-8s %s\n" "$node" "${line:-(нет копий)}"
    done
    echo
    bcm_color "WHITE" "  ── БД (db/<дата>/) ──"
    _bk_store_ls "db/" | tail -5 | sed 's/^/    /' || echo "    (нет копий)"
    echo
    # История файлов устроена по-разному: на S3 это версии объектов в одном префиксе,
    # на NFS — датированные снимки www/<дата> (разница между ними ужата жёсткими ссылками).
    if [[ "$BK_TARGET" == "s3" ]]; then
        bcm_color "WHITE" "  ── Файлы портала (www/, история — versioning) ──"
        _bk_store_du "www" | sed 's/^/    объём: /' || echo "    (нет копий)"
    else
        bcm_color "WHITE" "  ── Файлы портала (www/<дата>/, история — снимки) ──"
        _bk_store_du "www" | sed 's/^/    объём всех снимков: /' || echo "    (нет копий)"
        _bk_store_ls "www/" | tail -5 | sed 's/^/    снимок: /' || true
    fi
    _bk_store_ls "files/" | tail -3 | sed 's/^/    маркер: /' || true
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
            # ⚠️ Результат берём у исполнителя, а не печатаем «Готово» безусловно:
            # частичный сбой (rsync с кодом 23, недописанный маркер) выглядел бы
            # успехом, и о нерабочей копии узнали бы только при восстановлении.
            local out rc
            out=$(bcm_ssh_exec_timeout "$ip" 1800 "${BK_LIB} --files --force" 2>&1); rc=$?
            echo "$out" | tail -2 | sed 's/^/    /'
            if [[ $rc -eq 0 ]]; then
                bcm_ok "  Готово."
            else
                bcm_error "  ${node}: копия файлов не удалась (код ${rc}) — см. /var/log/bcm/backup.log."
            fi
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
    local root; root="$(_bk_store_root)"
    echo

    if [[ "$BK_TARGET" == "s3" ]]; then
        bcm_color "WHITE" "  ── Конфиги ноды (расшифровать архив) ──"
        bcm_info '  enc_key — в cluster.conf [backup]; выполнять на ноде:'
        echo "    /usr/local/bin/mc cp ${root}/conf/<нода>/<дата>.tar.gz.enc /root/"
        echo "    openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:<enc_key> -in /root/<дата>.tar.gz.enc | tar -tzv   # просмотр"
        echo "    ... | tar -xz -C /   # восстановить (ОСТОРОЖНО: поверх текущих)"
        echo
        bcm_color "WHITE" "  ── Файл портала из истории версий www/ ──"
        echo "    /usr/local/bin/mc ls --versions ${root}/www/<путь>     # список версий"
        echo "    /usr/local/bin/mc cp --version-id <id> ${root}/www/<путь> /root/"
        echo
        bcm_color "WHITE" "  ── БД (DR: развернуть кластер из копии) ──"
        bcm_info "  На чистой PXC-ноде (или все лежат — на будущем writer'е):"
        echo "    systemctl stop mysql; rm -rf /var/lib/mysql/*"
        echo "    /usr/local/bin/mc cat ${root}/db/<дата>/<нода>.xbstream.gz | gunzip | xbstream -x -C /var/lib/mysql"
    else
        bcm_info "  Хранилище смонтировано на каждой ноде: ${root} — копии читаются как обычные файлы."
        echo
        bcm_color "WHITE" "  ── Конфиги ноды (расшифровать архив) ──"
        bcm_info '  enc_key — в cluster.conf [backup]; выполнять на ноде:'
        echo "    ls ${root}/conf/<нода>/"
        echo "    openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:<enc_key> -in ${root}/conf/<нода>/<дата>.tar.gz.enc | tar -tzv   # просмотр"
        echo "    ... | tar -xz -C /   # восстановить (ОСТОРОЖНО: поверх текущих)"
        echo
        bcm_color "WHITE" "  ── Файлы портала из снимка www/<дата>/ ──"
        bcm_info "  История здесь — датированные снимки (versioning'а нет), разница ужата жёсткими ссылками:"
        echo "    ls ${root}/www/                                  # доступные снимки"
        echo "    cp -a ${root}/www/<дата>/<путь> /home/bitrix/www/<путь>          # один файл"
        echo "    rsync -a ${root}/www/<дата>/ /home/bitrix/www/                    # дерево целиком"
        bcm_warn "  После восстановления обязательно вернуть владельца: chown -R bitrix:bitrix <путь>"
        bcm_info "  Сетевое хранилище обычно сквошит root, поэтому владелец в копии не сохраняется."
        echo
        bcm_color "WHITE" "  ── БД (DR: развернуть кластер из копии) ──"
        bcm_info "  На чистой PXC-ноде (или все лежат — на будущем writer'е):"
        echo "    systemctl stop mysql; rm -rf /var/lib/mysql/*"
        echo "    gunzip < ${root}/db/<дата>/<нода>.xbstream.gz | xbstream -x -C /var/lib/mysql"
    fi

    echo "    xtrabackup --prepare --target-dir=/var/lib/mysql"
    echo "    chown -R mysql:mysql /var/lib/mysql"
    echo "    # выставить safe_to_bootstrap:1 в grastate.dat и: systemctl start mysql@bootstrap"
    echo "    # остальные ноды: rm -rf /var/lib/mysql/* && systemctl start mysql  (придут по SST)"
    echo
    bcm_info "  Доступные копии БД:"
    _bk_store_ls "db/" | tail -7 | sed 's/^/    /' || echo "    (нет)"
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
        bcm_section_header "Резервное копирование (${BK_TARGET}$([[ "$BK_TARGET" == "s3" ]] && echo ": ${BK_BUCKET}"), HA-aware)"
        local menu_items=(
            "1.  Статус бэкапов (все типы, таймеры по нодам)"
            "2.  Бэкап конфигов сейчас (все ноды)"
            "3.  Бэкап БД сейчас (Synced-реплика PXC)"
            "4.  Бэкап файлов портала сейчас (источник lsyncd)"
            "5.  Восстановление (копии и процедуры)"
            "6.  Offsite-копия (вторая линия)"
            "7.  Настроить хранилище копий (S3 / NFS)"
            "8.  Раскатать/переприменить бэкап на ноды"
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
            7) _bk_setup_target ;;
            8) bcm_bk_deploy ;;
            0) return 0 ;;
            *) bcm_warn "Неверный выбор." ;;
        esac
    done
}

_bk_menu
