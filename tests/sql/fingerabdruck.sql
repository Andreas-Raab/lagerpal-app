select
  (select md5(string_agg(x, '|' order by x)) from (
     select 'f:'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||'):'||md5(pg_get_functiondef(p.oid)) x
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind = 'f'
     union all
     select 't:'||table_name||'.'||column_name||':'||data_type
       from information_schema.columns where table_schema = 'public'
     union all
     select 'p:'||tablename||'.'||policyname from pg_policies where schemaname = 'public'
  ) s) as fingerabdruck;
