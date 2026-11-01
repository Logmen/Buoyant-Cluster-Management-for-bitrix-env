#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181,SC2029
# =============================================================================
# bcm_search.sh — поиск портала на кластере Manticore из web-узлов.
#
# Схема (выбрана и проверена на стенде, ноябрь 2026):
#   • Manticore на каждом web-узле, кластер репликации из них, одна RT-таблица индекса
#     модуля поиска Битрикса (схема — из полей штатного CSearchSphinx этой версии);
#   • кворум двух узлов держит внешний контролёр — search_role.sh (таймер 15 с и
#     cron_notify.sh): главный для поиска = master HA Cron, вес 2; повышение, перезапуск,
#     подъём после общего падения и лечение раскола — там же;
#   • Битрикс — модуль bcm.search в /local/modules (templates/search): наследник
#     CSearchSphinx с префиксом кластера для записи, отложенная индексация через очередь
#     search_sync_content, подставляется блоком bcm:search в действующем init.php.
#     Ядро Битрикса не правится.
#   • резервных копий индекса нет и не нужно: он пересобирается из b_search_content
#     (cli.php repair).
#
# ⚠️ Страница настроек модуля поиска в админке с этим движком не сохраняется: её проверка
# индекса написана под Sphinx (SHOW TABLES → колонка Index, DESCRIBE → тип field), а
# Manticore отдаёт Table и text. Поиск это не ломает; настройки ставит этот скрипт.
#
# Команды (на web-узле с BCM, под root):
#   --status                 узлы, контролёр, кластер, портал
#   --install                Manticore на всех web, конфиг, firewall, контролёр, кластер, таблица
#   --enable                 перевести портал: модуль, блок init.php, опции, заливка, движок
#   --disable                вернуть штатный поиск Битрикса (кластер остаётся)
#   --repair [--since=UNIX]  досинхронизировать индекс из базы (на главном узле)
#   --schema-sync [--auto]   добавить в таблицу поля, появившиеся в модуле поиска
#   --recover                один такт контролёра на всех узлах
# Внутренние (вызываются по ssh на конкретном узле): --local-setup, --local-files,
#   --local-hook add|remove|status, --local-cli ARGS…, --local-schema
# =============================================================================
set -uo pipefail

BCM_BASE_DIR="${BCM_BASE_DIR:-/opt/bcm}"
BCM_LIB_DIR="${BCM_LIB_DIR:-${BCM_BASE_DIR}/bin/lib}"
source "${BCM_LIB_DIR}/bcm_utils.sh"
source "${BCM_LIB_DIR}/bcm_config.sh"
source "${BCM_LIB_DIR}/bcm_ssh.sh"

SITE_ROOT="${BCM_SITE_ROOT:-/home/bitrix/www}"
MODULE_SRC="${BCM_BASE_DIR}/templates/search"
MODULE_DST="${SITE_ROOT}/local/modules/bcm.search"
CONF_TMPL="${BCM_BASE_DIR}/templates/manticore.conf.tmpl"
CONF_DST="/etc/manticoresearch/manticore.conf"
ENV_FILE="/etc/bitrix-cluster/search.env"
ROLE_TOOL="${BCM_LIB_DIR}/search_role.sh"
SELF="${BCM_LIB_DIR}/bcm_search.sh"
LOG="/var/log/bcm/search.log"
HOOK_BEGIN="// bcm:search-begin"
HOOK_END="// bcm:search-end"
REPO_RPM="https://repo.manticoresearch.com/manticore-repo.noarch.rpm"
UNIT_DIR="/etc/systemd/system"

_bs_log()  { mkdir -p /var/log/bcm 2>/dev/null; echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null || true; }
_bs_err()  { echo "ОШИБКА: $*" >&2; _bs_log "ERROR: $*"; }
_bs_info() { echo "$*"; }
_bs_require_root() { [[ "$(id -u)" -eq 0 ]] || { _bs_err "нужен root."; exit 1; }; }

# ──── Настройки: cluster.conf [search] ───────────────────────────────────────
_bs_cfg() { local v; v="$(bcm_conf_get search "$1" 2>/dev/null)"; echo "${v:-$2}"; }
# Значения из окружения BCM_SEARCH_* важнее cluster.conf: оркестратор передаёт свои
# настройки в шаги на узлах явно — cluster.conf соседа мог остаться без правок [search].
_bs_load_cfg() {
    CLUSTER="${BCM_SEARCH_CLUSTER:-$(_bs_cfg cluster bcm)}"
    TABLE="${BCM_SEARCH_TABLE:-$(_bs_cfg table bitrix)}"
    PORT="${BCM_SEARCH_PORT:-$(_bs_cfg port 9306)}"
    API_PORT="${BCM_SEARCH_API_PORT:-$(_bs_cfg api_port 9312)}"
    REPL_PORTS="${BCM_SEARCH_REPL_PORTS:-$(_bs_cfg repl_ports 9315-9325)}"
    MORPHOLOGY="$(_bs_cfg morphology stem_enru)"
    MIN_WORD="$(_bs_cfg min_word_len 2)"
    MIN_PREFIX="$(_bs_cfg min_prefix_len 2)"
    [[ "$CLUSTER" =~ ^[A-Za-z0-9_]+$ && "$TABLE" =~ ^[A-Za-z0-9_]+$ ]] \
        || { _bs_err "[search] cluster/table: только латиница, цифры, '_'"; exit 1; }
}

# Префикс удалённого вызова: настройки этого узла — шагу на соседнем.
_bs_envp() {
    printf 'BCM_SEARCH_CLUSTER=%s BCM_SEARCH_TABLE=%s BCM_SEARCH_PORT=%s BCM_SEARCH_API_PORT=%s BCM_SEARCH_REPL_PORTS=%s' \
        "$CLUSTER" "$TABLE" "$PORT" "$API_PORT" "$REPL_PORTS"
}

# ──── Узлы ───────────────────────────────────────────────────────────────────
_bs_topology() {
    bcm_load_topology || { _bs_err "не удалось прочитать топологию"; exit 1; }
    WEB_NAMES=(); WEB_IPS=()
    local n
    for n in "${BCM_NODES_WEB[@]}"; do
        [[ -n "${BCM_NODE_IP[$n]:-}" ]] || continue
        WEB_NAMES+=("$n"); WEB_IPS+=("${BCM_NODE_IP[$n]}")
    done
    [[ ${#WEB_IPS[@]} -ge 2 ]] || { _bs_err "нужно минимум два web-узла (сейчас ${#WEB_IPS[@]})"; exit 1; }
}

# Главный узел поиска: master HA Cron; нет — источник lsyncd; нет — первый.
_bs_master() {
    local i ip r
    for i in "${!WEB_IPS[@]}"; do
        ip="${WEB_IPS[$i]}"
        r="$(bcm_ssh_exec_timeout "$ip" 10 "cat /run/bcm-ha-cron.role 2>/dev/null" </dev/null)"
        [[ "$r" == "MASTER" ]] && { echo "$i"; return; }
    done
    for i in "${!WEB_IPS[@]}"; do
        [[ "$(bcm_ssh_exec_timeout "${WEB_IPS[$i]}" 10 "systemctl is-active lsyncd" </dev/null)" == "active" ]] && { echo "$i"; return; }
    done
    echo 0
}

# Источник lsyncd (туда кладутся файлы портала — на остальные их везёт lsyncd).
_bs_source() {
    local i
    for i in "${!WEB_IPS[@]}"; do
        [[ "$(bcm_ssh_exec_timeout "${WEB_IPS[$i]}" 10 "systemctl is-active lsyncd" </dev/null)" == "active" ]] && { echo "$i"; return; }
    done
    echo 0
}

# SQL к Manticore на узле (через ssh; текст запроса — stdin, без кавычек в командной строке).
_bs_sql() {
    local ip="$1" sql="$2" t="${3:-60}"
    bcm_ssh_exec_timeout "$ip" "$t" "mysql --no-defaults -h127.0.0.1 -P${PORT} -N -B" <<< "$sql"
}

_bs_cluster_status() {
    local ip="$1"
    _bs_sql "$ip" "SHOW STATUS LIKE 'cluster_${CLUSTER}_status'" 15 | awk -F'\t' '{print $2}'
}

_bs_peers_of() {
    local self="$1" ip out=""
    for ip in "${WEB_IPS[@]}"; do [[ "$ip" != "$self" ]] && out+="${ip} "; done
    echo "${out% }"
}

_bs_hosts_opt() {
    local ip out=""
    for ip in "${WEB_IPS[@]}"; do out+="${ip}:${PORT},"; done
    echo "${out%,}"
}

# ──── Локальные шаги (на узле) ───────────────────────────────────────────────
_bs_local_setup() {
    _bs_require_root
    local self_ip="$1" peers="$2" restart_ok="${3:-no}" changed=0
    [[ -n "$self_ip" ]] || { _bs_err "--local-setup: нет IP узла"; return 1; }

    # 1. Пакеты: сервер и библиотека репликации. ⚠️ На EL9 (29.x) это ОДИН пакет
    # «manticore», который провайдит manticore-server и manticore-galera; поэтому проверка
    # по --whatprovides и по самой библиотеке, а не rpm -q по имени.
    local galera_so="/usr/share/manticore/modules/libgalera_manticore.so"
    if ! rpm -q --whatprovides manticore-server >/dev/null 2>&1 || [[ ! -f "$galera_so" ]]; then
        rpm -q manticore-repo >/dev/null 2>&1 || dnf install -y "$REPO_RPM" >/dev/null 2>&1 \
            || { _bs_err "не удалось подключить репозиторий Manticore (${REPO_RPM})"; return 1; }
        dnf install -y manticore-server manticore-galera >/dev/null 2>&1 \
            || { _bs_err "не удалось установить manticore-server manticore-galera"; return 1; }
        [[ -f "$galera_so" ]] || { _bs_err "нет ${galera_so} — без неё кластер не соберётся"; return 1; }
        _bs_info "  пакеты: $(rpm -q --whatprovides manticore-server --qf '%{NAME}-%{VERSION}')"
    fi

    # 2. Конфиг searchd из шаблона.
    [[ -f "$CONF_TMPL" ]] || { _bs_err "нет ${CONF_TMPL} — раскатайте BCM на узел"; return 1; }
    local tmp; tmp="$(mktemp)"
    sed -e "s/__NODE_IP__/${self_ip}/g" -e "s/__PORT__/${PORT}/g" \
        -e "s/__API_PORT__/${API_PORT}/g" -e "s/__REPL_PORTS__/${REPL_PORTS}/g" "$CONF_TMPL" > "$tmp"
    if [[ "$(cksum < "$tmp")" != "$(cksum < "$CONF_DST" 2>/dev/null)" ]]; then
        [[ -f "$CONF_DST" && ! -f "${CONF_DST}.bcm-orig" ]] && cp -p "$CONF_DST" "${CONF_DST}.bcm-orig"
        install -m 0644 "$tmp" "$CONF_DST"; changed=1
        _bs_info "  конфиг ${CONF_DST} обновлён"
    fi
    rm -f "$tmp"

    # 3. Параметры контролёра. SEARCH_PORTAL сохраняется: его ставит --enable/--disable.
    local portal="0"
    [[ -f "$ENV_FILE" ]] && portal="$(sed -n 's/^SEARCH_PORTAL=//p' "$ENV_FILE" | tail -1)"
    mkdir -p "$(dirname "$ENV_FILE")"
    cat > "${ENV_FILE}.new" <<ENV
# Параметры кластера поиска для search_role.sh. Пишет bcm_search.sh — не править руками.
SEARCH_CLUSTER=${CLUSTER}
SEARCH_TABLE=${TABLE}
SEARCH_PORT=${PORT}
SEARCH_API_PORT=${API_PORT}
SEARCH_SELF_IP=${self_ip}
SEARCH_PEERS="${peers}"
SEARCH_SITE_ROOT=${SITE_ROOT}
SEARCH_PORTAL=${portal:-0}
ENV
    mv -f "${ENV_FILE}.new" "$ENV_FILE"; chmod 0644 "$ENV_FILE"

    # 4. Firewall: порты Manticore — только от соседних web-узлов.
    if systemctl is-active firewalld >/dev/null 2>&1; then
        local p port
        for p in $peers; do
            for port in "$PORT" "$API_PORT" "$REPL_PORTS"; do
                firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${p}/32 port port=${port} protocol=tcp accept" >/dev/null 2>&1
            done
        done
        firewall-cmd --reload >/dev/null 2>&1
    fi

    # 5. Служба. Работающий узел кластера перезапускает только оркестратор (по одному).
    systemctl enable manticore >/dev/null 2>&1
    if [[ "$(systemctl is-active manticore)" != "active" ]]; then
        timeout 900 systemctl start manticore || { _bs_err "manticore не запустился (journalctl -u manticore)"; return 1; }
    elif [[ $changed -eq 1 ]]; then
        if [[ "$restart_ok" == "restart" ]]; then
            timeout 900 systemctl restart manticore || { _bs_err "manticore не перезапустился"; return 1; }
        else
            _bs_info "  ⚠️ конфиг изменён, служба работает со старым — перезапуск: systemctl restart manticore (по одному узлу)"
        fi
    fi

    # 6. Контролёр: таймер раз в 15 с.
    cat > "${UNIT_DIR}/bcm-search-role.service" <<UNIT
[Unit]
Description=BCM: контролёр кластера поиска Manticore (search_role.sh)
After=network-online.target manticore.service

[Service]
Type=oneshot
ExecStart=${ROLE_TOOL} tick --reason timer
TimeoutStartSec=1800
UNIT
    cat > "${UNIT_DIR}/bcm-search-role.timer" <<UNIT
[Unit]
Description=BCM: такт контролёра поиска каждые 15 секунд

[Timer]
OnBootSec=60
OnUnitActiveSec=15
AccuracySec=2

[Install]
WantedBy=timers.target
UNIT
    chmod +x "$ROLE_TOOL" 2>/dev/null
    systemctl daemon-reload
    systemctl enable --now bcm-search-role.timer >/dev/null 2>&1
    _bs_info "  manticore: $(systemctl is-active manticore), контролёр: $(systemctl is-active bcm-search-role.timer)"
}

_bs_local_files() {
    _bs_require_root
    [[ -f "${MODULE_SRC}/lib/Manticore.php" ]] || { _bs_err "нет ${MODULE_SRC} — раскатайте BCM на узел"; return 1; }
    [[ -d "${SITE_ROOT}/local/modules" ]] || mkdir -p "${SITE_ROOT}/local/modules"
    local f
    for f in "${MODULE_SRC}"/*.php "${MODULE_SRC}"/lib/*.php; do
        php -l "$f" >/dev/null 2>&1 || { _bs_err "$(basename "$f") не проходит php -l на этом узле"; return 1; }
    done
    if [[ -d "$MODULE_DST" ]] && diff -rq "$MODULE_SRC" "$MODULE_DST" >/dev/null 2>&1; then
        _bs_info "  файлы модуля bcm.search актуальны"
        return 0
    fi
    mkdir -p "$MODULE_DST"
    cp -r "${MODULE_SRC}/." "${MODULE_DST}/" || { _bs_err "не удалось скопировать модуль"; return 1; }
    chown -R --reference="${SITE_ROOT}/local/modules" "$MODULE_DST" 2>/dev/null || chown -R bitrix:bitrix "$MODULE_DST"
    find "$MODULE_DST" -type d -exec chmod 0775 {} + 2>/dev/null
    find "$MODULE_DST" -type f -exec chmod 0664 {} + 2>/dev/null
    _bs_log "файлы модуля установлены в ${MODULE_DST}"
    _bs_info "  файлы модуля bcm.search установлены (${MODULE_DST})"
}

# Действующий init.php: local, если есть, иначе bitrix (ядро грузит только один).
_bs_init_php() {
    if [[ -f "${SITE_ROOT}/local/php_interface/init.php" ]]; then echo "${SITE_ROOT}/local/php_interface/init.php"
    elif [[ -f "${SITE_ROOT}/bitrix/php_interface/init.php" ]]; then echo "${SITE_ROOT}/bitrix/php_interface/init.php"; fi
}

_bs_local_hook() {
    _bs_require_root
    local f; f="$(_bs_init_php)"
    case "${1:-status}" in
        status) [[ -n "$f" ]] && grep -qF "$HOOK_BEGIN" "$f" && echo "HOOK=present" || echo "HOOK=absent" ;;
        add)
            if [[ -z "$f" ]]; then
                f="${SITE_ROOT}/local/php_interface/init.php"; mkdir -p "$(dirname "$f")"
                printf '<?php\n' > "$f"; chown --reference="${SITE_ROOT}/local/modules" "$f" 2>/dev/null || chown bitrix:bitrix "$f"; chmod 0664 "$f"
            fi
            grep -qF "$HOOK_BEGIN" "$f" && { _bs_info "  блок bcm:search уже в ${f}"; return 0; }
            php -l "$f" >/dev/null 2>&1 || { _bs_err "${f} не проходит php -l ещё до правки"; return 1; }
            local bak="${f}.bcm-bak-search"; [[ -f "$bak" ]] || cp -p "$f" "$bak"
            local open_tag=""; tail -c 200 "$f" | tr -d '[:space:]' | grep -qE '\?>$' && open_tag=$'<?php\n'
            cat >> "$f" <<HOOK

${open_tag}${HOOK_BEGIN} — поиск портала на кластере Manticore BCM (bcm_search.sh)
if (is_file(\$_SERVER['DOCUMENT_ROOT'] . '/local/modules/bcm.search/hook.php')) {
    require_once \$_SERVER['DOCUMENT_ROOT'] . '/local/modules/bcm.search/hook.php';
}
${HOOK_END}
HOOK
            if ! php -l "$f" >/dev/null 2>&1; then
                cp -p "$bak" "$f"; _bs_err "${f} после добавления блока не проходит php -l — возвращён из копии"; return 1
            fi
            _bs_log "init.php: блок bcm:search добавлен в ${f}"; _bs_info "  блок bcm:search добавлен в ${f}" ;;
        remove)
            [[ -n "$f" ]] && grep -qF "$HOOK_BEGIN" "$f" || { _bs_info "  блока bcm:search нет"; return 0; }
            local tmp; tmp="$(mktemp)"
            awk -v b="$HOOK_BEGIN" -v e="$HOOK_END" '
                { lines[NR]=$0 }
                END {
                    n=NR; s=0; t=0
                    for (i=1;i<=n;i++) if (index(lines[i], b)==1) { s=i; break }
                    for (i=s;i<=n;i++) if (index(lines[i], e)==1) { t=i; break }
                    if (s>0 && t>0) {
                        if (s>1 && lines[s-1]=="<?php") s--
                        if (s>1 && lines[s-1]=="") s--
                    }
                    for (i=1;i<=n;i++) if (s==0 || i<s || i>t) print lines[i]
                }' "$f" > "$tmp" && cat "$tmp" > "$f"
            rm -f "$tmp"
            php -l "$f" >/dev/null 2>&1 || _bs_err "${f} после удаления блока не проходит php -l (копия ${f}.bcm-bak-search)"
            _bs_log "init.php: блок bcm:search удалён из ${f}"; _bs_info "  блок bcm:search удалён из ${f}" ;;
    esac
}

_bs_local_cli() {
    [[ -f "${MODULE_DST}/cli.php" ]] || { _bs_err "нет ${MODULE_DST}/cli.php — сначала файлы модуля"; return 1; }
    runuser -u bitrix -- php "${MODULE_DST}/cli.php" "$@"
}

# ──── Задание «только на master»: потребитель очередей поиска ─────────────────
# Тот же механизм, что меню 10: канонический файл берётся с первой доступной web,
# раскатывается на все как .disabled, а cron_notify.sh assert включает его на master.
CRON_MASTER="/etc/cron.d/bcm-portal-master"
CRON_MASTER_OFF="/etc/bitrix-cluster/bcm-portal-master.disabled"
CRON_HEADER="# Сгенерировано BCM (меню 10 — фоновые задания). Правки руками не делать."
CONSUME_MARK="bcm.search/cli.php consume"
CONSUME_COMMENT="# очереди поиска портала (Manticore): разбор подряд, а не по одному сообщению за проход (BCM меню 17)"
CONSUME_LINE="* * * * * bitrix flock -n /home/bitrix/.bcm-search-consume.lock /usr/bin/php -f ${SITE_ROOT}/local/modules/bcm.search/cli.php consume 55 2>&1 | logger -t bcm-search"

_bs_cron_consume() {
    local action="$1" content="" raw="" ip got=0
    # ⚠️ «Файла нет» и «не удалось прочитать» — разные вещи: при сбое чтения пустое
    # содержимое раскатилось бы на все узлы и снесло остальные задания master
    # (агенты, autopush, Messenger). Поэтому явный маркер и код возврата ssh.
    for ip in "${WEB_IPS[@]}"; do
        bcm_node_reachable "$ip" 5 2>/dev/null || continue
        raw="$(bcm_ssh_exec_timeout "$ip" 10 "if [ -f '${CRON_MASTER}' ]; then cat '${CRON_MASTER}'; elif [ -f '${CRON_MASTER_OFF}' ]; then cat '${CRON_MASTER_OFF}'; fi; echo __BCM_EOF__" </dev/null)" || continue
        [[ "$raw" == *__BCM_EOF__* ]] || continue
        got=1; break
    done
    [[ $got -eq 1 ]] || { _bs_err "не удалось прочитать задания master ни с одного web — задание поиска не изменено"; return 1; }
    content="$(printf '%s\n' "$raw" | grep -v '^__BCM_EOF__$' | grep -v '^# Сгенерировано BCM' | grep -v '^[[:space:]]*$' || true)"
    if [[ "$action" == "add" ]]; then
        printf '%s\n' "$content" | grep -qF "$CONSUME_MARK" && { _bs_info "  задание разбора очередей поиска уже есть"; return 0; }
        content="${content:+$content$'\n'}${CONSUME_COMMENT}"$'\n'"${CONSUME_LINE}"
    else
        printf '%s\n' "$content" | grep -qF "$CONSUME_MARK" || return 0
        content="$(printf '%s\n' "$content" | grep -vF "$CONSUME_MARK" | grep -vF "$CONSUME_COMMENT" || true)"
    fi
    local ok=0
    for ip in "${WEB_IPS[@]}"; do
        printf '%s\n%s\n' "$CRON_HEADER" "$content" \
            | bcm_ssh_exec "$ip" "rm -f '${CRON_MASTER}'; cat > '${CRON_MASTER_OFF}' && chmod 644 '${CRON_MASTER_OFF}'; /opt/bcm/bin/lib/cron_notify.sh assert >/dev/null 2>&1" \
            || ok=1
    done
    _bs_info "  задание разбора очередей поиска: $([[ "$action" == "add" ]] && echo добавлено || echo снято) (класс «только master»)"
    return $ok
}

# ──── Оркестрация ────────────────────────────────────────────────────────────
_bs_maint_all() {
    local ip
    for ip in "${WEB_IPS[@]}"; do bcm_ssh_exec_timeout "$ip" 15 "${ROLE_TOOL} maint $1" </dev/null >/dev/null; done
}

_bs_set_portal_flag() {
    local ip
    for ip in "${WEB_IPS[@]}"; do
        bcm_ssh_exec_timeout "$ip" 15 "[ -f ${ENV_FILE} ] && sed -i 's/^SEARCH_PORTAL=.*/SEARCH_PORTAL=$1/' ${ENV_FILE}" </dev/null
    done
}

_bs_install() {
    _bs_require_root; _bs_topology
    local i ip m s ddl st
    m="$(_bs_master)"; s="$(_bs_source)"
    _bs_info "Кластер поиска «${CLUSTER}» на web-узлах: ${WEB_NAMES[*]} (главный — ${WEB_NAMES[$m]})"

    for ip in "${WEB_IPS[@]}"; do
        bcm_node_reachable "$ip" 5 2>/dev/null || { _bs_err "${ip} недоступен — установка невозможна"; return 1; }
    done

    # Узлы: пакеты, конфиг, firewall, контролёр (на паузе, пока собирается кластер).
    _bs_maint_all on
    for i in "${!WEB_IPS[@]}"; do
        ip="${WEB_IPS[$i]}"
        _bs_info "· ${WEB_NAMES[$i]} (${ip})"
        bcm_ssh_exec_timeout "$ip" 1200 "$(_bs_envp) ${SELF} --local-setup '${ip}' '$(_bs_peers_of "$ip")'" </dev/null \
            || { _bs_err "${WEB_NAMES[$i]}: подготовка узла не удалась"; _bs_maint_all off; return 1; }
    done

    # Файлы модуля на источник lsyncd: из них берётся схема таблицы (поля этой версии).
    bcm_ssh_exec_timeout "${WEB_IPS[$s]}" 60 "$(_bs_envp) ${SELF} --local-files" </dev/null || { _bs_maint_all off; return 1; }

    # Кластер и таблица на главном.
    ip="${WEB_IPS[$m]}"
    st="$(_bs_cluster_status "$ip")"
    if [[ -z "$st" ]]; then
        ddl="$(bcm_ssh_exec_timeout "${WEB_IPS[$s]}" 60 "$(_bs_envp) ${SELF} --local-cli ddl" </dev/null)"
        [[ "$ddl" == *"text indexed"* ]] || { _bs_err "схема индекса не получена из модуля поиска (cli.php ddl)"; _bs_maint_all off; return 1; }
        if [[ -z "$(_bs_sql "$ip" "SHOW TABLES LIKE '${TABLE}'")" ]]; then
            _bs_sql "$ip" "CREATE TABLE ${TABLE} (${ddl}) morphology='${MORPHOLOGY}' dict='keywords' min_word_len='${MIN_WORD}' min_prefix_len='${MIN_PREFIX}' index_exact_words='1'" \
                || { _bs_err "CREATE TABLE не удался"; _bs_maint_all off; return 1; }
        fi
        _bs_sql "$ip" "CREATE CLUSTER ${CLUSTER}" || { _bs_err "CREATE CLUSTER не удался"; _bs_maint_all off; return 1; }
        _bs_sql "$ip" "ALTER CLUSTER ${CLUSTER} ADD ${TABLE}" || { _bs_err "ALTER CLUSTER ADD не удался"; _bs_maint_all off; return 1; }
        _bs_info "  кластер ${CLUSTER} создан на ${WEB_NAMES[$m]}, таблица ${TABLE} в нём"
    else
        _bs_info "  кластер ${CLUSTER} уже есть на ${WEB_NAMES[$m]} (${st})"
    fi

    # Остальные узлы входят к главному.
    for i in "${!WEB_IPS[@]}"; do
        [[ $i -eq $m ]] && continue
        st="$(_bs_cluster_status "${WEB_IPS[$i]}")"
        if [[ -z "$st" ]]; then
            _bs_sql "${WEB_IPS[$i]}" "JOIN CLUSTER ${CLUSTER} AT '${WEB_IPS[$m]}:${API_PORT}'" 900 \
                || { _bs_err "${WEB_NAMES[$i]}: JOIN не удался"; _bs_maint_all off; return 1; }
            _bs_info "  ${WEB_NAMES[$i]} вошёл в кластер"
        else
            _bs_info "  ${WEB_NAMES[$i]} уже в кластере (${st})"
        fi
    done
    _bs_maint_all off
    for ip in "${WEB_IPS[@]}"; do bcm_ssh_exec_timeout "$ip" 120 "${ROLE_TOOL} tick --reason install" </dev/null; done

    bcm_conf_set search installed yes 2>/dev/null || true
    bcm_conf_set search cluster "$CLUSTER" 2>/dev/null || true
    bcm_conf_set search table "$TABLE" 2>/dev/null || true
    bcm_conf_sync 2>/dev/null || true
    _bs_log "установка: кластер ${CLUSTER} на ${WEB_NAMES[*]}"
    _bs_info "✓ Кластер поиска готов. Перевести портал: $(basename "$SELF") --enable"
}

_bs_enable() {
    _bs_require_root; _bs_topology
    local m s ip t0 out
    m="$(_bs_master)"; s="$(_bs_source)"
    for ip in "${WEB_IPS[@]}"; do
        [[ "$(_bs_cluster_status "$ip")" == "primary" ]] || { _bs_err "узел ${ip} не в рабочем кластере — сначала --install / --recover"; return 1; }
    done
    bcm_ssh_exec_timeout "${WEB_IPS[$s]}" 60 "$(_bs_envp) ${SELF} --local-files" </dev/null || return 1
    bcm_ssh_exec_timeout "${WEB_IPS[$s]}" 60 "$(_bs_envp) ${SELF} --local-hook add" </dev/null || return 1
    # Ждём, пока lsyncd довезёт модуль и init.php до остальных узлов.
    sleep 8
    out="$(bcm_ssh_exec_timeout "${WEB_IPS[$m]}" 60 "$(_bs_envp) ${SELF} --local-cli options '$(_bs_hosts_opt)' '${CLUSTER}' '${TABLE}' '${PORT}'" </dev/null)"
    _bs_info "  ${out}"; [[ "$out" == OK* ]] || { _bs_err "опции поиска не записаны"; return 1; }

    # Заливка до переключения: портал продолжает искать по старому движку.
    t0="$(date +%s)"
    _bs_info "  заливка индекса из b_search_content (поиск портала пока на старом движке)…"
    bcm_ssh_exec_timeout "${WEB_IPS[$m]}" 7200 "$(_bs_envp) ${SELF} --local-cli repair --no-delete" </dev/null \
        || { _bs_err "заливка не завершилась — портал не переключён (повторить: --enable)"; return 1; }
    out="$(bcm_ssh_exec_timeout "${WEB_IPS[$m]}" 60 "$(_bs_envp) ${SELF} --local-cli engine sphinx" </dev/null)"
    _bs_info "  ${out}"; [[ "$out" == OK* ]] || { _bs_err "движок не переключён"; return 1; }
    _bs_set_portal_flag 1
    bcm_conf_set search portal yes 2>/dev/null || true
    bcm_conf_sync 2>/dev/null || true
    _bs_cron_consume add
    _bs_info "  догоняем изменения за время заливки…"
    bcm_ssh_exec_timeout "${WEB_IPS[$m]}" 3600 "$(_bs_envp) ${SELF} --local-cli repair --since=$((t0 - 60))" </dev/null
    bcm_ssh_exec_timeout "${WEB_IPS[$m]}" 60 "$(_bs_envp) ${SELF} --local-cli probe" </dev/null
    _bs_log "портал переведён на кластер поиска ${CLUSTER}"
    _bs_info "✓ Поиск портала работает на кластере Manticore."
}

_bs_disable() {
    _bs_require_root; _bs_topology
    local m out; m="$(_bs_master)"
    out="$(bcm_ssh_exec_timeout "${WEB_IPS[$m]}" 60 "$(_bs_envp) ${SELF} --local-cli engine bitrix" </dev/null)"
    _bs_info "  ${out}"
    _bs_set_portal_flag 0
    bcm_conf_set search portal no 2>/dev/null || true
    bcm_conf_sync 2>/dev/null || true
    _bs_cron_consume remove
    _bs_log "портал возвращён на штатный поиск Битрикса"
    _bs_info "✓ Портал на штатном поиске Битрикса. Его индекс в MySQL не обновлялся, пока работал"
    _bs_info "  Manticore: переиндексируйте (Настройки → Поиск → Переиндексация)."
}

_bs_repair() {
    _bs_require_root; _bs_topology
    local m; m="$(_bs_master)"
    _bs_info "Досинхронизация индекса на ${WEB_NAMES[$m]}…"
    bcm_ssh_exec_timeout "${WEB_IPS[$m]}" 7200 "$(_bs_envp) ${SELF} --local-cli repair $*" </dev/null
}

# Поля модуля поиска, которых нет в таблице: «имя тип» построчно (на узле-источнике).
_bs_local_schema() {
    local fields ddl cols name
    ddl="$(_bs_local_cli ddl)" || return 1
    cols="$(mysql --no-defaults -h127.0.0.1 -P"$PORT" -N -B -e "DESCRIBE ${TABLE}" 2>/dev/null | awk -F'\t' '{print $1}')"
    printf '%s\n' "$ddl" | tr ',' '\n' | sed 's/^ *//' | while IFS= read -r col; do
        name="$(printf '%s' "$col" | sed -E 's/^`([^`]+)`.*/\1/')"
        printf '%s\n' "$cols" | grep -qx "$name" || printf '%s\n' "$col"
    done
}

_bs_schema_sync() {
    _bs_require_root; _bs_topology
    local auto="${1:-}" m i missing col
    m="$(_bs_master)"
    missing="$(bcm_ssh_exec_timeout "${WEB_IPS[$m]}" 60 "$(_bs_envp) ${SELF} --local-schema" </dev/null)"
    if [[ -z "$missing" ]]; then
        [[ "$auto" == "--auto" ]] || _bs_info "✓ Схема таблицы ${TABLE} совпадает с модулем поиска."
        return 0
    fi
    _bs_info "Новые поля модуля поиска: $(printf '%s' "$missing" | tr '\n' ' ')"
    # ALTER на таблице в кластере Manticore не поддерживает: таблица выходит из кластера,
    # меняется на главном, у остальных удаляется и приезжает заново с ALTER CLUSTER ADD.
    # Запись в это время отвергается и ждёт в очереди (повтор через минуту).
    _bs_maint_all on
    _bs_sql "${WEB_IPS[$m]}" "ALTER CLUSTER ${CLUSTER} DROP ${TABLE}" || { _bs_maint_all off; _bs_err "не удалось вывести таблицу из кластера"; return 1; }
    local -a cols=()
    mapfile -t cols <<< "$missing"
    for col in "${cols[@]}"; do
        [[ -n "$col" ]] || continue
        _bs_sql "${WEB_IPS[$m]}" "ALTER TABLE ${TABLE} ADD COLUMN ${col}" || _bs_err "не удалось добавить ${col}"
    done
    for i in "${!WEB_IPS[@]}"; do
        [[ $i -eq $m ]] && continue
        _bs_sql "${WEB_IPS[$i]}" "DROP TABLE IF EXISTS ${TABLE}"
    done
    _bs_sql "${WEB_IPS[$m]}" "ALTER CLUSTER ${CLUSTER} ADD ${TABLE}" 900 || { _bs_err "таблица не вернулась в кластер"; _bs_maint_all off; return 1; }
    _bs_maint_all off
    _bs_log "схема: добавлены поля $(printf '%s' "$missing" | tr '\n' ' ')"
    _bs_info "✓ Поля добавлены. Значения у старых документов появятся после досинхронизации (в фоне)."
    bcm_ssh_exec_timeout "${WEB_IPS[$m]}" 15 "$(_bs_envp) nohup ${SELF} --local-cli repair >> /var/log/bcm/search-repair.log 2>&1 &" </dev/null
}

_bs_recover() {
    _bs_require_root; _bs_topology
    local i
    for i in "${!WEB_IPS[@]}"; do
        bcm_ssh_exec_timeout "${WEB_IPS[$i]}" 1000 "${ROLE_TOOL} tick --reason manual" </dev/null
    done
    _bs_status
}

_bs_status() {
    _bs_topology
    local i ip out
    _bs_info "Поиск портала (Manticore): кластер ${CLUSTER}, таблица ${TABLE}, портал: $(_bs_cfg portal no), установлен: $(_bs_cfg installed no)"
    for i in "${!WEB_IPS[@]}"; do
        ip="${WEB_IPS[$i]}"
        out="$(bcm_ssh_exec_timeout "$ip" 20 "${ROLE_TOOL} status 2>/dev/null" </dev/null | tr '\n' ' ')"
        _bs_info "  ${WEB_NAMES[$i]} (${ip}): ${out:-нет ответа}"
    done
    local s; s="$(_bs_source)"
    out="$(bcm_ssh_exec_timeout "${WEB_IPS[$s]}" 60 "[ -f ${MODULE_DST}/cli.php ] && ${SELF} --local-cli status" </dev/null)"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/  портал: /'
}

# ──── Команда ────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _bs_load_cfg
    cmd="${1:-}"; shift || true
    case "$cmd" in
        --status)        _bs_status ;;
        --install)       _bs_install ;;
        --enable)        _bs_enable ;;
        --disable)       _bs_disable ;;
        --repair)        _bs_repair "$@" ;;
        --schema-sync)   _bs_schema_sync "$@" ;;
        --recover)       _bs_recover ;;
        --local-setup)   _bs_local_setup "$@" ;;
        --local-files)   _bs_local_files ;;
        --local-hook)    _bs_local_hook "$@" ;;
        --local-cli)     _bs_local_cli "$@" ;;
        --local-schema)  _bs_local_schema ;;
        *) echo "Использование: $(basename "$0") --status | --install | --enable | --disable | --repair [--since=UNIX] | --schema-sync [--auto] | --recover" >&2; exit 2 ;;
    esac
fi
