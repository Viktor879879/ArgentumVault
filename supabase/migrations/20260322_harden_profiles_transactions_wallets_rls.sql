do $$
declare
    v_table_name text;
    v_owner_column text;
    v_policy record;
begin
    foreach v_table_name in array array['profiles', 'transactions', 'wallets'] loop
        if to_regclass(format('public.%I', v_table_name)) is null then
            continue;
        end if;

        if exists (
            select 1
            from information_schema.columns
            where table_schema = 'public'
              and table_name = v_table_name
              and column_name = 'owner_user_id'
        ) then
            v_owner_column := 'owner_user_id';
        elsif exists (
            select 1
            from information_schema.columns
            where table_schema = 'public'
              and table_name = v_table_name
              and column_name = 'user_id'
        ) then
            v_owner_column := 'user_id';
        else
            raise exception 'public.% must have user_id or owner_user_id for user-scoped RLS hardening.', v_table_name;
        end if;

        execute format('alter table public.%I enable row level security', v_table_name);
        execute format('alter table public.%I force row level security', v_table_name);

        execute format('revoke all on public.%I from public', v_table_name);
        execute format('revoke all on public.%I from anon', v_table_name);
        execute format('revoke all on public.%I from authenticated', v_table_name);
        execute format('grant select, insert, update, delete on public.%I to authenticated', v_table_name);

        for v_policy in
            select pol.polname
            from pg_policy as pol
            join pg_class as cls
              on cls.oid = pol.polrelid
            join pg_namespace as nsp
              on nsp.oid = cls.relnamespace
            where nsp.nspname = 'public'
              and cls.relname = v_table_name
        loop
            execute format('drop policy if exists %I on public.%I', v_policy.polname, v_table_name);
        end loop;

        execute format(
            'create policy %I on public.%I for select to authenticated using (auth.uid() = %I)',
            v_table_name || '_select_own',
            v_table_name,
            v_owner_column
        );

        execute format(
            'create policy %I on public.%I for insert to authenticated with check (auth.uid() = %I)',
            v_table_name || '_insert_own',
            v_table_name,
            v_owner_column
        );

        execute format(
            'create policy %I on public.%I for update to authenticated using (auth.uid() = %I) with check (auth.uid() = %I)',
            v_table_name || '_update_own',
            v_table_name,
            v_owner_column,
            v_owner_column
        );

        execute format(
            'create policy %I on public.%I for delete to authenticated using (auth.uid() = %I)',
            v_table_name || '_delete_own',
            v_table_name,
            v_owner_column
        );
    end loop;
end
$$;
