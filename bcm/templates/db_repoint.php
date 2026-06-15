<?php
// =============================================================================
// db_repoint.php — чтение/правка подключения БД в bitrix/.settings.php
// Используется BCM (меню «Подключение портала к БД») для перевода портала на
// ProxySQL. dbconn.php в современном bitrix-env реквизитов БД не содержит —
// источник истины именно .settings.php (ключ 'connections').
//
// Параметры из окружения:
//   BX_DOCROOT  — корень портала (по умолчанию /home/bitrix/www)
//   BX_MODE     — read | write
//   (для write) BX_DB_HOST, BX_DB_LOGIN, BX_DB_PASS
//
// Вывод (для разбора в BCM): строки KEY=VALUE + RESULT=...
//   RESULT: OK | NO_SETTINGS | NO_CONNECTION | BAD_PARAMS | WRITE_FAIL
// =============================================================================
function out($s) { fwrite(STDOUT, $s . "\n"); }

$docroot = getenv('BX_DOCROOT') ?: '/home/bitrix/www';
$mode    = getenv('BX_MODE') ?: 'read';
$file    = $docroot . '/bitrix/.settings.php';

if (!is_file($file)) { out('RESULT=NO_SETTINGS'); exit(2); }
$cfg = include $file;
if (!is_array($cfg) || !isset($cfg['connections']['value']['default']) || !is_array($cfg['connections']['value']['default'])) {
    out('RESULT=NO_CONNECTION'); exit(3);
}
$d = $cfg['connections']['value']['default'];

if ($mode === 'read') {
    out('DB_HOST='  . (isset($d['host'])     ? $d['host']     : ''));
    out('DB_NAME='  . (isset($d['database']) ? $d['database'] : ''));
    out('DB_LOGIN=' . (isset($d['login'])    ? $d['login']    : ''));
    out('RESULT=OK');
    exit(0);
}

// write
$host   = getenv('BX_DB_HOST');
$login  = getenv('BX_DB_LOGIN');
$pass   = getenv('BX_DB_PASS');
$dbname = getenv('BX_DB_NAME');
if ($host === false || $host === '' || $login === false || $login === '') {
    out('RESULT=BAD_PARAMS'); exit(4);
}

// Бэкап один раз
$bak = $file . '.bcm-bak-db';
if (!is_file($bak)) { @copy($file, $bak); }

$cfg['connections']['value']['default']['host']     = $host;
$cfg['connections']['value']['default']['login']    = $login;
$cfg['connections']['value']['default']['password'] = ($pass === false ? '' : $pass);
// database задаём только если передан (чтобы все ноды сошлись на одну БД в PXC),
// иначе сохраняем как было; options не трогаем
if ($dbname !== false && $dbname !== '') {
    $cfg['connections']['value']['default']['database'] = $dbname;
}

if (file_put_contents($file, "<?php\nreturn " . var_export($cfg, true) . ";\n", LOCK_EX) === false) {
    out('RESULT=WRITE_FAIL'); exit(5);
}
out('RESULT=OK');
