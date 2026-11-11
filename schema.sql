-- MKAt v3: личные чаты, группы, каналы, фото.
-- Вставьте целиком в Supabase -> SQL Editor -> Run.
-- ВНИМАНИЕ: первые строки удаляют таблицы старой версии (если они были).
drop table if exists public.messages cascade;
drop table if exists public.rooms cascade;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 24),
  created_at timestamptz not null default now()
);
create table public.chats (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('direct','group','channel')),
  title text check (title is null or char_length(title) between 1 and 40),
  is_public boolean not null default false,
  owner_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.chat_members (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','member')),
  joined_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);
create index on public.chat_members (user_id);
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  sender text not null check (char_length(sender) between 1 and 24),
  body text not null default '' check (char_length(body) <= 2000),
  image_path text,
  created_at timestamptz not null default now(),
  check (char_length(body) > 0 or image_path is not null)
);
create index on public.messages (chat_id, created_at);

-- вспомогательные функции для правил доступа
create function public.is_member(c uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from chat_members where chat_id = c and user_id = auth.uid()) $$;
create function public.is_admin_of(c uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from chat_members where chat_id = c and user_id = auth.uid() and role in ('owner','admin')) $$;
create function public.can_post(c uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from chat_members m join chats h on h.id = m.chat_id
   where m.chat_id = c and m.user_id = auth.uid() and (h.type <> 'channel' or m.role in ('owner','admin'))) $$;

-- правила доступа (RLS)
alter table public.profiles enable row level security;
alter table public.chats enable row level security;
alter table public.chat_members enable row level security;
alter table public.messages enable row level security;

create policy "profiles read"   on public.profiles for select to authenticated using (true);
create policy "profiles insert" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles update" on public.profiles for update to authenticated using (id = auth.uid());

create policy "chats read" on public.chats for select to authenticated using (is_public or public.is_member(id));

create policy "members read"  on public.chat_members for select to authenticated using (user_id = auth.uid() or public.is_member(chat_id));
create policy "members leave" on public.chat_members for delete to authenticated using (user_id = auth.uid());

create policy "msg read"   on public.messages for select to authenticated using (public.is_member(chat_id));
create policy "msg send"   on public.messages for insert to authenticated with check (user_id = auth.uid() and public.can_post(chat_id));
create policy "msg delete" on public.messages for delete to authenticated using (user_id = auth.uid() or public.is_admin_of(chat_id));

-- действия, которые меняют сразу несколько таблиц: только через функции
create function public.create_chat(p_type text, p_title text, p_public boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if p_type not in ('group','channel') then raise exception 'Неверный тип чата'; end if;
  if p_title is null or char_length(trim(p_title)) = 0 then raise exception 'Введите название'; end if;
  insert into chats(type,title,is_public,owner_id) values (p_type, trim(p_title), p_public, auth.uid()) returning id into cid;
  insert into chat_members(chat_id,user_id,role) values (cid, auth.uid(), 'owner');
  return cid;
end $$;

create function public.start_direct(p_username text) returns uuid
language plpgsql security definer set search_path = public as $$
declare other uuid; cid uuid;
begin
  select id into other from profiles where username = lower(p_username);
  if other is null then raise exception 'Пользователь @% не найден', p_username; end if;
  if other = auth.uid() then raise exception 'Нельзя написать самому себе'; end if;
  select c.id into cid from chats c
   where c.type = 'direct'
     and exists (select 1 from chat_members where chat_id = c.id and user_id = auth.uid())
     and exists (select 1 from chat_members where chat_id = c.id and user_id = other) limit 1;
  if cid is null then
    insert into chats(type,owner_id) values ('direct', auth.uid()) returning id into cid;
    insert into chat_members(chat_id,user_id) values (cid, auth.uid()), (cid, other);
  end if;
  return cid;
end $$;

create function public.add_member(p_chat uuid, p_username text) returns boolean
language plpgsql security definer set search_path = public as $$
declare other uuid;
begin
  if not public.is_admin_of(p_chat) then raise exception 'Недостаточно прав'; end if;
  if (select type from chats where id = p_chat) = 'direct' then raise exception 'В личный чат нельзя добавлять людей'; end if;
  select id into other from profiles where username = lower(p_username);
  if other is null then raise exception 'Пользователь @% не найден', p_username; end if;
  insert into chat_members(chat_id,user_id) values (p_chat, other) on conflict do nothing;
  return true;
end $$;

create function public.join_chat(p_chat uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from chats where id = p_chat and is_public and type in ('group','channel')) then
    raise exception 'Чат недоступен для вступления';
  end if;
  insert into chat_members(chat_id,user_id) values (p_chat, auth.uid()) on conflict do nothing;
  return true;
end $$;

-- реальное время
alter table public.messages replica identity full;
alter publication supabase_realtime add table public.messages, public.chat_members;

-- хранилище для фото (до 5 МБ, только JPEG)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 5242880, array['image/jpeg'])
on conflict (id) do nothing;
create policy "media upload" on storage.objects for insert to authenticated with check (bucket_id = 'media');
