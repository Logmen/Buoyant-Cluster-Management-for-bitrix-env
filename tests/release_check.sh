#!/usr/bin/env bash
# =============================================================================
# tests/release_check.sh — предрелизная проверка корректности BCM.
#
#   tests/release_check.sh
#
# Набор статических проверок, ловящих классы ошибок, которые ломают релиз/деплой:
#   1.  VERSION в формате semver
#   2.  bash -n (синтаксис) всех скриптов
#   3.  shellcheck -S error (если установлен)
#   4.  ⚠ список bcm_deploy_to_node полон в ОБЕ стороны: каждый bcm/bin/lib/*.sh в
#       нём есть (иначе новый lib не доедет до нод — повторяющийся footgun) и
#       каждое имя из списка существует на диске (опечатка/переименование)
#   5.  все `source "${BCM_LIB_DIR}/X"` ссылаются на существующий файл
#   6.  все функции из case-диспетчера меню где-то определены
#   7.  каждый __PLACEHOLDER__ из templates/ где-то подставляется
#   8.  секреты НЕ закоммичены: и по именам файлов, и по содержимому (приватные ключи)
#   9.  все файлы из манифеста релизного tarball'а существуют
#   10. доверенный публичный GPG-ключ лежит в bcm/keys/
#   11. install_answers.conf.example парсится (KEY=VALUE)
#   12. php -l для templates/*.php и PHP-сниппетов, встроенных в install.sh (если есть php)
#   13. ⚠ нет циклов `while … read` с ssh в ТЕЛЕ (обрываются после первой итерации)
#
# Возвращает 0, если все проверки прошли; иначе число проваленных (>=1).
# НЕ требует доступа к кластеру — чистая статика по дереву репозитория.
# Запускается как preflight в scripts/release.sh и в CI (.github/workflows).
# =============================================================================
set -uo pipefail   # НЕ -e: прогоняем ВСЕ проверки и агрегируем результат

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILED=0
pass()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail()    { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; FAILED=$((FAILED+1)); }
warn()    { printf '  \033[33m⚠ %s\033[0m\n' "$*"; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# Все shell-скрипты проекта (без вендоренного/временного).
_all_sh() { { echo install.sh; echo scripts/release.sh; echo "$0"#; find bcm -name '*.sh'; find tests -name '*.sh'; } | grep -v '#$' | sort -u; }

# ──────────────────────────────────────────────────────────────────────────
section "1. Версия (semver)"
if [[ -f bcm/VERSION ]]; then
    VER="$(tr -d '[:space:]' < bcm/VERSION)"
    if [[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then pass "bcm/VERSION = $VER"
    else fail "bcm/VERSION='$VER' не semver (X.Y.Z)"; fi
else fail "нет bcm/VERSION"; fi

# ──────────────────────────────────────────────────────────────────────────
section "2. Синтаксис (bash -n)"
syn_fail=0
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if ! bash -n "$f" 2>/dev/null; then fail "bash -n: $f"; syn_fail=1; fi
done < <(_all_sh)
[[ $syn_fail -eq 0 ]] && pass "все скрипты синтаксически корректны"

# ──────────────────────────────────────────────────────────────────────────
section "3. shellcheck -S error"
if command -v shellcheck >/dev/null 2>&1; then
    sc_fail=0
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        if ! shellcheck -S error "$f" >/dev/null 2>&1; then fail "shellcheck: $f"; sc_fail=1; fi
    done < <(_all_sh)
    [[ $sc_fail -eq 0 ]] && pass "shellcheck чисто (severity=error)"
else
    warn "shellcheck не установлен — проверка пропущена (в CI он ставится)"
fi

# ──────────────────────────────────────────────────────────────────────────
section "4. Полнота списка bcm_deploy_to_node (в обе стороны)"
# Извлекаем токены bin/lib/<name>.sh из bcm_ssh.sh (явный список деплоя).
mapfile -t DEPLOY_LIBS < <(grep -oE 'bin/lib/[A-Za-z0-9_]+\.sh' bcm/bin/lib/bcm_ssh.sh | sort -u)
miss=0
while IFS= read -r libpath; do
    name="bin/lib/$(basename "$libpath")"
    if ! printf '%s\n' "${DEPLOY_LIBS[@]}" | grep -qx "$name"; then
        fail "lib не в списке bcm_deploy_to_node: $name (добавьте в bcm_ssh.sh, иначе не попадёт на ноды)"
        miss=1
    fi
done < <(find bcm/bin/lib -maxdepth 1 -name '*.sh' | sort)
[[ $miss -eq 0 ]] && pass "все bcm/bin/lib/*.sh присутствуют в bcm_deploy_to_node"

# Обратная сторона: имя в списке без файла на диске (опечатка, переименование,
# удалённый lib) — деплой молча не довезёт то, на что ссылается меню.
ghost=0
for name in "${DEPLOY_LIBS[@]}"; do
    if [[ ! -f "bcm/${name}" ]]; then
        fail "bcm_deploy_to_node ссылается на несуществующий файл: bcm/${name}"
        ghost=1
    fi
done
[[ $ghost -eq 0 ]] && pass "все имена из bcm_deploy_to_node существуют на диске"

# ──────────────────────────────────────────────────────────────────────────
section "5. Целостность source-ссылок на либы"
src_fail=0
while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    if [[ ! -f "bcm/bin/lib/${ref}" ]]; then
        fail "source ссылается на несуществующий lib: \${BCM_LIB_DIR}/${ref}"
        src_fail=1
    fi
done < <(grep -rhoE '\$\{BCM_LIB_DIR\}/[A-Za-z0-9_]+\.sh' bcm/ | sed 's#.*/##' | sort -u)
[[ $src_fail -eq 0 ]] && pass "все source \${BCM_LIB_DIR}/… указывают на существующие файлы"

# ──────────────────────────────────────────────────────────────────────────
section "6. Функции case-диспетчера меню определены"
# Множество всех имён функций, определённых где-либо в bcm/.
DEFS="$(grep -rhoE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' bcm/ \
        | sed -E 's/[[:space:]]*\(\).*//; s/^[[:space:]]*//' | sort -u)"
_is_def()    { printf '%s\n' "$DEFS" | grep -qx "$1"; }
_is_builtin(){ case "$1" in break|exit|return|continue|:|true|false|echo|printf|read|local|eval|cd|exec) return 0;; *) return 1;; esac; }
dispatch_fail=0
while IFS= read -r menu; do
    # Строки вида `N) funcname …` или `N|"") funcname …` в case-диспетчере.
    while IFS= read -r call; do
        [[ -z "$call" ]] && continue
        _is_builtin "$call" && continue
        if ! _is_def "$call"; then
            fail "$(basename "$menu"): диспетчер зовёт неопределённую функцию '${call}'"
            dispatch_fail=1
        fi
    done < <(grep -oE '^[[:space:]]*[0-9]+(\|"")?\)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*([[:space:];]|$)' "$menu" \
             | sed -E 's/^[[:space:]]*[0-9]+(\|"")?\)[[:space:]]+//; s/[[:space:];].*$//')
done < <(find bcm/menu -name '*.sh')
[[ $dispatch_fail -eq 0 ]] && pass "все вызовы из case-диспетчеров меню определены"

# ──────────────────────────────────────────────────────────────────────────
section "7. Плейсхолдеры шаблонов подставляются"
ph_fail=0
if compgen -G 'bcm/templates/*.tmpl' >/dev/null; then
    while IFS= read -r ph; do
        [[ -z "$ph" ]] && continue
        # Где-то вне templates/ должна быть подстановка этого плейсхолдера.
        if ! grep -rqF "$ph" install.sh bcm/bin bcm/menu 2>/dev/null; then
            fail "плейсхолдер $ph есть в шаблоне, но нигде не подставляется (install.sh/bcm)"
            ph_fail=1
        fi
    done < <(cat bcm/templates/*.tmpl | grep -vE '^[[:space:]]*(#|--)' \
             | grep -oE '__[A-Z0-9]([A-Z0-9_]*[A-Z0-9])?__' | sort -u)
    [[ $ph_fail -eq 0 ]] && pass "все __PLACEHOLDER__ из шаблонов подставляются в коде"
else
    warn "шаблоны не найдены — пропуск"
fi

# ──────────────────────────────────────────────────────────────────────────
section "8. Секреты НЕ закоммичены"
sec_fail=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r tracked; do
        case "$tracked" in
            install_answers.conf|*_id_rsa|temp_id_rsa|*.pem|CLAUDE.md)
                fail "в индексе git закоммичен секрет/локальный файл: $tracked"
                sec_fail=1 ;;
        esac
    done < <(git ls-files)
    [[ $sec_fail -eq 0 ]] && pass "секреты (answers.conf/ключи/pem/CLAUDE.md) не в индексе"

    # По именам ловятся только ожидаемые файлы. Приватный ключ, закоммиченный под
    # любым другим именем, проходит мимо — поэтому ещё и по содержимому.
    key_fail=0
    while IFS= read -r tracked; do
        [[ -f "$tracked" ]] || continue
        if head -c 4096 -- "$tracked" 2>/dev/null | grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
            fail "в отслеживаемом файле приватный ключ: $tracked"
            key_fail=1
        fi
    done < <(git ls-files)
    [[ $key_fail -eq 0 ]] && pass "приватных ключей в отслеживаемых файлах нет"
else
    warn "не git-репозиторий — проверка секретов пропущена"
fi

# ──────────────────────────────────────────────────────────────────────────
section "9. Манифест релизного tarball'а"
man_fail=0
for item in bcm install.sh install_answers.conf.example README.md LICENSE NOTICE DEPLOY_REQUIREMENTS.txt; do
    if [[ ! -e "$item" ]]; then fail "нет файла из манифеста релиза: $item"; man_fail=1; fi
done
[[ $man_fail -eq 0 ]] && pass "все файлы релизного манифеста на месте"

# ──────────────────────────────────────────────────────────────────────────
section "10. Доверенный публичный GPG-ключ"
if compgen -G 'bcm/keys/*.asc' >/dev/null || compgen -G 'bcm/keys/*.gpg' >/dev/null; then
    pass "в bcm/keys/ есть публичный ключ релизов"
else
    fail "в bcm/keys/ нет *.asc/*.gpg — операторы не смогут проверить подпись (bcm/keys/README.md)"
fi

# ──────────────────────────────────────────────────────────────────────────
section "11. install_answers.conf.example парсится"
ex_fail=0
if [[ -f install_answers.conf.example ]]; then
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"           # ltrim
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            fail "example: строка не в формате KEY=VALUE: ${line:0:50}"
            ex_fail=1
        fi
    done < install_answers.conf.example
    [[ $ex_fail -eq 0 ]] && pass "install_answers.conf.example — корректный KEY=VALUE"
else
    fail "нет install_answers.conf.example"
fi

# ──────────────────────────────────────────────────────────────────────────
section "12. Синтаксис PHP (шаблоны и сниппеты install.sh)"
# PHP-код BCM живёт в двух местах: bcm/templates/*.php и heredoc-блоки <<'PHPSNIP'
# внутри install.sh. Ошибка в них всплывает только на ноде во время установки —
# ловим статически. Плейсхолдеры (__PORT__ и т.п.) синтаксис не ломают: без
# подстановки это обращение к константе, а не parse error.
if command -v php >/dev/null 2>&1; then
    php_fail=0
    _phptmp="$(mktemp -d)"
    awk '/<<'"'"'PHPSNIP'"'"'/{n++; f=sprintf("%s/snip%02d.php", TMP, n); inb=1; next}
         /^PHPSNIP$/{inb=0; next}
         inb{print > f}' TMP="$_phptmp" install.sh
    while IFS= read -r p; do
        [[ -f "$p" ]] || continue
        if ! php -l "$p" >/dev/null 2>&1; then
            fail "php -l: ${p/#$_phptmp\//install.sh (сниппет )}"
            php_fail=1
        fi
    done < <( { compgen -G 'bcm/templates/*.php' || true; compgen -G "$_phptmp/*.php" || true; } )
    n_snip=$(find "$_phptmp" -name '*.php' | wc -l)
    rm -rf "$_phptmp"
    [[ $php_fail -eq 0 ]] && pass "php -l чисто (шаблоны + ${n_snip} сниппет(ов) install.sh)"
else
    warn "php не установлен — проверка синтаксиса PHP пропущена"
fi

# ──────────────────────────────────────────────────────────────────────────
section "13. Нет циклов while-read с ssh в теле"
# Документированный футган: `while … read` с вызовом ssh/bcm_ssh_* в ТЕЛЕ обрывается
# после первой итерации — ssh без -n съедает остаток stdin, то есть ещё не прочитанные
# строки producer'а. Ловили вживую (правило применялось лишь к одной LB-ноде из двух).
# Правильный приём — сначала mapfile в массив, потом for по нему.
# Безопасно и НЕ считается нарушением: ssh в самом producer'е (`done < <(ssh …)`),
# когда тело цикла только печатает. tests/ из области исключены — этот файл содержит
# сам паттерн как данные (регэксп ниже) и матчил бы сам себя.
loop_fail=0
while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    fail "цикл while-read с ssh в теле: ${hit} (обойдёт только первый узел; соберите список mapfile'ом в массив и итерируйте for)"
    loop_fail=1
done < <(awk '
    FNR == 1 { inloop = 0 }
    /^[[:space:]]*#/ { next }
    { line = $0; sub(/[[:space:]]*#.*$/, "", line) }
    !inloop && line ~ /while[[:space:]]+([^[:space:]]+=[^[:space:]]*[[:space:]]+)*read[[:space:]]/ {
        inloop = 1; depth = 0; start = FNR; hit = 0
    }
    inloop {
        body = line
        if (line ~ /^[[:space:]]*done([[:space:]]|$)/) body = ""
        if (body ~ /bcm_ssh_(exec|copy|fetch)|(^|[^[:alnum:]_-])ssh[[:space:]]/) hit = 1
        depth += gsub(/(^|[^[:alnum:]_])do([^[:alnum:]_]|$)/, "&", line)
        depth -= gsub(/(^|[^[:alnum:]_])done([^[:alnum:]_]|$)/, "&", line)
        if (depth <= 0 && line ~ /done/) {
            if (hit) printf "%s:%d\n", FILENAME, start
            inloop = 0
        }
    }
' $(_all_sh | grep -v '^tests/') 2>/dev/null)
[[ $loop_fail -eq 0 ]] && pass "циклов while-read с ssh в теле нет"

# ──────────────────────────────────────────────────────────────────────────
echo
if [[ $FAILED -eq 0 ]]; then
    printf '\033[32m✓ Все предрелизные проверки пройдены.\033[0m\n'
    exit 0
else
    printf '\033[31m✗ Провалено проверок: %d. Релиз НЕ готов.\033[0m\n' "$FAILED" >&2
    exit 1
fi
