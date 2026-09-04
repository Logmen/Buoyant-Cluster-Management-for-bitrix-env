<?php
/**
 * Маршрутизирующий $DB для старого API 1С-Битрикс.
 *
 * CDatabase::Query() исполняет SQL напрямую вызовом mysqli_query() на ресурсе
 * основного соединения (classes/mysql/database.php, QueryInternal), минуя
 * Connection::query() ядра D7 — поэтому Bcm\DbRouter\Connection эти запросы не
 * видит. Этот подкласс переопределяет QueryInternal: чистые SELECT уходят на
 * reader-линк маршрутизатора по тем же правилам, остальное исполняется как
 * прежде и учитывается в состоянии хита (изменённые таблицы, транзакции, SET).
 *
 * Подменяет $GLOBALS['DB'] из /local/php_interface/init.php (блок bcm:dbrouter):
 * ядро создаёт $DB в start.php, init.php подключается позже, а $USER и компоненты
 * создаются уже после него. Объект-предшественник не уничтожается — код, успевший
 * его запомнить, продолжает работать через writer.
 */

namespace Bcm\DbRouter;

use Bitrix\Main\Application;

class LegacyDatabase extends \CDatabase
{
	/** Последний запрос ушёл на reader: ошибки читать у маршрутизатора, а не у db_Conn. */
	private bool $lastOnReader = false;

	/**
	 * Подменяет $GLOBALS['DB'] маршрутизирующим экземпляром. Идемпотентно; ничего не
	 * делает, если маршрутизатор не включён в .settings.php (штатный класс подключения).
	 */
	public static function install(): void
	{
		$old = $GLOBALS['DB'] ?? null;
		if ($old instanceof self || !($old instanceof \CDatabase))
		{
			return;
		}
		if (!(Application::getConnection() instanceof Connection))
		{
			return;
		}

		$new = new self();
		// Публичные флаги, выставленные start.php/dbconn.php (debug, DebugToFile, ShowSqlStat…).
		foreach (get_object_vars($old) as $name => $value)
		{
			$new->$name = $value;
		}
		$GLOBALS['DB'] = $new;
	}

	/**
	 * @inheritDoc
	 */
	protected function QueryInternal($strSql)
	{
		$connection = Application::getConnection();
		if ($connection instanceof Connection)
		{
			$result = $connection->executeLegacy((string)$strSql);
			if ($result !== null)
			{
				$this->lastOnReader = true;
				return $result;
			}
		}

		$this->lastOnReader = false;
		$result = mysqli_query($this->db_Conn, $strSql);
		if ($result !== false && $connection instanceof Connection)
		{
			$connection->noteLegacyStatement((string)$strSql);
		}

		return $result;
	}

	/**
	 * @inheritDoc
	 */
	protected function GetError()
	{
		if ($this->lastOnReader)
		{
			$connection = Application::getConnection();
			if ($connection instanceof Connection)
			{
				return '(' . $connection->getLegacyErrorCode() . ') ' . $connection->getLegacyErrorMessage();
			}
		}

		return parent::GetError();
	}

	/**
	 * @inheritDoc
	 */
	protected function GetErrorCode()
	{
		if ($this->lastOnReader)
		{
			$connection = Application::getConnection();
			if ($connection instanceof Connection)
			{
				return $connection->getLegacyErrorCode();
			}
		}

		return parent::GetErrorCode();
	}
}
