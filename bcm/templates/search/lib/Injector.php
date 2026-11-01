<?php
// Bcm\Search\Injector — подставляет Bcm\Search\Manticore вместо штатного движка.
//
// CSearchFullText::getInstance() выбирает класс по опции full_text_engine жёстко
// (sphinx → new CSearchSphinx) и кладёт объект в защищённое статическое свойство
// $instance. Наследник CSearchFullText может положить туда свой объект раньше первого
// вызова getInstance() — ядро модуля поиска при этом не правится. Вызывается из
// hook.php (блок bcm:search в действующем init.php), то есть на старте каждого хита
// и в консольных процессах (обработчик очередей, cli.php), до работы модуля поиска.
namespace Bcm\Search;

final class Injector extends \CSearchFullText
{
    public static function install(array $config): void
    {
        if (!(self::$instance instanceof Manticore))
        {
            self::$instance = new Manticore($config);
        }
    }

    public static function active(): bool
    {
        return self::$instance instanceof Manticore;
    }
}
