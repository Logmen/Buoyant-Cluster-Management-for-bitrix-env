<?php
// Регистрация модуля в списке модулей портала (Настройки → Модули). Необязательна для
// работы маршрутизатора: подключение создаётся по className из .settings.php, а класс
// подгружается автозагрузчиком из .settings_extra.php до загрузки модулей.

use Bitrix\Main\ModuleManager;

class bcm_dbrouter extends CModule
{
	public $MODULE_ID = 'bcm.dbrouter';
	public $MODULE_VERSION;
	public $MODULE_VERSION_DATE;
	public $MODULE_NAME;
	public $MODULE_DESCRIPTION;
	public $PARTNER_NAME;
	public $PARTNER_URI;

	public function __construct()
	{
		$arModuleVersion = [];
		include __DIR__ . '/version.php';
		$this->MODULE_VERSION = $arModuleVersion['VERSION'];
		$this->MODULE_VERSION_DATE = $arModuleVersion['VERSION_DATE'];
		$this->MODULE_NAME = 'BCM: разделение чтений БД';
		$this->MODULE_DESCRIPTION = 'Класс подключения, направляющий чистые SELECT на реплики PXC через ProxySQL. Управляется BCM (меню 4).';
		$this->PARTNER_NAME = 'BCM';
		$this->PARTNER_URI = 'https://github.com/Logmen/Buoyant-Cluster-Management-for-bitrix-env';
	}

	public function DoInstall()
	{
		ModuleManager::registerModule($this->MODULE_ID);
		return true;
	}

	public function DoUninstall()
	{
		ModuleManager::unRegisterModule($this->MODULE_ID);
		return true;
	}
}
