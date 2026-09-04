<?php
// bcm-messenger.php — потребитель фоновой шины Messenger ядра Bitrix (очереди
// main, calendar, bizproc и др.; к чатам отношения не имеет).
//
// Штатно (run_mode=web) очереди опрашивает КАЖДЫЙ хит: Worker::process() обходит
// все очереди и каждая берёт именованную блокировку GET_LOCK с нулевым таймаутом —
// на нагруженном портале это четыре пятых всех запросов к БД и спам варнингов
// PXC. При run_mode=cli в .settings.php хиты очереди не трогают, а разбирает их
// этот скрипт. Штатная консольная команда messenger:consume делает ровно то же
// (цикл Worker::process() до лимита времени), но консоль bitrix.php требует
// Symfony Console, которого в bitrix-env нет.
//
// Запускается ТОЛЬКО на master web-ноде: задание лежит в /etc/cron.d/bcm-portal-master,
// который BCM выносит из cron.d на BACKUP-нодах (cron_notify.sh); повторный запуск
// в ту же минуту отсекает flock в строке cron. Аргументы: лимит секунд (55) и пауза
// между проходами в секундах (5: проход по ~30 очередям стоит ~50 запросов к БД,
// пауза держит нагрузку потребителя на уровне единиц процентов от прежней).
// Ставит и обновляет bcm_messenger.sh (BCM меню 10 → 10).
if (php_sapi_name() !== 'cli') {
    exit('nope');
}

$_SERVER['DOCUMENT_ROOT'] = realpath(__DIR__ . '/../..');
$DOCUMENT_ROOT = $_SERVER['DOCUMENT_ROOT'];

define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('BX_NO_ACCELERATOR_RESET', true);
define('NO_AGENT_CHECK', true);
define('STOP_STATISTICS', true);
define('BX_CRONTAB_SUPPORT', true);
define('BX_CRONTAB', true);

require $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/include/prolog_before.php';

@set_time_limit(0);
@ignore_user_abort(true);

$config = \Bitrix\Main\Config\Configuration::getValue('messenger');
if (($config['run_mode'] ?? 'web') !== 'cli') {
    // Очереди разбирают хиты — потребителю здесь делать нечего.
    exit(0);
}

$timeLimit = max(1, (int)($argv[1] ?? 55));
$sleepUs   = (int)(max(0.1, (float)($argv[2] ?? 1)) * 1000000);

$worker = new \Bitrix\Main\Messenger\Internals\Worker();
$end = time() + $timeLimit;
$passes = 0;
while (time() < $end) {
    $worker->process();
    $passes++;
    usleep($sleepUs);
}

if (getenv('BCM_MESSENGER_VERBOSE')) {
    fwrite(STDOUT, "passes={$passes}\n");
}

CMain::FinalActions();
