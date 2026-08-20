#!/usr/bin/env bash
# =============================================================================
# release.sh — выпуск нового релиза BCM.
#
#   scripts/release.sh X.Y.Z
#
# Что делает:
#   1) проверяет дерево (чистое, ветка main, синхронно с origin) и preflight
#      инструментов, gh-аутентификации и GPG-ключа подписи;
#   2) гоняет tests/release_check.sh — гейт ДО любых изменений;
#   3) пишет X.Y.Z в bcm/VERSION, коммитит "release: vX.Y.Z", ставит тег vX.Y.Z
#      (пока ЛОКАЛЬНО — всё обратимо);
#   4) собирает bcm-X.Y.Z.tar.gz из `git archive` тега, ПОДПИСЫВАЕТ его GPG,
#      считает sha256, проверяет подпись и структуру распаковкой;
#   5) только теперь пушит ветку и тег и публикует GitHub Release с артефактами.
#
# Порядок неслучаен: всё, что можно провалить, проваливается ДО необратимых
# удалённых действий (push тега, gh release create). Собираем из `git archive`,
# а не из рабочего дерева — так tarball гарантированно равен содержимому тега и
# не тащит неотслеживаемые/игнорируемые файлы.
#
# ⚠ .github/workflows/release.yml Release НЕ создаёт — он только валидирует
# (совпадение VERSION с тегом + tests/release_check.sh). Публикует ИМЕННО этот
# скрипт: два `gh release create` на один тег конфликтовали бы.
#
# После публикации операторы обновляются командой `bcm --update` на web-ноде —
# она проверяет подпись доверенным ключом из bcm/keys/.
# =============================================================================
set -euo pipefail

die() { echo "Ошибка: $*" >&2; exit 1; }

VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "укажите версию: scripts/release.sh X.Y.Z"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "версия должна быть в формате X.Y.Z (semver)"

# Корень проекта = родитель каталога scripts/.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VER_FILE="bcm/VERSION"
[[ -f "$VER_FILE" ]] || die "не найден $VER_FILE"

CUR="$(tr -d '[:space:]' < "$VER_FILE")"
TAG="v${VERSION}"

# Проверки состояния репозитория.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "не git-репозиторий"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "релиз делается с ветки main (сейчас: $BRANCH)"
[[ -z "$(git status --porcelain)" ]] || die "рабочее дерево не чистое — закоммитьте/уберите изменения"
git rev-parse "$TAG" >/dev/null 2>&1 && die "тег $TAG уже существует"

# Локальная main должна быть синхронна с origin/main: иначе push в конце упадёт
# (отставание) уже ПОСЛЕ создания коммита и тега, и состояние придётся разбирать руками.
if git remote get-url origin >/dev/null 2>&1; then
    git fetch --quiet origin "$BRANCH" || die "не удалось получить origin/$BRANCH"
    behind="$(git rev-list --count "HEAD..origin/${BRANCH}")"
    [[ "$behind" == "0" ]] || die "локальная $BRANCH отстаёт от origin на $behind коммит(ов) — сначала git pull"
    git rev-parse "refs/tags/${TAG}" >/dev/null 2>&1 && die "тег $TAG уже существует локально"
    git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 \
        && die "тег $TAG уже существует на origin — выберите другую версию"
else
    die "не настроен remote origin"
fi

# ── Предрелизная проверка корректности (статика по всему дереву) ─────────────
# Ловит: lib не в bcm_deploy_to_node, битые source, неопределённые функции меню,
# неподставленные плейсхолдеры, закоммиченные секреты, неполный манифест и т.п.
# Гейт ДО любых git/gh-действий — лучше упасть здесь, чем выпустить битый релиз.
if [[ -x tests/release_check.sh ]]; then
    echo "Предрелизная проверка (tests/release_check.sh)…"
    tests/release_check.sh || die "предрелизные проверки не пройдены — релиз остановлен"
else
    die "не найден tests/release_check.sh — предрелизная проверка обязательна"
fi

# ── Preflight: инструменты, аутентификация gh, GPG-ключ подписи ──────────────
command -v gh  >/dev/null 2>&1 || die "нужен GitHub CLI 'gh' (для публикации релиза)"
command -v gpg >/dev/null 2>&1 || die "нужен 'gpg' (для подписи релиза)"
gh auth status >/dev/null 2>&1 || die "gh не аутентифицирован — выполните: gh auth login"

# Ключ подписи: BCM_SIGNING_KEY → git config user.signingkey → дефолтный секретный.
SIGNING_KEY="${BCM_SIGNING_KEY:-$(git config --get user.signingkey 2>/dev/null || true)}"
if [[ -n "$SIGNING_KEY" ]]; then
    gpg --list-secret-keys "$SIGNING_KEY" >/dev/null 2>&1 \
        || die "секретный GPG-ключ '$SIGNING_KEY' не найден"
else
    [[ -n "$(gpg --list-secret-keys --with-colons 2>/dev/null | grep -m1 '^sec:')" ]] \
        || die "нет ни одного секретного GPG-ключа — создайте (gpg --full-generate-key) или задайте BCM_SIGNING_KEY"
fi

# Отпечаток подписанта.
SIGNER_FPR="$(gpg --list-secret-keys --with-colons ${SIGNING_KEY:+"$SIGNING_KEY"} 2>/dev/null \
              | awk -F: '/^fpr:/{print $10; exit}')"
[[ -n "$SIGNER_FPR" ]] || die "не удалось определить отпечаток ключа подписи"

# Доверенный публичный ключ ОБЯЗАН быть закоммичен в bcm/keys/ — иначе операторы
# не смогут проверить подпись (bcm --update откажет). Проверяем, что среди
# bundled-ключей есть ключ подписанта.
KEYS_DIR="bcm/keys"
shopt -s nullglob
PUBKEYS=( "$KEYS_DIR"/*.asc "$KEYS_DIR"/*.gpg )
shopt -u nullglob
[[ ${#PUBKEYS[@]} -gt 0 ]] || die "в $KEYS_DIR нет публичного ключа — экспортируйте его (см. $KEYS_DIR/README.md) и закоммитьте перед релизом"
_tmpgnupg="$(mktemp -d)"; trap 'rm -rf "$_tmpgnupg"' EXIT
for k in "${PUBKEYS[@]}"; do gpg --homedir "$_tmpgnupg" --batch --quiet --import "$k" 2>/dev/null || true; done
if ! gpg --homedir "$_tmpgnupg" --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10}' | grep -qx "$SIGNER_FPR"; then
    die "публичный ключ подписанта ($SIGNER_FPR) не найден в $KEYS_DIR — операторы не смогут проверить подпись. Экспортируйте: gpg --armor --export $SIGNER_FPR > $KEYS_DIR/bcm-release-pub.asc"
fi
echo "Подпись ключом: $SIGNER_FPR (публичный ключ найден в $KEYS_DIR ✓)"

# Сравнение версий: новая должна быть строго новее текущей.
if [[ "$CUR" == "$VERSION" ]]; then
    die "$VER_FILE уже содержит $VERSION"
fi
if [[ "$(printf '%s\n%s\n' "$CUR" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]]; then
    die "новая версия $VERSION не новее текущей $CUR"
fi

echo "VERSION ${CUR} -> ${VERSION}"
printf '%s\n' "$VERSION" > "$VER_FILE"

git add "$VER_FILE"
git commit -q -m "release: ${TAG}"
git tag -a "$TAG" -m "BCM ${TAG}"

# С этого момента и до пуша всё состояние ЛОКАЛЬНОЕ. Любой die ниже оставляет
# репозиторий с лишним коммитом и тегом — печатаем, как откатить.
_undo_hint() {
    echo "  Откат локального состояния: git tag -d ${TAG} && git reset --hard HEAD~1" >&2
}

# ── Сборка развёртываемого tarball'а (== содержимое тега) ─────────────────────
# Источник — `git archive` тега, а не рабочее дерево: tarball побайтово соответствует
# тому, что лежит в теге, и не может утащить неотслеживаемые или .gitignore'нутые
# файлы (редакторские бэкапы, локальные ключи), случайно оказавшиеся в bcm/.
BUILD="$(mktemp -d)"; trap 'rm -rf "$_tmpgnupg" "$BUILD"' EXIT
STAGE="bcm-${VERSION}"
mkdir -p "${BUILD}/${STAGE}"
git archive --format=tar "$TAG" \
    bcm install.sh install_answers.conf.example scripts/preflight_check.sh scripts/portal_export.sh \
    README.md LICENSE NOTICE DEPLOY_REQUIREMENTS.txt \
    | tar -x -C "${BUILD}/${STAGE}" \
    || { _undo_hint; die "не удалось собрать дерево релиза из git archive"; }
TARBALL="${BUILD}/bcm-${VERSION}.tar.gz"
tar -czf "$TARBALL" -C "$BUILD" "$STAGE"

# ── Smoke-тест собранного пакета ─────────────────────────────────────────────
# Проверяем распаковкой ровно то, на что опирается `bcm --update`: он ищет корень
# пакета как единственный путь '*/bin/bcm'. Лишний или отсутствующий — обновление
# на нодах сломается уже после публикации.
CHECK="${BUILD}/verify"; mkdir -p "$CHECK"
tar -xzf "$TARBALL" -C "$CHECK" || { _undo_hint; die "собранный tarball не распаковывается"; }
mapfile -t _roots < <(find "$CHECK" -path '*/bin/bcm' -type f)
[[ ${#_roots[@]} -eq 1 ]] \
    || { _undo_hint; die "в tarball'е ${#_roots[@]} путей '*/bin/bcm' (нужен ровно 1) — bcm --update не найдёт корень"; }
_pkg="$(dirname "$(dirname "${_roots[0]}")")"
_tarver="$(tr -d '[:space:]' < "${_pkg}/VERSION" 2>/dev/null || true)"
[[ "$_tarver" == "$VERSION" ]] \
    || { _undo_hint; die "VERSION внутри tarball'а ('$_tarver') не совпадает с релизом ($VERSION)"; }
for _need in "${CHECK}/${STAGE}/install.sh" "${_pkg}/bin/bcm"; do
    [[ -s "$_need" ]] || { _undo_hint; die "в tarball'е нет обязательного файла: ${_need#"$CHECK"/}"; }
done
compgen -G "${_pkg}/keys/*.asc" >/dev/null \
    || { _undo_hint; die "в tarball'е нет bcm/keys/*.asc — операторы не смогут проверить подпись"; }
echo "Пакет проверен: корень $(basename "$_pkg"), VERSION ${_tarver}, ключи на месте ✓"

# ── Подпись (detached, ASCII-armored) + контрольная сумма ────────────────────
echo "Подписываю tarball ключом ${SIGNER_FPR}…"
gpg --batch --yes --armor ${SIGNING_KEY:+--local-user "$SIGNING_KEY"} \
    --output "${TARBALL}.asc" --detach-sign "$TARBALL" \
    || { _undo_hint; die "подпись не удалась — релиз НЕ опубликован"; }
( cd "$BUILD" && sha256sum "bcm-${VERSION}.tar.gz" > "bcm-${VERSION}.tar.gz.sha256" )
# Самопроверка подписи перед публикацией.
gpg --verify "${TARBALL}.asc" "$TARBALL" >/dev/null 2>&1 \
    || { _undo_hint; die "самопроверка подписи не прошла — релиз НЕ опубликован"; }

# ── Необратимая часть: публикация ────────────────────────────────────────────
# Всё проверяемое проверено выше, поэтому push и создание Release идут последними.
echo "Пушу ветку и тег ${TAG}…"
git push origin "$BRANCH" || { _undo_hint; die "не удалось запушить ветку"; }
git push origin "$TAG"    || { _undo_hint; die "не удалось запушить тег"; }

# ── Публикация GitHub Release с подписанными артефактами ─────────────────────
echo "Публикую GitHub Release ${TAG}…"
gh release create "$TAG" \
    --title "BCM ${TAG}" \
    --generate-notes \
    "$TARBALL" "${TARBALL}.asc" "${TARBALL}.sha256"

echo
echo "Готово. Release ${TAG} опубликован с подписью (.asc) и sha256."
echo "Операторы обновляются на web-ноде: bcm --update  (подпись проверяется автоматически)"
