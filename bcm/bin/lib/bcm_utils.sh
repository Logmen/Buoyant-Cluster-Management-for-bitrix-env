#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2229,SC2015,SC2129,SC2001,SC2155,SC2181
# =============================================================================
# bcm_utils.sh — Общие утилиты Buoyant Cluster Management for bitrix-env
# TUI-рисование, цвета, псевдографика, вспомогательные функции
# =============================================================================
# НЕ содержит хардкодных IP, версий, имён узлов.
# =============================================================================

# ──── ANSI цвета ────────────────────────────────────────────────────────────
BCM_COLOR_RESET='\033[0m'
BCM_COLOR_RED='\033[0;31m'
BCM_COLOR_RED_BOLD='\033[1;31m'
BCM_COLOR_GREEN='\033[0;32m'
BCM_COLOR_GREEN_BOLD='\033[1;32m'
BCM_COLOR_YELLOW='\033[0;33m'
BCM_COLOR_YELLOW_BOLD='\033[1;33m'
BCM_COLOR_BLUE='\033[0;34m'
BCM_COLOR_BLUE_BOLD='\033[1;34m'
BCM_COLOR_CYAN='\033[0;36m'
BCM_COLOR_CYAN_BOLD='\033[1;36m'
BCM_COLOR_WHITE='\033[1;37m'
BCM_COLOR_GRAY='\033[0;37m'
BCM_COLOR_DIM='\033[2m'

# ──── Псевдографические символы ─────────────────────────────────────────────
BCM_LINE_H='═'      # горизонтальная двойная линия
BCM_LINE_H1='─'     # горизонтальная одиночная линия
BCM_LINE_V='║'      # вертикальная
BCM_CORNER_TL='╔'
BCM_CORNER_TR='╗'
BCM_CORNER_BL='╚'
BCM_CORNER_BR='╝'
BCM_T_TOP='╦'
BCM_T_BOT='╩'
BCM_T_LEFT='╠'
BCM_T_RIGHT='╣'
BCM_CROSS='╬'

# ──── Глобальные переменные ──────────────────────────────────────────────────
BCM_SCREEN_WIDTH=78       # ширина экрана TUI
BCM_DEBUG=${BCM_DEBUG:-0}

# ──── Определение ширины терминала ──────────────────────────────────────────
bcm_init_screen() {
    local cols
    cols=$(tput cols 2>/dev/null) || cols=80
    [[ $cols -gt 100 ]] && cols=100
    [[ $cols -lt 60  ]] && cols=78
    BCM_SCREEN_WIDTH=$cols
}

# ──── Строка из повторяющегося символа нужной длины ─────────────────────────
bcm_repeat_char() {
    local char="${1:- }"
    local count="${2:-$BCM_SCREEN_WIDTH}"
    printf '%0.s'"$char" $(seq 1 "$count")
}

# ──── Дополнение строки пробелами до ШИРИНЫ ОТОБРАЖЕНИЯ ──────────────────────
# printf '%-Ns' дополняет по БАЙТАМ → кириллица и '—' (2-3 байта/символ) делали
# ячейку визуально уже → разделители '│' и колонка статуса «уезжали» на строках
# с кириллицей (заголовки, 'держит: lb01', плейсхолдер '—'). ${#s} в UTF-8-локали
# (на нодах LANG=en_US.UTF-8) считает СИМВОЛЫ = ширину для наших глифов (все
# width-1). Левое выравнивание; длиннее ширины — не трогаем (обрезает вызывающий).
bcm_pad() {
    local s="$1" width="$2" pad
    pad=$(( width - ${#s} ))
    (( pad < 0 )) && pad=0
    printf '%s%*s' "$s" "$pad" ""
}

# ──── Цветной вывод ──────────────────────────────────────────────────────────
# bcm_color <color> <text>
bcm_color() {
    local color_var="BCM_COLOR_${1^^}"
    local color="${!color_var:-$BCM_COLOR_RESET}"
    echo -e "${color}${2}${BCM_COLOR_RESET}"
}

# bcm_echo_color <color> <text>  (без новой строки)
bcm_echo_color() {
    local color_var="BCM_COLOR_${1^^}"
    local color="${!color_var:-$BCM_COLOR_RESET}"
    printf '%b%s%b' "$color" "$2" "$BCM_COLOR_RESET"
}

# ──── Статус OK / FAIL / WARN ─────────────────────────────────────────────
# Маркер фиксированной ШИРИНЫ ОТОБРАЖЕНИЯ (8 колонок: ' <глиф> <LABEL>' + добивка).
# Только width-1 глифы (✓ ✗ ▲ … — ◆): ⚠ (U+26A0) и 🔧 (U+1F527) в части терминалов
# рендерятся шириной 2 (emoji-презентация) и рвали правый край колонки статуса.
# bcm_pad считает по символам, цвет оборачивает уже дополненную строку.
_bcm_status_marker() {
    bcm_echo_color "$1" "$(bcm_pad " ${2} ${3}" 8)"
}
bcm_status_ok()    { _bcm_status_marker "GREEN_BOLD"  "✓" "OK";    }
bcm_status_fail()  { _bcm_status_marker "RED_BOLD"    "✗" "FAIL";  }
bcm_status_warn()  { _bcm_status_marker "YELLOW_BOLD" "▲" "WARN";  }
bcm_status_na()    { _bcm_status_marker "GRAY"        "—" "N/A";   }
bcm_status_check() { _bcm_status_marker "CYAN"        "…" "CHK";   }
bcm_status_maint() { _bcm_status_marker "YELLOW"      "◆" "MAINT"; }

# ──── Заголовок BCM ──────────────────────────────────────────────────────────
# Параметры передаются извне из bcm_runtime.sh
bcm_print_header() {
    local app_ver="${1:-unknown}"
    local benv_ver="${2:-unknown}"
    local role="${3:-unknown}"
    local node="${4:-$(hostname -s)}"

    # clear только в интерактивном TTY: без TERM (ssh без -t, cron) clear
    # падает («TERM environment variable not set») и под set -e убивает bcm
    # — ломался даже --status-only (ловили вживую).
    { [[ -t 1 && ${BCM_DEBUG:-0} -eq 0 ]] && clear 2>/dev/null; } || true

    local title="Buoyant Cluster Management for bitrix-env"
    local ver_str="v${app_ver}  (bitrix-env ${benv_ver})"
    local node_str="Узел: ${node}  Роль: ${role}"

    echo
    bcm_color "CYAN_BOLD" "  ${title}  ${ver_str}"
    bcm_echo_color "DIM" "  ${node_str}"
    echo
    bcm_echo_color "CYAN" "  "
    bcm_repeat_char "$BCM_LINE_H" $((BCM_SCREEN_WIDTH - 2))
    echo
    echo
}

# ──── Горизонтальный разделитель ─────────────────────────────────────────────
bcm_divider() {
    local char="${1:-$BCM_LINE_H1}"
    local width="${2:-$BCM_SCREEN_WIDTH}"
    bcm_echo_color "DIM" "  "
    bcm_repeat_char "$char" $((width - 2))
    echo
}

# ──── Заголовок раздела ───────────────────────────────────────────────────────
bcm_section_header() {
    local title="$1"
    echo
    bcm_divider "$BCM_LINE_H"
    bcm_color "WHITE" "  ${title}"
    bcm_divider "$BCM_LINE_H"
    echo
}

# ──── Таблица статусов: заголовок ────────────────────────────────────────────
# Формат: Узел | IP | VIP/CRON | Роль | Версия | Статус
bcm_table_header() {
    # bcm_pad (по символам), а не printf %-Ns (по байтам): иначе кириллические
    # заголовки уже своих колонок и разделители не совпадают с данными.
    printf "  %s │ %s │ %s │ %s │ %s │ %s\n" \
        "$(bcm_pad 'Узел' 12)" "$(bcm_pad 'IP' 15)" "$(bcm_pad 'VIP/CRON' 8)" \
        "$(bcm_pad 'Роль' 4)" "$(bcm_pad 'Версия' 26)" "Статус"
    bcm_divider "$BCM_LINE_H1"
}

# ──── Таблица статусов: строка узла ──────────────────────────────────────────
# bcm_table_row <node> <ip> <vipcron> <role> <version_str> <status: ok|fail|warn|na|maint>
bcm_table_row() {
    local node="$1"
    local ip="$2"
    local vipcron="${3:- —}"
    local role="$4"
    local version="$5"
    local status="$6"

    # Цвет имени узла по статусу
    local node_color="WHITE"
    [[ "$status" == "fail" ]] && node_color="RED"
    [[ "$status" == "warn" ]] && node_color="YELLOW"
    [[ "$status" == "maint" ]] && node_color="GRAY"

    # Статус-маркер
    local status_marker
    case "$status" in
        ok)    status_marker=$(bcm_status_ok)   ;;
        fail)  status_marker=$(bcm_status_fail) ;;
        warn)  status_marker=$(bcm_status_warn) ;;
        na)    status_marker=$(bcm_status_na)   ;;
        maint) status_marker=$(bcm_status_maint) ;;
        *)     status_marker=$(bcm_status_check);;
    esac

    # Все ячейки — через bcm_pad (по символам): данные с кириллицей ('держит: lb01')
    # и плейсхолдер '—' иначе сдвигали колонку статуса относительно ASCII-строк.
    printf "  "
    bcm_echo_color "$node_color" "$(bcm_pad "$node" 12)"
    printf " │ %s │ %s │ %s │ %s │ %s\n" \
        "$(bcm_pad "$ip" 15)" "$(bcm_pad "$vipcron" 8)" "$(bcm_pad "$role" 4)" \
        "$(bcm_pad "${version:0:26}" 26)" "$status_marker"
}

# ──── Пустая строка-разделитель между слоями ─────────────────────────────────
bcm_table_layer_sep() {
    echo
}

# ──── Вывод меню ─────────────────────────────────────────────────────────────
# bcm_print_menu_items <array_nameref>
# Принимает массив строк вида "N. Название пункта"
bcm_print_menu() {
    local -n _items=$1
    echo
    bcm_color "WHITE" "  Доступные действия:"
    echo
    for item in "${_items[@]}"; do
        echo "    ${item}"
    done
    echo
}

# ──── Ввод пользователя ──────────────────────────────────────────────────────
bcm_read_choice() {
    local prompt="${1:-Введите ваш выбор}"
    local var_name="${2:-BCM_USER_CHOICE}"
    printf "  %b%s:%b " "$BCM_COLOR_CYAN_BOLD" "$prompt" "$BCM_COLOR_RESET"
    # shellcheck disable=SC2229
    read -r "$var_name"
}

# Аналог с таймаутом
bcm_read_choice_timeout() {
    local prompt="$1"
    local var_name="$2"
    local timeout="${3:-30}"
    printf "  %b%s (timeout %ds):%b " \
        "$BCM_COLOR_CYAN_BOLD" "$prompt" "$timeout" "$BCM_COLOR_RESET"
    read -r -t "$timeout" "$var_name" || true
}

# ──── Подтверждение y/N ──────────────────────────────────────────────────────
# bcm_confirm <prompt> → возвращает 0 (yes) или 1 (no)
bcm_confirm() {
    local prompt="${1:-Продолжить?}"
    local answer
    printf "  %b%s [y/N]:%b " "$BCM_COLOR_YELLOW" "$prompt" "$BCM_COLOR_RESET"
    read -r answer
    [[ "${answer,,}" =~ ^(y|yes|д|да)$ ]]
}

# ──── Сообщение об ошибке ────────────────────────────────────────────────────
bcm_error() {
    echo
    bcm_color "RED_BOLD" "  ✗ ОШИБКА: $*"
    echo
}

# ──── Информационное сообщение ───────────────────────────────────────────────
bcm_info() {
    bcm_color "BLUE" "  ℹ  $*"
}

# ──── Успешное сообщение ─────────────────────────────────────────────────────
bcm_ok() {
    bcm_color "GREEN_BOLD" "  ✓  $*"
}

# ──── Предупреждение ─────────────────────────────────────────────────────────
bcm_warn() {
    bcm_color "YELLOW_BOLD" "  ⚠  $*"
}

# ──── «Нажмите любую клавишу» ────────────────────────────────────────────────
bcm_any_key() {
    local msg="${1:-Нажмите Enter для продолжения...}"
    printf "  %b%s%b" "$BCM_COLOR_DIM" "$msg" "$BCM_COLOR_RESET"
    read -r -s
    echo
}

# ──── Прогресс-индикатор (спиннер) ───────────────────────────────────────────
# bcm_spinner_start <pid> <message>
bcm_spinner_start() {
    local pid="$1"
    local msg="${2:-Выполняется...}"
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local c="${spin_chars:$((i % ${#spin_chars})):1}"
        printf "  %b%s%b %s\r" \
            "$BCM_COLOR_CYAN" "$c" "$BCM_COLOR_RESET" "$msg"
        sleep 0.1
        i=$((i+1))   # ⚠ НЕ ((i++)): i=0 на 1-й итерации → rc=1 → set -e (тот же класс бага, что menu 4→7)
    done
    printf "  %-50s\r" ""   # очистить строку спиннера
}

# ──── Проверка, что скрипт запущен от root ───────────────────────────────────
bcm_require_root() {
    if [[ $EUID -ne 0 ]]; then
        bcm_error "BCM требует прав root. Запустите через sudo или от root."
        exit 1
    fi
}

# ──── Логирование ────────────────────────────────────────────────────────────
BCM_LOG_FILE="${BCM_LOG_FILE:-/var/log/bcm/bcm.log}"

bcm_log() {
    local level="${1:-INFO}"
    shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$BCM_LOG_FILE")" 2>/dev/null || true
    echo "${ts} [${level}] ${msg}" >> "$BCM_LOG_FILE" 2>/dev/null || true
    if [[ ${BCM_DEBUG:-0} -gt 0 ]]; then
        bcm_color "DIM" "  [${level}] ${msg}" || true
    fi
    return 0
}

bcm_log_info()  { bcm_log "INFO"  "$@" || true; }
bcm_log_warn()  { bcm_log "WARN"  "$@" || true; }
bcm_log_error() { bcm_log "ERROR" "$@" || true; }
bcm_log_debug() {
    if [[ ${BCM_DEBUG:-0} -gt 0 ]]; then
        bcm_log "DEBUG" "$@" || true
    fi
    return 0
}

# ──── Валидация IP-адреса ─────────────────────────────────────────────────────
bcm_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra parts <<< "$ip"
    for part in "${parts[@]}"; do
        [[ "$part" -ge 0 && "$part" -le 255 ]] || return 1
    done
    return 0
}

# ──── Валидация имени хоста ───────────────────────────────────────────────────
bcm_valid_hostname() {
    local h="$1"
    [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]]
}

# ──── Проверка доступности узла по SSH ───────────────────────────────────────
bcm_node_reachable() {
    local ip="$1"
    local timeout="${2:-5}"
    ssh -o ConnectTimeout="$timeout" \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        -i "${BCM_SSH_KEY:-/etc/bitrix-cluster/cluster_id_rsa}" \
        "root@${ip}" "exit" 2>/dev/null
}

# ──── Инициализация ───────────────────────────────────────────────────────────
bcm_init_screen

