#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# 14_transformer.sh — Генератор документов (сервис Transformer / Конвертер файлов)
#
# Сервис bitrix-env «Конвертер файлов»: преобразует документы/видео для просмотра
# в Диске и ленте, ГЕНЕРИРУЕТ документы по шаблонам в CRM. Состоит из модулей
# `transformer` (конвертер) + `transformercontroller` (сервер конвертации).
# Ставит LibreOffice + RabbitMQ + Erlang + FFmpeg на выбранный хост пула.
#
# ⚠️⚠️ НЕ ставится при установке кластера (install.sh) — ОСОЗНАННО:
#   • `transformercontroller` доступен ТОЛЬКО в редакции «1С-Битрикс24: Энтерпрайз»
#     (нужен портал с действующей лицензией Enterprise — из CLI не проверить);
#   • тяжёлый стек (LibreOffice/RabbitMQ/Erlang/FFmpeg), «одна роль на машину».
# Поэтому это РУЧНОЙ пункт меню, выполняется ПОСЛЕ развёртывания портала.
#
# Механика (как у push): bx-sites запускает async pool-задачу, ждём bx-process.
#   Установка: bx-sites -a configure_transformer --site S --root DIR --hostname H --domains S,localhost
#   Удаление:  bx-sites -a remove_transformer    --site S --root DIR --hostname H
# Команды выполняются на mgmt-ноде (источник lsyncd / WEB_NODES[0]).
# Документация: dev.1c-bitrix.ru course 37, lessons 30266/30268/30270.
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

WEBDIR="/opt/webdir/bin"
BX_SITES="${WEBDIR}/bx-sites"
BX_PROC="${WEBDIR}/bx-process"
WRAP="${WEBDIR}/wrapper_ansible_conf"

# ──── mgmt-нода bitrix-env (где крутится пул): источник lsyncd / WEB_NODES[0] ──
_tr_mgmt() {
    local node
    node=$(bcm_get_active_node 2>/dev/null || echo "")
    [[ -z "$node" || -z "${BCM_NODE_IP[$node]:-}" ]] && node="${BCM_NODES_WEB[0]:-}"
    [[ -z "${BCM_NODE_IP[$node]:-}" ]] && { return 1; }
    echo "${node} ${BCM_NODE_IP[$node]}"
}

# ──── Хост пула с ролью transformer (или пусто) ──────────────────────────────
# wrapper_ansible_conf: host:<name>:<ip>:<groups>:... — группа transformer в 4-м поле.
_tr_server_host() {
    local mip="$1"
    bcm_ssh_exec_timeout "$mip" 10 \
        "${WRAP} 2>/dev/null | awk -F: '/^host:/ && \$4 ~ /(^|,)transformer(,|\$)/ {print \$2}'" 2>/dev/null | head -1 | tr -d '[:space:]'
}

# ──── Список хостов пула: "name ip groups" ───────────────────────────────────
_tr_pool_hosts() {
    local mip="$1"
    bcm_ssh_exec_timeout "$mip" 10 \
        "${WRAP} 2>/dev/null | awk -F: '/^host:/ {print \$2\" \"\$3\" \"\$4}'" 2>/dev/null
}

# ──── Дождаться async pool-задачи bitrix-env (как push в install.sh) ──────────
# _tr_wait_task <mgmt_ip> <task_name> <timeout_sec>
_tr_wait_task() {
    local mip="$1" task="$2" timeout="${3:-900}" t=0 st rc
    bcm_info "Ожидание задачи ${task} (до $((timeout/60)) мин; лог: ${mip}:/opt/webdir/temp)..."
    while [[ $t -lt $timeout ]]; do
        st=$(bcm_ssh_exec_timeout "$mip" 15 "${BX_PROC} -a status -t '${task}' 2>&1" 2>/dev/null)
        if echo "$st" | grep -q ':finished:'; then
            rc=$(echo "$st" | sed -nE 's/.*:finished:([0-9]+).*/\1/p' | head -1)
            [[ "$rc" == "0" ]] && { bcm_ok "Задача ${task} завершена успешно."; return 0; }
            bcm_error "Задача ${task} завершилась с кодом ${rc}."; return 1
        fi
        if echo "$st" | grep -qE ':(error|failed):'; then
            bcm_error "Задача ${task} в состоянии ошибки."; return 1
        fi
        sleep 10; ((t+=10))
        printf '.' >&2
    done
    echo >&2
    bcm_warn "Таймаут ожидания ${task}. Проверьте: меню → фоновые задачи (bx-process), лог /opt/webdir/temp."
    return 1
}

# ──── Сайты с ядром (kernel) — только на них можно ставить transformer ───────
# Выводит "name root" для сайтов со статусом не error и наличием ядра.
_tr_kernel_sites() {
    local mip="$1"
    bcm_ssh_exec_timeout "$mip" 20 "
        ${BX_SITES} -a list -o json 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for name,v in d.get(\"params\",{}).items():
    st=v.get(\"SiteStatus\",\"\"); root=v.get(\"DocumentRoot\") or v.get(\"DocRoot\") or \"\"
    if st and st!=\"error\" and root:
        print(name, root)
' 2>/dev/null" 2>/dev/null
}

# ──── 1. Статус ──────────────────────────────────────────────────────────────
_tr_status() {
    bcm_section_header "Генератор документов (Transformer) — статус"
    local m mnode mip
    m=$(_tr_mgmt) || { bcm_error "Не найдена web/mgmt-нода."; bcm_any_key; return; }
    read -r mnode mip <<< "$m"
    bcm_info "mgmt-нода bitrix-env: ${mnode} (${mip})"
    echo

    local srv
    srv=$(_tr_server_host "$mip")
    if [[ -n "$srv" ]]; then
        bcm_ok "Роль transformer установлена на хосте пула: ${srv}"
    else
        bcm_warn "Роль transformer НЕ установлена (нет хоста с группой 'transformer' в пуле)."
    fi
    echo
    bcm_color "WHITE" "  ── Сервисы стека на хосте transformer ──"
    if [[ -n "$srv" ]]; then
        # srv — имя хоста пула; берём его IP из топологии, если это узел кластера
        local sip="${BCM_NODE_IP[$srv]:-}"
        if [[ -n "$sip" ]]; then
            for svc in rabbitmq-server libreoffice transformer; do
                local st
                st=$(bcm_ssh_service_status "$sip" "$svc" 2>/dev/null)
                printf "    %-20s %s\n" "$svc" "${st:-—}"
            done
        else
            bcm_info "    Хост '${srv}' вне cluster.conf — статус сервисов смотрите на нём напрямую."
        fi
    else
        bcm_info "    (нет)"
    fi
    echo
    bcm_color "WHITE" "  ── Модули по сайтам (transformer / transformercontroller) ──"
    bcm_ssh_exec_timeout "$mip" 15 \
        "${WEBDIR}/menu/11_transformer/functions.sh >/dev/null 2>&1; true" 2>/dev/null
    local sites
    sites=$(_tr_kernel_sites "$mip")
    if [[ -n "$sites" ]]; then
        echo "$sites" | while read -r sname sroot; do
            printf "    %-20s %s\n" "$sname" "$sroot"
        done
    else
        bcm_warn "    Сайтов с ядром не найдено (портал не развёрнут?)."
    fi
    bcm_any_key
}

# ──── 2. Установить ──────────────────────────────────────────────────────────
_tr_install() {
    bcm_section_header "Установка генератора документов (Transformer)"

    bcm_warn "╔════════════════════════════════════════════════════════════════════╗"
    bcm_warn "║ ТРЕБОВАНИЯ (проверьте ДО установки):                                ║"
    bcm_warn "║  • Портал развёрнут (сайт с ядром), не пустой.                      ║"
    bcm_warn "║  • Действующая лицензия «1С-Битрикс24: Энтерпрайз»                  ║"
    bcm_warn "║    (модуль transformercontroller — только Enterprise; из CLI не     ║"
    bcm_warn "║     проверяется, отвечаете вы).                                     ║"
    bcm_warn "║  • Ставит LibreOffice + RabbitMQ + Erlang + FFmpeg; «одна роль на    ║"
    bcm_warn "║    машину» — лучше выделенный хост пула, не web-мозг.               ║"
    bcm_warn "╚════════════════════════════════════════════════════════════════════╝"
    echo

    local m mnode mip
    m=$(_tr_mgmt) || { bcm_error "Не найдена web/mgmt-нода."; bcm_any_key; return; }
    read -r mnode mip <<< "$m"

    if ! bcm_ssh_exec_timeout "$mip" 8 "[ -x ${BX_SITES} ]" 2>/dev/null; then
        bcm_error "${BX_SITES} не найден на ${mnode} — bitrix-env не установлен?"
        bcm_any_key; return
    fi

    # Уже стоит?
    local srv
    srv=$(_tr_server_host "$mip")
    [[ -n "$srv" ]] && { bcm_warn "Transformer уже установлен на '${srv}'. Сначала удалите (пункт 3)."; bcm_any_key; return; }

    # Сайты с ядром
    local sites
    sites=$(_tr_kernel_sites "$mip")
    if [[ -z "$sites" ]]; then
        bcm_error "Нет сайтов с ядром — портал не развёрнут (на лабе 'default' в статусе error)."
        bcm_info "Сначала разверните портал с лицензией Enterprise, затем повторите."
        bcm_any_key; return
    fi

    echo "  Сайты с ядром:"
    local -a snames=() sroots=() i=1 sname sroot
    while read -r sname sroot; do
        [[ -z "$sname" ]] && continue
        printf "    %d. %-20s %s\n" "$i" "$sname" "$sroot"
        snames+=("$sname"); sroots+=("$sroot"); ((i++))
    done <<< "$sites"
    echo
    local sidx
    bcm_read_choice "Сайт для генератора документов (1-$((i-1)), 0 — отмена)" sidx
    [[ "$sidx" == "0" || -z "$sidx" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ "$sidx" =~ ^[0-9]+$ ]] && [[ "$sidx" -ge 1 && "$sidx" -lt "$i" ]] || { bcm_error "Неверный выбор."; bcm_any_key; return; }
    local site="${snames[$((sidx-1))]}" root="${sroots[$((sidx-1))]}"

    # Хост пула под роль transformer
    echo
    echo "  Хосты пула bitrix-env (роль transformer ставится на ОДИН из них):"
    local -a hnames=() j=1 hn hip hg
    while read -r hn hip hg; do
        [[ -z "$hn" ]] && continue
        printf "    %d. %-12s %-15s [%s]\n" "$j" "$hn" "$hip" "$hg"
        hnames+=("$hn"); ((j++))
    done < <(_tr_pool_hosts "$mip")
    if [[ ${#hnames[@]} -eq 0 ]]; then
        bcm_error "Хосты пула не найдены (${WRAP})."; bcm_any_key; return
    fi
    bcm_info "⚠ «Одна роль на машину»: если web-хосты не примут роль, добавьте в пул выделенный хост."
    echo
    local hidx
    bcm_read_choice "Хост для transformer (1-$((j-1)), 0 — отмена)" hidx
    [[ "$hidx" == "0" || -z "$hidx" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    [[ "$hidx" =~ ^[0-9]+$ ]] && [[ "$hidx" -ge 1 && "$hidx" -lt "$j" ]] || { bcm_error "Неверный выбор."; bcm_any_key; return; }
    local thost="${hnames[$((hidx-1))]}"

    echo
    bcm_info "Сайт: ${site} (${root})  →  хост: ${thost}"
    bcm_warn "Подтверждаете установку Transformer (нужна лицензия Enterprise)?"
    bcm_confirm "Запустить configure_transformer?" || { bcm_info "Отменено."; bcm_any_key; return; }

    bcm_info "Запуск задачи на ${mnode}..."
    local out
    out=$(bcm_ssh_exec_timeout "$mip" 60 \
        "${BX_SITES} -a configure_transformer --site '${site}' --root '${root}' --hostname '${thost}' --domains '${site},localhost' 2>&1" 2>/dev/null)
    echo "$out" | grep -iE 'error|message' | sed 's/^/    /' | head -5
    local task
    task=$(echo "$out" | grep -Eo '(configure_)?transformer[_a-z]*_[0-9]+' | head -1)
    if [[ -z "$task" ]]; then
        bcm_error "Не удалось получить id задачи. Вывод bx-sites:"
        echo "$out" | sed 's/^/    /' | head -8
        bcm_any_key; return
    fi
    bcm_ok "Задача запущена: ${task}"
    if _tr_wait_task "$mip" "$task" 1800; then
        echo
        bcm_ok "Transformer установлен для сайта '${site}'."
        bcm_info "Завершите в админке портала: Настройки → Настройки продукта → Настройки модулей →"
        bcm_info "Диск → включить просмотр документов средствами Bitrix24."
    fi
    bcm_any_key
}

# ──── 3. Удалить ─────────────────────────────────────────────────────────────
_tr_remove() {
    bcm_section_header "Удаление генератора документов (Transformer)"
    local m mnode mip
    m=$(_tr_mgmt) || { bcm_error "Не найдена web/mgmt-нода."; bcm_any_key; return; }
    read -r mnode mip <<< "$m"

    local srv
    srv=$(_tr_server_host "$mip")
    [[ -z "$srv" ]] && { bcm_warn "Transformer не установлен — удалять нечего."; bcm_any_key; return; }
    bcm_info "Transformer установлен на хосте: ${srv}"

    # Сайт+root для remove берём из списка сайтов с ядром (как при установке)
    local sites site root
    sites=$(_tr_kernel_sites "$mip")
    site=$(echo "$sites" | head -1 | awk '{print $1}')
    root=$(echo "$sites" | head -1 | awk '{print $2}')
    if [[ -z "$site" ]]; then
        bcm_warn "Не удалось определить сайт. Удаление выполните в TUI bitrix-env (меню 7→2)."
        bcm_any_key; return
    fi
    bcm_info "Сайт: ${site} (${root})  →  хост: ${srv}"
    bcm_confirm "Удалить Transformer (remove_transformer)?" || { bcm_info "Отменено."; bcm_any_key; return; }

    local out
    out=$(bcm_ssh_exec_timeout "$mip" 60 \
        "${BX_SITES} -a remove_transformer --site '${site}' --root '${root}' --hostname '${srv}' 2>&1" 2>/dev/null)
    local task
    task=$(echo "$out" | grep -Eo '(remove_)?transformer[_a-z]*_[0-9]+' | head -1)
    if [[ -z "$task" ]]; then
        bcm_error "Не удалось получить id задачи:"; echo "$out" | sed 's/^/    /' | head -8; bcm_any_key; return
    fi
    bcm_ok "Задача запущена: ${task}"
    _tr_wait_task "$mip" "$task" 1200
    bcm_any_key
}

# ──── 4. Фоновые задачи пула ─────────────────────────────────────────────────
_tr_pool_tasks() {
    bcm_section_header "Фоновые задачи пула bitrix-env (bx-process)"
    local m mnode mip
    m=$(_tr_mgmt) || { bcm_error "Не найдена web/mgmt-нода."; bcm_any_key; return; }
    read -r mnode mip <<< "$m"
    bcm_ssh_exec_timeout "$mip" 15 "${BX_PROC} -a list 2>&1" 2>/dev/null | sed 's/^/  /' | head -30
    bcm_any_key
}

# ──── HA: есть ли transformer-стек на ноде (rabbitmq + workerd) ──────────────
_tr_stack_present() {
    local ip="$1"
    bcm_ssh_exec_timeout "$ip" 8 \
        "systemctl list-unit-files 2>/dev/null | grep -qE '^rabbitmq-server\.service' && \
         systemctl list-unit-files 2>/dev/null | grep -qE '^transformer\.service' && echo OK" 2>/dev/null | grep -q OK
}

# ──── 5. Настроить HA-переключение (VIP + keepalived, active/standby) ─────────
_tr_setup_ha() {
    bcm_section_header "HA-переключение Transformer (VIP + keepalived, active/standby)"

    bcm_info "Сервис переезжает на запасную web-ноду через плавающий VIP (как redis-сессии)."
    bcm_warn "Вариант A: данные клиентов (документы/CRM) — в PXC/Диске/S3, в transformer их нет."
    bcm_warn "Задачи из очереди RabbitMQ в момент сбоя Bitrix перевыпустит (durable переживают рестарт,"
    bcm_warn "но не гибель ноды — это осознанный компромисс без кластера RabbitMQ)."
    echo

    if [[ ${#BCM_NODES_WEB[@]} -lt 2 ]]; then
        bcm_error "Нужно минимум 2 web-узла."; bcm_any_key; return
    fi
    local active="${BCM_NODES_WEB[0]}" standby="${BCM_NODES_WEB[1]}"
    local active_ip="${BCM_NODE_IP[$active]:-}" standby_ip="${BCM_NODE_IP[$standby]:-}"
    bcm_info "Активная нода: ${active} (${active_ip}); запасная: ${standby} (${standby_ip})"
    echo

    # Предусловие: transformer-стек (rabbitmq+workerd) есть на ОБЕИХ нодах.
    local miss=0
    _tr_stack_present "$active_ip"  || { bcm_error "  ${active}: нет rabbitmq-server/transformer — установите transformer (пункт 2)."; miss=1; }
    _tr_stack_present "$standby_ip" || { bcm_error "  ${standby}: нет rabbitmq-server/transformer — установите стек и на запасной ноде."; miss=1; }
    if [[ $miss -eq 1 ]]; then
        bcm_info "HA требует одинаковый transformer-стек на active И standby. Сначала обеспечьте его на обеих."
        bcm_any_key; return
    fi

    # VIP/VRID
    local cur_vip cur_vrid tr_vip tr_vrid
    cur_vip=$(bcm_conf_get transformer vip 2>/dev/null || echo "")
    cur_vrid=$(bcm_conf_get transformer vrid 2>/dev/null || echo "60")
    bcm_info "Существующие VIP: $(bcm_get_vip 2>/dev/null) (кластер), $(bcm_conf_get session redis_vip 2>/dev/null) (сессии), $(bcm_conf_get push redis_vip 2>/dev/null) (push)"
    bcm_read_choice "VIP для Transformer${cur_vip:+ [${cur_vip}]}" tr_vip
    tr_vip="${tr_vip:-$cur_vip}"
    if ! bcm_valid_ip "$tr_vip" 2>/dev/null; then bcm_error "Некорректный VIP."; bcm_any_key; return; fi
    bcm_read_choice "VRID [${cur_vrid:-60}]" tr_vrid
    tr_vrid="${tr_vrid:-${cur_vrid:-60}}"
    [[ "$tr_vrid" =~ ^[0-9]+$ ]] || { bcm_error "VRID — число."; bcm_any_key; return; }

    bcm_confirm "Настроить HA: VIP ${tr_vip} (VRID ${tr_vrid}), active=${active}, standby=${standby}?" \
        || { bcm_info "Отменено."; bcm_any_key; return; }

    # Записать [transformer] в cluster.conf + раздать
    bcm_conf_set transformer vip "$tr_vip"
    bcm_conf_set transformer vrid "$tr_vrid"
    bcm_conf_set transformer port "5672"
    bcm_conf_set transformer active "$active"
    bcm_conf_set transformer standby "$standby"
    bcm_conf_sync 2>/dev/null || true

    # keepalived auth_pass ограничен 8 символами — генерируем ровно 8 hex (4 байта).
    local auth_pass; auth_pass=$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || echo bcmtr001)
    local tmpl="${BCM_BASE_DIR}/templates/keepalived_transformer.conf.tmpl"
    [[ -f "$tmpl" ]] || tmpl="/opt/bcm/templates/keepalived_transformer.conf.tmpl"

    local node ip state priority peer_ip
    for node in "$active" "$standby"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        if [[ "$node" == "$active" ]]; then state="MASTER"; priority="110"; peer_ip="$standby_ip"; else state="BACKUP"; priority="100"; peer_ip="$active_ip"; fi
        local iface
        iface=$(bcm_ssh_exec_timeout "$ip" 8 "ip route | awk '/default/{print \$5; exit}'" 2>/dev/null | tr -d '[:space:]'); [[ -z "$iface" ]] && iface="ens18"

        local lka="/tmp/keepalived-transformer-${node}.conf"
        sed -e "s/__TR_VRID__/${tr_vrid}/g" \
            -e "s/__VRRP_STATE__/${state}/g" \
            -e "s/__NODE_IFACE__/${iface}/g" \
            -e "s/__PRIORITY__/${priority}/g" \
            -e "s/__VRRP_AUTH_PASS__/${auth_pass}/g" \
            -e "s/__TR_VIP__/${tr_vip}/g" \
            -e "s/__NODE_IP__/${ip}/g" \
            -e "s/__PEER_IP__/${peer_ip}/g" \
            "$tmpl" > "$lka"

        # notify/check уже раскатаны bcm_deploy_to_node; добиваем на всякий случай
        bcm_ssh_exec "$ip" "chmod +x /opt/bcm/bin/lib/transformer_notify.sh /opt/bcm/bin/lib/transformer_check.sh 2>/dev/null || true"
        # always-on: rabbitmq+transformer работают на ОБЕИХ нодах (keepalived только
        # держит VIP, без start/stop — иначе VRRP флапал на медленных start/stop).
        bcm_ssh_exec "$ip" "systemctl enable --now rabbitmq-server 2>/dev/null; systemctl enable --now transformer 2>/dev/null || true"
        # firewall: amqp 5672 должен быть доступен на VIP с другой web-ноды.
        bcm_ssh_exec "$ip" "systemctl is-active firewalld >/dev/null 2>&1 && firewall-cmd --permanent --add-port=5672/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 || true"
        # ⚠️ httpd (mod_php) ДОЛЖЕН быть перезапущен, чтобы загрузить php-amqp: если
        # extension ставился при работающем httpd, портал его «не видит» (модуль
        # «Сервер конвертации»: php-amqp Не работает, RabbitMQ Неизвестно) — ловили
        # вживую на запасной ноде при ручной репликации стека.
        bcm_ssh_exec "$ip" "php -m 2>/dev/null | grep -qi '^amqp\$' && systemctl restart httpd 2>/dev/null || true"
        # VRRP-блок (идемпотентно)
        if ! bcm_ssh_exec "$ip" "grep -q 'virtual_router_id ${tr_vrid}' /etc/keepalived/keepalived.conf 2>/dev/null"; then
            bcm_ssh_exec "$ip" "cat >> /etc/keepalived/keepalived.conf" < "$lka"
        fi
        bcm_ssh_exec_timeout "$ip" 15 "systemctl reload keepalived 2>/dev/null || systemctl restart keepalived" 2>/dev/null
        rm -f "$lka"
        bcm_ok "  ${node}: keepalived-инстанс transformer (${state}, prio ${priority}) добавлен."
    done

    # Репойнт эндпоинта RabbitMQ на VIP: модуль transformercontroller ходит на
    # host='default', который резолвится через /etc/hosts. Меняем default → VIP на
    # ОБЕИХ web-нодах (перед ANSIBLE-блоком, иначе ansible bitrix-env затрёт).
    echo
    bcm_info "Репойнт эндпоинта RabbitMQ (default → ${tr_vip}) в /etc/hosts на web-нодах..."
    for node in "$active" "$standby"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        bcm_ssh_exec "$ip" "cp -n /etc/hosts /etc/hosts.bcm-bak-tr 2>/dev/null
            sed -i '/[[:space:]]default\$/d' /etc/hosts
            if grep -q '# ANSIBLE MANAGED BLOCK' /etc/hosts; then sed -i '/# ANSIBLE MANAGED BLOCK/i ${tr_vip} default' /etc/hosts; else echo '${tr_vip} default' >> /etc/hosts; fi" 2>/dev/null \
            && bcm_ok "  ${node}: default → ${tr_vip}"
    done

    echo
    bcm_ok "HA-переключение настроено: VIP ${tr_vip} на ${active}, rabbitmq+transformer работают на обеих."
    bcm_info "Эндпоинт RabbitMQ модуля (host=default) → VIP. Проверьте failover: меню 14 → 6."
    bcm_any_key
}

# ──── 6. Статус HA / ручной failover ─────────────────────────────────────────
_tr_ha_status() {
    bcm_section_header "Transformer HA — статус"
    local vip vrid active standby
    vip=$(bcm_conf_get transformer vip 2>/dev/null || echo "")
    vrid=$(bcm_conf_get transformer vrid 2>/dev/null || echo "")
    active=$(bcm_conf_get transformer active 2>/dev/null || echo "")
    standby=$(bcm_conf_get transformer standby 2>/dev/null || echo "")
    if [[ -z "$vip" ]]; then
        bcm_warn "HA не настроен (нет [transformer] vip). Пункт 5 — настроить."; bcm_any_key; return
    fi
    bcm_info "VIP ${vip} (VRID ${vrid}); active=${active}, standby=${standby}"
    echo
    local node ip holder=""
    for node in "$active" "$standby"; do
        ip="${BCM_NODE_IP[$node]:-}"; [[ -z "$ip" ]] && continue
        local has_vip rmq wrk
        has_vip=$(bcm_ssh_exec_timeout "$ip" 8 "ip -4 addr | grep -q 'inet ${vip}/' && echo YES || echo no" 2>/dev/null | tr -d '[:space:]')
        rmq=$(bcm_ssh_service_status "$ip" "rabbitmq-server" 2>/dev/null)
        wrk=$(bcm_ssh_service_status "$ip" "transformer" 2>/dev/null)
        [[ "$has_vip" == "YES" ]] && holder="$node"
        printf "  %-8s VIP:%-4s rabbitmq:%-10s transformer:%-10s\n" "$node" "${has_vip}" "${rmq:-—}" "${wrk:-—}"
    done
    echo
    [[ -n "$holder" ]] && bcm_ok "VIP держит: ${holder}" || bcm_warn "VIP сейчас никто не держит (проверьте keepalived)."
    echo
    if bcm_confirm "Принудительный failover (перевести VIP на другую ноду)?"; then
        local from="$holder" to=""
        [[ "$holder" == "$active" ]] && to="$standby" || to="$active"
        [[ -z "$to" || -z "${BCM_NODE_IP[$to]:-}" ]] && { bcm_error "Не определить целевую ноду."; bcm_any_key; return; }
        bcm_info "Останавливаю keepalived на ${from} на 5с (VIP уедет на ${to})..."
        local fip="${BCM_NODE_IP[$from]:-}"
        bcm_ssh_exec_timeout "$fip" 15 "systemctl stop keepalived; sleep 5; systemctl start keepalived" 2>/dev/null &
        sleep 9
        bcm_ok "Готово. Проверьте статус повторно (VIP должен быть на ${to})."
    fi
    bcm_any_key
}

# ──── Меню ───────────────────────────────────────────────────────────────────
# ──── Репликация стека Transformer на web-ноды ВНЕ пула bitrix-env ───────────
# bx-sites -a configure_transformer ставит роль ТОЛЬКО на хост-член пула (у нас
# web01). Для HA (вариант A: rabbitmq+transformer always-on на ОБЕИХ web + VIP)
# стек на остальных web разворачивается репликацией с источника (документированная
# ручная процедура из CLAUDE.md, здесь автоматизирована). Файловые переносы идут
# С ИСТОЧНИКА (у него /etc/bitrix-cluster/cluster_id_rsa до пиров); команды на пире —
# напрямую с мозг-ноды. NODENAME rabbitmq — per-node. LibreOffice ставился из
# локальных rpm (@commandline, удаляются после) → докачиваем тарбол с repo.bitrix.info
# по версии источника. ⚠️ Нужен УЖЕ установленный (пункт 2) стек на источнике.
_tr_replicate_peers() {
    bcm_section_header "Репликация стека Transformer на остальные web (вне пула)"
    local m src src_ip
    m=$(_tr_mgmt) || { bcm_error "Не найдена mgmt/web-нода."; bcm_any_key; return; }
    read -r src src_ip <<< "$m"

    # SSH-обёртка для запуска rsync/ssh С ИСТОЧНИКА на пиры (ключ кластера на нодах)
    local NSSH="ssh -i /etc/bitrix-cluster/cluster_id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    if ! bcm_ssh_exec "$src_ip" "test -f /etc/systemd/system/transformer.service" </dev/null; then
        bcm_error "На источнике ${src} нет transformer.service — сначала установите Transformer (пункт 2)."
        bcm_any_key; return
    fi

    # Цели — web-ноды, кроме источника
    local -a peers=() pips=()
    local n
    for n in "${BCM_NODES_WEB[@]}"; do
        [[ -n "$n" && "$n" != "$src" ]] || continue
        local ip="${BCM_NODE_IP[$n]:-}"; [[ -z "$ip" ]] && continue
        peers+=("$n"); pips+=("$ip")
    done
    [[ ${#peers[@]} -gt 0 ]] || { bcm_info "Других web-нод нет."; bcm_any_key; return; }

    local lover
    lover=$(bcm_ssh_exec "$src_ip" "rpm -q --qf '%{version}' libreoffice25.2 2>/dev/null" </dev/null | tr -d '[:space:]')

    # Пароль rabbitmq-юзера bitrix — из опции модуля transformercontroller; иначе спросить
    local rmqpass
    rmqpass=$(bcm_ssh_exec "$src_ip" "cd /home/bitrix/www 2>/dev/null && php -r '\$_SERVER[\"DOCUMENT_ROOT\"]=\"/home/bitrix/www\"; define(\"NO_KEEP_STATISTIC\",true); define(\"NOT_CHECK_PERMISSIONS\",true); @include(\"/home/bitrix/www/bitrix/modules/main/include/prolog_before.php\"); if(class_exists(\"\\\\Bitrix\\\\Main\\\\Config\\\\Option\")) echo \\Bitrix\\Main\\Config\\Option::get(\"transformercontroller\",\"password\",\"\");' 2>/dev/null" </dev/null | tr -d '[:space:]')
    if [[ -z "$rmqpass" ]]; then
        bcm_warn "Пароль rabbitmq-юзера 'bitrix' не прочитан из опций модуля (нет портала/модуля transformercontroller)."
        bcm_read_choice "Введите пароль rabbitmq-юзера bitrix (как на ${src}) (0 — отмена)" rmqpass
        [[ "${rmqpass:-0}" == "0" || -z "${rmqpass:-}" ]] && { bcm_info "Отменено."; bcm_any_key; return; }
    fi
    local rmq_q="'${rmqpass//\'/\'\\\'\'}'"

    bcm_info "Источник: ${src} (${src_ip}); LibreOffice ${lover:-?}; цели: ${peers[*]}"
    bcm_warn "На каждой цели: репозитории+пакеты, LibreOffice (~сотни МБ), /etc/rabbitmq (NODENAME per-node),"
    bcm_warn "unit/workerd/tmpfiles, rabbitmq-юзер, firewall 5672/tcp, restart httpd. Тяжело — НЕ прерывайте."
    bcm_confirm "Реплицировать стек transformer на ${peers[*]}?" || { bcm_info "Отменено."; bcm_any_key; return; }

    local i
    for i in "${!peers[@]}"; do
        local p="${peers[$i]}" pip="${pips[$i]}"
        if ! bcm_node_reachable "$pip" 5 2>/dev/null; then bcm_warn "  ${p} (${pip}): недоступен — пропуск."; continue; fi
        bcm_info "── ${p} (${pip}) ──"

        # 1) репозитории + GPG-ключи (с источника на пир)
        bcm_ssh_exec "$src_ip" "rsync -az -e \"${NSSH}\" /etc/yum.repos.d/rabbitmq_erlang.repo /etc/yum.repos.d/rabbitmq_rabbitmq-server.repo \$(ls /etc/yum.repos.d/rpmfusion-*.repo 2>/dev/null) root@${pip}:/etc/yum.repos.d/ 2>/dev/null; rsync -az -e \"${NSSH}\" \$(ls /etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion* 2>/dev/null) root@${pip}:/etc/pki/rpm-gpg/ 2>/dev/null" </dev/null
        bcm_ok "  ${p}: репозитории/GPG скопированы."

        # 2) пакеты из репозиториев
        local r2; r2=$(bcm_ssh_exec_verbose "$pip" "dnf install -y erlang rabbitmq-server ffmpeg php-pecl-amqp >/dev/null 2>&1 && echo PKG_OK || echo PKG_FAIL" </dev/null)
        bcm_info "  ${p}: пакеты — ${r2}"

        # 3) LibreOffice (если ещё нет — докачать тарбол по версии источника)
        if [[ -n "$lover" ]]; then
            local r3; r3=$(bcm_ssh_exec_verbose "$pip" "rpm -q libreoffice25.2 >/dev/null 2>&1 && echo LO_PRESENT || { mkdir -p /tmp/bcm-lo && cd /tmp/bcm-lo && curl -fsSL -o lo.tgz 'https://repo.bitrix.info/sources/LibreOffice_${lover}_Linux_x86-64_rpm.tar.gz' && tar xf lo.tgz && dnf install -y \$(find . -name '*.rpm' | grep -viE 'gnome|kde') >/dev/null 2>&1 && echo LO_OK || echo LO_FAIL; cd /; rm -rf /tmp/bcm-lo; }" </dev/null)
            bcm_info "  ${p}: LibreOffice — ${r3}"
        else
            bcm_warn "  ${p}: версия LibreOffice не определена — поставьте вручную."
        fi

        # 4) /etc/rabbitmq (с источника) + per-node NODENAME
        bcm_ssh_exec "$src_ip" "rsync -az -e \"${NSSH}\" /etc/rabbitmq/ root@${pip}:/etc/rabbitmq/ 2>/dev/null" </dev/null
        bcm_ssh_exec "$pip" "sed -i 's/^NODENAME=.*/NODENAME=rabbit@${p}/' /etc/rabbitmq/rabbitmq-env.conf 2>/dev/null" </dev/null

        # 5) unit + workerd + tmpfiles (с источника)
        bcm_ssh_exec "$src_ip" "rsync -az -e \"${NSSH}\" /etc/systemd/system/transformer.service root@${pip}:/etc/systemd/system/ 2>/dev/null; rsync -az -e \"${NSSH}\" /usr/local/sbin/transformer-workerd root@${pip}:/usr/local/sbin/ 2>/dev/null; rsync -az -e \"${NSSH}\" /etc/tmpfiles.d/transformer.conf root@${pip}:/etc/tmpfiles.d/ 2>/dev/null" </dev/null

        # 6) rabbitmq up + юзер bitrix (идемпотентно)
        local r6; r6=$(bcm_ssh_exec_verbose "$pip" "systemctl enable --now rabbitmq-server >/dev/null 2>&1; sleep 3; rabbitmqctl list_users 2>/dev/null | awk '{print \$1}' | grep -qx bitrix || rabbitmqctl add_user bitrix ${rmq_q} >/dev/null 2>&1; rabbitmqctl set_user_tags bitrix administrator >/dev/null 2>&1; rabbitmqctl set_permissions -p / bitrix '.*' '.*' '.*' >/dev/null 2>&1; echo rabbit=\$(systemctl is-active rabbitmq-server)" </dev/null)
        bcm_info "  ${p}: ${r6}"

        # 7) firewall 5672 + tmpfiles + unit enable + httpd (php-amqp в mod_php)
        local r7; r7=$(bcm_ssh_exec_verbose "$pip" "(firewall-cmd --permanent --add-port=5672/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1) || true; systemd-tmpfiles --create /etc/tmpfiles.d/transformer.conf >/dev/null 2>&1 || true; systemctl daemon-reload; systemctl enable transformer >/dev/null 2>&1 || true; systemctl restart httpd >/dev/null 2>&1 || true; echo httpd=\$(systemctl is-active httpd)" </dev/null)
        bcm_info "  ${p}: 5672 открыт, ${r7}"

        # 8) transformer — стартуем ТОЛЬКО если модуль (sys_workerd.php) есть
        local r8; r8=$(bcm_ssh_exec_verbose "$pip" "test -f /home/bitrix/www/bitrix/modules/transformercontroller/tools/sys_workerd.php && { systemctl restart transformer >/dev/null 2>&1; echo transformer=\$(systemctl is-active transformer); } || echo 'transformer=skip(нет модуля transformercontroller)'" </dev/null)
        bcm_ok "  ${p}: ${r8}"
    done

    echo
    bcm_ok "Репликация завершена. Дальше — HA-переключение: пункт 5 (TRANSFORMER_VIP + keepalived)."
    bcm_warn "Пока модуль transformercontroller (Enterprise) не развёрнут — transformer.service не стартует (это норма)."
    bcm_any_key
}

_tr_menu() {
    while true; do
        bcm_section_header "Генератор документов (Transformer / Конвертер файлов)"
        local menu_items=(
            "1.  Статус (роль transformer, модули по сайтам)"
            "2.  Установить (нужен портал + лицензия Enterprise)"
            "3.  Удалить"
            "4.  Фоновые задачи пула (bx-process)"
            "5.  Настроить HA-переключение (VIP + keepalived)"
            "6.  Статус HA / ручной failover"
            "7.  Реплицировать стек transformer на остальные web (вне пула)"
            "0.  Назад"
        )
        bcm_print_menu menu_items
        local choice
        bcm_read_choice "Ваш выбор" choice
        case "$choice" in
            1) _tr_status     ;;
            2) _tr_install    ;;
            3) _tr_remove     ;;
            4) _tr_pool_tasks ;;
            5) _tr_setup_ha   ;;
            6) _tr_ha_status  ;;
            7) _tr_replicate_peers ;;
            0) return 0       ;;
            "") : ;;
            *) bcm_warn "Неверный выбор." ;;
        esac
    done
}

_tr_menu
