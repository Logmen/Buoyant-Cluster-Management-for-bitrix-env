#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181
# =============================================================================
# lsyncd_upload.sh — зеркало /upload между web-нодами для кластера БЕЗ S3.
#
# Зачем. Пользовательские файлы Bitrix (/upload) при развёрнутом слое S3 живут в
# MinIO и одинаково доступны всем web-нодам. Без S3 файл физически остаётся на
# той ноде, которая приняла загрузку: остальные отдают по нему 404 (LB
# балансирует round-robin), а отказ этой ноды делает файл недоступным, хотя
# запись b_file лежит в общей БД. Поэтому /upload зеркалится между всеми
# web-нодами.
#
# Чем это отличается от основного lsyncd (lsyncd_role.sh). Тот односторонний
# (источник→пиры), синкает КОД с --delete и работает ТОЛЬКО на держателе
# web-VRRP. Загрузки же приходят на ЛЮБУЮ ноду, поэтому здесь отдельный
# always-on инстанс на КАЖДОЙ web-ноде: каждый шлёт свой /upload всем пирам.
#
# ⚠️ delete=false — принципиально. Встречные потоки с --delete затирали бы друг
# друга (каждая нода считала бы своё дерево эталоном). Коллизий имён нет: Bitrix
# кладёт файл по уникальному пути SUBDIR/имя от ID записи, повторно тот же путь
# не переиспользуется. Цена: удаление файла в портале убирает его с ноды-хозяина,
# а на пирах остаётся сирота (место на диске; корректности не ломает — ссылку на
# него уже никто не выдаст).
# ⚠️ --update (rsync -u): приёмник не откатывается на более старую копию, и
# встречный проход не гоняет файл обратно — обязательное условие для взаимного
# зеркала.
# ⚠️ insist=true: пир недоступен на старте — lsyncd продолжает работу и догонит
# позже (без insist он завершился бы, и зеркала не было бы вовсе).
#
# Управляется install.sh (configure_lsyncd_upload_mirror) и меню 6; включается
# ТОЛЬКО когда слоя S3 нет. Параметры — из /etc/bitrix-cluster/lsyncd-role.env
# (тот же файл, что у lsyncd_role.sh).
#
# ВНИМАНИЕ: НЕ ставить `set -e` — операции с пирами best-effort (пир может лежать).
# =============================================================================
set -uo pipefail

ENV_FILE="${LSYNCD_ROLE_ENV:-/etc/bitrix-cluster/lsyncd-role.env}"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SELF_NODE="${SELF_NODE:-$(hostname -s 2>/dev/null || echo '?')}"
SELF_IP="${SELF_IP:-}"
WEB_PEERS="${WEB_PEERS:-}"                 # IP всех web-нод через пробел (включая себя)
SITE_PATH="${SITE_PATH:-/home/bitrix/www}"
SSH_KEY="${SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}"
LOG_FILE="${LOG_FILE:-/var/log/bcm/lsyncd-upload.log}"

UPLOAD_CONF="/etc/lsyncd/lsyncd-upload.conf"
UPLOAD_UNIT="/etc/systemd/system/lsyncd-upload.service"
UPLOAD_SVC="lsyncd-upload"
UPLOAD_LOG="/var/log/lsyncd/lsyncd-upload.log"
UPLOAD_STATUS="/run/lsyncd-upload.status"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=8
          -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR)

# Кэши и временные каталоги — per-node, регенерируются, зеркалить нельзя.
UPLOAD_EXCLUDES=(
    "--exclude=/resize_cache/"
    "--exclude=/tmp/"
    "--exclude=/.bx_temp/"
    "--exclude=*.tmp"
)

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${SELF_NODE}] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    echo "$msg" >&2
}

_other_peers() {
    local p
    for p in $WEB_PEERS; do
        [[ "$p" == "$SELF_IP" ]] && continue
        echo "$p"
    done
}

_reachable() {
    timeout 8 ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "root@${1}" "exit 0" 2>/dev/null
}

_lsyncd_bin() {
    command -v lsyncd 2>/dev/null || echo /usr/bin/lsyncd
}

# ──── Конфиг: мой /upload → все пиры (delete=false, --update) ────────────────
_gen_upload_conf() {
    mkdir -p "$(dirname "$UPLOAD_CONF")" /var/log/lsyncd 2>/dev/null || true
    {
        cat <<HEAD
-- ${UPLOAD_CONF}
-- Сгенерировано BCM lsyncd_upload.sh (нода: ${SELF_NODE})
-- Зеркало пользовательских файлов /upload между web-нодами (кластер без S3).
-- НЕ редактировать вручную.

settings {
    logfile    = "${UPLOAD_LOG}",
    statusFile = "${UPLOAD_STATUS}",
    statusInterval = 10,
    -- пир недоступен на старте → продолжать работу и догнать позже
    insist = true,
}
HEAD
        local ip
        for ip in $(_other_peers); do
            cat <<BLOCK

sync {
    default.rsync,
    source = "${SITE_PATH}/upload/",
    target = "root@${ip}:${SITE_PATH}/upload/",
    rsync = {
        archive  = true,
        compress = true,
        rsh      = "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -i ${SSH_KEY}",
        _extra = {
            -- не затирать на приёмнике более свежую копию (встречное зеркало)
            "--update",
            "--exclude=/resize_cache/",
            "--exclude=/tmp/",
            "--exclude=/.bx_temp/",
            "--exclude=*.tmp",
        },
    },
    delete = false,
    delay  = 5,
}
BLOCK
        done
    } > "$UPLOAD_CONF"
}

_gen_upload_unit() {
    local bin
    bin="$(_lsyncd_bin)"
    cat > "$UPLOAD_UNIT" <<UNIT
[Unit]
Description=BCM lsyncd: зеркало /upload между web-нодами (кластер без S3)
Documentation=man:lsyncd(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} -nodaemon -pidfile /run/lsyncd-upload.pid ${UPLOAD_CONF}
# lsyncd на SIGTERM выходит с 143 — без этого штатный systemctl stop оставляет
# юнит в состоянии failed, и «зеркало сломано» не отличить от «его выключили».
SuccessExitStatus=143
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

# ──── Стартовая сходимость: вобрать то, что уже лежит на пирах ───────────────
# lsyncd раздаёт СВОЁ дерево; файлы, осевшие на пирах до включения зеркала, к нам
# сами не приедут. Тянем их один раз rsync'ом --update (без --delete).
_catchup_from_peers() {
    local ip
    for ip in $(_other_peers); do
        if ! _reachable "$ip"; then
            log "catch-up /upload: пир ${ip} недоступен — пропуск."
            continue
        fi
        # У пира каталога может ещё не быть (портал не развёрнут, зеркало включается
        # на нодах по очереди) — это норма, а не сбой: тянуть нечего.
        if ! timeout 8 ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "root@${ip}" "[ -d '${SITE_PATH}/upload' ]" 2>/dev/null; then
            log "catch-up /upload: у пира ${ip} каталога upload ещё нет — пропуск."
            continue
        fi
        log "catch-up /upload: тяну свежее с ${ip}..."
        rsync -az --update "${UPLOAD_EXCLUDES[@]}" \
            -e "ssh ${SSH_OPTS[*]} -i ${SSH_KEY}" \
            "root@${ip}:${SITE_PATH}/upload/" "${SITE_PATH}/upload/" >>"$LOG_FILE" 2>&1 \
            && log "catch-up /upload с ${ip}: ок." \
            || log "catch-up /upload с ${ip}: rsync вернул ошибку (см. лог)."
    done
}

configure() {
    if [[ ! -d "${SITE_PATH}" ]]; then
        log "Каталог сайта ${SITE_PATH} не найден — bitrix-env не развёрнут, зеркало не включаю."
        return 1
    fi
    # ⚠️ В скелете bitrix-env каталога upload ещё нет — он появляется при установке
    # портала. Создаём его заранее (владелец/права — от каталога сайта) и поднимаем
    # зеркало сразу: иначе защита включилась бы только после ручного захода в меню
    # 6 → 10 уже ПОСЛЕ деплоя портала, то есть ровно тогда, когда первые загрузки
    # пользователей уже могли осесть на одной ноде.
    if [[ ! -d "${SITE_PATH}/upload" ]]; then
        mkdir -p "${SITE_PATH}/upload" 2>>"$LOG_FILE" || {
            log "ОШИБКА: не удалось создать ${SITE_PATH}/upload."; return 1; }
        chown --reference="${SITE_PATH}" "${SITE_PATH}/upload" 2>/dev/null || true
        chmod --reference="${SITE_PATH}" "${SITE_PATH}/upload" 2>/dev/null || true
        log "Создан ${SITE_PATH}/upload (портал ещё не развёрнут) — зеркало включаю заранее."
    fi
    if [[ -z "$(_other_peers)" ]]; then
        log "Нет web-пиров кроме себя — зеркало не нужно."
        return 0
    fi
    command -v lsyncd >/dev/null 2>&1 || { log "ОШИБКА: lsyncd не установлен."; return 1; }

    _catchup_from_peers
    _gen_upload_conf
    _gen_upload_unit
    systemctl daemon-reload 2>>"$LOG_FILE"
    systemctl enable "$UPLOAD_SVC" >>"$LOG_FILE" 2>&1
    if systemctl restart "$UPLOAD_SVC" 2>>"$LOG_FILE"; then
        log "Зеркало /upload запущено (пиры: $(_other_peers | tr '\n' ' '))."
    else
        log "ОШИБКА: не удалось запустить ${UPLOAD_SVC}."
        return 1
    fi
    return 0
}

disable_mirror() {
    systemctl disable --now "$UPLOAD_SVC" >/dev/null 2>&1
    systemctl reset-failed "$UPLOAD_SVC" 2>/dev/null || true
    rm -f "$UPLOAD_UNIT" "$UPLOAD_CONF"
    systemctl daemon-reload 2>/dev/null || true
    log "Зеркало /upload выключено (есть S3 либо отключено вручную)."
}

status() {
    local act="unknown" enab="unknown"
    act="$(systemctl is-active "$UPLOAD_SVC" 2>/dev/null || true)"
    enab="$(systemctl is-enabled "$UPLOAD_SVC" 2>/dev/null || true)"
    local peers
    peers="$(_other_peers | tr '\n' ' ')"
    printf 'node=%s active=%s enabled=%s conf=%s peers=%s\n' \
        "$SELF_NODE" "${act:-нет}" "${enab:-нет}" \
        "$([[ -f "$UPLOAD_CONF" ]] && echo есть || echo нет)" "${peers:-—}"
}

case "${1:---status}" in
    --configure) configure ;;
    --disable)   disable_mirror ;;
    --status)    status ;;
    *)
        echo "Использование: $0 --configure | --disable | --status" >&2
        exit 1
        ;;
esac
