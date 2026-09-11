failed_id="$1"
failed_host="$2"
new_main_id="$3"
new_main_host="$4"

psql=/opt/bitnami/postgresql/bin/psql
export PGPASSWORD="${PGPOOL_POSTGRES_PASSWORD:-secret}"

echo "failover: упал узел $failed_id ($failed_host), кандидат $new_main_id ($new_main_host)"

if [ "$failed_host" != "host-a" ]; then
  echo "failover: упал не host-a, повышение не выполняю"
  exit 0
fi

if [ "$new_main_host" = "host-c" ] || [ "$new_main_id" = "2" ]; then
  echo "failover: host-c не повышаем "
  exit 1
fi

if [ "$new_main_host" != "host-b" ] && [ "$new_main_id" != "1" ]; then
  echo "failover: ожидался host-b, но pgpool выбрал другой узел"
  exit 1
fi

in_recovery=$(
  "$psql" -h host-b -p 5432 -U postgres -d postgres -At \
    -c "select pg_is_in_recovery();" 2>&1
)

if [ "$in_recovery" = "f" ]; then
  echo "failover: host-b уже primary"
  exit 0
fi

if [ "$in_recovery" != "t" ]; then
  echo "failover: не удалось проверить состояние host-b: $in_recovery"
  exit 1
fi

echo "failover: повышаю host-b"
promote_result=$(
  "$psql" -h host-b -p 5432 -U postgres -d postgres -At \
    -c "select pg_promote();" 2>&1
)

if [ "$promote_result" != "t" ]; then
  echo "failover: pg_promote завершился ошибкой: $promote_result"
  exit 1
fi

after_promote=$(
  "$psql" -h host-b -p 5432 -U postgres -d postgres -At \
    -c "select pg_is_in_recovery();" 2>&1
)

if [ "$after_promote" = "f" ]; then
  echo "failover: host-b стал primary"
  exit 0
fi

echo "failover: host-b не стал primary: $after_promote"
exit 1
