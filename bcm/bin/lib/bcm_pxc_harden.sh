#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181,SC2016
# =============================================================================
# bcm_pxc_harden.sh — харднинг доступа к PXC: firewall, хосты учёток, root.
#
# Что закрывает (найдено вживую на crm.onelab.kz, сентябрь 2026):
#   1) install.sh открывал на PXC-нодах service mysql и порты Galera БЕЗ источника
#      → 3306 и 4567 были доступны ИЗ ИНТЕРНЕТА (ноды на публичных адресах).
#   2) учётки bitrix/bitrix_ro/monitor создавались с host='%' — вкупе с (1) от
#      всей базы (bitrix — ALL PRIVILEGES) отделял только пароль.
#   3) root@localhost без пароля (пустая строка при caching_sha2_password): только
#      сокет, но любой shell на ноде = root базы. auth_socket даёт тот же доступ
#      root'у ОС и никому больше; все инструменты BCM ходят как root ОС по сокету
#      (mysql без -h, xtrabackup через [client] socket), им ничего не меняется.
#
# Функции параметризованы IP-адресами (без bcm_load_topology), чтобы их звали и
# install.sh (у него свои массивы), и меню 3 → 11 (у него BCM_NODE_IP).
# Все шаги идемпотентны и аддитивны: разрешающие правила ставятся ДО снятия
# широких; учётки переносятся RENAME USER (пароль и гранты сохраняются, живые
# соединения не рвутся); auth_socket сперва ставится на ВСЕХ нодах и лишь потом
# ALTER USER на writer — ALTER USER реплицируется TOI, и нода без плагина не
# смогла бы его применить.
# =============================================================================

_PXCH_GALERA_PORTS="4567/tcp 4567/udp 4568/tcp 4444/tcp"
_PXCH_PLUGIN_SO="/usr/lib64/mysql/plugin/auth_socket.so"

# Хост-маска для учёток из набора IP: все в одной /24 → «a.b.c.%», иначе '%'.
# Перечислять хосты поштучно нельзя — ProxySQL ходит с каждой web-ноды, а ноды
# добавляются позже; маска подсети покрывает и это.
bcm_pxch_host_pattern() {
    local ip prefix="" p
    for ip in "$@"; do
        [[ -n "$ip" ]] || continue
        [[ "$ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]] || { echo '%'; return 0; }
        p="${BASH_REMATCH[1]}"
        if [[ -z "$prefix" ]]; then prefix="$p"
        elif [[ "$prefix" != "$p" ]]; then echo '%'; return 0; fi
    done
    [[ -n "$prefix" ]] && echo "${prefix}.%" || echo '%'
}

# ──── 1. Firewall одной PXC-ноды ─────────────────────────────────────────────
# 3306 — с web-нод (ProxySQL) и PXC-пиров; порты Galera — только с PXC-пиров.
# Аргументы: <ip ноды> "<ip всех pxc>" "<ip всех web>"
bcm_pxch_firewall_node() {
    local ip="$1" pxc_ips="$2" web_ips="$3"
    if ! bcm_ssh_exec "$ip" "systemctl is-active firewalld >/dev/null 2>&1" </dev/null; then
        bcm_warn "  ${ip}: firewalld не активен — правила не ставлю."
        return 0
    fi
    local rules="" src p
    for src in $web_ips $pxc_ips; do
        [[ "$src" == "$ip" ]] && continue
        rules+="firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${src}/32 port port=3306 protocol=tcp accept' >/dev/null 2>&1; "
    done
    for src in $pxc_ips; do
        [[ "$src" == "$ip" ]] && continue
        for p in $_PXCH_GALERA_PORTS; do
            rules+="firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${src}/32 port port=${p%/*} protocol=${p#*/} accept' >/dev/null 2>&1; "
        done
    done
    # Сначала разрешить пирам, применить, и только потом закрыть «всем».
    bcm_ssh_exec "$ip" "${rules} firewall-cmd --reload >/dev/null 2>&1" </dev/null \
        || { bcm_error "  ${ip}: не удалось добавить rich-правила."; return 1; }
    bcm_ssh_exec "$ip" "firewall-cmd --permanent --remove-service=mysql >/dev/null 2>&1; \
        for p in ${_PXCH_GALERA_PORTS}; do firewall-cmd --permanent --remove-port=\$p >/dev/null 2>&1; done; \
        firewall-cmd --reload >/dev/null 2>&1" </dev/null \
        || { bcm_error "  ${ip}: не удалось снять широкие правила."; return 1; }
    bcm_ok "  ${ip}: 3306 — только web/pxc, Galera — только pxc; service mysql и открытые порты сняты."
}

# Открыт ли 3306/Galera «всем» на ноде (для статуса).
bcm_pxch_firewall_is_open() {
    local ip="$1"
    bcm_ssh_exec "$ip" "firewall-cmd --list-services 2>/dev/null | grep -qw mysql || firewall-cmd --list-ports 2>/dev/null | grep -qE '4567|4444'" </dev/null
}

# ──── 2. root@localhost → auth_socket ────────────────────────────────────────
# Аргументы: "<ip всех pxc>" <ip writer>
bcm_pxch_root_socket() {
    local ips="$1" writer="$2" ip
    for ip in $ips; do
        if bcm_ssh_exec "$ip" "mysql -N -e \"SELECT 1 FROM information_schema.plugins WHERE plugin_name='auth_socket' AND plugin_status='ACTIVE'\" 2>/dev/null | grep -q 1" </dev/null; then
            bcm_ok "  ${ip}: плагин auth_socket активен."
            continue
        fi
        bcm_ssh_exec "$ip" "test -f ${_PXCH_PLUGIN_SO}" </dev/null \
            || { bcm_error "  ${ip}: нет ${_PXCH_PLUGIN_SO} — root оставляю как есть."; return 1; }
        # INSTALL PLUGIN — локальная операция (в mysql.plugin, переживает рестарт),
        # Galera её не реплицирует → выполняем на каждой ноде.
        bcm_ssh_exec "$ip" "mysql -e \"INSTALL PLUGIN auth_socket SONAME 'auth_socket.so'\"" </dev/null \
            || { bcm_error "  ${ip}: INSTALL PLUGIN auth_socket не удался."; return 1; }
        bcm_ok "  ${ip}: плагин auth_socket установлен."
    done

    local plug
    plug=$(bcm_ssh_exec "$writer" "mysql -N -e \"SELECT plugin FROM mysql.user WHERE user='root' AND host='localhost'\"" </dev/null 2>/dev/null | tr -d '[:space:]')
    if [[ "$plug" == "auth_socket" ]]; then
        bcm_ok "  root@localhost уже на auth_socket."
        return 0
    fi
    bcm_ssh_exec "$writer" "mysql -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket\"" </dev/null \
        || { bcm_error "  ALTER USER root@localhost не удался."; return 1; }
    # Проверка на КАЖДОЙ ноде: root ОС по сокету обязан работать (иначе откат:
    # ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '').
    for ip in $ips; do
        if ! bcm_ssh_exec "$ip" "mysql -N -e 'SELECT 1'" </dev/null 2>/dev/null | grep -q 1; then
            bcm_error "  ${ip}: root через сокет НЕ отвечает после ALTER USER — проверьте вручную."
            return 1
        fi
    done
    bcm_ok "  root@localhost → auth_socket; root ОС по сокету работает на всех нодах."
}

# ──── 3. Учётки с host='%' → маска подсети ───────────────────────────────────
# RENAME USER сохраняет пароль и гранты; уже открытые соединения не трогает.
# Аргументы: <ip writer> <маска> "<пользователи>"
bcm_pxch_scope_users() {
    local writer="$1" pattern="$2" users="$3" u n_any n_scoped
    if [[ "$pattern" == "%" ]]; then
        bcm_warn "  ноды кластера в разных подсетях — маску сузить нечем, host остаётся '%'."
        return 0
    fi
    for u in $users; do
        n_any=$(bcm_ssh_exec "$writer" "mysql -N -e \"SELECT COUNT(*) FROM mysql.user WHERE user='${u}' AND host='%'\"" </dev/null 2>/dev/null | tr -d '[:space:]')
        n_scoped=$(bcm_ssh_exec "$writer" "mysql -N -e \"SELECT COUNT(*) FROM mysql.user WHERE user='${u}' AND host='${pattern}'\"" </dev/null 2>/dev/null | tr -d '[:space:]')
        if [[ "$n_any" == "1" && "$n_scoped" == "0" ]]; then
            bcm_ssh_exec "$writer" "mysql -e \"RENAME USER '${u}'@'%' TO '${u}'@'${pattern}'\"" </dev/null \
                && bcm_ok "  ${u}@% → ${u}@${pattern}" \
                || { bcm_error "  ${u}: RENAME USER не удался."; return 1; }
        elif [[ "$n_any" == "1" && "$n_scoped" == "1" ]]; then
            # Узкая уже есть (со своими грантами) — широкую просто снимаем.
            bcm_ssh_exec "$writer" "mysql -e \"DROP USER '${u}'@'%'\"" </dev/null \
                && bcm_ok "  ${u}@% снят (узкая ${u}@${pattern} уже была)" \
                || { bcm_error "  ${u}: DROP USER '%' не удался."; return 1; }
        elif [[ "$n_scoped" == "1" ]]; then
            bcm_ok "  ${u}@${pattern} — уже узкий."
        else
            bcm_info "  ${u}: учётки нет — пропуск."
        fi
    done
}

# Список незаблокированных учёток с host='%' (кроме служебных mysql.*).
bcm_pxch_any_host_users() {
    local ip="$1"
    bcm_ssh_exec "$ip" "mysql -N -e \"SELECT user FROM mysql.user WHERE host='%' AND account_locked='N' AND user NOT LIKE 'mysql.%' ORDER BY user\"" </dev/null 2>/dev/null | tr '\n' ' '
}
