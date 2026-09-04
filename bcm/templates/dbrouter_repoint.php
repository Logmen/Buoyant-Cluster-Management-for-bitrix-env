<?php
// =============================================================================
// dbrouter_repoint.php — включение/выключение маршрутизатора чтений в bitrix/.settings.php
//
// Маршрутизатор (Bcm\DbRouter\Connection, /local/modules/bcm.dbrouter) подставляется
// через штатный параметр className подключения default; параметры читателя — блок
// reader того же подключения. Файл правится через var_export (closures в .settings.php
// bitrix-env нет), бэкап делается один раз с наследованием владельца и режима.
//
// Параметры из окружения:
//   BX_DOCROOT       — корень портала (по умолчанию /home/bitrix/www)
//   BX_MODE          — enable | disable | status
//   (enable) BX_READER_HOST (host:port ProxySQL), BX_READER_LOGIN (пользователь-читатель)
//
// Вывод (для разбора в BCM): строки KEY=VALUE + RESULT=...
//   RESULT: OK | NO_SETTINGS | NO_CONNECTION | BAD_PARAMS | WRITE_FAIL
// =============================================================================
const ROUTER_CLASS = '\\Bcm\\DbRouter\\Connection';
const VENDOR_CLASS = '\\Bitrix\\Main\\DB\\MysqliConnection';

function out($s) { fwrite(STDOUT, $s . "\n"); }

$docroot = getenv('BX_DOCROOT') ?: '/home/bitrix/www';
$mode    = getenv('BX_MODE') ?: 'status';
$file    = $docroot . '/bitrix/.settings.php';

if (!is_file($file)) { out('RESULT=NO_SETTINGS'); exit(2); }
$cfg = include $file;
if (!is_array($cfg) || !isset($cfg['connections']['value']['default']) || !is_array($cfg['connections']['value']['default'])) {
    out('RESULT=NO_CONNECTION'); exit(3);
}
$d = &$cfg['connections']['value']['default'];
$class = isset($d['className']) ? ltrim((string)$d['className'], '\\') : ltrim(VENDOR_CLASS, '\\');
$reader = (isset($d['reader']) && is_array($d['reader'])) ? $d['reader'] : [];

if ($mode === 'status') {
    out('CLASS=' . $class);
    out('READER_HOST='  . (isset($reader['host'])  ? $reader['host']  : ''));
    out('READER_LOGIN=' . (isset($reader['login']) ? $reader['login'] : ''));
    out('READER_ENABLED=' . ((isset($reader['host']) && ($reader['enabled'] ?? true) !== false) ? 'Y' : 'N'));
    out('ROUTED=' . (($class === ltrim(ROUTER_CLASS, '\\') && isset($reader['host']) && ($reader['enabled'] ?? true) !== false) ? 'Y' : 'N'));
    out('RESULT=OK');
    exit(0);
}

if ($mode === 'enable') {
    $host  = getenv('BX_READER_HOST');
    $login = getenv('BX_READER_LOGIN');
    if ($host === false || $host === '' || $login === false || $login === '') {
        out('RESULT=BAD_PARAMS'); exit(4);
    }
    $d['className'] = ROUTER_CLASS;
    // Прочие ключи reader (connect_timeout, cooldown…), если оператор их задал, сохраняем.
    $reader['host']    = $host;
    $reader['login']   = $login;
    $reader['enabled'] = true;
    unset($reader['password']); // пароль читателя совпадает с основным — не дублируем
    $d['reader'] = $reader;
} elseif ($mode === 'disable') {
    if ($class === ltrim(ROUTER_CLASS, '\\')) {
        $d['className'] = VENDOR_CLASS;
    }
    unset($d['reader']);
} else {
    out('RESULT=BAD_PARAMS'); exit(4);
}
unset($d);

$bak = $file . '.bcm-bak-dbrouter';
if (!is_file($bak) && @copy($file, $bak)) {
    @chmod($bak, @fileperms($file) & 0777);
    @chown($bak, @fileowner($file));
    @chgrp($bak, @filegroup($file));
}

if (file_put_contents($file, "<?php\nreturn " . var_export($cfg, true) . ";\n", LOCK_EX) === false) {
    out('RESULT=WRITE_FAIL'); exit(5);
}
out('CLASS=' . ltrim((string)$cfg['connections']['value']['default']['className'], '\\'));
out('RESULT=OK');
