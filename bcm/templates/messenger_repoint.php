<?php
// =============================================================================
// messenger_repoint.php — режим фоновой шины Messenger ядра в bitrix/.settings.php
//
// Секция messenger: run_mode = web (очереди разбирают хиты, умолчание ядра) либо cli
// (очереди разбирает потребитель local/cron/bcm-messenger.php из master-cron BCM).
// Прочие ключи секции (queues и т.п.), если оператор их задал, сохраняются.
//
// Параметры из окружения:
//   BX_DOCROOT — корень портала (по умолчанию /home/bitrix/www)
//   BX_MODE    — status | cli | web
// Вывод: строки KEY=VALUE + RESULT=OK | NO_SETTINGS | BAD_PARAMS | WRITE_FAIL
// =============================================================================
function out($s) { fwrite(STDOUT, $s . "\n"); }

$docroot = getenv('BX_DOCROOT') ?: '/home/bitrix/www';
$mode    = getenv('BX_MODE') ?: 'status';
$file    = $docroot . '/bitrix/.settings.php';

if (!is_file($file)) { out('RESULT=NO_SETTINGS'); exit(2); }
$cfg = include $file;
if (!is_array($cfg)) { out('RESULT=NO_SETTINGS'); exit(2); }

$value = (isset($cfg['messenger']['value']) && is_array($cfg['messenger']['value'])) ? $cfg['messenger']['value'] : [];
$current = isset($value['run_mode']) ? (string)$value['run_mode'] : 'web';

if ($mode === 'status') {
    out('RUN_MODE=' . $current);
    out('RESULT=OK');
    exit(0);
}

// ⚠️ Брокер по умолчанию ядро подставляет ТОЛЬКО когда секции messenger нет совсем
// (BrokerManager::loadGlobalConfig): секция с одним run_mode роняет и постановку в
// очередь на хитах (создание задачи — «Default broker for messenger did not configured»),
// и потребитель. Поэтому вместе с run_mode всегда пишем брокер default в том же виде,
// что и умолчание ядра (тип db, таблица MessengerMessageTable).
if (empty($value['brokers']['default'])) {
    $value['brokers']['default'] = [
        'type' => 'db',
        'params' => ['table' => '\\Bitrix\\Main\\Messenger\\Internals\\Storage\\Db\\Model\\MessengerMessageTable'],
    ];
}
if ($mode === 'cli') {
    $value['run_mode'] = 'cli';
    $cfg['messenger'] = ['value' => $value, 'readonly' => true];
} elseif ($mode === 'web') {
    unset($value['run_mode']);
    $cfg['messenger'] = ['value' => $value, 'readonly' => true];
} else {
    out('RESULT=BAD_PARAMS'); exit(4);
}

$bak = $file . '.bcm-bak-messenger';
if (!is_file($bak) && @copy($file, $bak)) {
    @chmod($bak, @fileperms($file) & 0777);
    @chown($bak, @fileowner($file));
    @chgrp($bak, @filegroup($file));
}

if (file_put_contents($file, "<?php\nreturn " . var_export($cfg, true) . ";\n", LOCK_EX) === false) {
    out('RESULT=WRITE_FAIL'); exit(5);
}
out('RUN_MODE=' . ($mode === 'cli' ? 'cli' : 'web'));
out('RESULT=OK');
