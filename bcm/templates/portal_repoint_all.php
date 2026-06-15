<?php
// =============================================================================
// portal_repoint_all.php — перенастройка bitrix/.settings.php ПЕРЕНЕСЁННОГО
// портала на инфраструктуру ЭТОГО кластера: БД → ProxySQL, сессии → session-redis
// VIP, кэш → cache-redis VIP, push path_to_publish → node-local.
//
// ⚠️ ПРИНЦИП «не ломать собственные настройки портала»: каждый перенесённый
// портал приходит со СВОИМ .settings.php. Поэтому секции НЕ перезаписываются
// целиком — выполняется ТОЧЕЧНЫЙ MERGE: читаем массив, меняем ТОЛЬКО
// инфраструктурные ключи (host/port/login/password/engine), а все прочие ключи
// секции и остальные секции (crypto, http, exception_handling, кастомные и т.п.)
// СОХРАНЯЕМ как есть. Бэкап .bcm-bak-repoint снимается один раз перед записью.
// (Отличие от install.sh::configure_*_redis, где секции пишутся целиком — там
// свежая установка без пользовательского кастома.)
//
// Запускается на НОДЕ-ИСТОЧНИКЕ lsyncd (active_node); правки разъезжаются lsyncd.
// signature_key НЕ меняем (канонический — по нему выравнивается security.key
// push-серверов, см. push_repoint.php) — только отдаём его наружу.
//
//   BX_DOCROOT       корень портала (по умолчанию /home/bitrix/www)
//   DB:      BX_DB_HOST (напр. 127.0.0.1:6033), BX_DB_LOGIN, BX_DB_PASS, BX_DB_NAME
//   session: BX_SESSION_HOST, BX_SESSION_PORT
//   cache:   BX_CACHE_HOST, BX_CACHE_PORT
//   push:    BX_PUSH_PUBPATH (напр. http://127.0.0.1:8895/bitrix/pub/)
// Пустая/неуказанная секция ПРОПУСКАЕТСЯ (можно перенастроить только нужное).
//
// Вывод: CHANGED=<csv>  SIG=<signature_key>  RESULT=<OK|NO_SETTINGS|BAD_SETTINGS|NO_CONNECTION|WRITE_FAIL>
// =============================================================================
function out($s) { fwrite(STDOUT, $s . "\n"); }

$docroot = getenv('BX_DOCROOT') ?: '/home/bitrix/www';
$file    = $docroot . '/bitrix/.settings.php';

if (!is_file($file)) { out('RESULT=NO_SETTINGS'); exit(2); }
$cfg = include $file;
if (!is_array($cfg)) { out('RESULT=BAD_SETTINGS'); exit(3); }

$changed = array();

// ── БД → ProxySQL: меняем ТОЛЬКО host/login/password/database; options,
//    className, classNameCrypto и прочее в default — сохраняем. ────────────────
$dbh = getenv('BX_DB_HOST');
if ($dbh !== false && $dbh !== '') {
    if (!isset($cfg['connections']['value']['default']) || !is_array($cfg['connections']['value']['default'])) {
        out('RESULT=NO_CONNECTION'); exit(4);
    }
    $cfg['connections']['value']['default']['host'] = $dbh;
    $l = getenv('BX_DB_LOGIN'); if ($l !== false && $l !== '') $cfg['connections']['value']['default']['login']    = $l;
    $p = getenv('BX_DB_PASS');  if ($p !== false)               $cfg['connections']['value']['default']['password'] = $p;
    $n = getenv('BX_DB_NAME');  if ($n !== false && $n !== '')   $cfg['connections']['value']['default']['database'] = $n;
    $changed[] = 'db';
}

// ── Сессии → redis: задаём ТОЛЬКО handlers.general.{type,host,port}; прочие
//    ключи session.value (mode, иные handlers, кастом) — сохраняем. ────────────
$sh = getenv('BX_SESSION_HOST'); $sp = getenv('BX_SESSION_PORT');
if ($sh !== false && $sh !== '' && $sp !== false && $sp !== '') {
    if (!isset($cfg['session']) || !is_array($cfg['session'])) $cfg['session'] = array();
    if (!isset($cfg['session']['value']) || !is_array($cfg['session']['value'])) $cfg['session']['value'] = array();
    if (!array_key_exists('readonly', $cfg['session'])) $cfg['session']['readonly'] = false;
    // mode оставляем как у портала; если его нет — ставим 'default' (нужно redis-хендлеру)
    if (!isset($cfg['session']['value']['mode']) || $cfg['session']['value']['mode'] === '') {
        $cfg['session']['value']['mode'] = 'default';
    }
    if (!isset($cfg['session']['value']['handlers']) || !is_array($cfg['session']['value']['handlers'])) {
        $cfg['session']['value']['handlers'] = array();
    }
    if (!isset($cfg['session']['value']['handlers']['general']) || !is_array($cfg['session']['value']['handlers']['general'])) {
        $cfg['session']['value']['handlers']['general'] = array();
    }
    $cfg['session']['value']['handlers']['general']['type'] = 'redis';
    $cfg['session']['value']['handlers']['general']['host'] = $sh;
    $cfg['session']['value']['handlers']['general']['port'] = (int)$sp;
    $changed[] = 'session';
}

// ── Кэш → redis-движок: задаём ТОЛЬКО type (engine) и redis.{host,port,scale_mode};
//    sid и прочие ключи cache.value — сохраняем (sid не трогаем, чтобы не сбить
//    общий неймспейс кэша; если его нет — ставим фиксированный). ───────────────
$ch = getenv('BX_CACHE_HOST'); $cp = getenv('BX_CACHE_PORT');
if ($ch !== false && $ch !== '' && $cp !== false && $cp !== '') {
    if (!isset($cfg['cache']) || !is_array($cfg['cache'])) $cfg['cache'] = array();
    if (!isset($cfg['cache']['value']) || !is_array($cfg['cache']['value'])) $cfg['cache']['value'] = array();
    if (!array_key_exists('readonly', $cfg['cache'])) $cfg['cache']['readonly'] = false;
    $cfg['cache']['value']['type'] = array(
        'class_name' => '\\Bitrix\\Main\\Data\\CacheEngineRedis',
        'extension'  => 'redis',
    );
    if (!isset($cfg['cache']['value']['redis']) || !is_array($cfg['cache']['value']['redis'])) {
        $cfg['cache']['value']['redis'] = array();
    }
    $cfg['cache']['value']['redis']['host']       = $ch;
    $cfg['cache']['value']['redis']['port']       = (int)$cp;
    $cfg['cache']['value']['redis']['scale_mode'] = 'single';
    if (!isset($cfg['cache']['value']['sid']) || $cfg['cache']['value']['sid'] === '') {
        $cfg['cache']['value']['sid'] = $docroot . '#bcmcache01';
    }
    $changed[] = 'cache';
}

// ── Push: ТОЛЬКО pull.value.path_to_publish (остальное в pull, в т.ч.
//    signature_key, не трогаем). Меняем лишь если секция pull уже есть. ─────────
$pub = getenv('BX_PUSH_PUBPATH');
if ($pub !== false && $pub !== '' && isset($cfg['pull']['value']['path_to_publish'])) {
    $cfg['pull']['value']['path_to_publish'] = $pub;
    $changed[] = 'pull';
}

// signature_key наружу (по нему BCM выровняет security.key push-серверов)
$sig = isset($cfg['pull']['value']['signature_key']) ? $cfg['pull']['value']['signature_key'] : '';

if (!empty($changed)) {
    $bak = $file . '.bcm-bak-repoint';
    if (!is_file($bak)) { @copy($file, $bak); }
    if (file_put_contents($file, "<?php\nreturn " . var_export($cfg, true) . ";\n", LOCK_EX) === false) {
        out('RESULT=WRITE_FAIL'); exit(5);
    }
}

out('CHANGED=' . implode(',', $changed));
out('SIG=' . $sig);
out('RESULT=OK');
