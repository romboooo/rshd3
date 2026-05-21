# РСХД Лабораторная работа №3

## Вариант 65213
## Задание:

```
Цель работы - ознакомиться с методами и средствами построения отказоустойчивых решений на базе СУБД Postgres; получить практические навыки восстановления работы системы после отказа.

Работа рассчитана на двух человек и выполняется в три этапа: настройка, симуляция и обработка сбоя, восстановление.
Требования к выполнению работы

    В качестве хостов использовать одинаковые виртуальные машины.
    В первую очередь необходимо обеспечить сетевую связность между ВМ.
    Для подключения к СУБД (например, через psql), использовать отдельную виртуальную или физическую машину.
    Демонстрировать наполнение базы и доступ на запись на примере не менее, чем двух таблиц, столбцов, строк, транзакций и клиентских сессий.

Этап 1. Конфигурация

Настроить репликацию postgres на трёх узлах в каскадном режиме A --> B --> C. Для управления использовать pgpool-II. Репликация с A на B синхронная. Репликация с B на C асинхронная. Продемонстрировать, что новые данные реплицируются на B в синхронном режиме, а на C с задержкой.
Этап 2. Симуляция и обработка сбоя

2.1 Подготовка:

    Установить несколько клиентских подключений к СУБД.
    Продемонстрировать состояние данных и работу клиентов в режиме чтение/запись.

2.2 Сбой:

Симулировать программную ошибку на основном узле - выполнить команду pkill -9 postgres.

2.3 Обработка:

    Найти и продемонстрировать в логах релевантные сообщения об ошибках.
    Выполнить переключение (failover) на резервный сервер.
    Продемонстрировать состояние данных и работу клиентов в режиме чтение/запись.

Восстановление

    Восстановить работу основного узла - откатить действие, выполненное с виртуальной машиной на этапе 2.2.
    Актуализировать состояние базы на основном узле - накатить все изменения данных, выполненные на этапе 2.3.
    Восстановить исправную работу узлов в исходной конфигурации (в соответствии с этапом 1).
    Продемонстрировать состояние данных и работу клиентов в режиме чтение/запись.
```

## этап 1

### Подготовка окружения


Работа выполнялась в докере, для каждого sql узла использовался образ postgres:16-alpine. также используется отдельный контейнер pgpool для управления подключениями и   
отдельный контейнер клиент для имитации пользовательских подключений

Используемая схема:

```text
client -> pgpool -> host-a -> host-b -> host-c
```

```
host-a — основной узел postgres;
host-b — синхронная реплика host-a;
host-c — асинхронная каскадная реплика host-b;
pgpool — единая точка входа для клиентских подключений;
client — отдельный клиентский контейнер для подключения через psql.
```

#### Очистка от прошлых приколов

```zsh
cd ~/itmo/rshd/lab3

docker compose down

sudo rm -rf data/a data/b data/c
mkdir -p data/a data/b data/c
sudo chown -R 70:70 data/a data/b data/c

ls -la data
```

```
total 20
drwxr-xr-x 5 rmb rmb 4096 May 21 15:45 .
drwxr-xr-x 5 rmb rmb 4096 Apr 29 15:43 ..
drwxr-xr-x 2  70  70 4096 May 21 15:45 a
drwxr-xr-x 2  70  70 4096 May 21 15:45 b
drwxr-xr-x 2  70  70 4096 May 21 15:45 c
```

### docker-compose.yml

```yml
services:
  host-a:
    image: postgres:16-alpine
    container_name: host-a
    hostname: host-a
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: secret
    volumes:
      - ./data/a:/var/lib/postgresql/data 
      - ./config/a:/etc/postgresql/config   
    ports:
      - "5433:5432"
    networks:
      - pgnet
    restart: no

  host-b:
    image: postgres:16-alpine
    container_name: host-b
    hostname: host-b
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: secret
    volumes:
      - ./data/b:/var/lib/postgresql/data
      - ./config/b:/etc/postgresql/config
    ports:
      - "5434:5432"
    networks:
      - pgnet
    restart: unless-stopped

  host-c:
    image: postgres:16-alpine
    container_name: host-c
    hostname: host-c
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: secret
    volumes:
      - ./data/c:/var/lib/postgresql/data
      - ./config/c:/etc/postgresql/config
    ports:
      - "5435:5432"
    networks:
      - pgnet
    restart: unless-stopped

  pgpool:
    image: bitnamilegacy/pgpool:latest
    container_name: pgpool
    hostname: pgpool
    environment:
      PGPOOL_BACKEND_NODES: "0:host-a:5432,1:host-b:5432,2:host-c:5432"
      PGPOOL_POSTGRES_USERNAME: postgres
      PGPOOL_POSTGRES_PASSWORD: secret
      PGPOOL_SR_CHECK_USER: postgres
      PGPOOL_SR_CHECK_PASSWORD: secret
      PGPOOL_HEALTH_CHECK_USER: postgres
      PGPOOL_HEALTH_CHECK_PASSWORD: secret
      PGPOOL_ADMIN_USERNAME: admin
      PGPOOL_ADMIN_PASSWORD: admin
      PGPOOL_SR_CHECK_PERIOD: 5
      PGPOOL_ENABLE_WATCHDOG: "no"
      PGPOOL_FAILOVER_ON_BACKEND_ERROR: "yes"
    ports:
      - "5432:5432"
    networks:
      - pgnet
    restart: unless-stopped
    depends_on:
      - host-a
      - host-b
      - host-c
  client:
    image: postgres:16-alpine
    container_name: client
    hostname: client
    networks:
      - pgnet
    entrypoint: ["sleep", "infinity"]
    depends_on:
      - pgpool
networks:
  pgnet:
    driver: bridge
```

### Запуск основного узла host-a

```sh
docker compose up -d host-a
```

```
[+] up 2/2
 ✔ Network lab3_pgnet Created
 ✔ Container host-a   Started
```

### проверим что postgres на host-a принимает подключения

```sh
docker exec host-a pg_isready -U postgres
```

```
/var/run/postgresql:5432 - accepting connections
```

### проверим что host-a не находится в режиме восстановления то есть является primary

```sh
docker exec host-a psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
 pg_is_in_recovery 
-------------------
 f
(1 row)
```

### настройка host-a как primary-узла

```sh
docker exec host-a psql -U postgres -c "alter system set wal_level = 'replica';"
docker exec host-a psql -U postgres -c "alter system set max_wal_senders = 10;"
docker exec host-a psql -U postgres -c "alter system set max_replication_slots = 10;"
docker exec host-a psql -U postgres -c "alter system set wal_keep_size = '256MB';"
docker exec host-a psql -U postgres -c "alter system set synchronous_standby_names = 'standby_b';"
```

```
alter system
alter system
alter system
alter system
alter system
```

### создадим юзера для репликации

```sh
docker exec host-a psql -U postgres -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'secret';"
```

```
CREATE ROLE
```

### настроим pg_hba.conf

```
host    all             all             127.0.0.1/32            trust
# IPv6 local connections:
host    all             all             ::1/128                 trust
# Allow replication connections from localhost, by a user with the
# replication privilege.
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust

host all all all scram-sha-256

host    replication    replicator    0.0.0.0/0    password
```

### перезагрузим конфиги и контейнер 

```sh
docker exec host-a psql -U postgres -c "SELECT pg_reload_conf();"
```

```
 pg_reload_conf 
----------------
 t
(1 row)
```

```sh
docker compose restart host-a
```

```
[+] restart 0/1
 ⠹ Container host-a Restarting
```

### проверим что всё применилось

```sh 
docker exec host-a psql -U postgres -c "SHOW wal_level;"
docker exec host-a psql -U postgres -c "SHOW max_wal_senders;"
docker exec host-a psql -U postgres -c "SHOW max_replication_slots;"
docker exec host-a psql -U postgres -c "SHOW wal_keep_size;"
docker exec host-a psql -U postgres -c "SHOW synchronous_standby_names;"
docker exec host-a psql -U postgres -c "SELECT rolname, rolreplication FROM pg_roles WHERE rolname IN ('postgres', 'replicator');"
```

```
 wal_level 
-----------
 replica
(1 row)

 max_wal_senders 
-----------------
 10
(1 row)

 max_replication_slots 
-----------------------
 10
(1 row)

 wal_keep_size 
---------------
 256MB
(1 row)

 synchronous_standby_names 
---------------------------
 standby_b
(1 row)

  rolname   | rolreplication 
------------+----------------
 postgres   | t
 replicator | t
(2 rows)
```

### настройка host-b как синхронной реплики host-a

#### очистка

```sh
docker compose stop host-b
sudo rm -rf data/b
mkdir -p data/b
sudo chown 70:70 data/b
sudo ls -la data/b
```

### cоздадим базовую копию с host-a

```sh
docker run --rm -it \
  --network lab3_pgnet \
  -e PGPASSWORD=secret \
  -v "$PWD/data/b:/var/lib/postgresql/data" \
  postgres:16-alpine \
  pg_basebackup \
    -h host-a \
    -U replicator \
    -D /var/lib/postgresql/data \
    -P \
    -R \
    --wal-method=stream \
    -C \
    -S slot_b
```

```
23246/23246 kB (100%), 1/1 tablespace
```
### запуск

```sh
docker compose start host-b
```

```
[+] start 1/1
 ✔ Container host-b Started
```
### конфигурация

```sh
docker exec host-b psql -U postgres -c "alter system set primary_conninfo = 'user=replicator password=secret host=host-a application_name=standby_b';"
docker exec host-b psql -U postgres -c "alter system set primary_slot_name = 'slot_b';"
```


### перезапуск
```sh
docker compose restart host-b
```

### проверка

```sh
docker exec host-b psql -U postgres -c "SHOW primary_conninfo;"
docker exec host-b psql -U postgres -c "SHOW primary_slot_name;"
```

```sh
primary_conninfo
--------------------------------------------------------------------------------
user=replicator password=secret host=host-a application_name=standby_b
(1 row)

primary_slot_name
------------------
slot_b
(1 row)
```



### проверим что postgres на host-b принимает подключения

```sh
docker exec host-b pg_isready -U postgres
```

```
/var/run/postgresql:5432 - accepting connections
```

### проверим standby

```sh
docker exec host-b psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
 pg_is_in_recovery 
-------------------
 t
(1 row)
```

### проверим на host-a, что реплика standby_b подключена и работает в синхронном режиме

```sh
docker exec host-a psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_b        | streaming | sync
(1 row)
```

### также проверими что replication slot slot_b active =true

```sh
docker exec host-a psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

```
 slot_name | active 
-----------+--------
 slot_b    | t
(1 row)
```

### Подготовка host-b для каскадной репликации (не только standby но и источник потоковой репликации)

```sh
docker exec host-b psql -U postgres -c "alter system set max_wal_senders = 10;"
docker exec host-b psql -U postgres -c "alter system set max_replication_slots = 10;"
docker exec host-b psql -U postgres -c "alter system set wal_keep_size = '256MB';"
```

```
alter system
alter system
alter system
```

### настроим pg_hba.conf

``` 
host    replication    replicator    0.0.0.0/0    password
```

### рестарт 
```sh
docker compose restart host-b
```

```
[+] restart 0/1
 ⠹ Container host-b Restarting
```

### проверим что настройки применились

```sh
docker exec host-b pg_isready -U postgres
docker exec host-b psql -U postgres -c "SELECT pg_is_in_recovery();"
docker exec host-b psql -U postgres -c "SHOW max_wal_senders;"
docker exec host-b psql -U postgres -c "SHOW max_replication_slots;"
docker exec host-b sh -c "grep -n 'replication.*replicator' /var/lib/postgresql/data/pg_hba.conf"
```

```
/var/run/postgresql:5432 - accepting connections

 pg_is_in_recovery 
-------------------
 t
(1 row)

 max_wal_senders 
-----------------
 10
(1 row)

 max_replication_slots 
-----------------------
 10
(1 row)

131:host    replication    replicator    0.0.0.0/0    password
```

### настройка host-с как асинхронной каскадной реплики host-b

#### очистка

```sh
docker compose stop host-c
sudo rm -rf data/c
mkdir -p data/c
sudo chown 70:70 data/c
sudo ls -la data/c
```

```
total 8
drwxr-xr-x 2  70  70 4096 May 21 16:21 .
drwxr-xr-x 5 rmb rmb 4096 May 21 16:21 ..
```

### создадим базовую копию host-b

```sh
docker run --rm -it \
  --network lab3_pgnet \
  -e PGPASSWORD=secret \
  -v "$PWD/data/c:/var/lib/postgresql/data" \
  postgres:16-alpine \
  pg_basebackup \
    -h host-b \
    -U replicator \
    -D /var/lib/postgresql/data \
    -P \
    -R \
    --wal-method=stream \
    -C \
    -S slot_c
```

```
23248/23248 kB (100%), 1/1 tablespace
```

### перезапуск

```sh
docker compose restart host-c
```

```
[+] start 1/1
 ✔ Container host-c Started
```

### зададим параметры подключения к host-b через alter system и перезапустим контейнер

```sh
docker exec host-c psql -U postgres -c "alter system set primary_conninfo = 'user=replicator password=secret host=host-b application_name=standby_c';"
docker exec host-c psql -U postgres -c "alter system set primary_slot_name = 'slot_c';"
```

```
ALTER SYSTEM
ALTER SYSTEM
```

### докер очень быстро обрабатывает асинхронную репликацию поэтому для наглядности задержки сделан delay
```
docker exec host-c psql -U postgres -c "alter system set recovery_min_apply_delay = '10s';"
```

```
ALTER SYSTEM
```

### перезапуск

```sh
docker compose restart host-c
```

```
[+] start 1/1
 ✔ Container host-c Started
```

### проверка применения

```sh
docker exec host-c psql -U postgres -c "SHOW primary_conninfo;"
docker exec host-c psql -U postgres -c "SHOW primary_slot_name;"
docker exec host-c psql -U postgres -c "SHOW recovery_min_apply_delay;"
```

```
 primary_conninfo
---------------------------------------------------------------------------
 user=replicator password=secret host=host-b application_name=standby_c
(1 row)

 primary_slot_name
-------------------
 slot_c
(1 row)

 recovery_min_apply_delay
--------------------------
 10s
(1 row)
```

### проверим, что host-c работает в режиме standby

```sh
docker exec host-c pg_isready -U postgres
docker exec host-c psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
/var/run/postgresql:5432 - accepting connections

 pg_is_in_recovery 
-------------------
 t
(1 row)
```

### проверим на host-b, что host-c подключён как асинхронная реплика

```sh
docker exec host-b psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_c        | streaming | async
(1 row)
```


### проверим replication slot на host-b

```sh
docker exec host-b psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

```
 slot_name | active 
-----------+--------
 slot_c    | t
(1 row)
```

### готово! репликация настроена

```
host-a -> host-b -> host-c
```

### подключение pgpool

```sh
docker compose up -d pgpool
```

```
[+] up 4/4
 ✔ Container host-c Running
 ✔ Container host-a Running
 ✔ Container host-b Running
 ✔ Container pgpool Started
```

```sh
docker compose ps
```

```
NAME      IMAGE                         COMMAND                  SERVICE   CREATED             STATUS             PORTS
host-a    postgres:16-alpine            "docker-entrypoint.s…"   host-a    About an hour ago   Up About an hour   0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp
host-b    postgres:16-alpine            "docker-entrypoint.s…"   host-b    About an hour ago   Up 34 minutes      0.0.0.0:5434->5432/tcp, [::]:5434->5432/tcp
host-c    postgres:16-alpine            "docker-entrypoint.s…"   host-c    26 minutes ago      Up 26 minutes      0.0.0.0:5435->5432/tcp, [::]:5435->5432/tcp
pgpool    bitnamilegacy/pgpool:latest   "/opt/bitnami/script…"   pgpool    23 minutes ago      Up 23 minutes      0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp
```

### тест подключения

```sh
docker exec -e PGPASSWORD=secret pgpool psql -U postgres -h localhost -p 5432 -c "SELECT 1;"
```

```
 ?column? 
----------
        1
(1 row)
```

```sh
docker exec -e PGPASSWORD=secret pgpool psql -U postgres -h localhost -p 5432 -c "SHOW POOL_NODES;"
```

```
 node_id | hostname | port | status | pg_status | lb_weight |  role   | pg_role | select_cnt | load_balance_node | replication_delay | replication_state | replication_sync_state | last_status_change  
---------+----------+------+--------+-----------+-----------+---------+---------+------------+-------------------+-------------------+-------------------+------------------------+---------------------
 0       | host-a   | 5432 | up     | up        | 0.333333  | primary | primary | 0          | false             | 0                 |                   |                        | 2026-05-21 13:57:06
 1       | host-b   | 5432 | up     | up        | 0.333333  | standby | standby | 0          | true              | 0                 |                   |                        | 2026-05-21 13:57:06
 2       | host-c   | 5432 | up     | up        | 0.333333  | standby | standby | 1          | false             | 0                 |                   |                        | 2026-05-21 13:57:06
(3 rows)
```

### подключение клиентского узла

```sh
docker compose up -d client
```

```
[+] up 5/5
 ✔ Container host-c Running
 ✔ Container host-a Running
 ✔ Container host-b Running
 ✔ Container pgpool Running
 ✔ Container client Started
```

### коннект тест

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -c "SELECT current_database(), current_user;"
```

```
 current_database | current_user 
------------------+--------------
 postgres         | postgres
(1 row)
```

### создадим бд и заполним данными

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -c "CREATE DATABASE illgreennews;"
```

```
CREATE DATABASE
```

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "
CREATE TABLE articles (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT now()
);

CREATE TABLE comments (
    id SERIAL PRIMARY KEY,
    article_id INTEGER NOT NULL REFERENCES articles(id),
    author TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT now()
);
"
```

```
CREATE TABLE
CREATE TABLE
```

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "\dt"
```

```
          List of relations
 Schema |   Name   | Type  |  Owner   
--------+----------+-------+----------
 public | articles | table | postgres
 public | comments | table | postgres
(2 rows)
```

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "\d articles"
```

```
                                        Table "public.articles"
   Column   |            Type             | Collation | Nullable |               Default                
------------+-----------------------------+-----------+----------+--------------------------------------
 id         | integer                     |           | not null | nextval('articles_id_seq'::regclass)
 title      | text                        |           | not null | 
 content    | text                        |           | not null | 
 created_at | timestamp without time zone |           |          | now()
Indexes:
    "articles_pkey" PRIMARY KEY, btree (id)
Referenced by:
    TABLE "comments" CONSTRAINT "comments_article_id_fkey" FOREIGN KEY (article_id) REFERENCES articles(id)
```

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "\d comments"
```

```
                                        Table "public.comments"
   Column   |            Type             | Collation | Nullable |               Default                
------------+-----------------------------+-----------+----------+--------------------------------------
 id         | integer                     |           | not null | nextval('comments_id_seq'::regclass)
 article_id | integer                     |           | not null | 
 author     | text                        |           | not null | 
 body       | text                        |           | not null | 
 created_at | timestamp without time zone |           |          | now()
Indexes:
    "comments_pkey" PRIMARY KEY, btree (id)
Foreign-key constraints:
    "comments_article_id_fkey" FOREIGN KEY (article_id) REFERENCES articles(id)
```


```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "
BEGIN;

INSERT INTO articles (title, content) VALUES
  ('Article X', 'Text X'),
  ('Article Y', 'Text Y'),
  ('Article Z', 'Text Z');

INSERT INTO comments (article_id, author, body) VALUES
  (1, 'UserX', 'Comment to X'),
  (2, 'UserY', 'Comment to Y'),
  (3, 'UserZ', 'Comment to Z');

COMMIT;
"
```

```
BEGIN
INSERT 0 3
INSERT 0 3
COMMIT
```


```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "SELECT * FROM articles ORDER BY id;"
```

```
 id |   title   | content |         created_at         
----+-----------+---------+----------------------------
  1 | Article X | Text X  | 2026-05-21 14:01:35.325729
  2 | Article Y | Text Y  | 2026-05-21 14:01:35.325729
  3 | Article Z | Text Z  | 2026-05-21 14:01:35.325729
(3 rows)
```

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "SELECT * FROM comments ORDER BY id;"
```

```
 id | article_id | author |     body     |         created_at         
----+------------+--------+--------------+----------------------------
  1 |          1 | UserX  | Comment to X | 2026-05-21 14:01:35.325729
  2 |          2 | UserY  | Comment to Y | 2026-05-21 14:01:35.325729
  3 |          3 | UserZ  | Comment to Z | 2026-05-21 14:01:35.325729
(3 rows)
```


### проверим на какой узел попадает клиентское подключение через pgpool

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "SELECT inet_server_addr(), inet_server_port(), pg_is_in_recovery();"
```

```
 inet_server_addr | inet_server_port | pg_is_in_recovery 
------------------+------------------+-------------------
 172.19.0.2       |             5432 | f
(1 row)
```

### проверим что данные появились на всех узлах

```sh
docker exec host-a psql -U postgres -d illgreennews -c "SELECT * FROM articles ORDER BY id;"
docker exec host-a psql -U postgres -d illgreennews -c "SELECT * FROM comments ORDER BY id;"
```

```
 id |   title   | content |         created_at         
----+-----------+---------+----------------------------
  1 | Article X | Text X  | 2026-05-21 14:01:35.325729
  2 | Article Y | Text Y  | 2026-05-21 14:01:35.325729
  3 | Article Z | Text Z  | 2026-05-21 14:01:35.325729
(3 rows)

 id | article_id | author |     body     |         created_at         
----+------------+--------+--------------+----------------------------
  1 |          1 | UserX  | Comment to X | 2026-05-21 14:01:35.325729
  2 |          2 | UserY  | Comment to Y | 2026-05-21 14:01:35.325729
  3 |          3 | UserZ  | Comment to Z | 2026-05-21 14:01:35.325729
(3 rows)
```

```sh
docker exec host-b psql -U postgres -d illgreennews -c "SELECT * FROM articles ORDER BY id;"
docker exec host-b psql -U postgres -d illgreennews -c "SELECT * FROM comments ORDER BY id;"
```

```
 id |   title   | content |         created_at         
----+-----------+---------+----------------------------
  1 | Article X | Text X  | 2026-05-21 14:01:35.325729
  2 | Article Y | Text Y  | 2026-05-21 14:01:35.325729
  3 | Article Z | Text Z  | 2026-05-21 14:01:35.325729
(3 rows)

 id | article_id | author |     body     |         created_at         
----+------------+--------+--------------+----------------------------
  1 |          1 | UserX  | Comment to X | 2026-05-21 14:01:35.325729
  2 |          2 | UserY  | Comment to Y | 2026-05-21 14:01:35.325729
  3 |          3 | UserZ  | Comment to Z | 2026-05-21 14:01:35.325729
(3 rows)
```

```sh
docker exec host-c psql -U postgres -d illgreennews -c "SELECT * FROM articles ORDER BY id;"
docker exec host-c psql -U postgres -d illgreennews -c "SELECT * FROM comments ORDER BY id;"
```

```
 id |   title   | content |         created_at         
----+-----------+---------+----------------------------
  1 | Article X | Text X  | 2026-05-21 14:01:35.325729
  2 | Article Y | Text Y  | 2026-05-21 14:01:35.325729
  3 | Article Z | Text Z  | 2026-05-21 14:01:35.325729
(3 rows)

 id | article_id | author |     body     |         created_at         
----+------------+--------+--------------+----------------------------
  1 |          1 | UserX  | Comment to X | 2026-05-21 14:01:35.325729
  2 |          2 | UserY  | Comment to Y | 2026-05-21 14:01:35.325729
  3 |          3 | UserZ  | Comment to Z | 2026-05-21 14:01:35.325729
(3 rows)
```

### демонстрация синхронной репликации на host-b и задержки на host-c

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "BEGIN;
    INSERT INTO articles (title, content)
    VALUES ('Article Delay Test', 'Appears on C after delay'); 
    INSERT INTO comments (article_id, author, body) 
    VALUES (4, 'DelayUser', 'Comment with delayed replication');
COMMIT;"
```

```
BEGIN
INSERT 0 1
INSERT 0 1
COMMIT
```

```sh
docker exec host-a psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
```

```
 id |       title        |         content          
----+--------------------+--------------------------
  1 | Article X          | Text X
  2 | Article Y          | Text Y
  3 | Article Z          | Text Z
  4 | Article Delay Test | Appears on C after delay
(4 rows)
```

```sh
docker exec host-b psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
```

```
 id |       title        |         content          
----+--------------------+--------------------------
  1 | Article X          | Text X
  2 | Article Y          | Text Y
  3 | Article Z          | Text Z
  4 | Article Delay Test | Appears on C after delay
(4 rows)
```

```sh
docker exec host-c psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
```

```
 id |   title   | content 
----+-----------+---------
  1 | Article X | Text X
  2 | Article Y | Text Y
  3 | Article Z | Text Z
(3 rows)
```

```sh
sleep 12
docker exec host-c psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
```

```
 id |       title        |         content          
----+--------------------+--------------------------
  1 | Article X          | Text X
  2 | Article Y          | Text Y
  3 | Article Z          | Text Z
  4 | Article Delay Test | Appears on C after delay
(4 rows)
```

### что имеем?

```
host-a -> host-b работает в синхронном режиме
host-b -> host-c работает в асинхронном режиме с задержкой применения wal
```

## этап 2

### 2.1 подготовка к сбою, несколько клиентских сессий и чтение/запись до сбоя
### первая сессия 

```sh
docker exec -it -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews
```

```sql
illgreennews=# SELECT 'session_1' AS session, pg_backend_pid(), inet_server_addr(), pg_is_in_recovery();
```

```
  session  | pg_backend_pid | inet_server_addr | pg_is_in_recovery 
-----------+----------------+------------------+-------------------
 session_1 |            845 | 172.19.0.2       | f
(1 row)
```

### вторая сессия в отдельном терминале

```sh
docker exec -it -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews
```

```sql
illgreennews=# SELECT 'session_2' AS session, pg_backend_pid(), inet_server_addr(), pg_is_in_recovery();
```

```
  session  | pg_backend_pid | inet_server_addr | pg_is_in_recovery 
-----------+----------------+------------------+-------------------
 session_2 |            848 | 172.19.0.2       | f
(1 row)
```

### 1 сессия

```sql
illgreennews=#
BEGIN; 
INSERT INTO articles (title, content) VALUES ('Article Before Failover', 'Inserted before primary failure'); INSERT INTO comments (article_id, author, body) VALUES (5, 'BeforeFailoverUser', 'Comment before failover'); COMMIT;
```

```
BEGIN
INSERT 0 1
INSERT 0 1
COMMIT
```

### 2 сессия

```sql
illgreennews=# SELECT id, title, content FROM articles ORDER BY id;
```

```
 id |          title          |             content             
----+-------------------------+---------------------------------
  1 | Article X               | Text X
  2 | Article Y               | Text Y
  3 | Article Z               | Text Z
  4 | Article Delay Test      | Appears on C after delay
  5 | Article Before Failover | Inserted before primary failure
(5 rows)
```

```sql 
illgreennews=# SELECT id, article_id, author, body FROM comments ORDER BY id;
```

```
 id | article_id |       author       |               body               
----+------------+--------------------+----------------------------------
  1 |          1 | UserX              | Comment to X
  2 |          2 | UserY              | Comment to Y
  3 |          3 | UserZ              | Comment to Z
  4 |          4 | DelayUser          | Comment with delayed replication
  5 |          5 | BeforeFailoverUser | Comment before failover
(5 rows)
```

### 2.2 симуляция программной ошибки на основном узле

```sh
docker exec host-a pkill -9 postgres
```

```sh
docker compose ps
```

```
NAME      IMAGE                         COMMAND                  SERVICE   CREATED             STATUS             PORTS
client    postgres:16-alpine            "sleep infinity"         client    15 minutes ago      Up 15 minutes      5432/tcp
host-a    postgres:16-alpine            "docker-entrypoint.s…"   host-a    About an hour ago   Up About an hour   0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp
host-b    postgres:16-alpine            "docker-entrypoint.s…"   host-b    About an hour ago   Up 53 minutes      0.0.0.0:5434->5432/tcp, [::]:5434->5432/tcp
host-c    postgres:16-alpine            "docker-entrypoint.s…"   host-c    45 minutes ago      Up 9 minutes       0.0.0.0:5435->5432/tcp, [::]:5435->5432/tcp
pgpool    bitnamilegacy/pgpool:latest   "/opt/bitnami/script…"   pgpool    42 minutes ago      Up 42 minutes      0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp
```

### не сработало ????????????????? почему же???

```
2026-05-21 14:13:32.359 UTC [1] LOG:  checkpointer process (PID 27) was terminated by signal 9: Killed
2026-05-21 14:13:32.359 UTC [1] LOG:  terminating any other active server processes
2026-05-21 14:13:32.359 UTC [1] LOG:  all server processes terminated; reinitializing
2026-05-21 14:13:32.369 UTC [972] LOG:  database system was interrupted; last known up at 2026-05-21 14:09:44 UTC
2026-05-21 14:13:32.369 UTC [975] FATAL:  the database system is in recovery mode
2026-05-21 14:13:32.399 UTC [972] LOG:  database system was not properly shut down; automatic recovery in progress
2026-05-21 14:13:32.403 UTC [972] LOG:  redo starts at 0/343C748
2026-05-21 14:13:32.404 UTC [972] LOG:  invalid record length at 0/343C830: expected at least 24, got 0
2026-05-21 14:13:32.404 UTC [972] LOG:  redo done at 0/343C7F8 system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
2026-05-21 14:13:32.410 UTC [973] LOG:  checkpoint starting: end-of-recovery immediate wait
2026-05-21 14:13:32.426 UTC [973] LOG:  checkpoint complete: wrote 3 buffers (0.0%); 0 WAL file(s) added, 0 removed, 0 recycled; write=0.005 s, sync=0.004 s, total=0.018 s; sync files=2, longest=0.003 s, average=0.002 s; distance=0 kB, estimate=0 kB; lsn=0/343C830, redo lsn=0/343C830
2026-05-21 14:13:32.430 UTC [1] LOG:  database system is ready to accept connections
```

### pkill -9 postgres postgres внутри контейнера был автоматически восстановлен
### тогда остановим весь контейнер

```sh
docker compose stop host-a
```

```
[+] stop 1/1
 ✔ Container host-a Stopped
```

```sh
docker compose ps
```

```
NAME      IMAGE                         COMMAND                  SERVICE   CREATED             STATUS          PORTS
client    postgres:16-alpine            "sleep infinity"         client    17 minutes ago      Up 17 minutes   5432/tcp
host-b    postgres:16-alpine            "docker-entrypoint.s…"   host-b    About an hour ago   Up 55 minutes   0.0.0.0:5434->5432/tcp, [::]:5434->5432/tcp
host-c    postgres:16-alpine            "docker-entrypoint.s…"   host-c    47 minutes ago      Up 11 minutes   0.0.0.0:5435->5432/tcp, [::]:5435->5432/tcp
pgpool    bitnamilegacy/pgpool:latest   "/opt/bitnami/script…"   pgpool    44 minutes ago      Up 44 minutes   0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp

```

### для переключения был выполнен promote узла host-b

```sh
docker exec host-b psql -U postgres -c "SELECT pg_promote();"
```

```
 pg_promote 
------------
 t
(1 row)
```

```sh
docker exec host-b psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
 pg_is_in_recovery 
-------------------
 f
(1 row)
```


### после promotion был перезапущен pgpool, чтобы он перечитал актуальные роли backend-узлов.

```sh
docker compose restart pgpool
```

```
[+] restart 0/1
 ⠹ Container pgpool Restarting
```

```sh 
docker logs pgpool --tail=120
```

```
2026-05-21 14:16:36.416: main pid 1: LOG:  find_primary_node: primary node is 1
2026-05-21 14:16:36.416: main pid 1: LOG:  find_primary_node: standby node is 2
2026-05-21 14:16:36.416: main pid 1: LOG:  failover: set new primary node: 1
2026-05-21 14:16:36.416: main pid 1: LOG:  failover: set new main node: 1
2026-05-21 14:16:36.422: main pid 1: LOG:  === Failover done. shutdown host host-a(5432) ===
```

### проверим прямые подключения из контейнера pgpool к host-b и host-c

```sh
docker exec -e PGPASSWORD=secret pgpool psql -U postgres -h host-b -p 5432 -c "SELECT pg_is_in_recovery();"
docker exec -e PGPASSWORD=secret pgpool psql -U postgres -h host-c -p 5432 -c "SELECT pg_is_in_recovery();"
```

```
 pg_is_in_recovery 
-------------------
 f
(1 row)

 pg_is_in_recovery 
-------------------
 t
(1 row)
```

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -c "SHOW POOL_NODES;"
```

```
 node_id | hostname | port | status | pg_status | lb_weight |  role   | pg_role | select_cnt | load_balance_node | replication_delay | replication_state | replication_sync_state | last_status_change  
---------+----------+------+--------+-----------+-----------+---------+---------+------------+-------------------+-------------------+-------------------+------------------------+---------------------
 0       | host-a   | 5432 | down   | down      | 0.333333  | standby | unknown | 0          | false             | 0                 |                   |                        | 2026-05-21 14:17:04
 1       | host-b   | 5432 | up     | up        | 0.333333  | primary | primary | 0          | true              | 0                 |                   |                        | 2026-05-21 14:19:04
 2       | host-c   | 5432 | up     | up        | 0.333333  | standby | standby | 0          | false             | 0                 |                   |                        | 2026-05-21 14:19:04
(3 rows)
```

### проверка чтения и записи после failover
в первой сессии при попытке записи был зафиксирован разрыв старого соединения:

```sql
BEGIN;
INSERT INTO articles (title, content)
VALUES ('Article After Failover', 'Inserted after host-b promotion');
INSERT INTO comments (article_id, author, body)
VALUES (6, 'AfterFailoverUser', 'Comment after failover');
COMMIT;
```

```
FATAL:  unable to read data from DB node 0
DETAIL:  EOF encountered with backend
server closed the connection unexpectedly
        This probably means the server terminated abnormally
        before or while processing the request.
The connection to the server was lost. Attempting reset: Succeeded.
INSERT 0 1
INSERT 0 1
WARNING:  there is no transaction in progress
COMMIT
```

во второй сессии при первом чтении также был зафиксирован разрыв соединения со старым узлом

```sql
SELECT id, title, content FROM articles ORDER BY id;
```

```
FATAL:  unable to read data from DB node 0
DETAIL:  EOF encountered with backend
server closed the connection unexpectedly
        This probably means the server terminated abnormally
        before or while processing the request.
The connection to the server was lost. Attempting reset: Succeeded.
```

### после failover была добавлена новая запись

```sql
INSERT INTO articles (title, content) VALUES ('Article After Failover Final', 'Inserted after failover through pgpool') RETURNING id;
```

```
 id 
----
 39
(1 row)

INSERT 0 1
```

```sql
INSERT INTO comments (article_id, author, body) VALUES (39, 'AfterFailoverUser', 'Clean comment after failover');
```

```
INSERT 0 1
```

```sql
SELECT id, title, content FROM articles WHERE title LIKE 'Article After Failover%' ORDER BY id;
```

```
 id |            title             |                 content                 
----+------------------------------+-----------------------------------------
 37 | Article After Failover       | Inserted after host-b promotion
 38 | Article After Failover OK    | Inserted after reconnect to new primary
 39 | Article After Failover Final | Inserted after failover through pgpool
(3 rows)
```

```sql
SELECT id, article_id, author, body FROM comments WHERE article_id = 39 ORDER BY id;
```

```
 id | article_id |      author       |             body             
----+------------+-------------------+------------------------------
 39 |         39 | AfterFailoverUser | Clean comment after failover
(1 row)
```

```sql
SELECT inet_server_addr(), pg_is_in_recovery();
```

```
 inet_server_addr | pg_is_in_recovery 
------------------+-------------------
 172.19.0.3       | f
(1 row)
```

### 2.3восстановление host-a как standby от host-b

```sh
docker exec host-b sh -c "grep -n 'replication.*replicator' /var/lib/postgresql/data/pg_hba.conf"
docker exec host-b psql -U postgres -c "SELECT pg_is_in_recovery();"
docker exec host-b psql -U postgres -c "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';"
```

```
131:host    replication    replicator    0.0.0.0/0    password

 pg_is_in_recovery 
-------------------
 f
(1 row)

  rolname   | rolreplication 
------------+----------------
 replicator | t
(1 row)
```

### остановим host-a и очистим его каталог данных

```
docker compose stop host-a
sudo rm -rf data/a
mkdir -p data/a
sudo chown 70:70 data/a
sudo ls -la data/a
```

```
[+] stop 1/1
 ✔ Container host-a Stopped

total 8
drwxr-xr-x 2  70  70 4096 May 21 18:23 .
drwx------ 5 rmb rmb 4096 May 21 18:23 ..
```

### создадим базовую копию с host-b для восстановления host-a

```sh
docker run --rm -it --network lab3_pgnet -e PGPASSWORD=secret -v "$PWD/data/a:/var/lib/postgresql/data" postgres:16-alpine pg_basebackup -h host-b -U replicator -D /var/lib/postgresql/data -P -R --wal-method=stream -C -S slot_a_from_b
```

```
31003/31003 kB (100%), 1/1 tablespace
```

### запустим host-a и зададим параметры подключения к host-b через alter system

```sh
docker compose up -d host-a
docker exec host-a psql -U postgres -c "alter system set primary_conninfo = 'user=replicator password=secret host=host-b application_name=standby_a';"
docker exec host-a psql -U postgres -c "alter system set primary_slot_name = 'slot_a_from_b';"
docker compose restart host-a
```

```
[+] up 1/1
 ✔ Container host-a Started

ALTER SYSTEM
ALTER SYSTEM

[+] restart 0/1
 ⠹ Container host-a Restarting
 ```


### проверим, что host-a запущен как standby от host-b

```sh
docker exec host-a pg_isready -U postgres
docker exec host-a psql -U postgres -c "SELECT pg_is_in_recovery();"
docker exec host-b psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
docker exec host-b psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

```
/var/run/postgresql:5432 - accepting connections

 pg_is_in_recovery 
-------------------
 t
(1 row)

 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_c        | streaming | async
 standby_a        | streaming | async
(2 rows)

   slot_name   | active 
---------------+--------
 slot_c        | t
 slot_a_from_b | t
(2 rows)
```

```sh
docker exec host-a psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles WHERE title LIKE 'Article After Failover%' ORDER BY id;"
docker exec host-a psql -U postgres -d illgreennews -c "SELECT id, article_id, author, body FROM comments WHERE article_id = 39 ORDER BY id;"
```

```

 id |            title             |                 content                 
----+------------------------------+-----------------------------------------
 37 | Article After Failover       | Inserted after host-b promotion
 38 | Article After Failover OK    | Inserted after reconnect to new primary
 39 | Article After Failover Final | Inserted after failover through pgpool
(3 rows)

 id | article_id |      author       |             body             
----+------------+-------------------+------------------------------
 39 |         39 | AfterFailoverUser | Clean comment after failover
(1 row)
```

```
данные, созданные после failover, появились на восстановленном host-a. это означает, что состояние базы на исходном основном узле было актуализировано
```

### возврат host-a в роль primary

после того как host-a был восстановлен из актуального состояния host-b его можно вернуть в роль основного узла. для этого был выполнен promote host-a

```sh
docker exec host-a psql -U postgres -c "SELECT pg_promote();"
```

```
 pg_promote 
------------
 t
(1 row)
```

```sh
docker exec host-a psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
 pg_is_in_recovery 
-------------------
 f
(1 row)
```

### восстановление host-b как standby от host-a

```sh
docker compose stop host-b
sudo rm -rf data/b
mkdir -p data/b
sudo chown 70:70 data/b
sudo ls -la data/b
```

```
[+] stop 1/1
 ✔ Container host-b Stopped

total 8
drwxr-xr-x 2  70  70 4096 May 21 18:27 .
drwx------ 5 rmb rmb 4096 May 21 18:27 ..
```

### создадим базовую копию с host-a

```sh
docker run --rm -it --network lab3_pgnet -e PGPASSWORD=secret -v "$PWD/data/b:/var/lib/postgresql/data" postgres:16-alpine pg_basebackup -h host-a -U replicator -D /var/lib/postgresql/data -P -R --wal-method=stream -C -S slot_b_recovered
```

```
31003/31003 kB (100%), 1/1 tablespace
```

### запустим host-b и зададим параметры подключения к host-a

```sh
docker compose up -d host-b
docker exec host-b psql -U postgres -c "alter system set primary_conninfo = 'user=replicator password=secret host=host-a application_name=standby_b';"
docker exec host-b psql -U postgres -c "alter system set primary_slot_name = 'slot_b_recovered';"
docker compose restart host-b`
```

```
[+] up 1/1
 ✔ Container host-b Started

ALTER SYSTEM
ALTER SYSTEM

[+] restart 0/1
 ⠹ Container host-b Restarting
```

### проверим, что host-b стал standby-репликой

```sh
docker exec host-b pg_isready -U postgres
docker exec host-b psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
/var/run/postgresql:5432 - accepting connections

 pg_is_in_recovery 
-------------------
 t
(1 row)
```

### проверим, что host-a видит host-b как реплику

```sh
docker exec host-a psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_b        | streaming | async
(1 row)

```

### на этом этапе репликация уже восстановлена, но она пока асинхронная

```sh
docker exec host-a psql -U postgres -c "alter system set synchronous_standby_names = 'standby_b';"
docker compose restart host-a
```

```
ALTER SYSTEM

[+] restart 0/1
 ⠹ Container host-a Restarting
```

```sh
docker exec host-a psql -U postgres -c "SHOW synchronous_standby_names;"
```

```
 synchronous_standby_names 
---------------------------
 standby_b
(1 row)
```

```sh
docker exec host-a psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_b        | streaming | sync
(1 row)
```

### восстановление host-c как standby от host-b

восстановление `host-c` выполнялось аналогично восстановлению `host-b`: старый каталог данных был очищен, после чего была создана новая базовая копия с upstream-узла.

отличие состоит в том, что для `host-c` источником репликации является не `host-a`, а `host-b`, а также сохраняется параметр задержки применения WAL:

```
recovery_min_apply_delay = '10s'
```
### очистим каталог данных host-c.
```sh
docker compose stop host-c
sudo rm -rf data/c
mkdir -p data/c
sudo chown 70:70 data/c
sudo ls -la data/c
```

```
[+] stop 1/1
 ✔ Container host-c Stopped

total 8
drwxr-xr-x 2  70  70 4096 May 21 18:33 .
drwx------ 5 rmb rmb 4096 May 21 18:33 ..
```
### создадим базовую копию с host-b.

```sh
docker run --rm -it --network lab3_pgnet -e PGPASSWORD=secret -v "$PWD/data/c:/var/lib/postgresql/data" postgres:16-alpine pg_basebackup -h host-b -U replicator -D /var/lib/postgresql/data -P -R --wal-method=stream -C -S slot_c_recovered
```

```
31004/31004 kB (100%), 1/1 tablespace
```

### запустим host-c и зададим параметры подключения к host-b

```sh
docker compose up -d host-c
docker exec host-c psql -U postgres -c "alter system set primary_conninfo = 'user=replicator password=secret host=host-b application_name=standby_c';"
docker exec host-c psql -U postgres -c "alter system set primary_slot_name = 'slot_c_recovered';"
docker exec host-c psql -U postgres -c "alter system set recovery_min_apply_delay = '10s';"
docker compose restart host-c
```

```
[+] up 1/1
 ✔ Container host-c Started

ALTER SYSTEM
ALTER SYSTEM
ALTER SYSTEM
```

### проверим, что host-c работает как standby

```sh
docker exec host-c pg_isready -U postgres
docker exec host-c psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
/var/run/postgresql:5432 - accepting connections

 pg_is_in_recovery 
-------------------
 t
(1 row)
```

### проверим, что host-b видит host-c как асинхронную реплику

```sh
docker exec host-b psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_c        | streaming | async
(1 row)
```

### проверим replication slot на host-b

```sh
docker exec host-b psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

```
    slot_name     | active 
------------------+--------
 slot_c_recovered | t
(1 row)
```

таким образом, host-c был восстановлен как асинхронная каскадная реплика host-b.

### проверим роли узлов

```
docker exec host-a psql -U postgres -c "SELECT 'host-a' AS node, pg_is_in_recovery();"
docker exec host-b psql -U postgres -c "SELECT 'host-b' AS node, pg_is_in_recovery();"
docker exec host-c psql -U postgres -c "SELECT 'host-c' AS node, pg_is_in_recovery();"
```

```
  node  | pg_is_in_recovery 
--------+-------------------
 host-a | f
(1 row)

  node  | pg_is_in_recovery 
--------+-------------------
 host-b | t
(1 row)

  node  | pg_is_in_recovery 
--------+-------------------
 host-c | t
(1 row)
```

```sh
docker exec host-a psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_b        | streaming | sync
(1 row)
```


```sh
docker exec host-b psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_c        | streaming | async
(1 row)
```

### таким образом, исходная конфигурация была восстановлена:

```
host-a — primary
host-b — synchronous standby
host-c — asynchronous standby
```

```sh
docker compose restart pgpool
```

```
[+] restart 0/1
 ⠹ Container pgpool Restarting
 ```

### проверим состояние узлов через pgpool

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -c "SHOW POOL_NODES;"
```

```
 node_id | hostname | port | status | pg_status | lb_weight |  role   | pg_role | select_cnt | load_balance_node | replication_delay | replication_state | replication_sync_state | last_status_change  
---------+----------+------+--------+-----------+-----------+---------+---------+------------+-------------------+-------------------+-------------------+------------------------+---------------------
 0       | host-a   | 5432 | up     | up        | 0.333333  | primary | primary | 0          | false             | 0                 |                   |                        | 2026-05-21 16:29:49
 1       | host-b   | 5432 | up     | up        | 0.333333  | standby | standby | 0          | true              | 0                 |                   |                        | 2026-05-21 16:29:49
 2       | host-c   | 5432 | up     | up        | 0.333333  | standby | standby | 0          | false             | 0                 |                   |                        | 2026-05-21 16:29:49
(3 rows)
```

### после восстановления была выполнена финальная запись через pgpoo

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "BEGIN; INSERT INTO articles (title, content) VALUES ('Article After Recovery', 'Inserted after full cluster recovery') RETURNING id; COMMIT;"
```

```
BEGIN
 id 
----
 40
(1 row)

INSERT 0 1
COMMIT
```

### добавим комментарий к созданной статье

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "INSERT INTO comments (article_id, author, body) VALUES (40, 'RecoveryUser', 'Comment after full recovery');"
```

```
INSERT 0 1
```

### проверим добавленную статью

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "SELECT id, title, content FROM articles WHERE id = 40;"
```

```
 id |         title          |               content                
----+------------------------+--------------------------------------
 40 | Article After Recovery | Inserted after full cluster recovery
(1 row)
```
### проверим добавленный комментарий.

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "SELECT id, article_id, author, body FROM comments WHERE article_id = 40;"
```
```
 id | article_id |    author    |            body             
----+------------+--------------+-----------------------------
 40 |         40 | RecoveryUser | Comment after full recovery
(1 row)
```
### 0проверим, что подключение через pgpool направлено на primary-узел.
```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "SELECT inet_server_addr(), pg_is_in_recovery();"
```sh

```
 inet_server_addr | pg_is_in_recovery 
------------------+-------------------
 172.19.0.5       | f
(1 row)
```

### done