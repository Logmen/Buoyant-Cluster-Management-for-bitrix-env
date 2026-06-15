<p align="center">
  <img src="docs/bcm-logo.png" alt="BCM — Buoyant Cluster Management" width="480">
</p>

# Buoyant Cluster Management for bitrix-env (BCM)

**BCM** (Buoyant Cluster Management) — TUI-инструмент для развёртывания и управления отказоустойчивым 6-слойным кластером 1С-Битрикс на базе `bitrix-env`.

---

## Скачивание и установка релиза

Готовые релизы — на странице [**Releases**](https://github.com/Logmen/Buoyant-Cluster-Management-for-bitrix-env/releases).
Каждый релиз — архив `bcm-X.Y.Z.tar.gz` с GPG-подписью (`.asc`) и контрольной суммой (`.sha256`).
Установка запускается с **управляющей машины** (любой Linux с SSH-доступом к будущим узлам кластера).

### 1. Скачать релиз

```bash
# через GitHub CLI (берёт последний релиз)
gh release download --repo Logmen/Buoyant-Cluster-Management-for-bitrix-env --pattern 'bcm-*'

# …или curl (подставьте нужную версию вместо v1.0.1)
ver=v1.0.1; base=https://github.com/Logmen/Buoyant-Cluster-Management-for-bitrix-env/releases/download/$ver
curl -LO $base/bcm-${ver#v}.tar.gz
curl -LO $base/bcm-${ver#v}.tar.gz.asc
curl -LO $base/bcm-${ver#v}.tar.gz.sha256
```

### 2. Проверить целостность и подпись (рекомендуется)

```bash
sha256sum -c bcm-*.tar.gz.sha256

# импортировать доверенный публичный ключ релизов и проверить подпись
curl -LO https://raw.githubusercontent.com/Logmen/Buoyant-Cluster-Management-for-bitrix-env/main/bcm/keys/bcm-release-pub.asc
gpg --import bcm-release-pub.asc
gpg --verify bcm-*.tar.gz.asc bcm-*.tar.gz      # ожидаем "Good signature"
```

### 3. Распаковать и установить

```bash
tar -xzf bcm-*.tar.gz
cd bcm-*/                       # каталог bcm-X.Y.Z
sudo bash install.sh           # интерактивно (или --answers-file, см. «Установка кластера»)
```

> Обновление уже развёрнутого кластера до нового релиза — командой `bcm --update`
> на любой web-ноде (скачивает релиз, проверяет GPG-подпись, раскатывает на все ноды).
> Подробнее — раздел [«Обновление BCM»](#обновление-bcm-по-релизам-github).

---

## Архитектура кластера

```
Интернет
   │
   ▼
[Слой 1-2] Балансировщики — Keepalived VRRP + HAProxy
   │  roundrobin HTTP :80, S3 :9000
   ▼
[Слой 3]   Веб-ноды — Nginx · Apache · PHP · bx-push-server (NodeJS RTC) ← МОЗГ
   │         + Redis (сессии · push · кэш — HA, master-replica + плавающие VIP)
   ▼
[Слой 4]   ProxySQL :6033 (embedded в web-ноды) — HG10 write · HG20 read
   │
   ▼
[Слой 5]   Percona XtraDB Cluster — Galera WSREP (multi-master)
   │
   ▼
[Слой 6]   MinIO S3 Object Storage — Site Replication Active-Active
```

> **Push & Pull** (NodeJS RTC), **хранение сессий в Redis** и **общий кэш в Redis**
> подключаются автоматически при установке (если заданы соответствующие VIP) — см.
> разделы ниже. SSL/HTTPS, резервное копирование и генератор документов (Transformer)
> управляются из меню BCM после развёртывания портала.

---

## Состав кластера

| Слой | Тип ноды | Минимум | Компоненты |
|---|---|---|---|
| **LB** | `lb` | 2 | HAProxy + Keepalived (VRRP VIP) |
| **WEB** | `web` | 2 | bitrix-env (Nginx+Apache+PHP) + ProxySQL + lsyncd + bx-push-server (NodeJS RTC) + Redis (сессии / push / кэш — каждый HA: master-replica + VIP) + Keepalived (HA Cron + VIP'ы Redis) + (опц.) Transformer |
| **PXC** | `pxc` | 3 (нечётное) | Percona XtraDB Cluster (Galera WSREP) |
| **S3** | `s3` | 2 | MinIO (Site Replication Active-Active) |

---

## Системные требования и подготовка

1. **ОС на всех узлах**: Проверенно на Oracle Linux 9, непротестировано но ожидается что также работает на RHEL 9 / AlmaLinux 9 / CentOS 9 Stream.
2. **Права**: Доступ под пользователем `root` на всех узлах.
3. **Управляющая нода**: Должна иметь сетевую доступность ко всем серверам по порту 22 (SSH).
4. **Утилита sshpass**: Нужна на управляющей ноде для первичной раскатки SSH-ключей и проверки пароля `root`. Установщик пытается поставить её автоматически (`dnf`/`yum`); если это не удалось — установка **прерывается с ошибкой** (раньше шаг молча пропускался).

---

## Установка кластера

Развёртывание запускается с **управляющей машины** (это может быть любой компьютер с Linux, имеющий доступ к серверам):

### Вариант 1. Интерактивный режим

Запустите скрипт без параметров:
```bash
sudo bash install.sh
```
Скрипт интерактивно запросит:
* Виртуальный IP-адрес (VIP) для балансировки.
* Список IP и имён серверов для каждого слоя (`lb`, `web`, `pxc`, `s3`).
* Имя PXC-писателя по умолчанию.
* Порты и пароли для ProxySQL и баз данных.
* Access/secret key для MinIO (secret можно сгенерировать автоматически).
* VIP для Redis-хранилища сессий (можно оставить пустым, чтобы пропустить).
* Единый пароль `root` удаленных серверов для первоначальной настройки авторизации по SSH-ключам.

> После сбора данных установщик дополнительно: бутстрапит PXC **идемпотентно**
> (не трогает уже работающий кластер) и дожидается состояния `Synced` каждой
> ноды; **подключает Push & Pull** на web-нодах; **разворачивает Redis-сессии**
> (если задан VIP).

### Вариант 2. Тихая установка (Answers File)

Готовый шаблон лежит в репозитории — **`install_answers.conf.example`**. Скопируйте его и заполните своими значениями:
```bash
cp install_answers.conf.example install_answers.conf
# отредактируйте пароли/IP
sudo bash install.sh --answers-file install_answers.conf
```

> ⚠️ **Безопасность:** файл ответов содержит пароли в открытом виде. Реальный
> `install_answers.conf`, приватные ключи (`*_id_rsa`, `temp_id_rsa`) и `*.pem`
> добавлены в `.gitignore` — **не коммитьте их**. В репозитории должен лежать
> только `install_answers.conf.example` с плейсхолдерами.

Полный комментированный шаблон — в [`install_answers.conf.example`](install_answers.conf.example)
(он же источник истины). Состав (сокращённо):
```bash
VIP="10.0.0.230"
LB_NODES="lb01,lb02";        LB_IPS_LIST="lb01:10.0.0.231,lb02:10.0.0.232"
WEB_NODES="web01,web02";     WEB_IPS_LIST="web01:10.0.0.210,web02:10.0.0.211"
PXC_NODES="db01,db02,db03";  PXC_IPS_LIST="db01:10.0.0.220,db02:10.0.0.221,db03:10.0.0.222"
PXC_WRITER="db01"
S3_NODES="s3-01,s3-02";      S3_IPS_LIST="s3-01:10.0.0.240,s3-02:10.0.0.241"
S3_PORT="9000"
S3_ACCESS_KEY="minioadmin"              # root user MinIO
S3_SECRET_KEY="CHANGE_ME_STRONG_SECRET" # пусто → сгенерируется случайный
S3_VHOST_DOMAIN="s3.bitrix.lab"         # vhost-домен для модуля «Облачные хранилища»
PROXYSQL_PORT="6033";        PROXYSQL_ADMIN_PORT="6032"
PROXYSQL_ADMIN_PASS="CHANGE_ME_ADMIN_PASS"
PROXYSQL_MONITOR_PASS="CHANGE_ME_MONITOR_PASS"
BITRIX_DB_USER="bitrix";     BITRIX_DB_PASS="CHANGE_ME_DB_PASS"
WEB_VRID="56"                            # VRID web-нод (HA Cron)

# Redis-сессии (HA). Пусто SESSION_VIP → шаг пропускается.
SESSION_VIP="10.0.0.235";    SESSION_REDIS_PORT="6380"; SESSION_VRID="57"; SESSION_REDIS_MAXMEM="256mb"
# Общий Redis для каналов Push&Pull (active-active). Пусто PUSH_REDIS_VIP → пропустить.
PUSH_REDIS_VIP="10.0.0.236"; PUSH_REDIS_PORT="6381";    PUSH_VRID="58";    PUSH_REDIS_MAXMEM="512mb"
# Общий Redis под кэш Bitrix (managed_cache+cache). Пусто CACHE_REDIS_VIP → пропустить.
CACHE_REDIS_VIP="10.0.0.237";CACHE_REDIS_PORT="6382";   CACHE_VRID="59";   CACHE_REDIS_MAXMEM="1024mb"

# Домен портала → /etc/hosts 127.0.0.1 на web (self-проверки Bitrix). Пусто → пропустить.
PORTAL_DOMAIN="portal.example.com"
# SSL/HTTPS (TLS на HAProxy). LE_EMAIL — учётка Let's Encrypt; FORCE_HTTPS=1 — редирект 80→443.
LE_EMAIL="";                 FORCE_HTTPS="0"
# Резервное копирование (HA-aware, MinIO). Ключ шифрования генерируется install'ом.
BACKUP_BUCKET="bitrix-backups"; BACKUP_RETENTION_DAYS="14"

ROOT_PASSWORD="CHANGE_ME_ROOT_PASS"      # общий root для первичной раскатки SSH-ключа
```

### Вариант 3. Тестовый запуск (Dry Run)

Позволяет проверить корректность конфигурационного файла без выполнения реальных изменений на серверах:
```bash
sudo bash install.sh --dry-run
```

---

## Push & Pull (NodeJS RTC)

`bitrix-env` 9.x ставит пакет `bx-push-server`, но **не подключает** его к пулу
автоматически. Установщик делает это сам на каждой web-ноде официальной
командой bitrix-env:

```bash
/opt/webdir/bin/bx-sites -a push_configure_nodejs -H <pool_hostname>
```

Шаг идемпотентный (если нода уже в группе `push` — пропускается) и дожидается
завершения ansible-задачи. В результате:

* ставятся пакеты, поднимается **Redis** (для push) и **NodeJS**;
* запускается `push-server.service`: **sub-порты 8010–8015**, **pub-порты 9010–9011**, WebSocket-порт **1337**;
* нода добавляется в группу `bitrix-push`;
* в `bitrix/.settings.php` прописывается секция `pull` (`/bitrix/sub/`).

Управление и статус — в BCM: меню **9. Push/RTC сервис**.

### Push HA / active-active

«Из коробки» каждый push-сервер хранит каналы в локальном Redis и публикует на
захардкоженный хост → при отказе ноды или round-robin сообщение не доходит до
подписчика на другой ноде. Если задан `PUSH_REDIS_VIP`, установщик
(`configure_push_redis`) делает push **active-active**:

* выделенный **общий push-Redis** — отдельный инстанс (порт **6381**, `allkeys-lru`),
  master-replica + плавающий **`PUSH_VIP`** на keepalived (VRID `PUSH_VRID`);
* все push-серверы репойнтятся на `PUSH_VIP:6381`; `path_to_publish` → `127.0.0.1`;
* единый `security.key` = `pull.signature_key` на всех нодах (иначе клиент ловит
  `4010 Wrong Channel Id`);
* при failover мастера push-Redis реплика промотится и `push-server` перезапускается.

Включается, только если задан `PUSH_REDIS_VIP`. Файлы: `templates/redis-push.conf.tmpl`,
`templates/keepalived_push.conf.tmpl`, `templates/push_repoint.php`.

---

## Хранение сессий в Redis (HA)

Чтобы клиентские сессии **не терялись при переключении web-нод**, разворачивается
отдельный Redis под сессии (не путать с Redis для push):

* отдельный инстанс на порту **6380** с политикой `noeviction` (сессии не вытесняются);
* топология **master-replica**: первая web-нода — master, остальные — реплики;
* плавающий **VIP** (`SESSION_VIP`) на keepalived: всегда «живёт» на текущем
  master. При отказе master VIP уезжает на реплику, и она промотится
  (`REPLICAOF NO ONE`) через `redis_session_notify.sh`;
* в `bitrix/.settings.php` прописывается секция `session` с `host = SESSION_VIP:6380`;
* порт 6380 ограничен firewall'ом доступом только с web-узлов.

Шаг включается, только если задан `SESSION_VIP` (в интерактиве или файле ответов).
Если оставить его пустым — настройка пропускается.

Файлы: шаблоны `templates/redis-session.conf.tmpl`, `templates/keepalived_session.conf.tmpl`;
скрипты `bin/lib/redis_session_notify.sh` (промоут/демоут) и `bin/lib/redis_session_check.sh` (health-check keepalived).

---

## Общий кэш в Redis (HA)

Чтобы кэш Bitrix (`managed_cache` + `cache`) был **общим между web-нодами** и
инвалидировался консистентно по тегам (иначе файловый per-node кэш расходится),
при заданном `CACHE_REDIS_VIP` разворачивается ещё один Redis под кэш:

* отдельный инстанс на порту **6382**, политика `allkeys-lru`, без AOF;
* master-replica + плавающий **`CACHE_VIP`** на keepalived (VRID `CACHE_VRID`);
* промоут реплики при отказе master — тем же механизмом, что у сессий.

Включается, только если задан `CACHE_REDIS_VIP`. Файлы: `templates/redis-cache.conf.tmpl`,
`templates/keepalived_cache.conf.tmpl`.

---

## Режим единой ноды (single-active)

Особое состояние кластера для **первичной установки** или **переноса сайта/портала**:
вся нагрузка временно закрепляется на одной web-ноде, чтобы трафик и запросы к БД
не «гуляли» между нодами, пока заливаются данные. Остальные ноды остаются
**тёплыми** — службы и `lsyncd` продолжают работать, поэтому данные синхронизируются.

Что делает режим:
* **HTTP** — на всех `lb` через admin-сокет HAProxy все web-сервера, кроме активного,
  переводятся в `state maint` (drain). Весь трафик идёт на активную ноду — без round-robin.
* **БД** — на всех `web` правило ProxySQL `^SELECT` (rule_id=3) временно направляется
  в `HG_WRITE`, т.е. и чтения уходят на writer (нет рассинхрона при импорте).
* Состояние пишется в `cluster.conf` (`[cluster] mode=single, active_node=<web>`),
  а в шапке `bcm` показывается жёлтый баннер.

Управление — в BCM: **меню «1. Управление узлами кластера» → «7. Режим единой ноды»**.
Там же — выключение (возврат в HA/балансировку) и смена активной ноды.

> Для первичной установки: после `install.sh` войдите в режим из BCM, залейте/перенесите
> портал на активную ноду (она же — источник `lsyncd`), затем **выключите режим** —
> кластер вернётся к балансировке и полному HA.

Файлы: `bin/lib/bcm_cluster_mode.sh` (`bcm_cluster_pin` / `bcm_cluster_unpin`).
Требует `socat` на `lb`-нодах (ставится установщиком).

---

## Файлы между web-нодами: код vs /upload

`lsyncd` односторонний (**мастер-слейв**, источник = активная нода) и предназначен
только для **кода** — он надёжен лишь когда запись идёт с одной ноды. Чтобы в
active-active не терять пользовательские файлы, данные разделены по типу записи:

* **`/upload`** (пользовательские файлы, пишутся на любой ноде) → выносятся в общий
  **MinIO S3** через модуль Bitrix «Облачные хранилища». Установщик создаёт бакет
  `bitrix-upload` (реплицируется Site Replication) и пишет параметры в `cluster.conf`
  (`[s3_upload]`). Регистрация в портале — BCM **меню «11. Облачное хранилище /upload»**:
  показывает готовые значения для админки, проверяет связь, делает best-effort
  авто-регистрацию (`templates/cloud_seeder.php`).
* **код/ядро** (`bitrix/`, компоненты, модули) → односторонний `lsyncd` web01→web02
  (деплой с активной ноды). Это корректный мастер-слейв, без конфликтов.
* **кэш и tmp** (`managed_cache`, `html_pages`, `stack_cache`, `cache`, `tmp`) →
  локальные на каждой ноде, из синхронизации **исключены**.

> `lsyncd` (`menu/06_lsyncd.sh`) синкает только код: исключает `/upload`, кэши и `tmp`
> (rsync `--delete` уважает excludes — исключённое на target не удаляется). Это снимает
> риск, что при возврате упавшей ноды её устаревшее дерево затрёт свежие файлы.

### Запись кода только на источник (обновления модулей, админка)

Поскольку `lsyncd` односторонний, любая запись кода (обновление модулей, маркетплейс,
правка файлов в админке) должна идти **на источник**, иначе round-robin может увести её
на не-источник, где она будет затёрта синхронизацией. Поэтому HAProxy **закрепляет
`/bitrix/admin/` на источнике**:

```
acl is_bitrix_admin path_beg /bitrix/admin
use_backend web_admin_backend if is_bitrix_admin   # источник primary, остальные backup
```

Публичный трафик остаётся сбалансированным (`web_backend`, round-robin). В режиме
единой ноды admin-бэкенд следует за активной нодой автоматически.

**Инвариант:** активная нода = источник lsyncd = admin-primary HAProxy. По умолчанию это
первая web-нода (web01). Не редактируйте файлы напрямую на остальных web-нодах — они
управляемые реплики, изменения на них теряются; все правки делайте через источник
(админка туда уже маршрутизируется).

---

## Подключение портала к БД через ProxySQL

`bitrix-env` уже при установке создаёт «скелет» подключения в `bitrix/.settings.php`
(БД `sitemanager`, host `localhost` — локальный MySQL web-ноды), а не PXC. Установщик
**автоматически** (`install.sh` → `configure_portal_db`, шаг после настройки PXC/ProxySQL)
переводит это на кластер:

1. читает имя БД портала из `.settings.php` на первой web-ноде;
2. переносит её в PXC на writer (`mysqldump` → import; если БД уже там — идемпотентно;
   если пусто — создаёт пустую БД);
3. **проверяет маршрутизацию** через ProxySQL (`127.0.0.1:<proxy_port>`, пользователь
   `BITRIX_DB_USER`) — если не проходит, `.settings.php` **не трогается** (портал не ломается);
4. на всех web-нодах переписывает `.settings.php` → `host=127.0.0.1:<proxy_port>`,
   `login/password/database` из конфига (`options` сохраняются; бэкап `.bcm-bak-db`);
5. отключает локальный MySQL на web-нодах (БД живёт в PXC).

Если на момент установки портал ещё не развёрнут (нет `.settings.php`), шаг мягко
пропускается с подсказкой: разворачивайте портал через restore (сохраняет `.settings.php`)
или укажите в web-инсталляторе `host=127.0.0.1:<proxy_port>` и пользователя кластера.

`.settings.php` — часть кода, разносится `lsyncd` на остальные web-ноды (host
`127.0.0.1:6033` верен на каждой — ProxySQL встроен в каждую web-ноду). В современном
bitrix-env `php_interface/dbconn.php` реквизитов БД не содержит — источник истины только
`.settings.php`. Хелпер правки: `templates/db_repoint.php`.

---

## Архитектура логирования и ротации

Для обеспечения надежности и предотвращения переполнения дискового пространства реализована двухуровневая система логирования с автоматической ротацией.

### 1. Подробные логи во время установки

В процессе выполнения `install.sh` все операции (установка пакетов, конфигурирование, запуск сервисов) выполняются через функцию `bcm_ssh_exec_logged` и пишутся отдельно для каждого узла.

* **Локация логов на управляющей машине**:
  * Общий лог установщика: `/var/log/bcm/install.log`
  * Подробный лог выполнения на каждой ноде: `/bcm/logs/<имя_ноды>.log` (например, `/bcm/logs/web01.log`)
* **Ротация логов установки**:
  На управляющей машине создаётся конфигурационный файл `/etc/logrotate.d/bcm-install`. Ротация выполняется по достижении размера 50 Мб с сохранением последних 5 копий и сжатием (`copytruncate` включен).

### 2. Локальное логирование на серверах кластера

После развёртывания BCM на каждом сервере кластера настраивается локальное логирование системных компонентов с ротацией для предотвращения нехватки дискового пространства.

* **MinIO (S3 ноды)**:
  В системную службу `/etc/systemd/system/minio.service` добавлены директивы перенаправления вывода `StandardOutput` и `StandardError` в файл `/var/log/minio/minio.log`.
* **Правила ротации (`/etc/logrotate.d/bcm-node`)**:
  В зависимости от роли сервера, на каждом узле кластера разворачивается файл конфигурации `logrotate`.

#### Конфигурация ротации по ролям:

* **Все узлы (Логи BCM)**:
  * Путь: `/var/log/bcm/*.log` (включая `bcm.log`, `keepalived_notify.log`, `cron_notify.log`, `redis_session_notify.log`)
  * Параметры: лимит **10M**, ежедневная ротация, хранить 4 архивные копии, сжатие `gzip`.
* **Балансировщики (`lb`)**:
  * Ротируемые файлы: HAProxy (`/var/log/haproxy.log`), Keepalived (`/var/log/keepalived.log`).
  * Параметры: лимит **50M**, ежедневная ротация, хранить 4 копии, сжатие, метод `copytruncate`.
* **Веб-серверы (`web`)**:
  * Ротируемые файлы: Nginx (`/var/log/nginx/*.log`), Apache httpd (`/var/log/httpd/*.log`), ProxySQL (`/var/log/proxysql/*.log`, `/var/lib/proxysql/proxysql.log`), lsyncd (`/var/log/lsyncd/*.log`).
  * Параметры: лимит **50M**, ежедневная ротация, хранить 4 копии, сжатие, метод `copytruncate`.
* **Базы данных (`pxc`)**:
  * Ротируемые файлы: Galera/MySQL (`/var/log/mysql/*.log`, `/var/log/mysql/error.log`, `/var/log/mysql/slow.log`).
  * Параметры: лимит **50M**, ежедневная ротация, хранить 4 копии, сжатие, метод `copytruncate` (безопасное обнуление без прерывания сессий MySQL).
* **Хранилища (`s3`)**:
  * Ротируемые файлы: MinIO S3 (`/var/log/minio/*.log`).
  * Параметры: лимит **50M**, ежедневная ротация, хранить 4 копии, сжатие, метод `copytruncate`.

---

## Тестирование и верификация логирования

1. **Проверка логов установки**:
   Во время установки вы можете наблюдать за ходом выполнения команд на определенном сервере в реальном времени:
   ```bash
   tail -f /bcm/logs/db01.log
   ```
2. **Проверка конфигурации logrotate**:
   Чтобы проверить правильность синтаксиса конфигурации `logrotate` на любом из серверов кластера:
   ```bash
   logrotate -d /etc/logrotate.d/bcm-node
   ```
3. **Принудительный запуск ротации (Dry Run / Test)**:
   Для симуляции ротации и проверки сжатия файлов выполните команду:
   ```bash
   logrotate -f /etc/logrotate.d/bcm-node
   ```
4. **Проверка логов MinIO**:
   ```bash
   tail -n 100 /var/log/minio/minio.log
   ```

---

## Авто-восстановление PXC после полного обесточивания

Galera после одновременной остановки **всех** PXC-нод сама не стартует (никто не
знает, у кого свежайшие данные). Установщик (`configure_pxc_autorecover`) ставит на
каждую PXC-ноду агент (`bin/lib/pxc_autorecover.sh` + `pxc-autorecover.service`,
oneshot при загрузке), который детерминированно поднимает кластер:

* если кворум цел (одиночная перезагрузка) — нода просто джойнится;
* иначе ноды по SSH обмениваются recovery-позициями (`grastate.dat` / `--wsrep-recover`),
  выбирается winner с максимальным `seqno` (тай-брейк — наименьший IP), он бутстрапит
  кластер, остальные джойнятся строго по очереди;
* при < большинства доступных нод бутстрап **не** выполняется (защита от split-brain).

Штатный автозапуск `mysql.service` на PXC-нодах отключён — стартом владеет агент.
Лог: `/var/log/bcm/pxc-autorecover.log`, конфиг: `/etc/bitrix-cluster/pxc-autorecover.env`.

---

## SSL / HTTPS (меню 12)

TLS терминируется **только на HAProxy** (`bind *:443 ssl`), один pem (fullchain+key)
на обоих LB; бэкенды — по HTTP. Установщик кладёт self-signed заглушку; реальный
сертификат настраивается из BCM **меню 12**:

* **свой pem** — валидация пары + раскатка на оба LB (держатель VIP последним) с
  seamless-reload;
* **Let's Encrypt** — `acme.sh`, HTTP-01 (через `acme_backend` в HAProxy) или
  DNS-01 (Cloudflare, в т.ч. wildcard); автопродление systemd-таймером `bcm-cert-renew`
  на обоих LB;
* **принудительный HTTPS** — редирект 80→443 на HAProxy (не через `.htsecure`!).

Копия pem раздаётся и на web-ноды (`/etc/nginx/ssl/cert.pem`) — для серверных
self-проверок Bitrix по `ssl://домен:443`. Конфиг — `[ssl]` в `cluster.conf`,
исполнитель — `bin/lib/ssl_certs.sh` (CLI на LB), оркестрация — `menu/12_ssl.sh`.

---

## Резервное копирование (меню 13)

HA-aware бэкапы в MinIO кластера (`configure_backup`, исполнитель `bin/lib/bcm_backup.sh`):

* **conf** — конфиги всех нод, шифрованный tar (`openssl enc aes-256`, ключ
  генерируется install'ом и сохраняется в `cluster.conf` между прогонами);
* **db** — PXC через `xtrabackup --stream` с Synced-ноды (гейты: только Synced,
  `wsrep_desync=ON` на время, идемпотентный маркер в S3);
* **files** — `/upload`-эквивалент с источника lsyncd через `mc mirror`.

Бакет `bitrix-backups` с **versioning + lifecycle-retention** (`BACKUP_RETENTION_DAYS`).
Таймеры `bcm-backup-{conf,db,files}` на нодах-кандидатах роли. Offsite-копия (3-2-1) —
пункт меню 13→6. Управление и восстановление — `menu/13_backup.sh`.

---

## Генератор документов / Transformer (меню 14)

Сервис bitrix-env для генерации документов в CRM и конвертации документов/видео
для Диска. **Не входит в `install.sh` осознанно**: требует развёрнутого портала с
лицензией Enterprise (модуль `transformercontroller`) и тяжёлого стека
(LibreOffice/RabbitMQ/Erlang/FFmpeg). Поэтому ставится **вручную** из BCM **меню 14**
после развёртывания портала.

HA — вариант A (always-on): плавающий **`TRANSFORMER_VIP`** (VRID 60) в keepalived
web-нод; `rabbitmq-server` + `transformer` работают на обеих web всегда, keepalived
лишь держит VIP. Портал и воркеры ходят на `default` → VIP → RabbitMQ держателя VIP.
Файлы: `menu/14_transformer.sh`, `bin/lib/transformer_{check,notify}.sh`,
`templates/keepalived_transformer.conf.tmpl`.

---

## Запуск Buoyant Cluster Management for bitrix-env

После успешного выполнения скрипта BCM будет развёрнут на всех нодах.

Запустите интерфейс управления на любой из **WEB-нод**:
```bash
bcm
```

* На `web` нодах доступно **полное меню** (web — «мозг» кластера):

  | № | Пункт | № | Пункт |
  |---|---|---|---|
  | 1 | Управление узлами кластера | 8 | Веб-серверы |
  | 2 | Настройка локального хоста | 9 | Push/RTC сервис |
  | 3 | Кластер БД (Percona XtraDB Cluster) | 10 | Фоновые задания (HA Cron) |
  | 4 | ProxySQL | 11 | Облачное хранилище /upload (S3) |
  | 5 | VIP / Keepalived | 12 | SSL-сертификаты (HTTPS / Let's Encrypt) |
  | 6 | Синхронизация файлов (lsyncd) | 13 | Резервное копирование (S3, HA-aware) |
  | 7 | Управление сайтами | 14 | Генератор документов (Transformer) |

* На `lb`, `pxc` и `s3` нодах при запуске команды `bcm` автоматически откроется ограниченное меню (только настройки локального хоста и состояние текущей службы).
* Статус кластера без TUI: `bcm --status-only`.

---

## Обновление BCM (по релизам GitHub)

BCM обновляется из релизов этого репозитория **одной командой** с web-ноды (мозг
кластера) — она тянет последний релиз и раскатывает его на все ноды через тот же
механизм, что и установка (`bcm_deploy_to_node`).

```bash
bcm --check-update     # есть ли новый релиз (ничего не меняет)
bcm --update           # обновить BCM до последнего релиза на ВСЕХ нодах
bcm --version          # текущая версия
```

`bcm --update`: запрашивает последний релиз через GitHub API, сверяет с локальной
`VERSION`, скачивает tarball релиза, **проверяет его GPG-подпись** (см. ниже), делает
бэкап `/opt/bcm` → `/opt/bcm.bak-<ts>`, обновляет локальный пакет и раскатывает его на
каждую ноду кластера. Для приватного репозитория или обхода лимита API —
`BCM_GITHUB_TOKEN=<token> bcm --update`; репозиторий переопределяется через
`BCM_UPDATE_REPO=owner/name` или секцию `[update] repo` в `cluster.conf`.

### Верификация источника (GPG-подпись)

Релизы подписываются GPG-ключом мейнтейнера; `bcm --update` **проверяет подпись
скачанного tarball'а перед раскаткой** и отказывается обновляться, если подпись
невалидна или отсутствует (fail-closed). Доверенный **публичный** ключ лежит в репозитории
(`bcm/keys/*.asc`) и раскатывается на ноды в `/opt/bcm/keys/`; приватный ключ
**никогда** не попадает в репозиторий и на GitHub.

* проверка: sha256 (целостность) + `gpg --verify` детачнутой подписи `.asc` доверенным
  ключом в изолированном keyring'е (штатный GPG узла не затрагивается);
* аварийный обход (НЕ рекомендуется, напр. до первичного бутстрапа ключа):
  `BCM_ALLOW_UNSIGNED=1 bcm --update`.

Бутстрап ключа подписи — один раз, см. [`bcm/keys/README.md`](bcm/keys/README.md):
`gpg --full-generate-key` → `gpg --armor --export <fpr> > bcm/keys/bcm-release-pub.asc`
→ закоммитить.

> Обновление раскатывает **инструментарий BCM** (TUI, библиотеки, шаблоны). Если релиз
> менял инфраструктурные фазы `install.sh` (новые сервисы/конфиги) — примените их с
> управляющей машины: `sudo bash install.sh`.

### Выпуск релиза (для мейнтейнера)

```bash
scripts/release.sh 1.1.0
```

Скрипт бампит `bcm/VERSION`, коммитит, ставит тег `v1.1.0`, пушит, затем **локально**
собирает `bcm-1.1.0.tar.gz`, **подписывает** его GPG-ключом мейнтейнера (`.asc`),
считает `.sha256` и публикует **GitHub Release** с этими артефактами через `gh`
(приватный ключ остаётся на машине мейнтейнера). Preflight проверяет наличие `gh`/`gpg`,
аутентификацию `gh` и что публичный ключ подписанта закоммичен в `bcm/keys/`.

Workflow [`.github/workflows/release.yml`](.github/workflows/release.yml) — лишь
страховочная валидация тега (синтаксис, `VERSION==тег`, наличие публичного ключа);
сам Release он не создаёт. Требования к ключу — `BCM_SIGNING_KEY` (или
`git config user.signingkey`), бутстрап — [`bcm/keys/README.md`](bcm/keys/README.md).

---

## Лицензия

Проект распространяется под лицензией **Apache License 2.0** — полный текст в файле
[`LICENSE`](LICENSE), атрибуция и товарные знаки — в [`NOTICE`](NOTICE).

«Bitrix», «1С-Битрикс», «bitrix-env» — товарные знаки соответствующих
правообладателей. Проект независимый, не аффилирован с ними; упоминание
`bitrix-env` описывает только совместимость (номинативное использование).
