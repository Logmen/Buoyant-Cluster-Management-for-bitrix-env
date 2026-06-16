#!/usr/bin/env bash
# =============================================================================
# release.sh — выпуск нового релиза BCM.
#
#   scripts/release.sh X.Y.Z
#
# Что делает:
#   1) проверяет, что дерево чистое и мы на ветке main;
#   2) пишет X.Y.Z в bcm/VERSION;
#   3) коммитит "release: vX.Y.Z";
#   4) ставит аннотированный тег vX.Y.Z;
#   5) пушит ветку и тег.
#
# Push тега запускает .github/workflows/release.yml, который собирает
# bcm-X.Y.Z.tar.gz и публикует GitHub Release. После этого операторы
# обновляются командой `bcm --update` на web-ноде.
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

echo "Пушу ветку и тег ${TAG}…"
git push origin "$BRANCH"
git push origin "$TAG"

# ── Сборка развёртываемого tarball'а (== содержимое тега) ─────────────────────
BUILD="$(mktemp -d)"; trap 'rm -rf "$_tmpgnupg" "$BUILD"' EXIT
STAGE="bcm-${VERSION}"
mkdir -p "${BUILD}/${STAGE}"
cp -a bcm install.sh install_answers.conf.example \
      README.md LICENSE NOTICE DEPLOY_REQUIREMENTS.txt "${BUILD}/${STAGE}/"
TARBALL="${BUILD}/bcm-${VERSION}.tar.gz"
tar -czf "$TARBALL" -C "$BUILD" "$STAGE"

# ── Подпись (detached, ASCII-armored) + контрольная сумма ────────────────────
echo "Подписываю tarball ключом ${SIGNER_FPR}…"
gpg --batch --yes --armor ${SIGNING_KEY:+--local-user "$SIGNING_KEY"} \
    --output "${TARBALL}.asc" --detach-sign "$TARBALL"
( cd "$BUILD" && sha256sum "bcm-${VERSION}.tar.gz" > "bcm-${VERSION}.tar.gz.sha256" )
# Самопроверка подписи перед публикацией.
gpg --verify "${TARBALL}.asc" "$TARBALL" >/dev/null 2>&1 \
    || die "самопроверка подписи не прошла — релиз НЕ опубликован"

# ── Публикация GitHub Release с подписанными артефактами ─────────────────────
echo "Публикую GitHub Release ${TAG}…"
gh release create "$TAG" \
    --title "BCM ${TAG}" \
    --generate-notes \
    "$TARBALL" "${TARBALL}.asc" "${TARBALL}.sha256"

echo
echo "Готово. Release ${TAG} опубликован с подписью (.asc) и sha256."
echo "Операторы обновляются на web-ноде: bcm --update  (подпись проверяется автоматически)"
