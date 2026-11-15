create table if not exists public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  username         text,
  xp               integer not null default 0 check (xp >= 0),
  streak           integer not null default 0 check (streak >= 0),
  last_active_date date,
  created_at       timestamptz not null default now(),
  constraint username_format check (username is null or username ~ '^[a-z0-9_]{3,20}$')
);

create unique index if not exists profiles_username_key on public.profiles (lower(username));

alter table public.profiles enable row level security;

revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (username) on public.profiles to authenticated;

drop policy if exists profiles_select_all on public.profiles;
create policy profiles_select_all on public.profiles
  for select to authenticated using (true);

drop policy if exists profiles_set_username_once on public.profiles;
create policy profiles_set_username_once on public.profiles
  for update to authenticated
  using (auth.uid() = id and username is null)
  with check (auth.uid() = id);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  u text := lower(nullif(trim(new.raw_user_meta_data ->> 'username'), ''));
begin
  if u is not null and u !~ '^[a-z0-9_]{3,20}$' then
    u := null;
  end if;
  insert into public.profiles (id, username) values (new.id, u);
  return new;
exception when unique_violation then
  insert into public.profiles (id, username) values (new.id, null)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.username_available(p text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select p ~ '^[a-z0-9_]{3,20}$'
     and not exists (select 1 from public.profiles where lower(username) = lower(p));
$$;

revoke all on function public.username_available(text) from public;
grant execute on function public.username_available(text) to anon, authenticated;

create table if not exists public.quest_defs (
  key    text primary key,
  period text not null check (period in ('day', 'week', 'month')),
  xp     integer not null check (xp > 0)
);

alter table public.quest_defs enable row level security;
revoke all on public.quest_defs from anon, authenticated;

insert into public.quest_defs (key, period, xp) values
  ('water_tap',     'day',   50),
  ('eco_bag',       'day',   50),
  ('battery',       'day',   50),
  ('sorting',       'day',   50),
  ('bottle',        'day',   50),
  ('lights',        'day',   50),
  ('w_transport',   'week',  150),
  ('w_plant',       'week',  150),
  ('w_cleanup',     'week',  150),
  ('m_tree',        'month', 400),
  ('m_secondhand',  'month', 400),
  ('m_cleanup_big', 'month', 400)
on conflict (key) do update set period = excluded.period, xp = excluded.xp;

create table if not exists public.quest_logs (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users (id) on delete cascade,
  quest_key    text not null,
  day          date not null default ((now() at time zone 'Asia/Almaty')::date),
  period_start date,
  photo_hash   text not null,
  phash        bit(64) not null,
  xp_awarded   integer not null,
  created_at   timestamptz not null default now(),
  constraint quest_photo_unique unique (photo_hash)
);

alter table public.quest_logs add column if not exists period_start date;
update public.quest_logs set period_start = day where period_start is null;
alter table public.quest_logs alter column period_start set not null;

alter table public.quest_logs drop constraint if exists quest_once_per_day;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'quest_once_per_period') then
    alter table public.quest_logs
      add constraint quest_once_per_period unique (user_id, quest_key, period_start);
  end if;
end $$;

alter table public.quest_logs enable row level security;
revoke all on public.quest_logs from anon, authenticated;
grant select on public.quest_logs to authenticated;

drop policy if exists quest_logs_select_own on public.quest_logs;
create policy quest_logs_select_own on public.quest_logs
  for select to authenticated using (auth.uid() = user_id);

create or replace function public.complete_quest(
  p_quest_key  text,
  p_photo_hash text,
  p_phash      text
)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  uid        uuid := auth.uid();
  today      date := (now() at time zone 'Asia/Almaty')::date;
  def        public.quest_defs;
  pstart     date;
  ph         bit(64);
  prof       public.profiles;
  new_streak integer;
begin
  if uid is null then raise exception 'not_authenticated'; end if;

  select * into def from public.quest_defs where key = p_quest_key;
  if not found then raise exception 'unknown_quest'; end if;

  if p_photo_hash !~ '^[0-9a-f]{64}$' or p_phash !~ '^[01]{64}$' then
    raise exception 'bad_input';
  end if;
  ph := p_phash::bit(64);

  pstart := case def.period
    when 'day'   then today
    when 'week'  then date_trunc('week',  today::timestamp)::date
    else              date_trunc('month', today::timestamp)::date
  end;

  select * into prof from public.profiles where id = uid for update;
  if not found or prof.username is null then raise exception 'no_profile'; end if;

  if exists (select 1 from public.quest_logs
             where user_id = uid and quest_key = p_quest_key and period_start = pstart) then
    raise exception 'already_done';
  end if;

  if exists (select 1 from public.quest_logs
             where photo_hash = p_photo_hash or bit_count(phash # ph) <= 6) then
    raise exception 'duplicate_photo';
  end if;

  insert into public.quest_logs (user_id, quest_key, day, period_start, photo_hash, phash, xp_awarded)
  values (uid, p_quest_key, today, pstart, p_photo_hash, ph, def.xp);

  if prof.last_active_date = today then
    new_streak := prof.streak;
  elsif prof.last_active_date = today - 1 then
    new_streak := prof.streak + 1;
  else
    new_streak := 1;
  end if;

  update public.profiles
     set xp = xp + def.xp, streak = new_streak, last_active_date = today
   where id = uid
   returning * into prof;

  return prof;
end;
$$;

revoke all on function public.complete_quest(text, text, text) from public;
grant execute on function public.complete_quest(text, text, text) to authenticated;

create or replace function public.ensure_profile()
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into public.profiles (id) values (auth.uid()) on conflict (id) do nothing;
  select * into p from public.profiles where id = auth.uid();
  return p;
end;
$$;

revoke all on function public.ensure_profile() from public;
grant execute on function public.ensure_profile() to authenticated;
