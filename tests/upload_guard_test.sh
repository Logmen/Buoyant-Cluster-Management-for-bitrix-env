#!/usr/bin/env bash
# Сторож зеркала /upload (bcm/bin/lib/lsyncd_upload.sh): узнаёт ли подменённый
# каталог upload по inotify-наблюдениям процесса и когда перезапускает зеркало.
# Вместо lsyncd на каталог смотрит маленький процесс на Python — fdinfo у ядра тот
# же («inotify wd:… ino:…»). Без кластера и без root: systemctl и configure — заглушки.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
command -v python3 >/dev/null 2>&1 || { echo "SKIP: нет python3"; exit 0; }

T="$(mktemp -d)"
W=0
trap 'kill "$W" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/site/upload"

# Наблюдатель: inotify на каталог, как у lsyncd на корень дерева.
python3 - "$T/site/upload" <<'PY' &
import ctypes, sys, time
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init()
if fd < 0 or libc.inotify_add_watch(fd, sys.argv[1].encode(), 0x00000FFF) < 0:
    sys.exit(1)
time.sleep(120)
PY
W=$!
for _ in $(seq 1 50); do grep -qs '^inotify' /proc/"$W"/fdinfo/* && break; sleep 0.1; done

export LSYNCD_ROLE_ENV=/nonexistent SITE_PATH="$T/site" LOG_FILE="$T/guard.log"
# shellcheck source=../bcm/bin/lib/lsyncd_upload.sh
source bcm/bin/lib/lsyncd_upload.sh
UPLOAD_UNIT="$T/lsyncd-upload.service"
UPLOAD_HEAL_MARK="$T/heal"
UPLOAD_GUARD="$T/guard"
UPTIME=999
CONFIGURED=0
_mirror_pid() { echo "$W"; }
_mirror_uptime() { echo "$UPTIME"; }
systemctl() { return 0; }
configure() { CONFIGURED=$((CONFIGURED + 1)); }

fails=0
check() {
    local what="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        echo "  ✓ ${what}: ${got}"
    else
        echo "  ✗ ${what}: ждали «${want}», получили «${got}»"
        fails=$((fails + 1))
    fi
}

check "наблюдение на текущем каталоге" ok "$(_watch_state)"
UPTIME=10
check "зеркало только что запущено" starting "$(_watch_state)"
UPTIME=999

mv "$T/site/upload" "$T/site/upload.old" && mkdir "$T/site/upload"
check "каталог переименован и создан заново" stale "$(_watch_state)"

assert_mirror
check "сторож без юнита ничего не делает" 0 "$CONFIGURED"
touch "$UPLOAD_UNIT"
assert_mirror
check "сторож перезапускает зеркало" 1 "$CONFIGURED"
assert_mirror
check "второй перезапуск — не раньше паузы" 1 "$CONFIGURED"
echo $(( $(date +%s) - GUARD_COOLDOWN - 1 )) > "$UPLOAD_HEAL_MARK"
assert_mirror
check "после паузы — снова" 2 "$CONFIGURED"

rm -rf "$T/site/upload.old"
check "старый каталог удалён (ядро сняло наблюдение)" stale "$(_watch_state)"

kill "$W" 2>/dev/null; wait "$W" 2>/dev/null
check "процесс зеркала завершился" down "$(_watch_state)"
rmdir "$T/site/upload"
check "каталога upload нет" nodir "$(_watch_state)"

[[ $fails -eq 0 ]] && echo "OK: сторож зеркала — все проверки совпали" || { echo "FAIL: ${fails}"; exit 1; }
