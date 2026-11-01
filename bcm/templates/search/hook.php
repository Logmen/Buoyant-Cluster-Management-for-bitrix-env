<?php
// bcm:search — подключается блоком bcm:search в действующем php_interface/init.php
// (ставит bcm_search.sh). Когда поиск портала переведён на кластер Manticore BCM
// (опция bcm.search/enabled = Y и full_text_engine = sphinx), подставляет движок
// Bcm\Search\Manticore вместо штатного CSearchSphinx (см. lib/Injector.php).
//
// Узлы: сначала локальный 127.0.0.1, затем все web-узлы кластера (опция bcm.search/hosts,
// её пишет bcm_search.sh). Ошибка здесь не должна ронять хит — тогда портал работает
// на штатном классе, а запись в индекс до починки не идёт (см. журнал исключений).
if (!class_exists('Bcm\Search\Injector', false))
{
    try
    {
        $bcmSearchOpt = static function (string $module, string $name, string $default = ''): string {
            return (string)\Bitrix\Main\Config\Option::get($module, $name, $default);
        };
        if ($bcmSearchOpt('bcm.search', 'enabled', 'N') === 'Y'
            && $bcmSearchOpt('search', 'full_text_engine') === 'sphinx'
            && \Bitrix\Main\Loader::includeModule('search'))
        {
            require_once __DIR__ . '/lib/Manticore.php';
            require_once __DIR__ . '/lib/Injector.php';
            $bcmSearchPort = (int)$bcmSearchOpt('bcm.search', 'port', '9306');
            \Bcm\Search\Injector::install([
                'hosts' => '127.0.0.1:' . $bcmSearchPort . ',' . $bcmSearchOpt('bcm.search', 'hosts'),
                'index_name' => $bcmSearchOpt('search', 'sphinx_index_name', 'bitrix'),
                'cluster' => $bcmSearchOpt('bcm.search', 'cluster'),
            ]);
        }
        unset($bcmSearchOpt, $bcmSearchPort);
    }
    catch (\Throwable $bcmSearchError)
    {
        try
        {
            \Bitrix\Main\Application::getInstance()->getExceptionHandler()->writeToLog($bcmSearchError);
        }
        catch (\Throwable $ignored)
        {
        }
        unset($bcmSearchError);
    }
}
