#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_backup_setup.sh — настройка цели резервного копирования и раскатка
# исполнителя (bin/lib/bcm_backup.sh) на ноды.
#
# Зачем отдельная библиотека. Раньше S3-цель умел настраивать ТОЛЬКО install.sh и
# только для СВОЕГО слоя MinIO: бакет он создавал сам (админские права есть),
# endpoint собирал как https://<VIP>:9000, ключи брал из файла ответов. Меню 13
# предлагало лишь NFS и заканчивалось «переприменить install.sh». Для кластера с
# ВНЕШНИМ хранилищем это не работает: бакет и ключи даёт провайдер, а полный
# прогон install.sh на живом кластере ради бэкапов — несоразмерная операция.
#
# Здесь: интерактивная настройка цели (s3 на любом бакете + nfs) и раскатка
# backup.env, юнитов и таймеров на ноды теми же bcm_ssh-хелперами.
#
# ⚠️ Формат backup.env и юнитов ОБЯЗАН совпадать с install.sh::configure_backup —
# держать синхронными: иначе повторный install.sh перезапишет раскатанное отсюда
# другим набором ключей, и таймеры начнут падать.
#
# ⚠️ Ключи в argv не передаём (видны в ps) — mc получает их через stdin.
# =============================================================================

_BK_MC="/usr/local/bin/mc"          # НЕ /usr/bin/mc — там Midnight Commander
_BK_SETUP_ALIAS="bcmbkchk"          # временный алиас проверки (снимаем за собой)

# ──── Параметры цели из cluster.conf ─────────────────────────────────────────
bcm_bk_get() { bcm_conf_get backup "$1" 2>/dev/null || echo ''; }

# s3 | nfs | '' (не настроено). Своя S3-нода без явной цели — исторически s3.
bcm_bk_target() {
    local v; v="$(bcm_bk_get target)"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
    bcm_s3_enabled && echo s3 || echo ''
}

bcm_bk_bucket()    { local v; v="$(bcm_bk_get bucket)";         echo "${v:-bitrix-backups}"; }
bcm_bk_retention() { local v; v="$(bcm_bk_get retention_days)"; echo "${v:-14}"; }
# Схема «дед-отец-сын» сверх ежедневных копий — только для цели nfs: на S3 сроком
# хранения распоряжается lifecycle бакета, а он умеет лишь «удалить старше N дней».
# 0 = уровень выключен, и политика вырождается в прежнюю «хранить N дней».
bcm_bk_retention_weeks()  { local v; v="$(bcm_bk_get retention_weeks)";  echo "${v:-0}"; }
# /upload в копии файлов: auto (по умолчанию — входит) | off (прежнее «он в облаке»).
bcm_bk_include_upload()   { local v; v="$(bcm_bk_get include_upload)";   echo "${v:-auto}"; }
bcm_bk_retention_months() { local v; v="$(bcm_bk_get retention_months)"; echo "${v:-0}"; }

# ⚠️ Креды копий: [backup] ПЕРЕКРЫВАЕТ [s3_upload]. Отдельные ключи — не
# паранойя, а норма у провайдеров: политика скоупится на ОДИН бакет (s3:* только
# на свой), поэтому ключ от /upload в бакет копий просто не пустят. Пусто в
# [backup] = «те же ключи, что у /upload» (свой слой MinIO — обычно этот случай).
bcm_bk_s3_endpoint() { local v; v="$(bcm_bk_get endpoint)";   [[ -n "$v" ]] && { echo "$v"; return 0; }; bcm_conf_get s3_upload endpoint   2>/dev/null || echo ''; }
bcm_bk_s3_access()   { local v; v="$(bcm_bk_get access_key)"; [[ -n "$v" ]] && { echo "$v"; return 0; }; bcm_conf_get s3_upload access_key 2>/dev/null || echo ''; }
bcm_bk_s3_secret()   { local v; v="$(bcm_bk_get secret_key)"; [[ -n "$v" ]] && { echo "$v"; return 0; }; bcm_conf_get s3_upload secret_key 2>/dev/null || echo ''; }

# Нода для проб: web (у неё тот же сетевой путь наружу, что у будущих таймеров).
_bk_probe_ip() {
    local n
    for n in "${BCM_NODES_WEB[@]}"; do
        [[ -n "$n" ]] || continue
        local ip="${BCM_NODE_IP[$n]:-}"
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    done
    return 1
}

_bk_ensure_mc() {
    local ip="$1"
    bcm_ssh_exec "$ip" "test -x ${_BK_MC}" </dev/null && return 0
    bcm_warn "  На ноде нет ${_BK_MC} — без него бэкапы в S3 не работают."
    bcm_confirm "Скачать mc с dl.min.io на ноду?" || return 1
    bcm_ssh_exec_timeout "$ip" 180 \
        "curl -fsSL -o ${_BK_MC} https://dl.min.io/client/mc/release/linux-amd64/mc && chmod +x ${_BK_MC}" </dev/null
    bcm_ssh_exec "$ip" "test -x ${_BK_MC}" </dev/null
}

# ──── Проверка доступа к бакету копий ────────────────────────────────────────
# Аргументы: ip endpoint bucket access secret. Возвращает 0, если бакет годится.
_bk_verify_s3() {
    local ip="$1" endpoint="$2" bucket="$3" access="$4" secret="$5"
    local fails=0

    local ls_out
    ls_out=$(bcm_ssh_exec_timeout "$ip" 60 \
        "${_BK_MC} --quiet alias set ${_BK_SETUP_ALIAS} '${endpoint}' --api s3v4 >/dev/null 2>&1 || { echo ALIAS_FAIL; exit 0; }
         ${_BK_MC} --quiet ls '${_BK_SETUP_ALIAS}/${bucket}' >/dev/null 2>&1 && echo LIST_OK || echo LIST_FAIL" \
        <<< "${access}
${secret}" | tr -d '[:space:]')
    case "$ls_out" in
        *LIST_OK*)    bcm_ok    "  бакет '${bucket}' виден с ноды, ключи приняты" ;;
        *ALIAS_FAIL*) bcm_error "  mc не принял endpoint ${endpoint}"; fails=$((fails+1)) ;;
        *)            bcm_error "  бакет '${bucket}' не читается — проверьте имя и права ключа"; fails=$((fails+1)) ;;
    esac

    # Запись/чтение/удаление: бэкапы без записи бессмысленны, а «только запись»
    # ломает проверки маркеров (_bk_exists) и восстановление.
    local rw
    rw=$(bcm_ssh_exec_timeout "$ip" 90 \
        "t=/tmp/.bcm-bkprobe.\$\$; echo bcm-backup-probe > \$t
         ${_BK_MC} --quiet cp \$t '${_BK_SETUP_ALIAS}/${bucket}/.bcm-probe' >/dev/null 2>&1 || { echo PUT_FAIL; rm -f \$t; exit 0; }
         got=\$(${_BK_MC} --quiet cat '${_BK_SETUP_ALIAS}/${bucket}/.bcm-probe' 2>/dev/null)
         ${_BK_MC} --quiet rm '${_BK_SETUP_ALIAS}/${bucket}/.bcm-probe' >/dev/null 2>&1 || echo DEL_FAIL
         rm -f \$t
         [ \"\$got\" = 'bcm-backup-probe' ] && echo RW_OK || echo GET_FAIL" </dev/null | tr -d '[:space:]')
    case "$rw" in
        *RW_OK*)    bcm_ok    "  запись, чтение и удаление в бакете работают" ;;
        *PUT_FAIL*) bcm_error "  нет прав на запись в бакет копий"; fails=$((fails+1)) ;;
        *)          bcm_error "  объект записан, но не прочитан/не удалён (${rw:-нет ответа})"; fails=$((fails+1)) ;;
    esac

    # Versioning — не блокирующее, но это ЕДИНСТВЕННАЯ защита копии кода (www/)
    # от перезаписи: mirror затирает объект, история живёт только в версиях.
    local ver
    ver=$(bcm_ssh_exec_timeout "$ip" 40 \
        "${_BK_MC} --quiet version info '${_BK_SETUP_ALIAS}/${bucket}' 2>/dev/null | head -2" </dev/null 2>/dev/null)
    if [[ "$ver" == *"is enabled"* ]]; then
        bcm_ok "  versioning включён — история www/ и защита от перезаписи есть"
    else
        bcm_warn "  versioning на бакете НЕ включён (или его не видно этим ключом):"
        bcm_info  "    без него mirror затирает вчерашнюю копию кода без права отката."
        bcm_info  "    Включить на стороне хранилища: mc version enable <alias>/${bucket}"
    fi

    bcm_ssh_exec "$ip" "${_BK_MC} --quiet alias rm ${_BK_SETUP_ALIAS} >/dev/null 2>&1 || true" </dev/null
    [[ $fails -eq 0 ]]
}

# ──── Настройка цели S3 ──────────────────────────────────────────────────────
bcm_bk_s3_setup() {
    bcm_section_header "Хранилище резервных копий: бакет S3"

    local ip; ip=$(_bk_probe_ip) || { bcm_error "Не найдена web-нода для проверки."; bcm_any_key; return; }
    _bk_ensure_mc "$ip" || { bcm_error "Без mc проверить доступ нельзя."; bcm_any_key; return; }

    local up_ep up_bucket
    up_ep="$(bcm_conf_get s3_upload endpoint 2>/dev/null || echo '')"
    up_bucket="$(bcm_conf_get s3_upload bucket 2>/dev/null || echo '')"
    if [[ -n "$up_ep" ]]; then
        bcm_info "Хранилище /upload: ${up_ep} (бакет ${up_bucket})."
        bcm_info "Копии кладём в ОТДЕЛЬНЫЙ бакет: bucket-policy, lifecycle и versioning"
        bcm_info "у копий свои, а общий бакет смешал бы данные портала с его же резервом."
    fi
    echo

    local endpoint bucket ret access secret same_keys=0
    bcm_read_choice "Эндпоинт со схемой${up_ep:+ [$up_ep]} (0 — отмена)" endpoint
    [[ "${endpoint:-0}" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ -z "$endpoint" ]] && endpoint="$up_ep"
    [[ "$endpoint" =~ ^https?:// ]] || { bcm_error "Эндпоинт должен начинаться с http:// или https://"; bcm_any_key; return; }

    bcm_read_choice "Бакет для копий [bitrix-backups] (0 — отмена)" bucket
    [[ "${bucket:-}" == "0" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ -z "$bucket" ]] && bucket="bitrix-backups"
    if [[ "$endpoint" == "$up_ep" && "$bucket" == "$up_bucket" ]]; then
        bcm_error "Это тот же бакет, что у /upload. Копии обязаны лежать отдельно:"
        bcm_info  "  их retention и versioning другие, а удаление бакета унесло бы и копии."
        bcm_any_key; return
    fi

    bcm_read_choice "Хранить копии, дней [14]" ret
    [[ -z "$ret" ]] && ret=14
    [[ "$ret" =~ ^[0-9]+$ ]] || { bcm_error "Retention — число дней."; bcm_any_key; return; }

    if [[ -n "$(bcm_conf_get s3_upload access_key 2>/dev/null || echo '')" ]] \
       && bcm_confirm "Использовать ключи от хранилища /upload?"; then
        same_keys=1
        access="$(bcm_conf_get s3_upload access_key)"
        secret="$(bcm_conf_get s3_upload secret_key)"
    else
        bcm_read_choice "Access key бакета копий (0 — отмена)" access
        [[ "${access:-0}" == "0" || -z "${access:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
        printf "  %bSecret key:%b " "$BCM_COLOR_CYAN_BOLD" "$BCM_COLOR_RESET"
        read -r -s secret; echo
        [[ -z "${secret:-}" ]] && { bcm_error "Secret key пуст."; bcm_any_key; return; }
    fi

    echo
    bcm_info "Проверяю доступ с ноды ${ip}..."
    if ! _bk_verify_s3 "$ip" "$endpoint" "$bucket" "$access" "$secret"; then
        echo; bcm_error "Проверка не пройдена — в конфиг ничего не записано."
        bcm_any_key; return
    fi

    echo
    bcm_confirm "Записать параметры бэкапа в cluster.conf?" || { bcm_info "Отменено."; bcm_any_key; return; }

    # Ключ шифрования conf-архивов: внутри них пароли ProxySQL/БД и серты.
    # ⚠️ Генерим ОДИН раз: смена ключа делает старые архивы нерасшифровываемыми.
    local enc; enc="$(bcm_bk_get enc_key)"
    if [[ -z "$enc" ]]; then
        enc="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        bcm_warn "Сгенерирован ключ шифрования conf-архивов ([backup] enc_key)."
        bcm_warn "Без него архив конфигов не расшифровать — сохраните его отдельно от кластера."
    fi

    bcm_conf_set backup target         "s3"
    bcm_conf_set backup bucket         "$bucket"
    bcm_conf_set backup retention_days "$ret"
    bcm_conf_set backup enc_key        "$enc"
    if [[ $same_keys -eq 1 && "$endpoint" == "$up_ep" ]]; then
        # Ключи и endpoint те же, что у /upload — не дублируем их в конфиге:
        # один источник правды, ротация ключа не разъедется по двум секциям.
        bcm_conf_set backup endpoint   ""
        bcm_conf_set backup access_key ""
        bcm_conf_set backup secret_key ""
    else
        bcm_conf_set backup endpoint   "$endpoint"
        bcm_conf_set backup access_key "$access"
        bcm_conf_set backup secret_key "$secret"
    fi
    bcm_conf_sync 2>/dev/null || true
    bcm_ok "Цель бэкапов записана: s3, бакет ${bucket}, retention ${ret}д."

    bcm_warn "Ротацию копий на S3 применяет LIFECYCLE бакета (BCM её на чужом"
    bcm_warn "хранилище не настраивает): проверьте, что на бакете есть правила"
    bcm_warn "expire ${ret}д для db/ и conf/ и noncurrent-expire ${ret}д для версий."
    echo
    if bcm_confirm "Раскатать бэкап на ноды сейчас (env, таймеры, mc)?"; then
        bcm_bk_deploy
    else
        bcm_info "Позже — меню 13 → «Раскатать/переприменить на ноды»."
        bcm_any_key
    fi
}

# ──── Раскатка исполнителя на ноды ───────────────────────────────────────────
# Порт шага 3 из install.sh::configure_backup, чтобы настройка бэкапов не
# требовала повторного прогона установщика на живом кластере.
bcm_bk_deploy() {
    bcm_section_header "Раскатка резервного копирования на ноды"

    local target; target="$(bcm_bk_target)"
    if [[ -z "$target" ]]; then
        bcm_error "Цель копий не настроена — сперва пункт «Настроить хранилище копий»."
        bcm_any_key; return 1
    fi

    local bucket ret enc ep ak sk
    bucket="$(bcm_bk_bucket)"; ret="$(bcm_bk_retention)"; enc="$(bcm_bk_get enc_key)"
    local retw retm
    retw="$(bcm_bk_retention_weeks)"; retm="$(bcm_bk_retention_months)"
    local incup; incup="$(bcm_bk_include_upload)"
    ep="$(bcm_bk_s3_endpoint)"; ak="$(bcm_bk_s3_access)"; sk="$(bcm_bk_s3_secret)"
    local nfs_server nfs_export nfs_mount nfs_subdir
    nfs_server="$(bcm_bk_get nfs_server)"; nfs_export="$(bcm_bk_get nfs_export)"
    nfs_mount="$(bcm_bk_get nfs_mount)";   nfs_subdir="$(bcm_bk_get nfs_subdir)"
    [[ -z "$nfs_mount" ]] && nfs_mount="/mnt/bcm-backup"

    if [[ "$target" == "s3" && ( -z "$ep" || -z "$ak" || -z "$sk" ) ]]; then
        bcm_error "Для цели s3 не хватает endpoint/ключей ни в [backup], ни в [s3_upload]."
        bcm_any_key; return 1
    fi
    if [[ -z "$enc" ]]; then
        enc="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        bcm_conf_set backup enc_key "$enc"; bcm_conf_sync 2>/dev/null || true
        bcm_warn "Сгенерирован [backup] enc_key (шифрование conf-архивов)."
    fi

    bcm_info "Цель: ${target}$([[ "$target" == s3 ]] && echo " ${bucket} @ ${ep}" || echo " ${nfs_server}:${nfs_export}")"
    if [[ "$target" == "nfs" && ( "$retw" -gt 0 || "$retm" -gt 0 ) ]]; then
        bcm_info "Хранение: ${ret} ежедневных, ${retw} еженедельных, ${retm} ежемесячных."
    else
        bcm_info "Хранение: ${ret} дней."
    fi
    bcm_info "На ноды уедут: backup.env (0600), юниты и таймеры bcm-backup-*."
    bcm_confirm "Продолжить?" || { bcm_info "Отменено."; bcm_any_key; return 1; }

    # Порядок PXC-кандидатов: реплики (по возрастанию IP) раньше writer'а — тот
    # же порядок, что ставит install.sh, иначе ранги разъедутся после его прогона.
    local writer; writer="$(bcm_conf_get layer.pxc writer 2>/dev/null || echo '')"
    local db_candidates=() n
    for n in $(for x in "${BCM_NODES_PXC[@]}"; do [[ -n "$x" && "$x" != "$writer" ]] && echo "${BCM_NODE_IP[$x]} $x"; done | sort | awk '{print $2}'); do
        db_candidates+=("$n")
    done
    [[ -n "$writer" ]] && db_candidates+=("$writer")

    local ak_esc="${ak//\'/\'\\\'\'}" sk_esc="${sk//\'/\'\\\'\'}"
    local enc_esc="${enc//\'/\'\\\'\'}"
    local tmp_env="/tmp/bcm-backup-env.$$" tmp_svc="/tmp/bcm-backup-svc.$$" tmp_tmr="/tmp/bcm-backup-tmr.$$"
    local ok=0 fail=0 node ip layer

    for node in "${BCM_NODES_LB[@]}" "${BCM_NODES_WEB[@]}" "${BCM_NODES_PXC[@]}" "${BCM_NODES_S3[@]}"; do
        [[ -z "$node" ]] && continue
        ip="${BCM_NODE_IP[$node]:-}"; layer="${BCM_NODE_LAYER[$node]:-}"
        [[ -z "$ip" || -z "$layer" ]] && continue
        bcm_info "  ${node} (${layer}, ${ip})..."
        if ! bcm_node_reachable "$ip" 5 2>/dev/null; then
            bcm_warn "    недоступна — пропуск (переприменить позже)."
            fail=$((fail+1)); continue
        fi

        if [[ "$target" == "s3" ]]; then
            bcm_ssh_exec_timeout "$ip" 180 \
                "[ -x ${_BK_MC} ] || (curl -fsSL -o ${_BK_MC} https://dl.min.io/client/mc/release/linux-amd64/mc && chmod +x ${_BK_MC}); true" </dev/null >/dev/null 2>&1
            if ! bcm_ssh_exec "$ip" "test -x ${_BK_MC}" </dev/null; then
                bcm_error "    mc не установился — бэкап на этой ноде работать не будет."
                fail=$((fail+1)); continue
            fi
        else
            bcm_ssh_exec_timeout "$ip" 300 \
                "rpm -q nfs-utils >/dev/null 2>&1 || dnf install -y -q nfs-utils; rpm -q rsync >/dev/null 2>&1 || dnf install -y -q rsync; true" </dev/null >/dev/null 2>&1
            bcm_ssh_exec_timeout "$ip" 120 \
                "mkdir -p '${nfs_mount}'; grep -q ' ${nfs_mount} ' /etc/fstab || echo '${nfs_server}:${nfs_export} ${nfs_mount} nfs rw,hard,timeo=600,retrans=2,noatime,_netdev 0 0' >> /etc/fstab; mountpoint -q '${nfs_mount}' || mount '${nfs_mount}' || true" </dev/null >/dev/null 2>&1
        fi

        # xtrabackup — только PXC. Ставить пакеты на живую БД молча нельзя:
        # спрашиваем, а без него --db честно откажется работать.
        if [[ "$layer" == "pxc" ]] && ! bcm_ssh_exec "$ip" "command -v xtrabackup >/dev/null 2>&1" </dev/null; then
            bcm_warn "    xtrabackup не установлен (нужен для копии БД)."
            if bcm_confirm "    Установить percona-xtrabackup-84 на ${node}?"; then
                bcm_ssh_exec_timeout "$ip" 900 \
                    "percona-release enable pxb-84-lts release >/dev/null 2>&1; dnf install -y percona-xtrabackup-84" </dev/null >/dev/null 2>&1 \
                    && bcm_ok "    xtrabackup установлен." \
                    || bcm_error "    установить не удалось — копия БД с этой ноды не пойдёт."
            else
                bcm_warn "    пропускаю: --db на ${node} будет отказывать."
            fi
        fi

        local db_rank=0 i
        for i in "${!db_candidates[@]}"; do
            [[ "${db_candidates[$i]}" == "$node" ]] && db_rank="$i"
        done

        # ⚠️ Значения — в ОДИНАРНЫХ кавычках: секрет может содержать '$' и т.п.,
        # в двойных source раскрыл бы его как переменную.
        cat > "$tmp_env" <<ENVEOF
# Сгенерировано BCM (меню 13) — параметры bcm_backup.sh
SELF_NODE='${node}'
ROLE='${layer}'
S3_ENDPOINT='${ep}'
S3_ACCESS='${ak_esc}'
S3_SECRET='${sk_esc}'
BUCKET='${bucket}'
ENC_KEY='${enc_esc}'
RETENTION_DAYS='${ret}'
RETENTION_WEEKS='${retw}'
INCLUDE_UPLOAD='${incup}'
RETENTION_MONTHS='${retm}'
DB_RANK='${db_rank}'
DB_STAGGER='180'
SITE_PATH='/home/bitrix/www'
MC_BIN='${_BK_MC}'
LOG_FILE='/var/log/bcm/backup.log'
BACKUP_TARGET='${target}'
NFS_SERVER='${nfs_server}'
NFS_EXPORT='${nfs_export}'
NFS_MOUNT='${nfs_mount}'
NFS_SUBDIR='${nfs_subdir}'
ENVEOF
        bcm_ssh_exec "$ip" "mkdir -p /etc/bitrix-cluster /var/log/bcm" </dev/null >/dev/null 2>&1
        bcm_ssh_copy_file "$tmp_env" "$ip" "/etc/bitrix-cluster/backup.env"
        bcm_ssh_exec "$ip" "chmod 600 /etc/bitrix-cluster/backup.env" </dev/null >/dev/null 2>&1
        # Исполнитель мог не доехать (нода добавлена после установки).
        bcm_ssh_copy_file "${BCM_BASE_DIR}/bin/lib/bcm_backup.sh" "$ip" "/opt/bcm/bin/lib/bcm_backup.sh"
        bcm_ssh_exec "$ip" "chmod +x /opt/bcm/bin/lib/bcm_backup.sh" </dev/null >/dev/null 2>&1

        # Таймеры: conf — все ноды; db — pxc; files — web; prune — только NFS и
        # только на первой web (на S3 старое чистит lifecycle бакета).
        local types=("conf:02:10") t
        [[ "$layer" == "pxc" ]] && types+=("db:03:10")
        [[ "$layer" == "web" ]] && types+=("files:04:30")
        [[ "$target" == "nfs" && "$node" == "${BCM_NODES_WEB[0]}" ]] && types+=("prune:05:30")
        for t in "${types[@]}"; do
            local typ="${t%%:*}" at="${t#*:}"
            cat > "$tmp_svc" <<UNITEOF
[Unit]
Description=BCM backup: ${typ}
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/bcm/bin/lib/bcm_backup.sh --${typ}
UNITEOF
            cat > "$tmp_tmr" <<UNITEOF
[Unit]
Description=BCM backup timer: ${typ}

[Timer]
OnCalendar=*-*-* ${at}:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF
            bcm_ssh_copy_file "$tmp_svc" "$ip" "/etc/systemd/system/bcm-backup-${typ}.service"
            bcm_ssh_copy_file "$tmp_tmr" "$ip" "/etc/systemd/system/bcm-backup-${typ}.timer"
        done
        # Лишние таймеры (сменилась роль ноды или цель) — снять, иначе они
        # ежедневно падали бы на неподходящей ноде и мусорили в логе.
        local want_list=" "; for t in "${types[@]}"; do want_list+="${t%%:*} "; done
        bcm_ssh_exec_timeout "$ip" 60 \
            "for u in /etc/systemd/system/bcm-backup-*.timer; do
                 [ -e \"\$u\" ] || continue
                 b=\$(basename \"\$u\" .timer); typ=\${b#bcm-backup-}
                 case '${want_list}' in *\" \$typ \"*) : ;; *) systemctl disable --now \"\$b.timer\" >/dev/null 2>&1; rm -f \"\$u\" \"/etc/systemd/system/\$b.service\";; esac
             done; true" </dev/null >/dev/null 2>&1
        if bcm_ssh_exec_timeout "$ip" 120 \
            "systemctl daemon-reload && for u in /etc/systemd/system/bcm-backup-*.timer; do systemctl enable --now \"\$(basename \"\$u\")\" >/dev/null 2>&1; done" </dev/null >/dev/null 2>&1; then
            bcm_ok "    готово (rank=${db_rank}, таймеры:${want_list% })"
            ok=$((ok+1))
        else
            bcm_error "    таймеры не включились."
            fail=$((fail+1))
        fi
    done
    rm -f "$tmp_env" "$tmp_svc" "$tmp_tmr"

    echo
    if [[ $fail -eq 0 ]]; then
        bcm_ok "Резервное копирование раскатано на все ноды (${ok})."
    else
        bcm_warn "Раскатано на ${ok} нод, с проблемами — ${fail}. Почините и переприменте."
    fi
    bcm_info "Проверить сразу: пункты 2–4 (ручной запуск) и пункт 1 (статус)."
    bcm_any_key
}
