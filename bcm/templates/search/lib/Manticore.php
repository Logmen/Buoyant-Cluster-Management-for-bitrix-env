<?php
// Bcm\Search\Manticore — движок полнотекстового поиска Битрикса поверх кластера
// Manticore из двух web-узлов (BCM, bin/lib/bcm_search.sh).
//
// Наследник штатного CSearchSphinx: схема индекса, запросы поиска, права, сниппеты —
// его. Здесь только то, что кластеру Manticore нужно сверх одиночного Sphinx.
//
// 1. Запись в реплицируемую таблицу Manticore принимает только как «кластер:таблица»
//    («table is a part of cluster, use 'c:t'»), а CSearchSphinx пишет по имени индекса,
//    и имя с двоеточием не пропускает его же проверка. query() дописывает префикс к
//    REPLACE/INSERT/UPDATE/DELETE/TRUNCATE — чтение, DESCRIBE и CALL SNIPPETS идут по
//    обычному имени в локальную копию таблицы (сниппеты на распределённой таблице
//    Manticore не строит — поэтому кластер из обычных RT-таблиц, а не шардов).
// 2. Узлов два: подключение пробует сначала локальный, затем остальные (короткий
//    таймаут — упавший узел не должен держать хит). Запрос, отвергнутый узлом без
//    кворума или оборванный на полпути, повторяется на следующем узле. Запись не
//    прошла нигде — ConnectionException: обработчик очереди search_sync_content
//    превращает её в повтор через минуту, а не выбрасывает сообщение.
// 3. syncContent() — отложенная индексация через очередь (как у штатного OpenSearch;
//    у CSearchSphinx её нет): сохранение документа не зависит от доступности поиска, а
//    писатель в индекс один — обработчик очередей на master web (bcm-messenger).
// 4. Поиск при недоступном кластере отдаёт пустой результат, а не исключение: строка
//    поиска в шапке портала не должна ронять страницу.
namespace Bcm\Search;

class Manticore extends \CSearchSphinx
{
    public const VERSION = '1';

    /** Ошибки, после которых запрос имеет смысл повторить на другом узле. */
    private const RETRY_ERRNO = [2002, 2003, 2006, 2013, 2055];
    // «unknown column» — обновление модуля поиска добавило поле, а схема таблицы ещё
    // старая: запись ждёт в очереди, пока контролёр BCM не синхронизирует схему
    // (bcm_search.sh --schema-sync), вместо того чтобы сообщение было выброшено.
    private const RETRY_TEXT = '/not ready|not primary|non-primary|recovery is required|is not running|unknown column/i';

    protected string $bcmCluster = '';
    /** @var string[] */
    protected array $bcmHosts = [];
    protected int $bcmHostIdx = 0;
    protected int $bcmConnectTimeout = 2;
    protected int $bcmReadTimeout = 30;
    protected bool $bcmReadFailLogged = false;

    public function __construct($config = [])
    {
        $hosts = [];
        foreach (preg_split('/[\s,;]+/', (string)($config['hosts'] ?? '')) as $h)
        {
            if ($h !== '' && !in_array($h, $hosts, true))
            {
                $hosts[] = $h;
            }
        }
        if (!$hosts && !empty($config['connection']))
        {
            $hosts[] = (string)$config['connection'];
        }
        $config['connection'] = $hosts[0] ?? '';

        parent::__construct($config);

        $this->bcmHosts = $hosts;
        $this->bcmCluster = preg_match('/^\w+$/', (string)($config['cluster'] ?? '')) ? (string)$config['cluster'] : '';
        $this->bcmConnectTimeout = max(1, (int)($config['connect_timeout'] ?? 2));
        $this->bcmReadTimeout = max(5, (int)($config['read_timeout'] ?? 30));
    }

    /**
     * Префикс кластера для запросов записи в индекс; остальное — как есть.
     * Идемпотентно: уже с префиксом («c:t») не совпадает и не меняется.
     */
    public static function withClusterPrefix(string $sql, string $table, string $cluster): string
    {
        if ($cluster === '' || !preg_match('/^\w+$/', $cluster) || !preg_match('/^\w+$/', $table))
        {
            return $sql;
        }
        $re = '/^(\s*(?:replace\s+into|insert\s+into|update|delete\s+from|truncate\s+(?:rtindex|table))\s+)`?'
            . preg_quote($table, '/') . '`?(?=[\s(;]|$)/i';

        return (string)preg_replace($re, '${1}' . $cluster . ':' . $table, $sql, 1);
    }

    public function getHosts(): array
    {
        return $this->bcmHosts;
    }

    public function getCurrentHost(): string
    {
        return (string)$this->connectionIndex;
    }

    public function getCluster(): string
    {
        return $this->bcmCluster;
    }

    public function query($query)
    {
        $query = (string)$query;
        $sql = static::withClusterPrefix($query, (string)$this->indexName, $this->bcmCluster);
        $write = ($sql !== $query);

        $result = $this->bcmRun($sql);
        if ($result === false && $this->bcmRetryable($write))
        {
            // Узел без кворума или оборванное соединение: тот же запрос — на другом узле.
            $error = $this->getError();
            if ($this->bcmNextHost())
            {
                $result = $this->bcmRun($sql);
                if ($result !== false || !$this->bcmRetryable($write))
                {
                    return $result;
                }
                $error = $this->getError();
            }
            // Нигде не вышло. ConnectionException, а не false: из обработчика очереди
            // сообщение уйдёт на повтор, а не в отказ; поиск отдаст пустой результат.
            throw new \Bitrix\Main\DB\ConnectionException('Manticore: query failed on every node', $error);
        }

        return $result;
    }

    public function syncContent($id)
    {
        if (!class_exists(\Bitrix\Search\SyncIndexItemMessage::class))
        {
            return false;
        }
        (new \Bitrix\Search\SyncIndexItemMessage((int)$id))->send('search_sync_content');

        return true;
    }

    public function search($arParams, $aSort, $aParamsEx, $bTagsCloud)
    {
        try
        {
            return parent::search($arParams, $aSort, $aParamsEx, $bTagsCloud);
        }
        catch (\Bitrix\Main\DB\ConnectionException $e)
        {
            $this->bcmReadFailed($e);

            return [];
        }
    }

    public function searchTitle($phrase = '', $arPhrase = [], $nTopCount = 5, $arParams = [], $bNotFilter = false, $order = '')
    {
        try
        {
            return parent::searchTitle($phrase, $arPhrase, $nTopCount, $arParams, $bNotFilter, $order);
        }
        catch (\Bitrix\Main\DB\ConnectionException $e)
        {
            $this->bcmReadFailed($e);

            return [];
        }
    }

    // Подключение: узлы по кругу, начиная с текущего; короткие таймауты.
    protected function internalConnect($connectionIndex, &$error)
    {
        $error = '';
        $n = count($this->bcmHosts);
        if ($n === 0 || !function_exists('mysqli_init'))
        {
            $error = $n === 0 ? 'Manticore: no hosts configured' : 'No MySql connection function has been found.';

            return false;
        }
        $errors = [];
        for ($i = 0; $i < $n; $i++)
        {
            $idx = ($this->bcmHostIdx + $i) % $n;
            [$host, $port] = array_pad(explode(':', $this->bcmHosts[$idx], 2), 2, 0);
            $db = mysqli_init();
            $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, $this->bcmConnectTimeout);
            if (defined('MYSQLI_OPT_READ_TIMEOUT'))
            {
                $db->options(MYSQLI_OPT_READ_TIMEOUT, $this->bcmReadTimeout);
            }
            try
            {
                $ok = @$db->real_connect($host, '', '', '', (int)$port ?: null);
            }
            catch (\mysqli_sql_exception $e)
            {
                $ok = false;
            }
            if ($ok)
            {
                $this->bcmHostIdx = $idx;
                $this->connectionIndex = $this->bcmHosts[$idx];

                return $db;
            }
            $errors[] = $this->bcmHosts[$idx] . ': ' . mysqli_connect_error();
        }
        $error = implode('; ', $errors);

        return false;
    }

    private function bcmRun(string $sql)
    {
        try
        {
            return parent::query($sql);
        }
        catch (\mysqli_sql_exception $e)
        {
            return false;
        }
    }

    private function bcmRetryable(bool $write): bool
    {
        if (!is_object($this->db))
        {
            return false;
        }
        if (in_array((int)$this->db->errno, self::RETRY_ERRNO, true))
        {
            return true;
        }

        return $write && preg_match(self::RETRY_TEXT, (string)$this->db->error) === 1;
    }

    // Переключиться на следующий узел; false — других узлов нет или ни один не ответил.
    private function bcmNextHost(): bool
    {
        if (count($this->bcmHosts) < 2)
        {
            return false;
        }
        if (is_object($this->db))
        {
            @$this->db->close();
        }
        $this->db = false;
        $this->connected = false;
        $this->bcmHostIdx = ($this->bcmHostIdx + 1) % count($this->bcmHosts);
        try
        {
            return $this->connect();
        }
        catch (\Bitrix\Main\DB\ConnectionException $e)
        {
            return false;
        }
    }

    private function bcmReadFailed(\Throwable $e): void
    {
        if ($this->bcmReadFailLogged)
        {
            return;
        }
        $this->bcmReadFailLogged = true;
        if (class_exists(\Bitrix\Main\Application::class))
        {
            try
            {
                \Bitrix\Main\Application::getInstance()->getExceptionHandler()->writeToLog($e);
            }
            catch (\Throwable $ignored)
            {
            }
        }
    }
}
