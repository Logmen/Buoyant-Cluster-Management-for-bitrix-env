#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091,SC2155,SC2015,SC2181
# =============================================================================
# bcm_settings_guard.sh — защита кластерных настроек портала от перезаписи
# средствами bitrix-env.
#
# Зачем. Ansible bitrix-env перезаписывает `.settings.php` ЦЕЛИКОМ из шаблона:
# в роли web, задача «create settings file for site» — модуль `template` без
# `force: no` и без `creates:`, то есть при каждом прогоне кладёт скелет поверх
# рабочей конфигурации. Портал теряет подключение к БД (в скелете host=localhost),
# кэш и сессии — то есть переезжает с ProxySQL и redis-VIP на несуществующие
# локальные службы. Второй путь той же беды — свежая нода: там ansible создаёт
# скелет штатно, а catch-up lsyncd (`rsync --update`, побеждает более свежий
# файл) затаскивает его на источник и раздаёт остальным.
#
# Как защищаемся. НЕ пытаемся запретить запись (Bitrix пишет в этот файл
# легально — например при установке модулей, а `chattr +i` сломал бы это).
# Вместо запрета делаем перезапись БЕЗВРЕДНОЙ: кластерные секции дублируются в
# `.settings_extra.php`, который Bitrix накладывает ПОВЕРХ `.settings.php` при
# загрузке конфигурации. Скелет от ansible остаётся, но поверх него продолжают
# действовать наши подключение к БД, кэш и сессии.
#
# ⚠️ Почему именно extra. Проверено на bitrix-env 9: в `/opt/webdir` нет ни
# одного упоминания `.settings_extra.php` — ansible его не трогает; сам Bitrix
# в него тоже НЕ пишет (`Configuration::saveConfiguration()` пишет только в
# `.settings.php`, а при наличии extra сохраняет туда состояние БЕЗ наложений).
# ⚠️ Секции из extra применяются БЕЗ проверки флага `readonly` — поэтому extra
# перекрывает всё, включая наши readonly-секции в `.settings.php`. Это и делает
# приём работающим, но требует, чтобы содержимое extra принадлежало ТОЛЬКО BCM:
# посторонний блок здесь тихо победит рабочую конфигурацию (так и получали
# CacheEngineNone вместо redis — в extra лежал забытый memcache со старого
# сервера). Поэтому сторож приводит файл к эталону ПОБАЙТНО, а не дописывает.
#
# Эталон лежит ВНЕ дерева портала (/etc/bitrix-cluster/settings-cluster.php):
# туда не дотянутся ни ansible, ни lsyncd.
#
# Реакция — по inotify (systemd.path), а не по таймеру: между перезаписью и
# починкой не должно быть окна, в которое портал отдаёт 500.
# =============================================================================
set -uo pipefail

SITE_ROOT="${BCM_SITE_ROOT:-/home/bitrix/www}"
SETTINGS="${SITE_ROOT}/bitrix/.settings.php"
EXTRA="${SITE_ROOT}/bitrix/.settings_extra.php"
REFERENCE="/etc/bitrix-cluster/settings-cluster.php"
LOG="/var/log/bcm/settings-guard.log"
UNIT_PATH="/etc/systemd/system/bcm-settings-guard.path"
UNIT_SERVICE="/etc/systemd/system/bcm-settings-guard.service"

# Секции, которые обязаны пережить перезапись. Push-секции (pull*) сюда НЕ
# входят намеренно: их bitrix-env правит через bx_blockinfile между маркерами,
# не разрушая остальной файл, а signature_key завязан на security.key
# push-сервера и должен оставаться под управлением bitrix-env.
GUARDED_SECTIONS="connections cache session"

# ──── Файлы nginx, которые тоже сносит ansible ──────────────────────────────
# ⚠️ Роль web (`sites_synchronize.yml`) синхронизирует /etc/nginx/bx/settings
# модулем synchronize с `delete: yes` при добавлении web-ноды: посторонние для
# мастера пула файлы там удаляются. Под удар попадают и слой оператора, и наш
# zz-bcm-lb.conf (real_ip от LB + Host с портом бэкенда) — без него портал за
# терминатором строит ссылки с :80 и не видит настоящий IP клиента.
NGINX_DIR="/etc/nginx/bx/settings"
# Слой оператора назван zzz-, чтобы сортироваться ПОСЛЕ zz-bcm-lb.conf: nginx
# подключает каталог по алфавиту (`include bx/settings/*.conf`), и для простых
# директив побеждает последняя.
NGINX_CUSTOM="${NGINX_DIR}/zzz-bcm-custom.conf"
NGINX_CUSTOM_REF="/etc/bitrix-cluster/nginx-custom.conf"
NGINX_LB="${NGINX_DIR}/zz-bcm-lb.conf"
NGINX_LB_REF="/etc/bitrix-cluster/nginx-bcm-lb.conf"

_sg_log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

_sg_die() { echo "ОШИБКА: $*" >&2; _sg_log "ОШИБКА: $*"; exit 1; }

# Владелец и режим — как у соседних файлов bitrix-env (bitrix:bitrix 0640).
# Инвариант BCM: файл, созданный root'ом внутри дерева портала, наследует
# владельца соседа, иначе «Проверка системы» Bitrix ругается на права.
_sg_fix_ownership() {
    local f="$1"
    [[ -f "$SETTINGS" ]] || return 0
    chown --reference="$SETTINGS" "$f" 2>/dev/null || true
    chmod --reference="$SETTINGS" "$f" 2>/dev/null || true
}

# ──── Снятие эталона с текущего (заведомо рабочего) .settings.php ────────────
_sg_make_reference() {
    [[ -f "$SETTINGS" ]] || _sg_die "нет $SETTINGS — портал не развёрнут"

    php -r '
        $src = $argv[1]; $sections = explode(" ", $argv[2]);
        $s = include $src;
        if (!is_array($s)) { fwrite(STDERR, "не удалось прочитать .settings.php\n"); exit(2); }
        $out = [];
        foreach ($sections as $k) {
            if (isset($s[$k])) { $out[$k] = $s[$k]; }
        }
        if (!$out) { fwrite(STDERR, "в .settings.php нет ни одной защищаемой секции\n"); exit(3); }
        // Формат обязан совпадать с .settings.php: Bitrix кладёт значение из
        // extra прямо в data[секция], а читает его как data[секция]["value"].
        echo "<?php\n";
        echo "// Сгенерировано BCM (bcm_settings_guard.sh). Правки будут ЗАТЁРТЫ.\n";
        echo "// Этот файл накладывается ПОВЕРХ .settings.php и держит кластерные\n";
        echo "// настройки, когда ansible bitrix-env возвращает .settings.php к скелету.\n";
        echo "// Эталон: /etc/bitrix-cluster/settings-cluster.php\n";
        echo "return ", var_export($out, true), ";\n";
    ' "$SETTINGS" "$GUARDED_SECTIONS" > "${REFERENCE}.tmp" || _sg_die "не удалось собрать эталон"

    php -l "${REFERENCE}.tmp" >/dev/null 2>&1 || { rm -f "${REFERENCE}.tmp"; _sg_die "собранный эталон не проходит проверку синтаксиса"; }

    mkdir -p "$(dirname "$REFERENCE")"
    mv -f "${REFERENCE}.tmp" "$REFERENCE"
    chmod 600 "$REFERENCE"
    _sg_log "эталон снят с $SETTINGS (секции: $GUARDED_SECTIONS)"
}

# Эталоны файлов nginx снимаем с текущих (рабочих) — они уже приведены
# install.sh к нужному виду. Слой оператора при первом запуске создаём пустым:
# он должен существовать, чтобы сторожу было что восстанавливать.
_sg_make_nginx_reference() {
    if [[ ! -f "$NGINX_CUSTOM" ]]; then
        mkdir -p "$NGINX_DIR"
        printf '%s\n' \
            '# Ваш слой настроек nginx (контекст http). BCM этот файл не перезаписывает.' \
            '# Редактируется через меню BCM (8 → 9).' \
            '#' \
            '# Подключается ПОСЛЕ zz-bcm-lb.conf (каталог читается по алфавиту), поэтому' \
            '# простые директивы, заданные здесь, побеждают.' \
            '# ⚠️ Только директивы уровня http: файл включается из блока http nginx.conf.' \
            > "$NGINX_CUSTOM"
        chmod 644 "$NGINX_CUSTOM"
    fi
    cp -f "$NGINX_CUSTOM" "$NGINX_CUSTOM_REF" && chmod 600 "$NGINX_CUSTOM_REF"
    [[ -f "$NGINX_LB" ]] && { cp -f "$NGINX_LB" "$NGINX_LB_REF"; chmod 600 "$NGINX_LB_REF"; }
    _sg_log "эталоны nginx сняты ($NGINX_CUSTOM, $NGINX_LB)"
}

# ──── Сверка и восстановление ───────────────────────────────────────────────
# ⚠️ Пишем ТОЛЬКО при расхождении. Иначе inotify зациклится: запись файла
# порождает событие, событие — новый запуск сторожа, и так далее.
_sg_assert() {
    _sg_assert_settings
    _sg_assert_nginx
}

# Файлы nginx: восстанавливаем из эталонов и перечитываем nginx, но ТОЛЬКО если
# что-то реально поменялось и конфиг проходит проверку — иначе reload на битом
# конфиге уронил бы отдачу сайта.
_sg_assert_nginx() {
    local changed=0 pair target ref
    for pair in "${NGINX_CUSTOM}|${NGINX_CUSTOM_REF}" "${NGINX_LB}|${NGINX_LB_REF}"; do
        target="${pair%%|*}"; ref="${pair##*|}"
        [[ -f "$ref" ]] || continue
        if [[ -f "$target" ]] && cmp -s "$ref" "$target"; then continue; fi
        local reason="файл отсутствует"
        [[ -f "$target" ]] && reason="содержимое разошлось с эталоном"
        mkdir -p "$(dirname "$target")" 2>/dev/null
        cp -f "$ref" "$target" || { _sg_log "НЕ УДАЛОСЬ восстановить $target"; continue; }
        chmod 644 "$target" 2>/dev/null
        _sg_log "ВОССТАНОВЛЕНО: $target ($reason)"
        changed=1
    done
    if [[ $changed -eq 1 ]]; then
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 && _sg_log "nginx перечитан"
        else
            _sg_log "ВНИМАНИЕ: nginx -t не прошёл — reload НЕ выполнен, конфиг требует внимания"
        fi
    fi
}

_sg_assert_settings() {
    [[ -f "$REFERENCE" ]] || { _sg_log "эталона нет ($REFERENCE) — сторож бездействует, нужен --install"; return 0; }

    if [[ -f "$EXTRA" ]] && cmp -s "$REFERENCE" "$EXTRA"; then
        _sg_fix_ownership "$EXTRA"
        return 0
    fi

    local reason="файл отсутствует"
    [[ -f "$EXTRA" ]] && reason="содержимое разошлось с эталоном"

    cp -f "$REFERENCE" "$EXTRA" || { _sg_log "НЕ УДАЛОСЬ восстановить $EXTRA"; return 1; }
    _sg_fix_ownership "$EXTRA"
    _sg_log "ВОССТАНОВЛЕНО: $EXTRA ($reason)"

    # Отдельно предупреждаем про сам .settings.php: если он вернулся к скелету,
    # портал сейчас работает на наложениях из extra. Это штатно, но означает,
    # что по нему прошёлся ansible и стоит прогнать install.sh.
    if grep -q "'host' => 'localhost'" "$SETTINGS" 2>/dev/null; then
        _sg_log "ВНИМАНИЕ: $SETTINGS похож на скелет bitrix-env (host=localhost) — портал держится на extra"
    fi
    return 0
}

# ──── Установка юнитов ──────────────────────────────────────────────────────
_sg_install_units() {
    local self="/opt/bcm/bin/lib/bcm_settings_guard.sh"

    cat > "$UNIT_SERVICE" <<UNIT
[Unit]
Description=BCM: восстановление кластерных настроек портала
# Предохранитель от зацикливания: если сторож срабатывает чаще, чем это
# бывает при обычной перезаписи, systemd остановит его и это будет видно.
StartLimitIntervalSec=60
StartLimitBurst=15

[Service]
Type=oneshot
ExecStart=${self} --assert

[Install]
WantedBy=multi-user.target
UNIT

    cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=BCM: слежение за настройками портала (.settings.php)

[Path]
# PathChanged, а не PathModified: ansible и Bitrix пишут файл через временный
# с последующим переименованием — событие приходит именно на замену.
PathChanged=${SETTINGS}
PathChanged=${EXTRA}
PathChanged=${NGINX_CUSTOM}
PathChanged=${NGINX_LB}
Unit=bcm-settings-guard.service

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    # Сервис включён отдельно: он отработает при загрузке и подхватит случай,
    # когда файл подменили, пока нода была выключена (inotify такое не увидит).
    systemctl enable --now bcm-settings-guard.service >/dev/null 2>&1
    systemctl enable --now bcm-settings-guard.path >/dev/null 2>&1
    _sg_log "юниты установлены и запущены"
}

_sg_status() {
    echo "Эталон:     $REFERENCE $( [[ -f "$REFERENCE" ]] && echo "(есть)" || echo "(НЕТ)" )"
    echo "Наложения:  $EXTRA"
    if [[ -f "$EXTRA" && -f "$REFERENCE" ]]; then
        cmp -s "$REFERENCE" "$EXTRA" && echo "Состояние:  совпадает с эталоном" || echo "Состояние:  РАСХОЖДЕНИЕ"
    else
        echo "Состояние:  файла наложений нет"
    fi
    echo "Слежение:   $(systemctl is-active bcm-settings-guard.path 2>/dev/null)"
    [[ -f "$REFERENCE" ]] && echo "Секции:     $(php -r '$s=include $argv[1]; echo implode(", ", array_keys($s));' "$REFERENCE" 2>/dev/null)"
    echo "Журнал:     $LOG"
    [[ -f "$LOG" ]] && { echo "--- последние события ---"; tail -5 "$LOG"; }
}

case "${1:---status}" in
    --install)
        [[ $EUID -eq 0 ]] || _sg_die "нужны права root"
        _sg_make_reference
        _sg_make_nginx_reference
        _sg_assert
        _sg_install_units
        echo "Сторож настроек портала установлен."
        ;;
    --assert)  _sg_assert ;;
    --status)  _sg_status ;;
    --disable)
        [[ $EUID -eq 0 ]] || _sg_die "нужны права root"
        systemctl disable --now bcm-settings-guard.path bcm-settings-guard.service >/dev/null 2>&1
        rm -f "$UNIT_PATH" "$UNIT_SERVICE"
        systemctl daemon-reload
        _sg_log "сторож отключён"
        echo "Сторож отключён (файл наложений и эталон оставлены на месте)."
        ;;
    *)
        echo "Использование: $(basename "$0") --install | --assert | --status | --disable"
        exit 1
        ;;
esac
