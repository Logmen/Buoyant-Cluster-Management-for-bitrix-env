<?php
// =============================================================================
// push_repoint.php — репойнт локальных конфигов push-сервера на ноде.
// Переносит логику install.sh::configure_push_redis (источник истины — там):
//   • storage всех /etc/push-server/push-server-{sub,pub}-*.json → host=VIP,
//     port=PORT (убирает локальный socket) — общий push-redis (active-active);
//   • security.key = signature_key (канонический, с ноды-источника lsyncd) —
//     ИНАЧЕ клиент, балансируемый LB на «чужой» sub-сервер, ловит «4010 Wrong
//     Channel Id» (push-сервер проверяет подпись канала своим security.key,
//     PHP подписывает signature_key — обязаны совпадать на ВСЕХ нодах).
// Шаблонные конфиги (с '__PORT__' в имени) пропускаются.
// Запускать на КАЖДОЙ web-ноде; после — systemctl restart push-server.
//
//   argv[1] = VIP push-redis, argv[2] = порт, argv[3] = signature_key (канон.)
// Вывод: REPOINT_OK changed=<n> sig=<8симв|NONE>  |  BAD_ARGS
// =============================================================================
$vip = $argv[1] ?? '';
$port = (int)($argv[2] ?? 0);
if ($vip === '' || $port <= 0) { fwrite(STDERR, "BAD_ARGS\n"); exit(2); }

// Канонический signature_key — аргументом (с источника lsyncd, единый для всех
// нод); фоллбэк — локальный .settings.php.
$sig = $argv[3] ?? '';
if ($sig === '') {
    $sf = '/home/bitrix/www/bitrix/.settings.php';
    if (is_file($sf)) { $s = @include $sf; $sig = $s['pull']['value']['signature_key'] ?? ''; }
}

$changed = 0;
foreach (glob('/etc/push-server/push-server-{sub,pub}-*.json', GLOB_BRACE) as $f) {
    if (strpos($f, '__PORT__') !== false) continue; // пропустить шаблоны bitrix-env
    $j = json_decode(@file_get_contents($f), true);
    if (!is_array($j) || !isset($j['storage'])) continue;
    unset($j['storage']['socket']);
    $j['storage']['host'] = $vip;
    $j['storage']['port'] = $port;
    if ($sig !== '') {
        if (!isset($j['security']) || !is_array($j['security'])) $j['security'] = array();
        $j['security']['key'] = $sig;
    }
    file_put_contents($f, json_encode($j, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    $changed++;
}
echo "REPOINT_OK changed=$changed sig=" . ($sig !== '' ? substr($sig, 0, 8) : 'NONE') . "\n";
