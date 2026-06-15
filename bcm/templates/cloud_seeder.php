<?php
// =============================================================================
// cloud_seeder.php — регистрация бакета MinIO как «Облачного хранилища» Bitrix.
// Запускается BCM на web-ноде с реальным порталом. Параметры — из окружения:
//   BX_DOCROOT, BX_S3_APIHOST, BX_S3_BUCKET, BX_S3_REGION, BX_S3_ACCESS,
//   BX_S3_SECRET, BX_S3_USE_HTTPS (Y/N)
//
// Выводит строки RESULT=... для разбора в BCM:
//   NO_KERNEL | NO_CLOUDS_MODULE | ALREADY_EXISTS | OK | ADDED_BUT_TEST_FAILED | ADD_FAILED
//
// ⚠️ Контракт модуля проверен вживую (bitrix-env 9, клауд clouds):
//   SERVICE_ID = 'generic_s3' (S3 compatible storage; НЕ 'amazon_s3' — тот хардкодит
//   s3.amazonaws.com). SETTINGS = HOST (api_host БЕЗ схемы; модуль строит
//   bucket.HOST — только virtual-host!), ACCESS_KEY, SECRET_KEY, USE_HTTPS (Y/N).
//   LOCATION = region (подпись AWS V4 → region обязателен и должен совпасть с MinIO).
// =============================================================================
function out($s) { fwrite(STDOUT, $s . "\n"); }

$docroot  = getenv('BX_DOCROOT') ?: '/home/bitrix/www';
$apihost  = getenv('BX_S3_APIHOST');   // virtual-host имя БЕЗ схемы, напр. s3.bitrix.lab:9000
$bucket   = getenv('BX_S3_BUCKET');
$region   = getenv('BX_S3_REGION') ?: 'us-east-1';
$access   = getenv('BX_S3_ACCESS');
$secret   = getenv('BX_S3_SECRET');
$useHttps = (getenv('BX_S3_USE_HTTPS') === 'Y') ? 'Y' : 'N';
// На случай, если передали полный endpoint со схемой — берём только host[:port].
$apihost  = preg_replace('#^https?://#', '', (string)$apihost);

$prolog = $docroot . '/bitrix/modules/main/include/prolog_before.php';
if (!is_file($prolog)) { out('RESULT=NO_KERNEL'); exit(2); }

$_SERVER['DOCUMENT_ROOT'] = $docroot;
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('BX_NO_ACCELERATOR_RESET', true);
define('CHK_EVENT', true);
require $prolog;

// Модуль «Облачные хранилища»
if (!CModule::IncludeModule('clouds')) {
    $inst = $docroot . '/bitrix/modules/clouds/install/index.php';
    if (is_file($inst)) {
        require_once $inst;
        if (class_exists('clouds')) {
            $o = new clouds();
            if (method_exists($o, 'DoInstall')) { @$o->DoInstall(); }
        }
    }
    if (!CModule::IncludeModule('clouds')) { out('RESULT=NO_CLOUDS_MODULE'); exit(3); }
}

// Уже зарегистрирован бакет с таким именем?
if (class_exists('CCloudStorageBucket')) {
    $res = CCloudStorageBucket::GetList(array(), array());
    while (is_object($res) && ($b = $res->Fetch())) {
        if (isset($b['BUCKET']) && $b['BUCKET'] === $bucket) { out('RESULT=ALREADY_EXISTS'); exit(0); }
    }
}

$arFields = array(
    'ACTIVE'     => 'Y',
    'READ_ONLY'  => 'N',
    // 'generic_s3' = «S3 compatible storage» (virtual-host + V4). НЕ 'amazon_s3'.
    'SERVICE_ID' => 'generic_s3',
    'LOCATION'   => $region,
    'BUCKET'     => $bucket,
    'CNAME'      => '',
    'PREFIX'     => '',
    // ⚠️ FILE_RULES = catch-all (пустой MODULE/EXTENSION/SIZE): иначе бакет ловит
    // НЕ ВСЕ файлы. Если оставить MODULE="upload" (дефолт мастера админки), файлы
    // модуля Disk (MODULE_ID="disk") под правило НЕ попадают → оседают в ЛОКАЛЬНЫЙ
    // /upload ноды (не синкается между web!) → генератор документов/просмотрщик
    // (transformer-workerd ходит на VIP-ноду по http://default/upload/...) ловит
    // 404 на .docx/.pdf. Пустой MODULE = match all (проверено вживую). FindBucketForFile
    // вернёт этот бакет для любого модуля → всё уедет в общий S3.
    'FILE_RULES' => array(array('MODULE' => '', 'EXTENSION' => '', 'SIZE' => '')),
    // Ключи строго по контракту CCloudStorageService_S3: HOST (без схемы; модуль
    // строит bucket.HOST), ACCESS_KEY, SECRET_KEY, USE_HTTPS.
    'SETTINGS'   => array(
        'HOST'       => $apihost,
        'ACCESS_KEY' => $access,
        'SECRET_KEY' => $secret,
        'USE_HTTPS'  => $useHttps,
    ),
);

$id = false;
try {
    $id = CCloudStorageBucket::Add($arFields);
} catch (\Throwable $e) {
    out('ADD_EXCEPTION=' . $e->getMessage());
}
if (!$id) { out('RESULT=ADD_FAILED'); exit(4); }
out('BUCKET_ID=' . $id);

// Самопроверка: пробуем записать и удалить тестовый объект через бакет
$ok = false;
try {
    $obj = new CCloudStorageBucket($id);
    $obj->Init();
    $name = '/bcm_test/probe_' . time() . '.txt';
    if ($obj->SaveFile($name, array('content' => 'bcm-probe', 'type' => 'text/plain'))) {
        $ok = true;
        @$obj->DeleteFile($name);
    }
} catch (\Throwable $e) {
    out('TEST_EXCEPTION=' . $e->getMessage());
}

out('RESULT=' . ($ok ? 'OK' : 'ADDED_BUT_TEST_FAILED'));
