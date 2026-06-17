#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2181
# =============================================================================
# bcm_update.sh — самообновление BCM по релизам GitHub.
#
# Запускается ТОЛЬКО с brain-ноды (web): у неё есть cluster.conf, ключ
# /etc/bitrix-cluster/cluster_id_rsa и функция bcm_deploy_to_node (bcm_ssh.sh).
# Алгоритм: спросить latest-release у GitHub API → сравнить с локальной VERSION →
# скачать tarball релиза → проверить → обновить локальный /opt/bcm → раскатать
# на все ноды кластера через существующий bcm_deploy_to_node.
#
# Репозиторий по умолчанию можно переопределить env BCM_UPDATE_REPO или
# в cluster.conf: [update] repo = owner/name. Токен (для приватного репо /
# обхода лимита API) — env BCM_GITHUB_TOKEN.
# =============================================================================

# Репозиторий релизов (owner/name).
_bcm_update_repo() {
    local r="${BCM_UPDATE_REPO:-}"
    [[ -z "$r" ]] && r=$(bcm_conf_get "update" "repo" 2>/dev/null || true)
    [[ -z "$r" ]] && r="Logmen/Buoyant-Cluster-Management-for-bitrix-env"
    echo "$r"
}

# Вернуть 0, если $2 строго новее $1 (semver через sort -V).
_bcm_ver_gt() {
    [[ "$1" != "$2" ]] && \
        [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$2" ]]
}

# Каталог доверенных публичных ключей релизов (deployed: /opt/bcm/keys).
_bcm_keys_dir() { echo "${BCM_BASE_DIR:-/opt/bcm}/keys"; }

# Проверить подпись tarball'а доверенным публичным ключом + sha256 (defense-in-depth).
# Аргументы: <tarball> <sig.asc|""> <sha256|"">. Fail-closed; обход — BCM_ALLOW_UNSIGNED=1.
_bcm_verify_release() {
    local tarball="$1" sig="$2" sha="$3"
    local keys_dir; keys_dir=$(_bcm_keys_dir)

    # 1. Контрольная сумма (если есть) — дешёвая защита от битого скачивания.
    if [[ -n "$sha" && -f "$sha" ]]; then
        local want got
        want=$(awk '{print $1; exit}' "$sha")
        got=$(sha256sum "$tarball" | awk '{print $1}')
        if [[ -n "$want" && "$want" != "$got" ]]; then
            bcm_error "SHA256 не совпал: ожидалось ${want}, получено ${got}."
            return 1
        fi
        bcm_ok "SHA256 совпал."
    fi

    # 2. GPG-подпись — верификация источника.
    local -a pubkeys=()
    if [[ -d "$keys_dir" ]]; then
        while IFS= read -r k; do pubkeys+=("$k"); done \
            < <(find "$keys_dir" -maxdepth 1 -type f \( -name '*.asc' -o -name '*.gpg' \) 2>/dev/null)
    fi

    if [[ ${#pubkeys[@]} -eq 0 || -z "$sig" || ! -f "$sig" ]]; then
        if [[ "${BCM_ALLOW_UNSIGNED:-0}" == "1" ]]; then
            bcm_warn "Подпись не проверена (нет ключа в ${keys_dir} или нет .asc), но BCM_ALLOW_UNSIGNED=1 — продолжаю."
            return 0
        fi
        bcm_error "Невозможно проверить подпись релиза: $([[ ${#pubkeys[@]} -eq 0 ]] && echo "нет доверенного ключа в ${keys_dir} (см. keys/README.md)" || echo "релиз без .asc-подписи")."
        bcm_error "Обновление отклонено. Аварийный обход (НЕ рекомендуется): BCM_ALLOW_UNSIGNED=1 bcm --update"
        return 1
    fi

    command -v gpg >/dev/null 2>&1 || { bcm_error "Нужна утилита 'gpg' для проверки подписи."; return 1; }

    # Изолированный keyring — не трогаем штатный GPG узла.
    local gh; gh=$(mktemp -d /tmp/bcm-gpg.XXXXXX) || return 1
    chmod 700 "$gh"
    local rc=0 key
    for key in "${pubkeys[@]}"; do
        gpg --homedir "$gh" --batch --quiet --import "$key" 2>/dev/null || true
    done
    if gpg --homedir "$gh" --batch --verify "$sig" "$tarball" 2>/dev/null; then
        local signer
        signer=$(gpg --homedir "$gh" --batch --verify "$sig" "$tarball" 2>&1 \
                 | sed -n 's/.*[Gg]ood signature from "\(.*\)".*/\1/p' | head -1)
        bcm_ok "GPG-подпись верна${signer:+ (подписант: ${signer})}."
    else
        bcm_error "GPG-подпись НЕ прошла проверку — источник не доверенный. Обновление отклонено."
        rc=1
    fi
    rm -rf "$gh"
    return $rc
}

# curl с опциональным токеном GitHub.
_bcm_gh_curl() {
    local url="$1"; shift
    if [[ -n "${BCM_GITHUB_TOKEN:-}" ]]; then
        curl -fsSL -H "Authorization: Bearer ${BCM_GITHUB_TOKEN}" \
             -H "Accept: application/vnd.github+json" "$@" "$url"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "$@" "$url"
    fi
}

# bcm_self_update [--check] [--force]
# --check  — только проверить наличие новой версии, ничего не ставить.
# --force  — переустановить даже если версия не новее (откат/переналадка).
bcm_self_update() {
    local check_only=0 force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) check_only=1 ;;
            --force) force=1 ;;
        esac
        shift
    done

    # Только brain-нода: нужны cluster.conf, ключ и список нод.
    local role
    role=$(bcm_get_current_role 2>/dev/null || echo "")
    if [[ "$role" != "web" ]]; then
        bcm_error "Обновление запускается только с web-ноды (мозг кластера)."
        return 1
    fi
    for bin in curl tar; do
        command -v "$bin" >/dev/null 2>&1 || { bcm_error "Нужна утилита '$bin'."; return 1; }
    done

    local repo cur
    repo=$(_bcm_update_repo)
    cur=$(bcm_get_app_version)
    bcm_info "Репозиторий: ${repo}"
    bcm_info "Текущая версия: ${cur}"

    # 1. Узнать последний релиз.
    bcm_info "Запрашиваю последний релиз с GitHub…"
    local json
    json=$(_bcm_gh_curl "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)
    if [[ -z "$json" ]]; then
        bcm_error "Не удалось получить данные релиза (нет сети до github.com или репозиторий приватный — задайте BCM_GITHUB_TOKEN)."
        return 1
    fi

    local tag latest asset tball sig_url sha_url
    tag=$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
    latest="${tag#v}"
    if [[ -z "$latest" ]]; then
        bcm_error "Не удалось разобрать tag_name из ответа API."
        return 1
    fi
    bcm_info "Доступна:        ${latest}"

    # 2. Сравнить версии.
    if ! _bcm_ver_gt "$cur" "$latest"; then
        if [[ $force -eq 1 ]]; then
            bcm_warn "Версия не новее, но указан --force — продолжаю."
        else
            bcm_ok "Установлена актуальная версия (${cur}). Обновление не требуется."
            return 0
        fi
    fi
    if [[ $check_only -eq 1 ]]; then
        bcm_warn "Доступно обновление: ${cur} → ${latest}. Запустите 'bcm --update'."
        return 0
    fi

    # 3. Найти ссылки на ассеты: tarball, его GPG-подпись (.asc) и sha256.
    local all_urls
    all_urls=$(printf '%s' "$json" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
               | sed -E 's/.*"(https[^"]+)".*/\1/' || true)
    asset=$(printf '%s' "$all_urls"   | grep -E '\.tar\.gz$'        | head -1 || true)
    sig_url=$(printf '%s' "$all_urls" | grep -E '\.tar\.gz\.asc$'   | head -1 || true)
    sha_url=$(printf '%s' "$all_urls" | grep -E '\.tar\.gz\.sha256$'| head -1 || true)
    tball=$(printf '%s' "$json" | grep -m1 '"tarball_url"' | sed -E 's/.*"(https[^"]+)".*/\1/' || true)
    local url="${asset:-$tball}"
    if [[ -z "$url" ]]; then
        bcm_error "В релизе ${tag} нет ни .tar.gz-ассета, ни tarball_url."
        return 1
    fi

    # 4. Скачать tarball (+ подпись/sha) и ПРОВЕРИТЬ подпись ДО распаковки.
    local tmp
    tmp=$(mktemp -d /tmp/bcm-update.XXXXXX) || { bcm_error "mktemp не удался."; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    bcm_info "Скачиваю релиз ${tag}…"
    if ! _bcm_gh_curl "$url" -o "${tmp}/bcm.tar.gz"; then
        bcm_error "Скачивание не удалось: ${url}"
        return 1
    fi
    local sig_file="" sha_file=""
    if [[ -n "$sig_url" ]]; then
        _bcm_gh_curl "$sig_url" -o "${tmp}/bcm.tar.gz.asc" 2>/dev/null && sig_file="${tmp}/bcm.tar.gz.asc"
    fi
    if [[ -n "$sha_url" ]]; then
        _bcm_gh_curl "$sha_url" -o "${tmp}/bcm.tar.gz.sha256" 2>/dev/null && sha_file="${tmp}/bcm.tar.gz.sha256"
    fi

    bcm_info "Проверяю подпись релиза…"
    if ! _bcm_verify_release "${tmp}/bcm.tar.gz" "$sig_file" "$sha_file"; then
        return 1
    fi

    if ! tar -xzf "${tmp}/bcm.tar.gz" -C "$tmp"; then
        bcm_error "Распаковка архива не удалась."
        return 1
    fi

    # 5. Найти корень пакета (директорию с bin/bcm) и валидировать.
    local entry pkg_root proj_root
    entry=$(find "$tmp" -type f -path '*/bin/bcm' | head -1 || true)
    if [[ -z "$entry" ]]; then
        bcm_error "В архиве не найден bin/bcm — некорректный релиз."
        return 1
    fi
    pkg_root=$(dirname "$(dirname "$entry")")          # …/bcm
    proj_root=$(dirname "$pkg_root")                   # корень проекта (install.sh здесь)
    if [[ ! -f "${pkg_root}/VERSION" ]]; then
        bcm_error "В пакете нет VERSION — некорректный релиз."
        return 1
    fi
    local pkg_ver
    pkg_ver=$(tr -d '[:space:]' < "${pkg_root}/VERSION")
    bcm_info "Версия в архиве: ${pkg_ver}"

    # 6. Бэкап текущего /opt/bcm и обновление локального пакета на brain-ноде.
    local dest="/opt/bcm"
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    bcm_info "Бэкап ${dest} → ${dest}.bak-${ts}"
    cp -a "$dest" "${dest}.bak-${ts}" 2>/dev/null || true
    bcm_info "Обновляю локальный пакет BCM…"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
            --exclude='logs/' --exclude='*.bak-*' \
            "${pkg_root}/" "${dest}/"
    else
        cp -af "${pkg_root}/." "${dest}/"
    fi
    # install.sh лежит в корне проекта (не в пакете) — обновим best-effort.
    [[ -f "${proj_root}/install.sh" ]] && cp -af "${proj_root}/install.sh" "${dest}/install.sh" 2>/dev/null || true
    chmod +x "${dest}/bin/bcm" "${dest}"/bin/lib/*.sh 2>/dev/null || true
    # ⚠️ Владелец локального /opt/bcm — root: tar-распаковка релиза может восстановить uid
    # сборщика (1000), а keepalived brain-ноды (web01) читает notify-скрипты из СВОЕГО
    # /opt/bcm — под чужим uid он их отключит (enable_script_security). См. bcm_deploy_to_node.
    chown -R root:root "$dest" 2>/dev/null || true

    # 7. Раскатать обновлённый пакет на все ноды кластера.
    bcm_load_topology || true
    local -a failed=()
    local node ip layer
    for node in "${!BCM_NODE_IP[@]}"; do
        ip="${BCM_NODE_IP[$node]}"
        layer="${BCM_NODE_LAYER[$node]:-}"
        [[ -z "$ip" || -z "$layer" ]] && continue
        bcm_info "→ ${node} (${ip}, ${layer})"
        if ! BCM_INSTALL_SRC="$dest" bcm_deploy_to_node "$ip" "$layer"; then
            failed+=("${node} (${ip})")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        bcm_error "Обновление дошло не до всех нод: ${failed[*]}"
        bcm_warn "Локальный /opt/bcm обновлён до ${pkg_ver}; повторите 'bcm --update' для отставших нод."
        return 1
    fi

    bcm_ok "BCM обновлён до ${pkg_ver} на всех нодах."
    bcm_warn "Если релиз менял install.sh (инфраструктурные фазы), примените их с управляющей машины: sudo bash install.sh"
    return 0
}
