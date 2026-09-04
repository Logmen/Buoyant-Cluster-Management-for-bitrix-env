<?php
// Модуль bcm.dbrouter — разделение чтений БД между узлами PXC (см. lib/Connection.php).
//
// Установка модуля в b_module не требуется: класс подключения подгружается
// автозагрузчиком из bitrix/.settings_extra.php (его пишет bcm_settings_guard.sh)
// на этапе создания подключения к БД, когда модули ещё недоступны. Регистрация
// пространства имён здесь нужна только коду, который подключит модуль явно.
\Bitrix\Main\Loader::registerNamespace('Bcm\\DbRouter', __DIR__ . '/lib');
