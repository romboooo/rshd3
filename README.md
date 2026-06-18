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
    command: >
      postgres
      -c config_file=/etc/postgresql/config/postgresql.conf
      -c hba_file=/etc/postgresql/config/pg_hba.conf
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
    command: >
      postgres
      -c config_file=/etc/postgresql/config/postgresql.conf
      -c hba_file=/etc/postgresql/config/pg_hba.conf
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
    command: >
      postgres
      -c config_file=/etc/postgresql/config/postgresql.conf
      -c hba_file=/etc/postgresql/config/pg_hba.conf
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

### настройка конфигурационных файлов host-a

```sh
cat > config/a/postgresql.conf <<'EOF'
listen_addresses = '*'

wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 256MB
hot_standby = on


wal_log_hints = on
EOF
```

### настроим pg_hba.conf

```sh
cat > config/a/pg_hba.conf <<'EOF'
local   all             all                                     password
host    all             all             127.0.0.1/32            password
host    all             all             ::1/128                 password
host    all             all             0.0.0.0/0               password

local   replication     all                                     password
host    replication     replicator      0.0.0.0/0               password
EOF
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
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
 pg_is_in_recovery 
-------------------
 f
(1 row)
```

### создадим юзера для репликации

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'secret';"
```

```
CREATE ROLE
```

### проверим что всё применилось

```sh 
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SHOW wal_level;"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SHOW max_wal_senders;"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SHOW max_replication_slots;"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SHOW wal_keep_size;"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT rolname, rolreplication FROM pg_roles WHERE rolname IN ('postgres', 'replicator');"
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

  rolname   | rolreplication 
------------+----------------
 postgres   | t
 replicator | t
(2 rows)
```

### настройка host-b как синхронной реплики host-a



### Подготовка host-b для каскадной репликации (не только standby но и источник потоковой репликации)

```sh
cat > config/b/postgresql.conf <<'EOF'
listen_addresses = '*'

wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 256MB
hot_standby = on

wal_log_hints = on
EOF
```

### настроим pg_hba.conf

```sh
cat > config/b/pg_hba.conf <<'EOF'
local   all             all                                     password
host    all             all             127.0.0.1/32            password
host    all             all             ::1/128                 password
host    all             all             0.0.0.0/0               password

local   replication     all                                     password
host    replication     replicator      0.0.0.0/0               password
EOF
```

#### очистка каталога данных host-b

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
    -d "host=host-a port=5432 user=replicator application_name=standby_b" \
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

### запуск host-b

```sh
docker compose start host-b
```

```
[+] start 1/1
 ✔ Container host-b Started
```

### проверка, что host-b использует вынесенные конфиги

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SHOW config_file;"
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SHOW hba_file;"
docker exec host-b sh -c "grep -n 'replication.*replicator' /etc/postgresql/config/pg_hba.conf"
```

```

              config_file               
----------------------------------------
 /etc/postgresql/config/postgresql.conf
(1 row)

              hba_file              
------------------------------------
 /etc/postgresql/config/pg_hba.conf
(1 row)

7:host    replication     replicator      0.0.0.0/0               password

```


### проверка recovery-настроек host-b

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SHOW primary_conninfo;" 
```

```
primary_conninfo                                                                                                                                                 
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 user=replicator password=secret channel_binding=prefer host='host-a' port=5432 application_name=standby_b sslmode=prefer sslcompression=0 sslcertmode=allow sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable
(1 row)
```

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SHOW primary_slot_name;"
```

```
primary_slot_name 
-------------------
 slot_b
(1 row)
```


### проверим, что host-b работает как standby

```sh
docker exec host-b pg_isready -U postgres
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
/var/run/postgresql:5432 - accepting connections
 pg_is_in_recovery 
-------------------
 t
(1 row)
```

### проверка подключения host-b к host-a до включения синхронности

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```
```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_b        | streaming | async
(1 row)

 slot_name | active 
-----------+--------
 slot_b    | t
(1 row)
```
### включим синхронную репликацию на host-a

```sh
cat >> config/a/postgresql.conf <<'EOF'

synchronous_standby_names = 'standby_b'
EOF

docker compose restart host-a
```

```
[+] restart 0/1
 ⠸ Container host-a Restarting   
```

### проверим на host-a, что standby_b работает в синхронном режиме

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SHOW synchronous_standby_names;"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

```
synchronous_standby_names 
---------------------------
 standby_b
(1 row)

 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_b        | streaming | sync
(1 row)

 slot_name | active 
-----------+--------
 slot_b    | t
(1 row)
```

### настройка host-с как асинхронной каскадной реплики host-b

### подготовка конфигурационного файла host-c

```sh
cat > config/c/postgresql.conf <<'EOF'
listen_addresses = '*'

wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 256MB
hot_standby = on

recovery_min_apply_delay = '10s'

wal_log_hints = on
EOF
```

### очистка каталога данных host-c

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
    -d "host=host-b port=5432 user=replicator application_name=standby_c" \
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

### запуск host-c

```sh
docker compose start host-c
```

```
[+] start 1/1
 ✔ Container host-c Started
```


### проверка, что host-c использует вынесенные конфиги

```sh
docker exec -e PGPASSWORD=secret host-c psql -U postgres -c "SHOW config_file;"
docker exec -e PGPASSWORD=secret host-c psql -U postgres -c "SHOW hba_file;"
docker exec host-c sh -c "grep -n 'recovery_min_apply_delay' /etc/postgresql/config/postgresql.conf"
```

```
              config_file               
----------------------------------------
 /etc/postgresql/config/postgresql.conf
(1 row)

              hba_file              
------------------------------------
 /etc/postgresql/config/pg_hba.conf
(1 row)

9:recovery_min_apply_delay = '10s'
```

### проверка recovery-настроек host-c

```sh
docker exec -e PGPASSWORD=secret host-c psql -U postgres -c "SHOW primary_conninfo;"
docker exec -e PGPASSWORD=secret host-c psql -U postgres -c "SHOW primary_slot_name;"
docker exec -e PGPASSWORD=secret host-c psql -U postgres -c "SHOW recovery_min_apply_delay;"
```

```
primary_conninfo                                                                                                                                                 
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 user=replicator password=secret channel_binding=prefer host='host-b' port=5432 application_name=standby_c sslmode=prefer sslcompression=0 sslcertmode=allow sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable
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
docker exec -e PGPASSWORD=secret host-c psql -U postgres -c "SELECT pg_is_in_recovery();"
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
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_c        | streaming | async
(1 row)
```


### проверим replication slot на host-b

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

```
slot_name | active 
-----------+--------
 slot_c    | t
(1 row)
```

### готово! репликация настроена

```
host-a -> host-b (синхронный) 
host-a -> host-c (асинхронный delay=10)
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

### проверка запущенных контейнеров

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

### тест подключения к pgpool

```sh
docker exec -e PGPASSWORD=secret pgpool psql -U postgres -h localhost -p 5432 -c "SELECT 1;"
```

```
 ?column? 
----------
        1
(1 row)
```

### проверка узлов через pgpool

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
docker exec -e PGPASSWORD=secret  host-a psql -U postgres -d illgreennews -c "SELECT * FROM articles ORDER BY id;"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -d illgreennews -c "SELECT * FROM comments ORDER BY id;"
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
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "SELECT * FROM articles ORDER BY id;"
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "SELECT * FROM comments ORDER BY id;"
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
docker exec -e PGPASSWORD=secret host-c psql -U postgres -d illgreennews -c "SELECT * FROM articles ORDER BY id;"
docker exec- e PGPASSWORD=secret host-c psql -U postgres -d illgreennews -c "SELECT * FROM comments ORDER BY id;"
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
docker exec -e PGPASSWORD=secret host-a psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
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
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
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
docker exec -e PGPASSWORD=secret host-c psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
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
docker exec -e PGPASSWORD=secret  host-c psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
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

  session  | pg_backend_pid | inet_server_addr | pg_is_in_recovery 
-----------+----------------+------------------+-------------------
 session_1 |            777 | 172.19.0.5       | f
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
 session_2 |            807 | 172.19.0.5       | f
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
docker kill --signal=KILL host-a
```

```
host-a
```

```sh
docker compose ps
```

```
NAME      IMAGE                         COMMAND                  SERVICE   CREATED       STATUS          PORTS
client    postgres:16-alpine            "sleep infinity"         client    2 hours ago   Up 52 minutes   5432/tcp
host-b    postgres:16-alpine            "docker-entrypoint.s…"   host-b    6 days ago    Up 58 minutes   0.0.0.0:5434->5432/tcp, [::]:5434->5432/tcp
host-c    postgres:16-alpine            "docker-entrypoint.s…"   host-c    6 days ago    Up 58 minutes   0.0.0.0:5435->5432/tcp, [::]:5435->5432/tcp
pgpool    bitnamilegacy/pgpool:latest   "/opt/bitnami/script…"   pgpool    2 hours ago   Up 58 minutes   0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp
```

### 2.3 Обработка

### зафиксируем состояние после фейловера

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c " 
INSERT INTO articles (title, content)
VALUES ('Article After Failover', 'Inserted after promotion of host-b');
"
```

```
INSERT 0 1
```

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
```

```
id |          title          |              content               
----+-------------------------+------------------------------------
  1 | Article X               | Text X
  2 | Article Y               | Text Y
  3 | Article Z               | Text Z
  4 | Article Delay Test      | Appears on C after delay
  5 | Article Before Failover | Inserted before primary failure
 38 | Article After Failover  | Inserted after promotion of host-b
(6 rows)
```

```sh
sleep 10
docker exec -e PGPASSWORD=secret host-c psql -U postgres -d illgreennews -c "SELECT id, title, content FROM articles ORDER BY id;"
```

```
id |          title          |              content               
----+-------------------------+------------------------------------
  1 | Article X               | Text X
  2 | Article Y               | Text Y
  3 | Article Z               | Text Z
  4 | Article Delay Test      | Appears on C after delay
  5 | Article Before Failover | Inserted before primary failure
 38 | Article After Failover  | Inserted after promotion of host-b
(6 rows)
```


### проверяем что pgpool увидел failover правильно

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "SHOW POOL_NODES;"
```

```
 node_id | hostname | port | status | pg_status | lb_weight |  role   | pg_role | select_cnt | load_balance_node | replication_delay | replication_state | replication_sync_state | last_status_change  
---------+----------+------+--------+-----------+-----------+---------+---------+------------+-------------------+-------------------+-------------------+------------------------+---------------------
 0       | host-a   | 5432 | down   | up        | 0.333333  | standby | primary | 3          | false             | 0                 |                   |                        | 2026-06-17 17:46:51
 1       | host-b   | 5432 | up     | up        | 0.333333  | primary | primary | 0          | true              | 0                 |                   |                        | 2026-06-17 17:46:51
 2       | host-c   | 5432 | up     | up        | 0.333333  | standby | standby | 5          | false             | 0                 |                   |                        | 2026-06-17 13:47:15
(3 rows)
```

### перед pg_rewind создадим на host-b replication slot для временной реплики host-a

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "
DO 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_replication_slots WHERE slot_name = 'slot_a'
    ) THEN
        PERFORM pg_create_physical_replication_slot('slot_a');
    END IF;
END;
"
```

```
DO
```

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

```
slot_name | active 
-----------+--------
 slot_c    | t
 slot_a    | f
(2 rows)
```

### сделаем pg_rewind 

```sh
docker run --rm -it                                                                         
  --network lab3_pgnet \
  --user 70:70 \
  -e PGPASSWORD=secret \
  -v "$PWD/data/a:/var/lib/postgresql/data" \
  postgres:16-alpine \
  pg_rewind \
    --target-pgdata=/var/lib/postgresql/data \
    --source-server="host=host-b port=5432 user=postgres password=secret dbname=postgres"
```

```
pg_rewind: servers diverged at WAL location 0/843E8B0 on timeline 1
pg_rewind: rewinding from last common checkpoint at 0/843E800 on timeline 1
pg_rewind: Done!
```

### создадим standby.signal

```sh
sudo touch data/a/standby.signal
```

### конфигурация a
```sh
sudo tee data/a/postgresql.auto.conf > /dev/null <<'EOF'
primary_conninfo = 'user=replicator password=secret host=host-b port=5432 application_name=standby_a'
primary_slot_name = 'slot_a'
EOF
```

```sh
sudo chown 70:70 data/a/standby.signal data/a/postgresql.auto.conf
```

### поднимем узел

```sh
docker compose start host-a      
```

```
✔ Container host-a Started   
```

### проверим что всё ок

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT pg_is_in_recovery();"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SHOW primary_conninfo;"
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SHOW primary_slot_name;"
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 pg_is_in_recovery 
-------------------
 t
(1 row)

                                 primary_conninfo                                 
----------------------------------------------------------------------------------
 user=replicator password=secret host=host-b port=5432 application_name=standby_a
(1 row)

 primary_slot_name 
-------------------
 slot_a
(1 row)
application_name |   state   | sync_state 
------------------+-----------+------------
 standby_c        | streaming | async
 standby_a        | streaming | async
(2 rows)
```

### сделаем чекпоинт перед восстановлением

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "CHECKPOINT;"
```

```
CHECKPOINT
```

### переведи host-b в read-only:

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "ALTER DATABASE illgreennews SET default_transaction_read_only = on;"
```
```
ALTER DATABASE
```

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "SHOW default_transaction_read_only;"
```

```
 default_transaction_read_only 
-------------------------------
 on
(1 row)
```

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "SELECT id, title FROM articles ORDER BY id;"
```

```
 id |          title          
----+-------------------------
  1 | Article X
  2 | Article Y
  3 | Article Z
  4 | Article Delay Test
  5 | Article Before Failover
 38 | Article After Failover
(6 rows)
```

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "INSERT INTO articles (title, content) VALUES ('Blocked Write Test', 'Should not be inserted');"
```

```
ERROR:  cannot execute INSERT in a read-only transaction
```

### проверим что a догнал b


```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SELECT application_name, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"
```

```
application_name |   state   | sync_state | sent_lsn  | write_lsn | flush_lsn | replay_lsn 
------------------+-----------+------------+-----------+-----------+-----------+------------
 standby_c        | streaming | async      | 0/8449640 | 0/8449640 | 0/8449640 | 0/8449640
 standby_a        | streaming | async      | 0/8449640 | 0/8449640 | 0/8449640 | 0/8449640
(2 rows)
```

### остановим текущий primary host-b перед обратным переключением

Так как `host-a` уже догнал `host-b`, а запись на `host-b` заблокирована, останавливаем текущий primary. Это нужно, чтобы при promotion `host-a` не получить два primary-узла одновременно.

```sh
docker compose stop host-b
```

```
[+] stop 1/1
 ✔ Container host-b Stopped
```

```sh
docker compose ps -a
```

```
NAME      IMAGE                         COMMAND                  SERVICE   CREATED       STATUS                     PORTS
client    postgres:16-alpine            "sleep infinity"         client    6 hours ago   Up 5 hours                 5432/tcp
host-a    postgres:16-alpine            "docker-entrypoint.s…"   host-a    6 days ago    Up 33 minutes              0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp
host-b    postgres:16-alpine            "docker-entrypoint.s…"   host-b    6 days ago    Exited (0) 2 seconds ago   
host-c    postgres:16-alpine            "docker-entrypoint.s…"   host-c    6 days ago    Up 5 hours                 0.0.0.0:5435->5432/tcp, [::]:5435->5432/tcp
pgpool    bitnamilegacy/pgpool:latest   "/opt/bitnami/script…"   pgpool    6 hours ago   Up 5 hours                 0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp
```

### promote host-a

После остановки `host-b` повышаем `host-a` до primary.

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT pg_promote();"
```

```
 pg_promote 
------------
 t
(1 row)
```

Проверим, что `host-a` больше не находится в recovery-режиме.

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
 pg_is_in_recovery 
-------------------
 f
(1 row)
```

Теперь `host-a` снова является primary.

### создадим replication slot для host-b на новом primary host-a

Перед возвратом `host-b` в режим standby создадим на `host-a` слот `slot_b`.

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_replication_slots WHERE slot_name = 'slot_b'
    ) THEN
        PERFORM pg_create_physical_replication_slot('slot_b');
    END IF;
END
\$\$;
"
```

```
DO
```

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

```
 slot_name | active 
-----------+--------
 slot_b    | f
(1 row)
```

Слот неактивен, потому что `host-b` ещё не запущен.

### сделаем pg_rewind для host-b от нового primary host-a

Теперь приводим каталог данных `host-b` к WAL-истории нового primary `host-a`.

```sh
docker run --rm -it \
  --network lab3_pgnet \
  --user 70:70 \
  -e PGPASSWORD=secret \
  -v "$PWD/data/b:/var/lib/postgresql/data" \
  postgres:16-alpine \
  pg_rewind \
    --target-pgdata=/var/lib/postgresql/data \
    --source-server="host=host-a port=5432 user=postgres password=secret dbname=postgres"
```

```
pg_rewind: servers diverged at WAL location 0/84496B8 on timeline 2
pg_rewind: no rewind required
```

В данном случае физическое перематывание не потребовалось, так как `host-b` был остановлен после блокировки записи и после того, как `host-a` успел догнать его состояние.

### настроим host-b как standby от host-a

Создадим `standby.signal`, чтобы при следующем запуске PostgreSQL на `host-b` стартовал в режиме standby.

```sh
sudo touch data/b/standby.signal
```

Пропишем подключение к новому primary `host-a`.

```sh
sudo tee data/b/postgresql.auto.conf > /dev/null <<'EOF'
primary_conninfo = 'user=replicator password=secret host=host-a port=5432 application_name=standby_b'
primary_slot_name = 'slot_b'
EOF
```

Выставим владельца файлов.

```sh
sudo chown 70:70 data/b/standby.signal data/b/postgresql.auto.conf
```

### поднимем host-b

```sh
docker compose start host-b
```

```
[+] start 1/1
 ✔ Container host-b Started
```

Проверим, что `host-b` поднялся как standby.

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
 pg_is_in_recovery 
-------------------
 t
(1 row)
```

Проверим на `host-a`, что `host-b` подключился как синхронная реплика.

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_b        | streaming | sync
(1 row)
```

### проверим host-c

Проверим, что `host-c` остался standby.

```sh
docker exec -e PGPASSWORD=secret host-c psql -U postgres -c "SELECT pg_is_in_recovery();"
```

```
 pg_is_in_recovery 
-------------------
 t
(1 row)
```

Проверим, что `host-c` подключился к `host-b` как каскадная асинхронная реплика.

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_c        | streaming | async
(1 row)
```


### снимем read-only с базы illgreennews

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -d postgres -c "ALTER DATABASE illgreennews RESET default_transaction_read_only;"
```

```
ALTER DATABASE
```

### проверим, что read-only отключён.

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -d illgreennews -c "SHOW default_transaction_read_only;"
```

```
 default_transaction_read_only 
-------------------------------
 off
(1 row)
```

### проверим запись на восстановленном primary host-a

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -d illgreennews -c "
INSERT INTO articles (title, content)
VALUES ('Article After Recovery', 'Inserted after returning original topology');
"
```

```
INSERT 0 1
```

### проверим данные на `host-a`.

```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -d illgreennews -c "SELECT id, title FROM articles ORDER BY id;"
```

```
 id |          title          
----+-------------------------
  1 | Article X
  2 | Article Y
  3 | Article Z
  4 | Article Delay Test
  5 | Article Before Failover
 38 | Article After Failover
 71 | Article After Recovery
(7 rows)
```

### проверим, что запись дошла до `host-b`.

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "SELECT id, title FROM articles ORDER BY id;"
```

```
 id |          title          
----+-------------------------
  1 | Article X
  2 | Article Y
  3 | Article Z
  4 | Article Delay Test
  5 | Article Before Failover
 38 | Article After Failover
 71 | Article After Recovery
(7 rows)
```

### проверим, что запись дошла до `host-c`.

```sh
sleep 10; docker exec -e PGPASSWORD=secret host-c psql -U postgres -d illgreennews -c "SELECT id, title FROM articles ORDER BY id;"
```

```
 id |          title          
----+-------------------------
  1 | Article X
  2 | Article Y
  3 | Article Z
  4 | Article Delay Test
  5 | Article Before Failover
 38 | Article After Failover
 71 | Article After Recovery
(7 rows)
```

### обновим состояние pgpool

После обратного переключения перезапустим `pgpool`, чтобы он заново определил роли узлов.

```sh
docker compose restart pgpool
```

### проверим состояние узлов через `pgpool`.

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "SHOW POOL_NODES;"
```

```
 node_id | hostname | port | status | pg_status | lb_weight |  role   | pg_role | select_cnt | load_balance_node | replication_delay | replication_state | replication_sync_state | last_status_change  
---------+----------+------+--------+-----------+-----------+---------+---------+------------+-------------------+-------------------+-------------------+------------------------+---------------------
 0       | host-a   | 5432 | up     | up        | 0.333333  | primary | primary | 0          | true              | 0                 |                   |                        | 2026-06-17 18:53:23
 1       | host-b   | 5432 | up     | up        | 0.333333  | standby | standby | 0          | false             | 0                 |                   |                        | 2026-06-17 18:53:23
 2       | host-c   | 5432 | up     | up        | 0.333333  | standby | standby | 0          | false             | 0                 |                   |                        | 2026-06-17 18:53:23
(3 rows)
```


### финальная проверка записи через pgpool


```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "
INSERT INTO articles (title, content)
VALUES ('Article Through Pgpool After Recovery', 'Inserted through pgpool after full recovery');
"
```

```
INSERT 0 1
```

### проверим данные через `pgpool`.

```sh
docker exec -e PGPASSWORD=secret client psql -h pgpool -p 5432 -U postgres -d illgreennews -c "SELECT id, title FROM articles ORDER BY id;"
```

```
 id |                 title                 
----+---------------------------------------
  1 | Article X
  2 | Article Y
  3 | Article Z
  4 | Article Delay Test
  5 | Article Before Failover
 38 | Article After Failover
 71 | Article After Recovery
 72 | Article Through Pgpool After Recovery
(8 rows)
```

### проверим, что запись дошла до `host-b`.

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -d illgreennews -c "SELECT id, title FROM articles ORDER BY id;"
```

```
 id |                 title                 
----+---------------------------------------
  1 | Article X
  2 | Article Y
  3 | Article Z
  4 | Article Delay Test
  5 | Article Before Failover
 38 | Article After Failover
 71 | Article After Recovery
 72 | Article Through Pgpool After Recovery
(8 rows)
```

### проверим, что запись дошла до `host-c`.

```sh
sleep 10; docker exec -e PGPASSWORD=secret host-c psql -U postgres -d illgreennews -c "SELECT id, title FROM articles ORDER BY id;"
```

```
 id |                 title                 
----+---------------------------------------
  1 | Article X
  2 | Article Y
  3 | Article Z
  4 | Article Delay Test
  5 | Article Before Failover
 38 | Article After Failover
 71 | Article After Recovery
 72 | Article Through Pgpool After Recovery
(8 rows)
```

### финальная проверка репликации


```sh
docker exec -e PGPASSWORD=secret host-a psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_b        | streaming | sync
(1 row)
```

### проверим каскадную асинхронную репликацию `host-c` от `host-b`.

```sh
docker exec -e PGPASSWORD=secret host-b psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

```
 application_name |   state   | sync_state 
------------------+-----------+------------
 standby_c        | streaming | async
(1 row)
```

```
host-a -> host-b -> host-c
```

### Вывод

```
В ходе лабораторной работы была настроена репликация на трех узлах в каскадном режиме. Установлено клиентское соединение, симулирован сбой а также восстановление системы
```