-- =====================================================================
-- EcoHabits · Supabase схемасы
-- Supabase → SQL Editor ішінде бір рет толық іске қос.
--
-- Негізгі идея: клиент XP мен серияны тікелей өзгерте алмайды.
-- Барлығы complete_quest() функциясы арқылы сервер жағында есептеледі.
-- =====================================================================

-- ---------- 1. profiles ----------
create table if not exists public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  username         text,
  xp               integer not null default 0 check (xp >= 0),
  streak           integer not null default 0 check (streak >= 0),
  last_active_date date,
  created_at       timestamptz not null default now(),
  constraint username_format check (username is null or username ~ '^[a-z0-9_]{3,20}$')
);

-- Ник бірегей (бос мән бірнеше болуы мүмкін: Google-мен кіріп, әлі таңдамағандар)
create unique index if not exists profiles_username_key on public.profiles (lower(username));

alter table public.profiles enable row level security;

revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (username) on public.profiles to authenticated;   -- XP/streak бағандарына жазуға болмайды

drop policy if exists profiles_select_all on public.profiles;
create policy profiles_select_all on public.profiles
  for select to authenticated using (true);

-- Ник тек әлі қойылмаған болса ғана орнатылады (бір рет)
drop policy if exists profiles_set_username_once on public.profiles;
create policy profiles_set_username_once on public.profiles
  for update to authenticated
  using (auth.uid() = id and username is null)
  with check (auth.uid() = id);

-- ---------- 2. Жаңа қолданушыға профиль ашу ----------
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
  -- ник сол сәтте басқа адамға кетіп қалса, тіркелу құламайды: ник кейін таңдалады
  insert into public.profiles (id, username) values (new.id, null)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 3. Ник бос па, тексеру (тіркелуге дейін шақырылады) ----------
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

-- ---------- 4. quest_logs ----------
create table if not exists public.quest_logs (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  quest_key   text not null,
  day         date not null default ((now() at time zone 'Asia/Almaty')::date),
  photo_hash  text not null,   -- SHA-256: дәл көшірмені ұстайды
  phash       bit(64) not null, -- dHash: өлшемі өзгерген/қайта сақталған көшірмені ұстайды
  xp_awarded  integer not null,
  created_at  timestamptz not null default now(),
  constraint quest_once_per_day unique (user_id, quest_key, day),
  constraint quest_photo_unique unique (photo_hash)
);

alter table public.quest_logs enable row level security;
revoke all on public.quest_logs from anon, authenticated;
grant select on public.quest_logs to authenticated;

drop policy if exists quest_logs_select_own on public.quest_logs;
create policy quest_logs_select_own on public.quest_logs
  for select to authenticated using (auth.uid() = user_id);

-- ---------- 5. Тапсырманы есепке алу (XP + streak сервер жағында) ----------
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
  xp_gain    constant integer := 50;
  ph         bit(64);
  prof       public.profiles;
  new_streak integer;
begin
  if uid is null then raise exception 'not_authenticated'; end if;

  if p_quest_key not in ('water_tap', 'eco_bag', 'battery', 'sorting', 'bottle', 'lights') then
    raise exception 'unknown_quest';
  end if;
  if p_photo_hash !~ '^[0-9a-f]{64}$' or p_phash !~ '^[01]{64}$' then
    raise exception 'bad_input';
  end if;
  ph := p_phash::bit(64);

  select * into prof from public.profiles where id = uid for update;
  if not found or prof.username is null then raise exception 'no_profile'; end if;

  if exists (select 1 from public.quest_logs
             where user_id = uid and quest_key = p_quest_key and day = today) then
    raise exception 'already_done';
  end if;

  -- дәл көшірме немесе өте ұқсас сурет (Хэмминг қашықтығы ≤ 6) кез келген қолданушыда болған
  if exists (select 1 from public.quest_logs
             where photo_hash = p_photo_hash or bit_count(phash # ph) <= 6) then
    raise exception 'duplicate_photo';
  end if;

  insert into public.quest_logs (user_id, quest_key, day, photo_hash, phash, xp_awarded)
  values (uid, p_quest_key, today, p_photo_hash, ph, xp_gain);

  -- серия: бүгін алғашқы тапсырма болса ғана өзгереді
  if prof.last_active_date = today then
    new_streak := prof.streak;
  elsif prof.last_active_date = today - 1 then
    new_streak := prof.streak + 1;
  else
    new_streak := 1;                -- бір тәуліктен астам үзіліс: қайта басталады
  end if;

  update public.profiles
     set xp = xp + xp_gain, streak = new_streak, last_active_date = today
   where id = uid
   returning * into prof;

  return prof;
end;
$$;

revoke all on function public.complete_quest(text, text, text) from public;
grant execute on function public.complete_quest(text, text, text) to authenticated;
