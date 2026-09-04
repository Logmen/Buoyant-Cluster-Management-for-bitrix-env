<?php
/**
 * BCM DB Router — разделение чтений между узлами PXC для 1С-Битрикс.
 *
 * Класс подключения к БД, который BCM подставляет в bitrix/.settings.php вместо
 * штатного (connections → default → className). Наследует MysqliConnection и
 * перехватывает выполнение каждого запроса: чистые SELECT уходят по второму
 * соединению на reader-пользователя ProxySQL (hostgroup читателей), всё остальное —
 * по штатному соединению на writer. Ядро при этом не правится, модуль
 * «Веб-кластер» (доступен не во всех редакциях) не нужен.
 *
 * Гарантии корректности:
 *  • на reader идут ТОЛЬКО SELECT без блокировок (FOR UPDATE, LOCK IN SHARE MODE,
 *    GET_LOCK и родственные), без пользовательских и системных переменных (@),
 *    без LAST_INSERT_ID/FOUND_ROWS/ROW_COUNT/CONNECTION_ID и прочих функций,
 *    привязанных к соединению;
 *  • внутри транзакции — только writer (уровень транзакций ядра и сырые
 *    START TRANSACTION/BEGIN отслеживаются оба);
 *  • SELECT по таблице, изменённой в этом же хите, — только writer («прочитай то,
 *    что сам записал»; страховка на случай wsrep_sync_wait=0 на PXC);
 *  • DDL, временные таблицы, LOCK TABLES, autocommit=0 и всё, что меняет состояние
 *    соединения, переводят остаток хита на writer;
 *  • сессионные SET (NAMES, collation_connection, sql_mode, time_zone…) повторяются
 *    на reader-линке, чтобы обе стороны видели одинаковую сессию;
 *  • явное требование ядра «только master» (ConnectionPool::useMasterOnly — так
 *    обёрнуты lock()/unlock() и служебные запросы) соблюдается;
 *  • при недоступности читателей — прозрачный откат на writer с паузой повторных
 *    попыток (APCu или файл), а файл-рубильник KILL_SWITCH выключает маршрутизацию
 *    без правки конфигов и рестартов.
 *
 * Причинная согласованность между узлами обеспечивается на стороне PXC
 * (wsrep_sync_wait=1): SELECT на реплике ждёт применения всех транзакций,
 * закоммиченных до его начала, поэтому запись через writer видна следующим
 * чтением через реплику даже из другого хита.
 *
 * Старый API ($DB->Query) исполняет SQL мимо этого класса — напрямую на ресурсе
 * mysqli; его накрывает LegacyDatabase (подмена $GLOBALS['DB'] из init.php), которая
 * зовёт executeLegacy()/noteLegacyStatement() и делит с этим классом состояние хита.
 *
 * Конфигурация — блок reader внутри подключения default в .settings.php:
 *   'reader' => ['host' => '127.0.0.1:6033', 'login' => 'bitrix_ro',
 *                'password' => …(по умолчанию как у основного), 'database' => …,
 *                'enabled' => true, 'connect_timeout' => 2, 'cooldown' => 30]
 */

namespace Bcm\DbRouter;

use Bitrix\Main\Application;
use Bitrix\Main\DB\MysqliConnection;
use Bitrix\Main\Diag\SqlTrackerQuery;

class Connection extends MysqliConnection
{
	/** Файл-рубильник: существует → все запросы идут на writer, конфиги не трогаются. */
	public const KILL_SWITCH = '/etc/bitrix-cluster/dbrouter.off';

	/** Пауза после отказа читателей хранится в APCu (httpd) либо в файле (CLI без APCu). */
	private const DOWN_KEY = 'bcm.dbrouter.reader_down_until';
	private const DOWN_FILE_PREFIX = 'bcm-dbrouter.reader-down.';

	/** Как часто перечитывать рубильник в долгоживущих процессах (агенты, workerd), секунд. */
	private const ENABLED_TTL = 5;

	/** Сколько сессионных SET хранить для повтора на reader-линке; сверх этого — остаток хита на writer. */
	private const SESSION_STATEMENTS_MAX = 64;

	/** SELECT с этими конструкциями привязан к соединению или блокировке — только writer. */
	private const WRITER_ONLY_SELECT = '/\b(?:FOR\s+UPDATE|FOR\s+SHARE|LOCK\s+IN\s+SHARE\s+MODE'
		. '|GET_LOCK|RELEASE_LOCK|RELEASE_ALL_LOCKS|IS_FREE_LOCK|IS_USED_LOCK'
		. '|LAST_INSERT_ID|FOUND_ROWS|ROW_COUNT|CONNECTION_ID|SQL_CALC_FOUND_ROWS'
		. '|INTO\s+(?:OUTFILE|DUMPFILE)|MASTER_POS_WAIT|WAIT_FOR_EXECUTED_GTID_SET'
		. '|WAIT_UNTIL_SQL_THREAD_AFTER_GTIDS)\b/i';

	/** Ошибки, после которых читателя считаем недоступным и уходим на writer (клиентские ≥2000, ProxySQL ≥9000). */
	private const TRANSIENT_ERRORS = [1040, 1042, 1043, 1047, 1053, 1077, 1129, 1180, 1205, 1213, 1290, 1317, 1836, 1927, 3024];

	private ?\mysqli $reader = null;
	private int $readerPid = 0;
	private bool $readerDead = false;
	private bool $masterOnlyRequest = false;
	private int $rawTransactionDepth = 0;
	/** @var array<string, true> */
	private array $modifiedTables = [];
	/** @var string[] */
	private array $sessionStatements = [];
	private ?array $readerConfig = null;
	private ?bool $enabled = null;
	private int $enabledCheckedAt = 0;
	/** Ошибка последнего reader-запроса старого API: [errno, message]. */
	private ?array $legacyError = null;

	/** @var array<string, int> */
	private static array $stats = ['reader' => 0, 'writer' => 0, 'fallback' => 0];

	/**
	 * Линки, унаследованные дочерним процессом при fork. Закрывать их нельзя: COM_QUIT
	 * ушёл бы в сокет, общий с родителем. Ссылки держим, чтобы деструктор не сработал.
	 * @var \mysqli[]
	 */
	private static array $orphans = [];

	/**
	 * @inheritDoc
	 */
	protected function queryInternal($sql, ?array $binds = null, ?SqlTrackerQuery $trackerQuery = null)
	{
		if (!$this->isEnabled())
		{
			return parent::queryInternal($sql, $binds, $trackerQuery);
		}

		$head = self::statementHead($sql);

		if ($head === 'SELECT' || $head === '(')
		{
			$stripped = self::stripLiterals($sql);
			if ($this->isReadable($stripped))
			{
				$result = $this->queryReader($sql, $trackerQuery);
				if ($result !== null)
				{
					self::$stats['reader']++;
					return $result;
				}
				self::$stats['fallback']++;
			}
		}

		$result = parent::queryInternal($sql, $binds, $trackerQuery);
		self::$stats['writer']++;
		$this->noteWriterStatement($sql, $head);

		return $result;
	}

	/**
	 * @inheritDoc
	 */
	protected function disconnectInternal()
	{
		parent::disconnectInternal();
		$this->closeReader();
	}

	// ──── Старый API (CDatabase::Query через LegacyDatabase) ────────────────

	/**
	 * Выполняет запрос старого API на reader, если он туда маршрутизируется.
	 * null — исполнять на writer (вызывающий делает это сам через mysqli_query и затем
	 * зовёт noteLegacyStatement); false — reader вернул ошибку SQL (см. getLegacyError*);
	 * иначе результат mysqli.
	 *
	 * @return \mysqli_result|bool|null
	 */
	public function executeLegacy(string $sql)
	{
		$this->legacyError = null;
		if (!$this->isEnabled())
		{
			return null;
		}
		$head = self::statementHead($sql);
		if ($head !== 'SELECT' && $head !== '(')
		{
			return null;
		}
		if (!$this->isReadable(self::stripLiterals($sql)))
		{
			return null;
		}
		if (!$this->connectReader())
		{
			self::$stats['fallback']++;
			return null;
		}

		[$ok, $errno, $error, $result] = self::execOn($this->reader, $sql);
		if ($ok)
		{
			self::$stats['reader']++;
			return $result;
		}
		if (self::isTransientError($errno))
		{
			$this->markReaderDown("query error {$errno}: {$error}");
			self::$stats['fallback']++;
			return null;
		}
		$this->legacyError = [$errno, $error];

		return false;
	}

	/** Учёт запроса старого API, успешно выполненного на writer (таблицы, транзакции, SET). */
	public function noteLegacyStatement(string $sql): void
	{
		self::$stats['writer']++;
		if ($this->isEnabled())
		{
			$this->noteWriterStatement($sql, self::statementHead($sql));
		}
	}

	public function getLegacyErrorCode(): int
	{
		return (int)($this->legacyError[0] ?? 0);
	}

	public function getLegacyErrorMessage(): string
	{
		return (string)($this->legacyError[1] ?? '');
	}

	/**
	 * Счётчики маршрутизации за время жизни процесса (для самопроверки BCM).
	 * @return array<string, int>
	 */
	public static function getStats(): array
	{
		return self::$stats;
	}

	/**
	 * Состояние маршрутизатора (для самопроверки BCM). Пароль не раскрывается.
	 */
	public function getRouterState(): array
	{
		$enabled = $this->isEnabled();
		$cfg = $this->readerConfig ?? [];

		return [
			'enabled' => $enabled,
			'kill_switch' => is_file(self::KILL_SWITCH),
			'reader_host' => $cfg['host'] ?? null,
			'reader_port' => $cfg['port'] ?? null,
			'reader_login' => $cfg['login'] ?? null,
			'reader_connected' => $this->reader !== null,
			'reader_dead' => $this->readerDead,
			'master_only_request' => $this->masterOnlyRequest,
			'in_transaction' => ($this->transactionLevel > 0 || $this->rawTransactionDepth > 0),
			'modified_tables' => array_keys($this->modifiedTables),
			'session_statements' => count($this->sessionStatements),
			'stats' => self::$stats,
		];
	}

	// ──── Решение о маршруте ────────────────────────────────────────────────

	private function isEnabled(): bool
	{
		$now = time();
		if ($this->enabled !== null && ($now - $this->enabledCheckedAt) < self::ENABLED_TTL)
		{
			return $this->enabled;
		}
		if ($this->readerConfig === null)
		{
			$this->readerConfig = $this->resolveReaderConfig();
		}
		$this->enabled = ($this->readerConfig !== [] && !is_file(self::KILL_SWITCH));
		$this->enabledCheckedAt = $now;

		return $this->enabled;
	}

	/** Пустой массив — маршрутизация не сконфигурирована. */
	private function resolveReaderConfig(): array
	{
		$r = $this->configuration['reader'] ?? null;
		if (!is_array($r) || empty($r['host']) || ($r['enabled'] ?? true) === false)
		{
			return [];
		}

		$host = (string)$r['host'];
		$port = 0;
		if (($pos = strrpos($host, ':')) !== false)
		{
			$port = (int)substr($host, $pos + 1);
			$host = substr($host, 0, $pos);
		}

		return [
			'host' => $host,
			'port' => $port,
			'login' => (string)($r['login'] ?? $this->login),
			'password' => (string)($r['password'] ?? $this->password),
			'database' => (string)($r['database'] ?? $this->database),
			'connect_timeout' => max(1, (int)($r['connect_timeout'] ?? 2)),
			'cooldown' => max(5, (int)($r['cooldown'] ?? 30)),
		];
	}

	private function isReadable(string $stripped): bool
	{
		if ($this->readerDead || $this->masterOnlyRequest)
		{
			return false;
		}
		if ($this->transactionLevel > 0 || $this->rawTransactionDepth > 0)
		{
			return false;
		}
		if (!preg_match('/^\s*\(*\s*SELECT\b/i', $stripped))
		{
			return false;
		}
		if (Application::getInstance()->getConnectionPool()->isMasterOnly())
		{
			return false;
		}
		if (str_contains($stripped, '@'))
		{
			return false;
		}
		if (preg_match(self::WRITER_ONLY_SELECT, $stripped))
		{
			return false;
		}
		if ($this->modifiedTables !== [] && $this->touchesModifiedTable($stripped))
		{
			return false;
		}

		return true;
	}

	private function touchesModifiedTable(string $stripped): bool
	{
		foreach ($this->getSqlHelper()->getQueryTables($stripped) as $table)
		{
			if (isset($this->modifiedTables[self::normalizeTable((string)$table)]))
			{
				return true;
			}
		}

		return false;
	}

	// ──── Учёт состояния, накопленного на writer-соединении ───────────────────

	private function noteWriterStatement(string $sql, string $head): void
	{
		switch ($head)
		{
			case 'SELECT':
			case '(':
			case 'SHOW':
			case 'DESC':
			case 'DESCRIBE':
			case 'EXPLAIN':
			case 'SAVEPOINT':
			case 'RELEASE':
				return;

			case 'INSERT':
			case 'UPDATE':
			case 'DELETE':
			case 'REPLACE':
				$this->noteModifiedTables($sql);
				return;

			case 'BEGIN':
				$this->rawTransactionDepth = 1;
				return;

			case 'START':
				if (preg_match('/^\s*START\s+TRANSACTION\b/i', $sql))
				{
					$this->rawTransactionDepth = 1;
				}
				return;

			case 'COMMIT':
				$this->rawTransactionDepth = 0;
				return;

			case 'ROLLBACK':
				if (!preg_match('/^\s*ROLLBACK\s+TO\b/i', $sql))
				{
					$this->rawTransactionDepth = 0;
				}
				return;

			case 'SET':
				$this->noteSetStatement($sql);
				return;

			case 'USE':
				$this->noteSessionStatement($sql);
				return;

			default:
				// DDL, LOCK TABLES, CALL, LOAD DATA, XA, временные таблицы и всё
				// неизвестное: состояние соединения могло измениться — остаток хита на writer.
				$this->masterOnlyRequest = true;
				return;
		}
	}

	private function noteModifiedTables(string $sql): void
	{
		$tables = $this->getSqlHelper()->getQueryTables($sql, 0);
		if ($tables === [])
		{
			$this->masterOnlyRequest = true;
			return;
		}
		foreach ($tables as $table)
		{
			$this->modifiedTables[self::normalizeTable((string)$table)] = true;
		}
	}

	private function noteSetStatement(string $sql): void
	{
		if (preg_match('/^\s*SET\s+(?:GLOBAL|PERSIST|PERSIST_ONLY)\b/i', $sql))
		{
			return; // не сессионное состояние
		}
		if (preg_match('/^\s*SET\s+@[^@]/i', $sql))
		{
			return; // пользовательская переменная: SELECT с '@' и так идёт на writer
		}
		if (preg_match('/^\s*SET\s+(?:(?:SESSION|LOCAL)\s+)?(?:@@(?:SESSION|LOCAL)\.)?(?:AUTOCOMMIT|TRANSACTION)\b/i', $sql))
		{
			$this->masterOnlyRequest = true;
			return;
		}
		$this->noteSessionStatement($sql);
	}

	private function noteSessionStatement(string $sql): void
	{
		if (count($this->sessionStatements) >= self::SESSION_STATEMENTS_MAX)
		{
			$this->masterOnlyRequest = true;
			return;
		}
		$this->sessionStatements[] = $sql;

		if ($this->reader !== null && $this->readerPid === getmypid())
		{
			[$ok, $errno, $error] = self::execOn($this->reader, $sql);
			if (!$ok)
			{
				$this->dropReader("session replay failed ({$errno}): {$error}");
			}
		}
	}

	// ──── Reader-соединение ─────────────────────────────────────────────────

	/** @return \mysqli_result|bool|null null — читатель недоступен, выполнять на writer. */
	private function queryReader(string $sql, ?SqlTrackerQuery $trackerQuery)
	{
		if (!$this->connectReader())
		{
			return null;
		}

		$trackerQuery?->startQuery($sql, null);
		[$ok, $errno, $error, $result] = self::execOn($this->reader, $sql);
		$trackerQuery?->finishQuery();

		if ($ok)
		{
			return $result;
		}
		if (self::isTransientError($errno))
		{
			$this->markReaderDown("query error {$errno}: {$error}");
			return null;
		}

		throw $this->createQueryException($errno, $error, $sql);
	}

	private function connectReader(): bool
	{
		if ($this->reader !== null)
		{
			if ($this->readerPid === getmypid())
			{
				return true;
			}
			self::$orphans[] = $this->reader;
			$this->reader = null;
		}

		$cfg = $this->readerConfig;
		if ($this->isReaderDown($cfg['cooldown']))
		{
			$this->readerDead = true;
			return false;
		}

		$link = mysqli_init();
		if (!$link)
		{
			$this->markReaderDown('mysqli_init failed');
			return false;
		}
		$link->options(MYSQLI_OPT_CONNECT_TIMEOUT, $cfg['connect_timeout']);
		if (!empty($this->initCommand))
		{
			$link->options(MYSQLI_INIT_COMMAND, $this->initCommand);
		}

		$error = '';
		try
		{
			$ok = @$link->real_connect($cfg['host'], $cfg['login'], $cfg['password'], $cfg['database'], $cfg['port'] > 0 ? $cfg['port'] : null);
			if (!$ok)
			{
				$error = "({$link->connect_errno}) {$link->connect_error}";
			}
		}
		catch (\mysqli_sql_exception $e)
		{
			$ok = false;
			$error = '(' . $e->getCode() . ') ' . $e->getMessage();
		}
		if (!$ok)
		{
			$this->markReaderDown('connect ' . $error);
			return false;
		}

		if (isset($this->configuration['charset']))
		{
			$link->set_charset($this->configuration['charset']);
		}
		foreach ($this->sessionStatements as $statement)
		{
			[$ok, $errno, $err] = self::execOn($link, $statement);
			if (!$ok)
			{
				@$link->close();
				$this->dropReader("session replay failed ({$errno}): {$err}");
				return false;
			}
		}

		$this->reader = $link;
		$this->readerPid = getmypid();

		return true;
	}

	/** @return array{0: bool, 1: int, 2: string, 3: mixed} */
	private static function execOn(\mysqli $link, string $sql): array
	{
		try
		{
			$result = @$link->query($sql);
			if ($result === false)
			{
				return [false, (int)$link->errno, (string)$link->error, false];
			}
			return [true, 0, '', $result];
		}
		catch (\mysqli_sql_exception $e)
		{
			return [false, (int)$e->getCode(), $e->getMessage(), false];
		}
	}

	private static function isTransientError(int $errno): bool
	{
		return $errno >= 2000 || in_array($errno, self::TRANSIENT_ERRORS, true);
	}

	/** Читатель недоступен: до конца хита — writer, следующие процессы не пробуют cooldown секунд. */
	private function markReaderDown(string $why): void
	{
		$this->readerDead = true;
		$this->closeReader();

		$cfg = $this->readerConfig;
		$cooldown = (int)$cfg['cooldown'];
		if (self::apcuAvailable())
		{
			@apcu_store(self::DOWN_KEY, time() + $cooldown, $cooldown);
		}
		else
		{
			@touch(self::downFile());
		}
		error_log(sprintf('BCM dbrouter: reader %s:%d unavailable (%s); reads go to writer for %ds',
			$cfg['host'], $cfg['port'], $why, $cooldown));
	}

	/** Читатель сломан только для этого хита (расхождение сессии) — без общей паузы. */
	private function dropReader(string $why): void
	{
		$this->readerDead = true;
		$this->closeReader();
		error_log('BCM dbrouter: reader dropped for this request (' . $why . ')');
	}

	private function isReaderDown(int $cooldown): bool
	{
		if (self::apcuAvailable())
		{
			$until = apcu_fetch(self::DOWN_KEY);
			return $until !== false && (int)$until > time();
		}
		$file = self::downFile();
		clearstatcache(true, $file);

		return is_file($file) && (filemtime($file) + $cooldown) > time();
	}

	private function closeReader(): void
	{
		if ($this->reader === null)
		{
			return;
		}
		if ($this->readerPid === getmypid())
		{
			try
			{
				@$this->reader->close();
			}
			catch (\Throwable)
			{
				// соединение уже разорвано
			}
		}
		else
		{
			self::$orphans[] = $this->reader;
		}
		$this->reader = null;
	}

	private static function apcuAvailable(): bool
	{
		return function_exists('apcu_enabled') && apcu_enabled();
	}

	private static function downFile(): string
	{
		return sys_get_temp_dir() . '/' . self::DOWN_FILE_PREFIX . getmyuid();
	}

	// ──── Разбор SQL ────────────────────────────────────────────────────────

	/** Первое ключевое слово (в верхнем регистре) после пробелов и комментариев, либо '('. */
	private static function statementHead(string $sql): string
	{
		if (preg_match('~^\s*(?:/\*.*?\*/\s*)*([A-Za-z]+|\()~s', $sql, $m))
		{
			return strtoupper($m[1]);
		}

		return '';
	}

	/** Убирает комментарии и строковые литералы, чтобы '@' и ключевые слова из них не влияли на маршрут. */
	private static function stripLiterals(string $sql): string
	{
		$s = preg_replace('~/\*.*?\*/~s', ' ', $sql);
		$s = preg_replace('~\'(?:[^\'\\\\]|\\\\.)*\'|"(?:[^"\\\\]|\\\\.)*"~s', "''", $s ?? $sql);

		return $s ?? $sql;
	}

	private static function normalizeTable(string $table): string
	{
		$t = strtolower(trim($table, "` \t\r\n"));
		if (($p = strrpos($t, '.')) !== false)
		{
			$t = substr($t, $p + 1);
		}

		return trim($t, '`');
	}
}
