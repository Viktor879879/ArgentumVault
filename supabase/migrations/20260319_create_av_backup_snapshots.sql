create table if not exists public.av_backup_snapshots (
    owner_user_id uuid not null references auth.users(id) on delete cascade,
    account_bucket text not null,
    payload_base64 text not null,
    payload_hash text not null,
    schema_version integer not null default 1,
    updated_at timestamptz not null default timezone('utc', now()),
    created_at timestamptz not null default timezone('utc', now()),
    primary key (owner_user_id, account_bucket)
);

create index if not exists av_backup_snapshots_owner_updated_at_idx
    on public.av_backup_snapshots (owner_user_id, updated_at desc);

alter table public.av_backup_snapshots enable row level security;

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

grant select, insert, update, delete on public.av_backup_snapshots to authenticated;
