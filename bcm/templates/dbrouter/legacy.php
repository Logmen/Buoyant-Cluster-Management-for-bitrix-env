<?php
// Подмена $GLOBALS['DB'] маршрутизирующим экземпляром для старого API (см.
// lib/LegacyDatabase.php). Подключается из /local/php_interface/init.php блоком
// bcm:dbrouter (пишет bcm_dbrouter.sh --settings enable). Без автозагрузчика из
// .settings_extra.php или без класса CDatabase ничего не делает — портал работает.
if (class_exists('CDatabase', false) && class_exists(\Bcm\DbRouter\LegacyDatabase::class))
{
	\Bcm\DbRouter\LegacyDatabase::install();
}
