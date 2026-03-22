alter table public.av_backup_snapshots enable row level security;
alter table public.av_backup_snapshots force row level security;

revoke all on public.av_backup_snapshots from public;
revoke all on public.av_backup_snapshots from anon;
grant select, insert, update, delete on public.av_backup_snapshots to authenticated;

do $$
begin
    alter table public.av_backup_snapshots
        add constraint av_backup_snapshots_account_bucket_format_chk
        check (account_bucket ~ '^[0-9a-f]{24}$');
exception
    when duplicate_object then null;
end
$$;

do $$
begin
    alter table public.av_backup_snapshots
        add constraint av_backup_snapshots_payload_hash_format_chk
        check (payload_hash ~ '^[0-9a-f]{64}$');
exception
    when duplicate_object then null;
end
$$;

do $$
begin
    alter table public.av_backup_snapshots
        add constraint av_backup_snapshots_payload_base64_non_empty_chk
        check (length(trim(payload_base64)) > 0);
exception
    when duplicate_object then null;
end
$$;

create or replace function public.av_backup_snapshots_enforce_owner()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_auth_uid uuid := auth.uid();
begin
    if v_auth_uid is null then
        raise exception 'Authentication required for backup snapshot writes.';
    end if;

    new.owner_user_id := v_auth_uid;
    new.account_bucket := lower(trim(new.account_bucket));
    new.payload_hash := lower(trim(new.payload_hash));
    new.schema_version := greatest(coalesce(new.schema_version, 1), 1);
    new.updated_at := timezone('utc', now());

    if tg_op = 'INSERT' then
        new.created_at := timezone('utc', now());
    else
        new.created_at := old.created_at;
    end if;

    if new.account_bucket !~ '^[0-9a-f]{24}$' then
        raise exception 'Backup account bucket format is invalid.';
    end if;

    if new.payload_hash !~ '^[0-9a-f]{64}$' then
        raise exception 'Backup payload hash format is invalid.';
    end if;

    if length(trim(new.payload_base64)) = 0 then
        raise exception 'Backup payload must not be empty.';
    end if;

    return new;
end;
$$;

drop trigger if exists av_backup_snapshots_enforce_owner_before_write on public.av_backup_snapshots;
create trigger av_backup_snapshots_enforce_owner_before_write
    before insert or update
    on public.av_backup_snapshots
    for each row
    execute function public.av_backup_snapshots_enforce_owner();

drop policy if exists "Users can read own backup snapshots" on public.av_backup_snapshots;
create policy "Users can read own backup snapshots"
    on public.av_backup_snapshots
    for select
    to authenticated
    using (auth.uid() = owner_user_id);

drop policy if exists "Users can insert own backup snapshots" on public.av_backup_snapshots;
create policy "Users can insert own backup snapshots"
    on public.av_backup_snapshots
    for insert
    to authenticated
    with check (auth.uid() = owner_user_id);

drop policy if exists "Users can update own backup snapshots" on public.av_backup_snapshots;
create policy "Users can update own backup snapshots"
    on public.av_backup_snapshots
    for update
    to authenticated
    using (auth.uid() = owner_user_id)
    with check (auth.uid() = owner_user_id);

drop policy if exists "Users can delete own backup snapshots" on public.av_backup_snapshots;
create policy "Users can delete own backup snapshots"
    on public.av_backup_snapshots
    for delete
    to authenticated
    using (auth.uid() = owner_user_id);

update storage.buckets
set public = false
where id in (
    'backup',
    'backups',
    'snapshot',
    'snapshots',
    'argentumvault-backups',
    'argentumvault-snapshots',
    'av-backups',
    'av-snapshots'
);
