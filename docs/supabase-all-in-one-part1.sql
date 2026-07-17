-- ============================================================================
-- AI 虚拟手机 · Supabase 初始化脚本（上篇，共两篇）
--
-- 手机端复制超长文件容易被截断，因此把 docs/supabase-all-in-one.sql 拆成
-- 两篇，先跑本篇、再跑下篇（docs/supabase-all-in-one-part2.sql）即可建齐
-- 全部可选云端功能。本篇包含：
--   1. 账号 / 激活码 / 会话        （docs/account-supabase.sql）
--   2. 成年审核 + 审核图片桶       （docs/verify-supabase.sql，说明见 docs/verify-setup.md）
--   3. 便签墙                      （docs/notewall-supabase.sql）
--   4. 游戏大厅                    （docs/game-hall-supabase.sql）
--
-- 全部语句均为幂等写法，重复执行不会报错、不会破坏已有数据。
-- 执行完请核对文件末尾一行是 "-- ===== 上篇结束 ====="，缺了说明复制被截断。
-- ============================================================================


-- ============================================================================
-- >>> docs/account-supabase.sql
-- ============================================================================

-- Account, activation code, and session foundation.
-- Run this in Supabase SQL Editor before enabling account login.

create table if not exists public.app_users (
  id text primary key,
  username text not null unique,
  password_hash text not null,
  display_name text not null,
  status text not null default 'active',
  activated_at timestamptz,
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_users_username_check check (username ~ '^[A-Za-z0-9_@.-]{3,40}$'),
  constraint app_users_status_check check (status in ('active', 'disabled'))
);

create table if not exists public.activation_codes (
  code text primary key,
  label text,
  status text not null default 'active',
  max_uses integer not null default 1,
  used_count integer not null default 0,
  last_used_by text references public.app_users(id) on delete set null,
  last_used_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint activation_codes_status_check check (status in ('active', 'disabled')),
  constraint activation_codes_max_uses_check check (max_uses >= 1),
  constraint activation_codes_used_count_check check (used_count >= 0)
);

create table if not exists public.app_sessions (
  token_hash text primary key,
  user_id text not null references public.app_users(id) on delete cascade,
  user_agent text,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index if not exists app_sessions_user_idx
  on public.app_sessions (user_id, expires_at desc);

create index if not exists app_sessions_expires_idx
  on public.app_sessions (expires_at);

alter table public.app_users enable row level security;
alter table public.activation_codes enable row level security;
alter table public.app_sessions enable row level security;

-- These tables are written through Next.js API routes with the service role key.
-- Do not grant anon insert/update permissions here.

-- Atomic registration: claim an activation code and create the account in one
-- transaction. The activation code row is locked (FOR UPDATE) so two concurrent
-- first-time registrations with the same code cannot both succeed past max_uses.
create or replace function public.app_register_account(
  p_id text,
  p_username text,
  p_password_hash text,
  p_display_name text,
  p_code text
)
returns public.app_users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code public.activation_codes;
  v_user public.app_users;
  v_now timestamptz := now();
begin
  -- Serialize concurrent claims of the same code.
  select * into v_code
  from public.activation_codes
  where code = p_code
  for update;

  if not found then
    raise exception 'activation_code_not_found';
  end if;
  if v_code.status <> 'active' then
    raise exception 'activation_code_disabled';
  end if;
  if v_code.expires_at is not null and v_code.expires_at <= v_now then
    raise exception 'activation_code_expired';
  end if;
  if v_code.used_count >= v_code.max_uses then
    raise exception 'activation_code_exhausted';
  end if;

  if exists (select 1 from public.app_users where username = p_username) then
    raise exception 'username_taken';
  end if;

  insert into public.app_users
    (id, username, password_hash, display_name, status, activated_at, last_login_at, created_at, updated_at)
  values
    (p_id, p_username, p_password_hash, coalesce(nullif(p_display_name, ''), p_username),
     'active', v_now, v_now, v_now, v_now)
  returning * into v_user;

  update public.activation_codes
  set used_count = used_count + 1,
      last_used_by = p_id,
      last_used_at = v_now,
      updated_at = v_now
  where code = p_code;

  return v_user;
end;
$$;

-- Example activation code. Change this before public release.
-- insert into public.activation_codes (code, label, max_uses)
-- values ('CHANGE_ME', 'internal test', 20)
-- on conflict (code) do update
-- set label = excluded.label,
--     max_uses = excluded.max_uses,
--     status = 'active',
--     updated_at = now();


-- ============================================================================
-- >>> docs/verify-supabase.sql
-- ============================================================================

-- 成年审核 · 激活码自助申请
-- 在 Supabase SQL Editor 中执行一次。
-- 依赖：docs/account-supabase.sql（activation_codes 表）已执行。

create table if not exists public.verification_requests (
  id uuid primary key default gen_random_uuid(),
  query_code text not null unique,
  contact text not null,
  image_path text,
  status text not null default 'pending',
  activation_code text,
  note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  constraint verification_requests_status_check check (status in ('pending', 'approved', 'rejected'))
);

-- 开启 RLS 且不创建任何 policy：仅 service_role（服务端 API）可读写。
alter table public.verification_requests enable row level security;

create index if not exists verification_requests_status_idx
  on public.verification_requests (status, created_at desc);

-- 私有图片桶（public=false：匿名/客户端不可读，只有服务端能取）
insert into storage.buckets (id, name, public)
values ('verification-images', 'verification-images', false)
on conflict (id) do nothing;


-- ============================================================================
-- >>> docs/notewall-supabase.sql
-- ============================================================================

-- Supabase SQL for the global note wall.
-- Run this once in the Supabase SQL editor.

create table if not exists public.note_wall_boards (
  id text primary key,
  title text not null default '便签墙',
  width integer not null default 1600,
  height integer not null default 1200,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.note_wall_notes (
  id uuid primary key default gen_random_uuid(),
  board_id text not null references public.note_wall_boards(id) on delete cascade,

  author_type text not null check (author_type in ('user', 'character')),
  author_id text not null,
  author_name text not null,
  is_anonymous boolean not null default false,

  summary text not null,
  body text not null,

  x integer not null,
  y integer not null,
  width integer not null,
  height integer not null,
  size text not null default 'medium' check (size in ('small', 'medium', 'large')),

  paper text not null default 'plain',
  tape text not null default 'none',
  font text not null default 'default',
  decoration text not null default 'none',

  raw_css text,
  safe_style jsonb not null default '{}'::jsonb,

  created_by text,
  updated_by text,
  deleted_by text,
  deleted_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table if exists public.note_wall_notes
  add column if not exists is_anonymous boolean not null default false;

create index if not exists note_wall_notes_board_created_idx
  on public.note_wall_notes (board_id, created_at);

create table if not exists public.note_wall_comments (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references public.note_wall_notes(id) on delete cascade,

  author_id text not null,
  author_name text not null,
  body text not null,
  is_anonymous boolean not null default false,

  created_by text,
  deleted_by text,
  deleted_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table if exists public.note_wall_comments
  add column if not exists is_anonymous boolean not null default false;

create index if not exists note_wall_comments_note_created_idx
  on public.note_wall_comments (note_id, created_at);

insert into public.note_wall_boards (id, title, width, height)
values ('global', '便签墙', 1600, 1200)
on conflict (id) do nothing;

alter table public.note_wall_boards enable row level security;
alter table public.note_wall_notes enable row level security;
alter table public.note_wall_comments enable row level security;

grant select on public.note_wall_boards to anon;
grant select on public.note_wall_notes to anon;
grant select on public.note_wall_comments to anon;

drop policy if exists "note_wall_boards_public_read" on public.note_wall_boards;
create policy "note_wall_boards_public_read"
  on public.note_wall_boards
  for select
  to anon
  using (true);

drop policy if exists "note_wall_notes_public_read" on public.note_wall_notes;
create policy "note_wall_notes_public_read"
  on public.note_wall_notes
  for select
  to anon
  using (deleted_at is null);

drop policy if exists "note_wall_comments_public_read" on public.note_wall_comments;
create policy "note_wall_comments_public_read"
  on public.note_wall_comments
  for select
  to anon
  using (deleted_at is null);

alter table public.note_wall_boards replica identity full;
alter table public.note_wall_notes replica identity full;
alter table public.note_wall_comments replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'note_wall_boards'
  ) then
    alter publication supabase_realtime add table public.note_wall_boards;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'note_wall_notes'
  ) then
    alter publication supabase_realtime add table public.note_wall_notes;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'note_wall_comments'
  ) then
    alter publication supabase_realtime add table public.note_wall_comments;
  end if;
end $$;


-- ============================================================================
-- >>> docs/game-hall-supabase.sql
-- ============================================================================

-- Supabase SQL for the game hall marketplace.
-- Run this once in the Supabase SQL editor.

create table if not exists public.game_hall_games (
  id text primary key,

  title text not null,
  code_name text not null,
  subtitle text not null default '',
  synopsis text not null default '',
  play_note text not null default '',
  cover_image text not null default '',
  tags jsonb not null default '[]'::jsonb,

  author_id text not null default 'anonymous',
  author_name text not null default '匿名作者',
  author_avatar text not null default '',
  source text not null default 'community' check (source in ('builtin', 'community', 'local')),
  version integer not null default 1,

  role_slots jsonb not null default '[]'::jsonb,
  picker_html text not null,
  game_html text not null,
  allow_external_control boolean not null default false,

  purchase_count integer not null default 0 check (purchase_count >= 0),
  rating numeric not null default 0 check (rating >= 0 and rating <= 5),
  like_count integer not null default 0 check (like_count >= 0),
  favorite_count integer not null default 0 check (favorite_count >= 0),
  comment_count integer not null default 0 check (comment_count >= 0),

  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.game_hall_games
  add column if not exists role_slots jsonb not null default '[]'::jsonb;

alter table public.game_hall_games
  add column if not exists picker_html text not null default '';

alter table public.game_hall_games
  add column if not exists game_html text not null default '';

alter table public.game_hall_games
  add column if not exists allow_external_control boolean not null default false;

alter table public.game_hall_games
  add column if not exists play_note text not null default '';

alter table public.game_hall_games
  add column if not exists cover_image text not null default '';

alter table public.game_hall_games
  add column if not exists author_avatar text not null default '';

alter table public.game_hall_games
  add column if not exists like_count integer not null default 0 check (like_count >= 0);

alter table public.game_hall_games
  add column if not exists favorite_count integer not null default 0 check (favorite_count >= 0);

alter table public.game_hall_games
  add column if not exists comment_count integer not null default 0 check (comment_count >= 0);

create index if not exists game_hall_games_updated_idx
  on public.game_hall_games (updated_at desc)
  where deleted_at is null;

create index if not exists game_hall_games_author_idx
  on public.game_hall_games (author_id, updated_at desc)
  where deleted_at is null;

create index if not exists game_hall_games_tags_idx
  on public.game_hall_games using gin (tags);

create table if not exists public.game_hall_likes (
  game_id text not null references public.game_hall_games(id) on delete cascade,
  user_id text not null,
  created_at timestamptz not null default now(),
  primary key (game_id, user_id)
);

create index if not exists game_hall_likes_user_idx
  on public.game_hall_likes (user_id, created_at desc);

create table if not exists public.game_hall_favorites (
  game_id text not null references public.game_hall_games(id) on delete cascade,
  user_id text not null,
  created_at timestamptz not null default now(),
  primary key (game_id, user_id)
);

create index if not exists game_hall_favorites_user_idx
  on public.game_hall_favorites (user_id, created_at desc);

create table if not exists public.game_hall_comments (
  id text primary key,
  game_id text not null references public.game_hall_games(id) on delete cascade,
  parent_id text references public.game_hall_comments(id) on delete cascade,
  author_id text not null,
  author_name text not null default '匿名玩家',
  author_avatar text not null default '',
  content text not null,
  deleted_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.game_hall_comments
  add column if not exists parent_id text references public.game_hall_comments(id) on delete cascade;

create index if not exists game_hall_comments_game_idx
  on public.game_hall_comments (game_id, created_at asc)
  where deleted_at is null;

create index if not exists game_hall_comments_parent_idx
  on public.game_hall_comments (game_id, parent_id, created_at asc)
  where deleted_at is null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'game-hall-assets',
  'game-hall-assets',
  true,
  1048576,
  array['image/webp', 'image/png', 'image/jpeg']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

alter table public.game_hall_games enable row level security;
alter table public.game_hall_likes enable row level security;
alter table public.game_hall_favorites enable row level security;
alter table public.game_hall_comments enable row level security;

grant select on public.game_hall_games to anon;
grant select on public.game_hall_likes to anon;
grant select on public.game_hall_favorites to anon;
grant select on public.game_hall_comments to anon;

drop policy if exists "game_hall_games_public_read" on public.game_hall_games;
create policy "game_hall_games_public_read"
  on public.game_hall_games
  for select
  to anon
  using (deleted_at is null);

drop policy if exists "game_hall_likes_public_read" on public.game_hall_likes;
create policy "game_hall_likes_public_read"
  on public.game_hall_likes
  for select
  to anon
  using (true);

drop policy if exists "game_hall_favorites_public_read" on public.game_hall_favorites;
create policy "game_hall_favorites_public_read"
  on public.game_hall_favorites
  for select
  to anon
  using (true);

drop policy if exists "game_hall_comments_public_read" on public.game_hall_comments;
create policy "game_hall_comments_public_read"
  on public.game_hall_comments
  for select
  to anon
  using (deleted_at is null);

alter table public.game_hall_games replica identity full;
alter table public.game_hall_likes replica identity full;
alter table public.game_hall_favorites replica identity full;
alter table public.game_hall_comments replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'game_hall_games'
  ) then
    alter publication supabase_realtime add table public.game_hall_games;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'game_hall_comments'
  ) then
    alter publication supabase_realtime add table public.game_hall_comments;
  end if;
end $$;

notify pgrst, 'reload schema';

-- ===== 上篇结束 =====
