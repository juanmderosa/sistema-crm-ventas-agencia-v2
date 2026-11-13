-- Internal evidence only: complete row hashes/counts and sequence positions.
do $snapshot$
declare r record; rows_hash text; rows_count bigint; seq jsonb;
  tables jsonb := '{}'::jsonb; sequences jsonb := '{}'::jsonb;
begin
  for r in select schemaname, tablename from pg_tables
    where schemaname = 'public'
       or (schemaname = 'auth' and tablename in ('users','identities'))
    order by schemaname, tablename
  loop
    execute format('select count(*), md5(coalesce(string_agg(to_jsonb(t)::text, '
      || '''|'' order by to_jsonb(t)::text), '''')) from %I.%I t',
      r.schemaname, r.tablename) into rows_count, rows_hash;
    tables := tables || jsonb_build_object(r.schemaname || '.' || r.tablename,
      jsonb_build_array(rows_count, rows_hash));
  end loop;
  for r in select schemaname, sequencename from pg_sequences
    where schemaname in ('public','auth') order by schemaname, sequencename
  loop
    execute format('select jsonb_build_array(last_value,is_called) from %I.%I',
      r.schemaname, r.sequencename) into seq;
    sequences := sequences || jsonb_build_object(
      r.schemaname || '.' || r.sequencename, seq);
  end loop;
  perform set_config('completion_probe.state',
    jsonb_build_object('tables',tables,'sequences',sequences)::text,false);
end $snapshot$;
select current_setting('completion_probe.state');
