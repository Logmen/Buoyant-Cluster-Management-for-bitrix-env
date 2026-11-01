<?php
// cli.php — консольный инструмент поиска портала на кластере Manticore (BCM).
// Запускать от владельца портала (кэш и журналы Битрикса — его файлы):
//   runuser -u bitrix -- php <docroot>/local/modules/bcm.search/cli.php <команда>
// Ставит и вызывает bin/lib/bcm_search.sh; руками — для диагностики.
//
// Команды:
//   status                     опции, движок, узлы (состояние кластера, строки), очередь
//   fields                     поля индекса этой версии модуля поиска (имя:тип)
//   ddl                        колонки для CREATE TABLE в Manticore (из fields)
//   options HOSTS CLUSTER INDEX [PORT]
//                              записать опции bcm.search и sphinx_* (движок не трогает)
//   engine sphinx|bitrix       переключить full_text_engine; sphinx — с отложенной индексацией
//   repair [--since=UNIXTIME] [--no-delete]
//                              досинхронизация: каждый документ b_search_content заново в
//                              индекс, затем удаление из индекса того, чего в базе нет
//   consume [СЕКУНД]           разбор очередей поиска (search_sync_*) подряд — из master-cron
//   probe                      пробная запись через класс, чтение на каждом узле, удаление
//
// ⚠️ Консоль bitrix.php (search:reindex) в bitrix-env не работает: ей нужен Symfony
// Console, которого там нет. Поэтому досинхронизация — здесь, тем же путём, что
// обработчик очереди search_sync_content (update() штатного класса).
if (php_sapi_name() !== 'cli')
{
    exit('nope');
}

// Корень портала — три уровня вверх (<docroot>/local/modules/bcm.search); BCM_DOCROOT —
// для запуска копии вне дерева портала (проверка до установки модуля).
$_SERVER['DOCUMENT_ROOT'] = getenv('BCM_DOCROOT') ?: realpath(__DIR__ . '/../../..');
$DOCUMENT_ROOT = $_SERVER['DOCUMENT_ROOT'];
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('BX_NO_ACCELERATOR_RESET', true);
define('NO_AGENT_CHECK', true);
define('STOP_STATISTICS', true);
define('BX_CRONTAB_SUPPORT', true);
define('BX_CRONTAB', true);

require $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/include/prolog_before.php';

use Bitrix\Main\Config\Option;

@set_time_limit(0);

if (!\Bitrix\Main\Loader::includeModule('search'))
{
    fwrite(STDERR, "модуль search не установлен\n");
    exit(2);
}
require_once __DIR__ . '/lib/Manticore.php';
require_once __DIR__ . '/lib/Injector.php';

function bcmOut(string $line): void
{
    fwrite(STDOUT, $line . "\n");
}

function bcmFail(string $line, int $code = 1): void
{
    fwrite(STDERR, $line . "\n");
    exit($code);
}

function bcmOpt(string $module, string $name, string $default = ''): string
{
    return (string)Option::get($module, $name, $default);
}

function bcmPort(): int
{
    return (int)bcmOpt('bcm.search', 'port', '9306');
}

/** Движок из опций — независимо от того, включён ли он как full_text_engine. */
function bcmEngine(): \Bcm\Search\Manticore
{
    return new \Bcm\Search\Manticore([
        'hosts' => '127.0.0.1:' . bcmPort() . ',' . bcmOpt('bcm.search', 'hosts'),
        'index_name' => bcmOpt('search', 'sphinx_index_name', 'bitrix'),
        'cluster' => bcmOpt('bcm.search', 'cluster'),
        'read_timeout' => 120,
    ]);
}

/** Поля индекса из штатного CSearchSphinx: имя => [типы]. */
function bcmFields(): array
{
    $rp = new \ReflectionProperty(\CSearchSphinx::class, 'fields');
    if (PHP_VERSION_ID < 80100)
    {
        $rp->setAccessible(true);
    }

    return (array)$rp->getValue();
}

/** Тип колонки Manticore для поля модуля поиска. */
function bcmColumnType(array $types): string
{
    if (in_array('field', $types, true))
    {
        return 'text indexed';
    }
    if (in_array('timestamp', $types, true))
    {
        return 'timestamp';
    }
    if (in_array('mva', $types, true) || in_array('uint_set', $types, true))
    {
        return 'multi';
    }
    if (in_array('bigint', $types, true))
    {
        return 'bigint';
    }
    if (in_array('string', $types, true))
    {
        return 'string';
    }

    return 'uint';
}

/** Отдельное соединение с одним узлом (для статуса и проверки репликации). */
function bcmNode(string $hostPort): ?\mysqli
{
    [$host, $port] = array_pad(explode(':', $hostPort, 2), 2, 9306);
    $db = mysqli_init();
    $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 2);
    try
    {
        if (@$db->real_connect($host, '', '', '', (int)$port))
        {
            return $db;
        }
    }
    catch (\mysqli_sql_exception $e)
    {
    }

    return null;
}

function bcmNodeHosts(): array
{
    $hosts = [];
    foreach (preg_split('/[\s,;]+/', bcmOpt('bcm.search', 'hosts')) as $h)
    {
        if ($h !== '')
        {
            $hosts[] = $h;
        }
    }

    return $hosts;
}

function bcmClusterState(\mysqli $db, string $cluster): array
{
    $state = ['status' => 'none', 'size' => 0, 'node_state' => ''];
    if ($cluster === '')
    {
        return $state;
    }
    $res = @$db->query("SHOW STATUS LIKE 'cluster_" . $cluster . "_%'");
    while ($res && ($row = $res->fetch_row()))
    {
        $key = substr((string)$row[0], strlen('cluster_' . $cluster . '_'));
        if (isset($state[$key]))
        {
            $state[$key] = $row[1];
        }
    }

    return $state;
}

$cmd = $argv[1] ?? 'status';
$args = array_slice($argv, 2);
$conn = \Bitrix\Main\Application::getConnection();

switch ($cmd)
{
    case 'fields':
        foreach (bcmFields() as $name => $types)
        {
            bcmOut($name . ':' . implode('|', (array)$types));
        }
        break;

    case 'ddl':
        $cols = [];
        foreach (bcmFields() as $name => $types)
        {
            $cols[] = '`' . $name . '` ' . bcmColumnType((array)$types);
        }
        bcmOut(implode(', ', $cols));
        break;

    case 'options':
        [$hosts, $cluster, $index, $port] = array_pad($args, 4, '');
        if ($hosts === '' || !preg_match('/^\w+$/', $cluster) || !preg_match('/^\w+$/', $index))
        {
            bcmFail('использование: options HOSTS CLUSTER INDEX [PORT]');
        }
        $port = (int)$port ?: 9306;
        Option::set('bcm.search', 'hosts', $hosts);
        Option::set('bcm.search', 'cluster', $cluster);
        Option::set('bcm.search', 'port', (string)$port);
        Option::set('bcm.search', 'enabled', 'Y');
        Option::set('search', 'sphinx_connection', '127.0.0.1:' . $port);
        Option::set('search', 'sphinx_index_name', $index);
        bcmOut("OK options hosts={$hosts} cluster={$cluster} index={$index} port={$port}");
        break;

    case 'engine':
        $to = $args[0] ?? '';
        if ($to === 'sphinx')
        {
            if (bcmOpt('bcm.search', 'enabled') !== 'Y' || bcmOpt('bcm.search', 'cluster') === '')
            {
                bcmFail('сначала options: опции bcm.search не заданы');
            }
            // Сначала отложенная индексация, потом движок: в промежутке документ не должен
            // уйти прямой записью мимо очереди.
            Option::set('search', 'full_text_delay_index', 'Y');
            Option::set('search', 'full_text_engine', 'sphinx');
        }
        elseif ($to === 'bitrix')
        {
            Option::set('search', 'full_text_engine', 'bitrix');
        }
        else
        {
            bcmFail('использование: engine sphinx|bitrix');
        }
        bcmOut('OK engine=' . bcmOpt('search', 'full_text_engine') . ' delay=' . bcmOpt('search', 'full_text_delay_index'));
        break;

    case 'status':
        $cluster = bcmOpt('bcm.search', 'cluster');
        $index = bcmOpt('search', 'sphinx_index_name', 'bitrix');
        bcmOut('ENGINE=' . bcmOpt('search', 'full_text_engine'));
        bcmOut('DELAY=' . bcmOpt('search', 'full_text_delay_index', 'N'));
        bcmOut('ENABLED=' . bcmOpt('bcm.search', 'enabled', 'N'));
        bcmOut('CLUSTER=' . $cluster);
        bcmOut('INDEX=' . $index);
        bcmOut('HOSTS=' . bcmOpt('bcm.search', 'hosts'));
        bcmOut('ACTIVE=' . (\CSearchFullText::getInstance() instanceof \Bcm\Search\Manticore ? 'Y' : 'N'));
        bcmOut('CONTENT_ROWS=' . (int)$conn->queryScalar('SELECT COUNT(*) FROM b_search_content'));
        $queue = 0;
        try
        {
            $queue = (int)$conn->queryScalar("SELECT COUNT(*) FROM b_main_messenger_message WHERE QUEUE_ID = 'search_sync_content'");
        }
        catch (\Throwable $e)
        {
            $queue = -1;
        }
        bcmOut('QUEUE=' . $queue);
        foreach (bcmNodeHosts() as $h)
        {
            $db = bcmNode($h);
            if (!$db)
            {
                bcmOut("NODE {$h} down");
                continue;
            }
            $st = bcmClusterState($db, $cluster);
            $rows = '?';
            $res = @$db->query('SELECT COUNT(*) FROM `' . $index . '`');
            if ($res && ($r = $res->fetch_row()))
            {
                $rows = $r[0];
            }
            bcmOut("NODE {$h} {$st['status']} size={$st['size']} state={$st['node_state']} rows={$rows}");
            $db->close();
        }
        break;

    case 'repair':
        $since = null;
        $deleteStale = true;
        foreach ($args as $a)
        {
            if (preg_match('/^--since=(\d+)$/', $a, $m))
            {
                $since = (int)$m[1];
                $deleteStale = false;
            }
            elseif ($a === '--no-delete')
            {
                $deleteStale = false;
            }
        }
        $lock = fopen(sys_get_temp_dir() . '/bcm-search-repair.lock', 'c');
        if (!$lock || !flock($lock, LOCK_EX | LOCK_NB))
        {
            bcmFail('досинхронизация уже идёт', 3);
        }
        $engine = bcmEngine();
        $helper = $conn->getSqlHelper();
        $filter = $since !== null
            ? ' AND DATE_CHANGE >= ' . $helper->getCharToDateFunction(date('Y-m-d H:i:s', $since))
            : '';
        $total = (int)$conn->queryScalar('SELECT COUNT(*) FROM b_search_content WHERE 1=1' . $filter);
        bcmOut("repair: документов к записи {$total}" . ($since !== null ? ' (изменённых с ' . date('Y-m-d H:i:s', $since) . ')' : ''));
        $last = 0;
        $done = 0;
        $failed = 0;
        $t0 = microtime(true);
        while (true)
        {
            $rows = $conn->query(
                'SELECT ID, MODULE_ID, ITEM_ID FROM b_search_content WHERE ID > ' . $last . $filter . ' ORDER BY ID LIMIT 500'
            )->fetchAll();
            if (!$rows)
            {
                break;
            }
            foreach ($rows as $row)
            {
                $last = (int)$row['ID'];
                try
                {
                    $engine->update($last, $row);
                    $done++;
                }
                catch (\Throwable $e)
                {
                    $failed++;
                    fwrite(STDERR, "repair: ID {$last}: " . $e->getMessage() . "\n");
                    if ($failed >= 50 && $failed > $done)
                    {
                        bcmFail("repair: прервано — {$failed} ошибок (последняя: " . $e->getMessage() . ')', 4);
                    }
                }
                if (($done + $failed) % 2000 === 0)
                {
                    $rate = ($done + $failed) / max(1, microtime(true) - $t0);
                    bcmOut(sprintf('repair: %d из %d, ошибок %d, %.0f док/с', $done + $failed, $total, $failed, $rate));
                }
            }
        }
        $removed = 0;
        if ($deleteStale)
        {
            // Документы, которых в базе уже нет (удалены, пока узел не принимал запись).
            $index = bcmOpt('search', 'sphinx_index_name', 'bitrix');
            $from = 0;
            while (true)
            {
                $res = $engine->query('SELECT id FROM `' . $index . '` WHERE id > ' . $from . ' ORDER BY id ASC LIMIT 1000 OPTION max_matches=1000');
                $ids = [];
                while ($res && ($r = $engine->fetch($res)))
                {
                    $ids[] = (int)$r['id'];
                }
                if (!$ids)
                {
                    break;
                }
                $from = end($ids);
                $have = [];
                foreach ($conn->query('SELECT ID FROM b_search_content WHERE ID IN (' . implode(',', $ids) . ')')->fetchAll() as $r)
                {
                    $have[(int)$r['ID']] = true;
                }
                foreach ($ids as $id)
                {
                    if (!isset($have[$id]))
                    {
                        $engine->deleteById($id);
                        $removed++;
                    }
                }
            }
        }
        bcmOut(sprintf(
            'RESULT=OK written=%d failed=%d removed=%d seconds=%d',
            $done,
            $failed,
            $removed,
            (int)(microtime(true) - $t0)
        ));
        exit($failed > 0 ? 5 : 0);

    case 'consume':
        // Потребитель очередей поиска. Модуль search задаёт им limit=1 (одно сообщение за
        // проход), а общий потребитель bcm-messenger делает проход раз в 5 с — это ~11
        // документов в минуту, меньше, чем меняется индекс живого портала. Здесь проходы
        // идут подряд, пока в очередях есть готовые сообщения; пустые опрашиваются раз в
        // 2 с. Лимит модуля поиска не меняется (его .settings.php перекрывает глобальный).
        // Запуск — раз в минуту из класса «только master» (bcm_search.sh --enable).
        // Готовое сообщение — как его выбирает брокер (DbStorage): статус new и AVAILABLE_AT
        // не позже «сейчас», где «сейчас» — PHP-время в формате ORM, а не NOW() базы (часовые
        // пояса PHP и MySQL могут не совпадать).
        $seconds = max(5, (int)($args[0] ?? 55));
        $queues = ['search_sync_content', 'search_sync_perm'];
        $worker = new \Bitrix\Main\Messenger\Internals\Worker(false);
        $helper = $conn->getSqlHelper();
        $readySql = "SELECT ID FROM b_main_messenger_message WHERE QUEUE_ID IN ('" . implode("','", $queues) . "')"
            . " AND STATUS = 'new' AND AVAILABLE_AT <= %s ORDER BY ID"; // LIMIT добавляет queryScalar
        $end = time() + $seconds;
        $passes = 0;
        $last = 0;
        while (time() < $end)
        {
            $head = (int)$conn->queryScalar(sprintf($readySql, $helper->convertToDbDateTime(new \Bitrix\Main\Type\DateTime())));
            if ($head === 0 || $head === $last)
            {
                // Пусто — или прошлый проход это сообщение не взял (метка «очередь пуста» в кэше
                // ещё жива, блокировку очереди держит общий потребитель): ждём и пробуем снова.
                $last = 0;
                sleep(2);
                continue;
            }
            $worker->process(['queues' => $queues]);
            $passes++;
            $last = $head;
            usleep(50000);
        }
        if ($passes > 0)
        {
            bcmOut("consume: проходов {$passes}");
        }
        break;

    case 'probe':
        $engine = bcmEngine();
        $index = bcmOpt('search', 'sphinx_index_name', 'bitrix');
        $id = 4000000000 + (int)(microtime(true) * 10) % 1000000;
        $mark = 'bcmprobe' . $id;
        $engine->query('REPLACE INTO `' . $index . '` (id, title, body) VALUES (' . $id . ", '" . $mark . "', '" . $mark . "')");
        bcmOut('PROBE_WRITE=' . $engine->getCurrentHost());
        usleep(300000);
        $okAll = true;
        foreach (bcmNodeHosts() as $h)
        {
            $db = bcmNode($h);
            $found = false;
            if ($db)
            {
                $res = @$db->query('SELECT id FROM `' . $index . '` WHERE id = ' . $id);
                $found = $res && $res->num_rows === 1;
                $db->close();
            }
            $okAll = $okAll && $found;
            bcmOut("PROBE_READ {$h} " . ($db ? ($found ? 'ok' : 'missing') : 'down'));
        }
        $engine->deleteById($id);
        bcmOut('RESULT=' . ($okAll ? 'OK' : 'FAIL'));
        exit($okAll ? 0 : 6);

    default:
        bcmFail('команды: status | fields | ddl | options | engine | repair | consume | probe');
}
