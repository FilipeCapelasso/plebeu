-- =====================================================================
--  PLEBEU GAMES — BANCO COMPLETO v6  (loja + painel admin + integração Bling)
--  Supabase > SQL Editor > cole TUDO > Run.
--
--  • Idempotente: pode rodar de novo quantas vezes quiser. Nunca apaga dados.
--  • Cria o que falta, completa colunas que faltam e atualiza as funções/views.
--  • Checkout (place_order / get_order_payment / validate_coupon): só é criado
--    se ainda não existir, para NÃO sobrescrever o que já roda com o Mercado Pago.
--
--  O usuário admin plebeugames@gmail.com é criado AQUI (se ainda não existir), já confirmado.
--  A senha não aparece em texto: só o hash bcrypt. Depois do primeiro login, troque a senha
--  no painel (botão "Senha") e use uma frase longa e única.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) ADMIN
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

drop policy if exists plb_self on public.admins;
create policy plb_self on public.admins for select to authenticated using (user_id = auth.uid());

-- Cria o usuário admin se ainda não existir. NUNCA altera a senha de um usuário existente
-- (assim, rodar este script de novo não desfaz uma senha que você trocou).
do $$
declare uid uuid := gen_random_uuid();
begin
  if exists (select 1 from auth.users where email = 'plebeugames@gmail.com') then
    raise notice 'Usuário admin já existe: senha mantida.';
    return;
  end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', 'plebeugames@gmail.com',
      '$2a$10$FnWe5o0t7Yq34j41sG0BF.9i5.o7oT2w5w3k7nEmCQElmqBdsLkyO', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text,
      jsonb_build_object('sub', uid::text, 'email', 'plebeugames@gmail.com', 'email_verified', true), 'email', now(), now(), now());
  raise notice 'Usuário admin criado.';
exception when others then
  raise notice 'Não foi possível criar o usuário por SQL (%). Crie em Authentication > Users > Add user (Auto Confirm).', sqlerrm;
end $$;
-- Se o usuário JÁ existia e você quer definir a senha combinada, rode esta linha UMA vez (tire o "--"):
-- update auth.users set encrypted_password = '$2a$10$FnWe5o0t7Yq34j41sG0BF.9i5.o7oT2w5w3k7nEmCQElmqBdsLkyO' where email = 'plebeugames@gmail.com';

insert into public.admins (user_id)
select id from auth.users where email = 'plebeugames@gmail.com'
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 2) TABELAS DA LOJA (create if not exists + colunas que podem faltar)
-- ---------------------------------------------------------------------
create table if not exists public.stores (
  id text primary key, name text not null, kind text, whatsapp text
);
alter table public.stores add column if not exists bling_deposito_id bigint;

create table if not exists public.categories (
  slug text primary key, name text not null, emoji text, position int default 0
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  slug text unique, name text not null, price numeric(12,2) not null default 0,
  created_at timestamptz not null default now()
);
alter table public.products
  add column if not exists brand text,
  add column if not exists category_slug text,
  add column if not exists emoji text,
  add column if not exists image_url text,
  add column if not exists gallery text[] default '{}',
  add column if not exists old_price numeric(12,2),
  add column if not exists pix_discount numeric default 0,
  add column if not exists pix_price numeric(12,2),
  add column if not exists max_installments int default 5,
  add column if not exists description text,
  add column if not exists features text[] default '{}',
  add column if not exists featured boolean default false,
  add column if not exists active boolean default true,
  add column if not exists sold_count int default 0,
  add column if not exists sku text,
  add column if not exists bling_id bigint;
create unique index if not exists uq_products_sku on public.products (lower(sku)) where sku is not null;
create index if not exists idx_products_bling on public.products (bling_id) where bling_id is not null;

create table if not exists public.product_stock (
  product_id uuid not null references public.products(id) on delete cascade,
  store_id text not null references public.stores(id) on delete cascade,
  qty int not null default 0 check (qty >= 0),
  primary key (product_id, store_id)
);
alter table public.product_stock
  add column if not exists bling_qty int,
  add column if not exists updated_at timestamptz default now();

create table if not exists public.reviews (
  id bigint generated always as identity primary key,
  customer_name text not null, rating int not null default 5 check (rating between 1 and 5),
  body text not null, created_at timestamptz not null default now()
);

create table if not exists public.store_settings (
  id int primary key default 1 check (id = 1),
  delivery_fee numeric default 12, free_shipping_from numeric default 300, cutoff_hour int default 15
);

create table if not exists public.coupons (
  code text primary key, percent numeric not null check (percent > 0 and percent <= 100),
  min_subtotal numeric default 0, max_uses int, uses int not null default 0, active boolean not null default true
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number bigint generated always as identity unique,
  public_token uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);
alter table public.orders
  add column if not exists store_id text,
  add column if not exists customer_name text,
  add column if not exists customer_phone text,
  add column if not exists payment text,
  add column if not exists delivery_type text,
  add column if not exists address text,
  add column if not exists items jsonb default '[]',
  add column if not exists subtotal numeric(12,2),
  add column if not exists discount numeric(12,2) default 0,
  add column if not exists delivery_fee numeric(12,2) default 0,
  add column if not exists total numeric(12,2),
  add column if not exists coupon_code text,
  add column if not exists status text default 'novo',
  add column if not exists payment_status text default 'pending',
  add column if not exists status_detail text,
  add column if not exists pix_qr_code text,
  add column if not exists pix_qr_base64 text,
  add column if not exists checkout_url text,
  add column if not exists payment_expires_at timestamptz,
  add column if not exists mp_method text,
  add column if not exists payer_email text,
  add column if not exists pix_ticket_url text,
  add column if not exists mp_preference_id text,
  add column if not exists mp_payment_id text,
  add column if not exists visitor_id text,
  add column if not exists reserve_until timestamptz,
  add column if not exists stock_reserved boolean default false,
  add column if not exists bling_order_id bigint,
  add column if not exists bling_pushed_at timestamptz,
  add column if not exists bling_error text,
  add column if not exists bling_stock_posted boolean default false;
create index if not exists idx_orders_phone  on public.orders (customer_phone);
create index if not exists idx_orders_status on public.orders (status, created_at desc);
create unique index if not exists uq_orders_token on public.orders (order_number, public_token);

-- ---------------------------------------------------------------------
-- 3) VISUALIZAÇÕES (rastreio de produtos vistos)
-- ---------------------------------------------------------------------
create table if not exists public.product_views (
  id         bigint generated always as identity primary key,
  product_id uuid not null references public.products(id) on delete cascade,
  visitor_id text not null check (length(visitor_id) between 8 and 64),
  created_at timestamptz not null default now()
);
create index if not exists idx_pv_product on public.product_views(product_id, created_at desc);
create index if not exists idx_pv_visitor on public.product_views(visitor_id);

create or replace function public.track_view(p_product uuid, p_visitor text) returns void
language plpgsql security definer set search_path = public, pg_temp as $fn$
begin
  if p_visitor is null or length(p_visitor) not between 8 and 64 then return; end if;
  if not exists (select 1 from public.products where id = p_product) then return; end if;
  if exists (select 1 from public.product_views where product_id = p_product
             and visitor_id = p_visitor and created_at > now() - interval '30 minutes') then return; end if;
  insert into public.product_views (product_id, visitor_id) values (p_product, p_visitor);
end $fn$;

create or replace function public.link_visitor(p_order bigint, p_token uuid, p_visitor text) returns void
language sql security definer set search_path = public, pg_temp as $fn$
  update public.orders set visitor_id = left(p_visitor, 64)
   where order_number = p_order and public_token = p_token and visitor_id is null;
$fn$;

-- ---------------------------------------------------------------------
-- 4) INTEGRAÇÃO BLING (configuração, tokens, fila e eventos)
-- ---------------------------------------------------------------------
create table if not exists public.bling_settings (
  id int primary key default 1 check (id = 1),
  functions_url text,                                   -- https://<projeto>.supabase.co/functions/v1
  cron_secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  enabled boolean not null default true,                -- integração ligada (só age depois de conectar ao Bling)
  push_orders boolean not null default false,           -- enviar pedidos pagos do site ao Bling (ligue só após testar)
  sync_stock boolean not null default true,             -- receber estoque do Bling
  bling_reserves_stock boolean not null default true,   -- o Bling já reserva/baixa estoque ao receber o pedido
  stock_movement boolean not null default false,        -- o SITE lança a saída no depósito da loja (em vez do Bling baixar sozinho)
  situacao_id bigint, loja_id bigint,                   -- opcionais: situação inicial e canal de venda no Bling
  forma_pagamento_pix bigint, forma_pagamento_cartao bigint,
  last_stock_sync timestamptz
);

alter table public.bling_settings
  add column if not exists stock_movement boolean not null default false,
  add column if not exists site_url text,                          -- preenchido sozinho ao clicar em Conectar
  add column if not exists safety_stock int not null default 0,    -- mostra no site (saldo - N) para cobrir o atraso de avisos
  add column if not exists sync_price boolean not null default false, -- true = o preço do Bling atualiza o preço do site
  add column if not exists push_since timestamptz,                 -- só pedidos criados depois disso vão ao Bling (evita reenviar antigos)
  add column if not exists schema_version int not null default 0;
-- migração v4 (roda uma única vez): estoque do Bling ligado; envio de pedidos só quando VOCÊ ligar
update public.bling_settings set enabled = true, sync_stock = true, push_orders = false, schema_version = 4 where schema_version < 4;
create or replace function public.plb_push_since() returns trigger language plpgsql as $fn$
begin
  if new.push_orders and (tg_op = 'INSERT' or not old.push_orders or new.push_since is null) then new.push_since := now(); end if;
  return new;
end $fn$;
drop trigger if exists plb_push_since on public.bling_settings;
create trigger plb_push_since before insert or update on public.bling_settings
  for each row execute function public.plb_push_since();

create table if not exists public.bling_tokens (        -- só a service_role (Edge Function) acessa
  id int primary key default 1 check (id = 1),
  access_token text, refresh_token text, expires_at timestamptz,
  oauth_state text, oauth_state_at timestamptz, connected_at timestamptz
);

alter table public.bling_tokens
  add column if not exists client_id text, add column if not exists client_secret text,
  add column if not exists refreshing_at timestamptz,   -- trava: só uma renovação de token por vez
  add column if not exists refresh_fail_at timestamptz, -- após falha, pausa 10 min (o Bling bloqueia o IP se insistir)
  add column if not exists last_error text;

create table if not exists public.bling_queue (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('push_order','stock','stock_all')),
  ref text not null,
  status text not null default 'pending' check (status in ('pending','processing','done','error')),
  attempts int not null default 0, run_at timestamptz not null default now(),
  started_at timestamptz, done_at timestamptz, last_error text,
  created_at timestamptz not null default now()
);
create unique index if not exists uq_bling_queue_open on public.bling_queue (kind, ref)
  where status in ('pending','processing','error');
create index if not exists idx_bling_queue_run on public.bling_queue (status, run_at);

create table if not exists public.bling_events (        -- idempotência dos webhooks (o Bling pode repetir)
  event_id text primary key, event text, received_at timestamptz not null default now()
);

alter table public.bling_settings enable row level security;
alter table public.bling_tokens   enable row level security;
alter table public.bling_queue    enable row level security;
alter table public.bling_events   enable row level security;
revoke all on public.bling_tokens, public.bling_events from anon, authenticated;
drop policy if exists plb_admin on public.bling_settings;
create policy plb_admin on public.bling_settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists plb_admin on public.bling_queue;
create policy plb_admin on public.bling_queue for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- chama a Edge Function agora (pg_net); se não houver pg_net/cron, o worker agendado cobre
create or replace function public.bling_kick() returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $fn$
declare s public.bling_settings;
begin
  select * into s from public.bling_settings where id = 1;
  if s.functions_url is null or not s.enabled
     or not exists (select 1 from public.bling_tokens where refresh_token is not null) then return; end if;
  perform net.http_post(url := s.functions_url || '/bling',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', s.cron_secret),
    body := '{"action":"process"}'::jsonb);
exception when others then null;
end $fn$;

-- pedido pago e ainda não enviado ao Bling -> entra na fila
create or replace function public.plb_bling_order() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare s public.bling_settings;
begin
  select * into s from public.bling_settings where id = 1;
  if s.enabled and s.push_orders and s.push_since is not null and new.created_at >= s.push_since - interval '40 minutes'
     and new.bling_order_id is null and new.status <> 'cancelado'
     and (new.payment_status = 'approved' or new.status in ('pago','enviado','entregue')) then
    insert into public.bling_queue (kind, ref) values ('push_order', new.order_number::text)
      on conflict (kind, ref) where status in ('pending','processing','error') do nothing;
    perform public.bling_kick();
  end if;
  return new;
end $fn$;
drop trigger if exists plb_bling_orders on public.orders;
create trigger plb_bling_orders after insert or update of status, payment_status on public.orders
  for each row execute function public.plb_bling_order();

-- unidades do produto/loja que o site já vendeu mas o Bling ainda não conhece
create or replace function public.bling_reserved(p_product uuid, p_store text) returns int
language sql stable security definer set search_path = public, pg_temp as $fn$
  select coalesce(sum((i->>'qty')::int), 0)::int
    from public.orders o, jsonb_array_elements(o.items) i, public.bling_settings s
   where s.id = 1 and o.store_id = p_store and i->>'id' = p_product::text
     and o.status in ('novo','confirmado','pago')
     and (not s.bling_reserves_stock or o.bling_order_id is null)
$fn$;

-- grava o saldo vindo do Bling (por depósito) no estoque de cada loja
create or replace function public.bling_apply_stock(p_bling_id bigint, p_deps jsonb) returns int
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare pr public.products; st record; s public.bling_settings; d jsonb; v int; n int := 0;
begin
  select * into s from public.bling_settings where id = 1;
  select * into pr from public.products where bling_id = p_bling_id;
  if not found then return 0; end if;
  for st in select id, bling_deposito_id from public.stores where bling_deposito_id is not null loop
    select x into d from jsonb_array_elements(coalesce(p_deps,'[]')) x where (x->>'id')::bigint = st.bling_deposito_id limit 1;
    v := greatest(0, round(coalesce(
           case when s.bling_reserves_stock and not s.stock_movement then (d->>'virtual')::numeric end,
           (d->>'fisico')::numeric, 0))::int);
    insert into public.product_stock (product_id, store_id, qty, bling_qty)
    values (pr.id, st.id, greatest(0, v - public.bling_reserved(pr.id, st.id) - coalesce(s.safety_stock, 0)), v)
    on conflict (product_id, store_id) do update
      set qty = excluded.qty, bling_qty = excluded.bling_qty, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $fn$;

-- fila: pegar, concluir/falhar (só service_role)
create or replace function public.bling_claim_jobs(p_n int default 10) returns setof public.bling_queue
language plpgsql security definer set search_path = public, pg_temp as $fn$
begin
  update public.bling_queue set status = 'pending' where status = 'processing' and started_at < now() - interval '5 minutes';
  return query
  update public.bling_queue q set status = 'processing', attempts = q.attempts + 1, started_at = now()
   where q.id in (select id from public.bling_queue where status = 'pending' and run_at <= now()
                   order by id limit p_n for update skip locked)
  returning q.*;
end $fn$;

create or replace function public.bling_job_finish(p_id bigint, p_err text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $fn$
begin
  if p_err is null then
    update public.bling_queue set status = 'done', done_at = now(), last_error = null where id = p_id;
  else
    update public.bling_queue
       set status = case when attempts >= 8 then 'error' else 'pending' end,
           run_at = now() + make_interval(mins => least(attempts * attempts, 60)),
           last_error = left(p_err, 500)
     where id = p_id;
  end if;
end $fn$;

create or replace function public.bling_reconcile() returns void
language plpgsql security definer set search_path = public, pg_temp as $fn$
begin
  if exists (select 1 from public.bling_settings where id = 1 and enabled and sync_stock)
     and exists (select 1 from public.bling_tokens where refresh_token is not null) then
    insert into public.bling_queue (kind, ref) values ('stock_all', 'all')
      on conflict (kind, ref) where status in ('pending','processing','error') do nothing;
    perform public.bling_kick();
  end if;
end $fn$;

-- painel admin: resumo da integração (sem tokens)
create or replace function public.bling_status() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'connected',  exists (select 1 from public.bling_tokens where refresh_token is not null),
    'connected_at', (select connected_at from public.bling_tokens where id = 1),
    'has_credentials', exists (select 1 from public.bling_tokens where client_id is not null and client_secret is not null),
    'token_error', (select case when refresh_fail_at > now() - interval '30 minutes' then last_error end from public.bling_tokens where id = 1),
    'settings',   (select to_jsonb(s) - 'cron_secret' from public.bling_settings s where id = 1),
    'queue', jsonb_build_object(
       'pending', (select count(*) from public.bling_queue where status in ('pending','processing')),
       'error',   (select count(*) from public.bling_queue where status = 'error'),
       'done24',  (select count(*) from public.bling_queue where status = 'done' and done_at > now() - interval '24 hours')),
    'errors', (select coalesce(jsonb_agg(e), '[]') from (
                 select id, kind, ref, attempts, last_error from public.bling_queue
                  where last_error is not null and status <> 'done' order by id desc limit 10) e),
    'linked', (select count(*) from public.products where bling_id is not null),
    'total',  (select count(*) from public.products));
end $fn$;

-- reenviar pedido com erro ao Bling
create or replace function public.bling_retry_order(p_order bigint) returns void
language plpgsql security definer set search_path = public, pg_temp as $fn$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.orders set bling_error = null where order_number = p_order and bling_order_id is null;
  update public.bling_queue set status = 'pending', attempts = 0, run_at = now(), last_error = null
   where kind = 'push_order' and ref = p_order::text and status <> 'done';
  if not found then
    insert into public.bling_queue (kind, ref) values ('push_order', p_order::text) on conflict do nothing;
  end if;
  perform public.bling_kick();
end $fn$;

-- O admin não consegue digitar saldo de produto ligado ao Bling (o Bling é a fonte). Pedidos/reservas (funções do banco) continuam livres.
create or replace function public.plb_stock_guard() returns trigger language plpgsql set search_path = public, pg_temp as $fn$
begin
  if current_user = 'authenticated' and (tg_op = 'INSERT' or new.qty is distinct from old.qty)
     and exists (select 1 from public.products p, public.bling_settings s
                  where p.id = new.product_id and p.bling_id is not null and s.id = 1 and s.enabled and s.sync_stock) then
    raise exception 'Estoque controlado pelo Bling: altere o saldo no Bling (o site atualiza sozinho).' using errcode = 'P0001';
  end if;
  return new;
end $fn$;
drop trigger if exists plb_stock_guard on public.product_stock;
create trigger plb_stock_guard before insert or update of qty on public.product_stock
  for each row execute function public.plb_stock_guard();

revoke execute on function public.bling_kick(), public.bling_reserved(uuid,text), public.bling_apply_stock(bigint,jsonb),
  public.bling_claim_jobs(int), public.bling_job_finish(bigint,text), public.bling_reconcile(),
  public.bling_status(), public.bling_retry_order(bigint) from public, anon, authenticated;
grant execute on function public.bling_status(), public.bling_retry_order(bigint) to authenticated;
grant execute on function public.bling_kick(), public.bling_reserved(uuid,text), public.bling_apply_stock(bigint,jsonb),
  public.bling_claim_jobs(int), public.bling_job_finish(bigint,text), public.bling_reconcile() to service_role;

-- ---------------------------------------------------------------------
-- 5) CHECKOUT — só instala se ainda não existir (não mexe no que já funciona)
-- ---------------------------------------------------------------------
do $do$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'place_order') then
    raise notice 'place_order já existe: checkout atual mantido.';
    return;
  end if;

  execute $f$
  create or replace function public.validate_coupon(p_code text, p_subtotal numeric)
  returns table (percent numeric) language sql stable security definer set search_path = public, pg_temp as $b$
    select c.percent from public.coupons c
     where upper(c.code) = upper(trim(p_code)) and c.active and p_subtotal >= coalesce(c.min_subtotal,0)
       and (c.max_uses is null or c.uses < c.max_uses)
  $b$ $f$;

  execute $f$
  create or replace function public.place_order(p_store text, p_name text, p_phone text, p_payment text,
    p_delivery text, p_address text, p_items jsonb, p_coupon text) returns jsonb
  language plpgsql security definer set search_path = public, pg_temp as $b$
  declare it jsonb; pr public.products; q int; u numeric; v_sub numeric := 0; v_disc numeric := 0;
          v_fee numeric := 0; v_pct numeric; v_items jsonb := '[]'; o public.orders; cfg public.store_settings;
  begin
    if length(trim(coalesce(p_name,''))) < 2 or length(regexp_replace(coalesce(p_phone,''),'\D','','g')) < 10 then
      raise exception 'Informe seu nome e WhatsApp com DDD.' using errcode = 'P0001'; end if;
    if p_payment not in ('pix','cartao') or p_delivery not in ('entrega','retirada') then
      raise exception 'Dados do pedido inválidos.' using errcode = 'P0001'; end if;
    if p_delivery = 'entrega' and length(trim(coalesce(p_address,''))) < 8 then
      raise exception 'Informe o endereço de entrega.' using errcode = 'P0001'; end if;
    if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 30 then
      raise exception 'Carrinho inválido.' using errcode = 'P0001'; end if;
    for it in select * from jsonb_array_elements(p_items) loop
      select * into pr from public.products where id = (it->>'id')::uuid and active;
      if not found then raise exception 'Produto indisponível.' using errcode = 'P0001'; end if;
      q := greatest(1, least(50, coalesce((it->>'qty')::int, 1)));
      update public.product_stock set qty = qty - q where product_id = pr.id and store_id = p_store and qty >= q;
      if not found then raise exception 'Sem estoque suficiente de "%" nesta loja.', pr.name using errcode = 'P0001'; end if;
      u := case when p_payment = 'pix'
                then coalesce(pr.pix_price, round(pr.price * (1 - coalesce(pr.pix_discount,0) / 100), 2))
                else pr.price end;
      v_sub := v_sub + u * q;
      v_items := v_items || jsonb_build_object('id', pr.id, 'name', pr.name, 'qty', q, 'unit', u, 'sku', pr.sku);
    end loop;
    if nullif(trim(p_coupon),'') is not null then
      select percent into v_pct from public.validate_coupon(p_coupon, v_sub) limit 1;
      if v_pct is not null then
        v_disc := round(v_sub * v_pct / 100, 2);
        update public.coupons set uses = uses + 1 where upper(code) = upper(trim(p_coupon));
      end if;
    end if;
    select * into cfg from public.store_settings where id = 1;
    if p_delivery = 'entrega' and v_sub - v_disc < coalesce(cfg.free_shipping_from, 300) then
      v_fee := coalesce(cfg.delivery_fee, 12); end if;
    insert into public.orders (store_id, customer_name, customer_phone, payment, delivery_type, address, items,
        subtotal, discount, delivery_fee, total, coupon_code, reserve_until, stock_reserved)
    values (p_store, trim(p_name), regexp_replace(p_phone,'\D','','g'), p_payment, p_delivery,
        case when p_delivery = 'entrega' then trim(p_address) end, v_items, v_sub, v_disc, v_fee,
        v_sub - v_disc + v_fee, case when v_pct is not null then upper(trim(p_coupon)) end,
        now() + interval '30 minutes', true)
    returning * into o;
    return jsonb_build_object('order_number', o.order_number, 'token', o.public_token, 'total', o.total);
  end $b$ $f$;

  execute $f$
  create or replace function public.get_order_payment(p_order_number bigint, p_token uuid) returns jsonb
  language sql stable security definer set search_path = public, pg_temp as $b$
    select jsonb_build_object('order_number', o.order_number, 'total', o.total, 'status', o.status,
      'payment_status', o.payment_status, 'status_detail', o.status_detail, 'items', o.items,
      'delivery_type', o.delivery_type, 'address', o.address, 'customer_name', o.customer_name,
      'store_name', s.name, 'whatsapp', s.whatsapp, 'pix_qr_code', o.pix_qr_code,
      'pix_qr_base64', o.pix_qr_base64, 'checkout_url', o.checkout_url, 'expires_at', o.payment_expires_at)
      from public.orders o join public.stores s on s.id = o.store_id
     where o.order_number = p_order_number and o.public_token = p_token
  $b$ $f$;

  -- devolve o estoque reservado quando o pedido é cancelado/expira; soma vendidos quando paga
  execute $f$
  create or replace function public.plb_order_stock() returns trigger
  language plpgsql security definer set search_path = public, pg_temp as $b$
  begin
    if new.status = 'cancelado' and old.status <> 'cancelado' and new.payment_status is distinct from 'approved' and new.stock_reserved then
      update public.product_stock ps set qty = ps.qty + (i->>'qty')::int
        from jsonb_array_elements(new.items) i
       where ps.product_id = (i->>'id')::uuid and ps.store_id = new.store_id;
      update public.orders set stock_reserved = false where id = new.id;
    end if;
    if new.payment_status = 'approved' and old.payment_status is distinct from 'approved' then
      update public.products p set sold_count = coalesce(p.sold_count,0) + (i->>'qty')::int
        from jsonb_array_elements(new.items) i where p.id = (i->>'id')::uuid;
    end if;
    return new;
  end $b$ $f$;
  drop trigger if exists plb_order_stock on public.orders;
  create trigger plb_order_stock after update of status, payment_status on public.orders
    for each row execute function public.plb_order_stock();

  execute $f$
  create or replace function public.expire_orders() returns void
  language sql security definer set search_path = public, pg_temp as $b$
    update public.orders set status = 'cancelado'
     where status = 'novo' and coalesce(payment_status,'pending') <> 'approved' and reserve_until < now()
  $b$ $f$;
  revoke execute on function public.expire_orders() from public, anon, authenticated;
  raise notice 'Checkout instalado (place_order, get_order_payment, validate_coupon, expire_orders).';
end $do$;

grant execute on function public.is_admin(), public.track_view(uuid,text), public.link_visitor(bigint,uuid,text) to anon, authenticated;
do $$ begin
  if exists (select 1 from pg_proc where proname = 'place_order' and pronamespace = 'public'::regnamespace) then
    grant execute on function public.place_order(text,text,text,text,text,text,jsonb,text) to anon, authenticated;
    grant execute on function public.get_order_payment(bigint,uuid) to anon, authenticated;
    grant execute on function public.validate_coupon(text,numeric) to anon, authenticated;
  end if;
exception when undefined_function then null; end $$;
revoke execute on function public.track_view(uuid,text), public.link_visitor(bigint,uuid,text) from public;

-- ---------------------------------------------------------------------
-- 6) SEGURANÇA (RLS): cliente só lê o catálogo; tudo mais é do admin
-- ---------------------------------------------------------------------
do $$ declare t text; begin
  foreach t in array array['stores','categories','product_stock','reviews','store_settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists plb_read on public.%I', t);
    execute format('create policy plb_read on public.%I for select using (true)', t);
    execute format('drop policy if exists plb_admin on public.%I', t);
    execute format('create policy plb_admin on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
  foreach t in array array['coupons','orders','product_views'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists plb_admin on public.%I', t);
    execute format('create policy plb_admin on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;
alter table public.products enable row level security;
drop policy if exists plb_read  on public.products;
drop policy if exists plb_admin on public.products;
create policy plb_read  on public.products for select using (active);
create policy plb_admin on public.products for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 7) VIEWS DE GESTÃO (security_invoker: só o admin enxerga)
-- ---------------------------------------------------------------------
drop view if exists public.admin_product_views;
create view public.admin_product_views with (security_invoker = true) as
select p.id as product_id, p.name, count(v.id) as views,
       count(distinct v.visitor_id) as visitors, max(v.created_at) as last_view
  from public.products p left join public.product_views v on v.product_id = p.id
 group by p.id, p.name;

drop view if exists public.admin_customers;
create view public.admin_customers with (security_invoker = true) as
select customer_phone as phone,
       (array_agg(customer_name order by created_at desc))[1] as name,
       count(*) filter (where status <> 'cancelado') as orders,
       coalesce(sum(total) filter (where status in ('pago','enviado','entregue')), 0) as spent,
       min(created_at) as first_order, max(created_at) as last_order
  from public.orders group by customer_phone;

drop view if exists public.admin_customer_views;
create view public.admin_customer_views with (security_invoker = true) as
select o.customer_phone as phone, p.name as product, count(v.id) as views, max(v.created_at) as last_view
  from (select distinct customer_phone, visitor_id from public.orders where visitor_id is not null) o
  join public.product_views v on v.visitor_id = o.visitor_id
  join public.products p on p.id = v.product_id
 group by o.customer_phone, p.name;

drop view if exists public.admin_low_stock;
create view public.admin_low_stock with (security_invoker = true) as
select p.name as product, s.name as store, ps.qty
  from public.product_stock ps join public.products p on p.id = ps.product_id
  join public.stores s on s.id = ps.store_id
 where p.active and ps.qty <= 3 order by ps.qty, p.name;

drop view if exists public.admin_bling_stock;
create view public.admin_bling_stock with (security_invoker = true) as
select p.name as product, p.sku, p.bling_id, s.name as store, ps.bling_qty, ps.qty, ps.updated_at
  from public.product_stock ps join public.products p on p.id = ps.product_id
  join public.stores s on s.id = ps.store_id
 where p.bling_id is not null order by ps.updated_at desc nulls last;

grant select on public.admin_product_views, public.admin_customers, public.admin_customer_views, public.admin_low_stock, public.admin_bling_stock to authenticated;

-- ---------------------------------------------------------------------
-- 8) IMAGENS (bucket público para leitura; só admin envia/apaga)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('products', 'products', true)
on conflict (id) do update set public = true;
drop policy if exists "products_admin_write"  on storage.objects;
drop policy if exists "products_admin_update" on storage.objects;
drop policy if exists "products_admin_delete" on storage.objects;
create policy "products_admin_write"  on storage.objects for insert to authenticated
  with check (bucket_id = 'products' and public.is_admin());
create policy "products_admin_update" on storage.objects for update to authenticated
  using (bucket_id = 'products' and public.is_admin());
create policy "products_admin_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'products' and public.is_admin());

-- ---------------------------------------------------------------------
-- 9) DADOS INICIAIS (só se ainda não existirem) + estoque em tempo real
-- ---------------------------------------------------------------------
insert into public.stores (id, name, kind, whatsapp) values
  ('rb','Rio Branco','Matriz','5568992116920'), ('pv','Porto Velho','Filial','5569999895007')
on conflict do nothing;
insert into public.categories (slug, name, emoji, position) values
  ('consoles','Consoles','🎮',1), ('jogos','Jogos','💿',2), ('perifericos','Periféricos','🎧',3), ('informatica','Informática','💻',4)
on conflict do nothing;
insert into public.store_settings (id, delivery_fee, free_shipping_from, cutoff_hour) values (1, 12, 300, 15) on conflict do nothing;
insert into public.bling_settings (id, functions_url, schema_version) values (1, 'https://hlanjhafrhebmheozkmt.supabase.co/functions/v1', 4) on conflict do nothing;

do $$ begin alter publication supabase_realtime add table public.product_stock;
exception when others then null; end $$;

-- ---------------------------------------------------------------------
-- 10) TAREFAS AGENDADAS (pg_cron). Se a extensão não estiver ativa, ative em Database > Extensions.
-- ---------------------------------------------------------------------
do $$ begin
  create extension if not exists pg_cron;
  create extension if not exists pg_net;
exception when others then raise notice 'pg_cron/pg_net indisponíveis: ative em Database > Extensions e rode de novo.'; end $$;

do $$ begin
  perform cron.schedule('plb-bling-worker',    '* * * * *',   'select public.bling_kick()');
  perform cron.schedule('plb-bling-reconcile', '*/5 * * * *', 'select public.bling_reconcile()');
  perform cron.schedule('plb-bling-prune',     '15 3 * * *',  $c$delete from public.bling_queue where status = 'done' and done_at < now() - interval '7 days';
                                                                  delete from public.bling_events where received_at < now() - interval '30 days'$c$);
  if exists (select 1 from pg_proc where proname = 'expire_orders' and pronamespace = 'public'::regnamespace) then
    perform cron.schedule('plb-expire-orders', '* * * * *', 'select public.expire_orders()');
  end if;
exception when others then raise notice 'Agendamentos não criados: %', sqlerrm; end $$;

-- ---------------------------------------------------------------------
-- 11) QUALIDADE: desempenho, auditoria, proteção contra abuso, painel e diagnóstico
-- ---------------------------------------------------------------------
alter table public.products add column if not exists updated_at timestamptz not null default now();
alter table public.orders   add column if not exists updated_at timestamptz not null default now();

create or replace function public.plb_touch() returns trigger language plpgsql as $fn$
begin new.updated_at := now(); return new; end $fn$;
do $$ declare t text; begin
  foreach t in array array['products','orders','product_stock'] loop
    execute format('drop trigger if exists plb_touch on public.%I', t);
    execute format('create trigger plb_touch before update on public.%I for each row execute function public.plb_touch()', t);
  end loop;
end $$;

create index if not exists idx_products_active_cat on public.products (active, category_slug);
create index if not exists idx_products_created    on public.products (created_at desc);
create index if not exists idx_orders_created      on public.orders (created_at desc);
create index if not exists idx_orders_paystatus    on public.orders (payment_status, created_at desc);
create index if not exists idx_stock_store         on public.product_stock (store_id);
create index if not exists idx_orders_bling_todo   on public.orders (order_number)
  where bling_order_id is null and status in ('pago','enviado','entregue');

-- valores absurdos nunca entram (NOT VALID: não mexe nas linhas antigas)
do $$ begin
  alter table public.products add constraint plb_chk_price check (price >= 0) not valid;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.orders add constraint plb_chk_total check (total >= 0) not valid;
exception when duplicate_object then null; end $$;

-- AUDITORIA: quem (admin) mudou o quê. Registra só ações de usuários logados (não pedidos de clientes nem sincronizações).
create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor uuid, actor_email text, table_name text not null, op text not null,
  row_id text, summary text, diff jsonb
);
create index if not exists idx_audit_at on public.audit_log (at desc);
alter table public.audit_log enable row level security;
drop policy if exists plb_admin_read on public.audit_log;
create policy plb_admin_read on public.audit_log for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.audit_log from anon, authenticated;

create or replace function public.plb_audit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare r jsonb; o jsonb; d jsonb; em text; excl text[] := array['updated_at','cron_secret','client_secret','pix_qr_base64'];
begin
  if auth.uid() is null then return null; end if;
  select email into em from auth.users where id = auth.uid();
  if tg_op = 'DELETE' then o := to_jsonb(old); r := o; d := o - excl;
  elsif tg_op = 'INSERT' then r := to_jsonb(new); d := r - excl;
  else
    r := to_jsonb(new); o := to_jsonb(old);
    select coalesce(jsonb_object_agg(n.key, jsonb_build_object('de', o -> n.key, 'para', n.value)), '{}'::jsonb) into d
      from jsonb_each(r) n where n.value is distinct from o -> n.key and n.key <> all (excl);
    if d = '{}'::jsonb then return null; end if;
  end if;
  insert into public.audit_log (actor, actor_email, table_name, op, row_id, summary, diff)
  values (auth.uid(), em, tg_table_name, tg_op, coalesce(r->>'id', r->>'code', r->>'slug'),
          coalesce(r->>'name', 'pedido #' || (r->>'order_number'), r->>'code'), d);
  return null;
end $fn$;

do $$ declare t text; begin
  foreach t in array array['products','coupons','categories','stores','store_settings','bling_settings'] loop
    execute format('drop trigger if exists plb_audit on public.%I', t);
    execute format('create trigger plb_audit after insert or update or delete on public.%I for each row execute function public.plb_audit()', t);
  end loop;
end $$;
drop trigger if exists plb_audit on public.orders;
create trigger plb_audit after update on public.orders for each row
  when (old.status is distinct from new.status) execute function public.plb_audit();

-- PROTEÇÃO: um mesmo WhatsApp não segura estoque com pedidos pendentes sem pagar
create or replace function public.plb_order_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $fn$
begin
  if (select count(*) from public.orders
       where customer_phone = new.customer_phone and status = 'novo'
         and coalesce(payment_status, 'pending') <> 'approved'
         and created_at > now() - interval '30 minutes') >= 5 then
    raise exception 'Você tem vários pedidos aguardando pagamento. Conclua um deles ou aguarde alguns minutos.' using errcode = 'P0001';
  end if;
  return new;
end $fn$;
drop trigger if exists plb_order_guard on public.orders;
create trigger plb_order_guard before insert on public.orders for each row execute function public.plb_order_guard();

-- PAINEL: todos os números do Resumo numa única chamada (admin)
create or replace function public.admin_dashboard(p_days int default 30) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare tz constant text := 'America/Rio_Branco'; d0 date := (now() at time zone tz)::date; res jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  p_days := greatest(7, least(coalesce(p_days, 30), 90));
  with paid as (
    select o.*, (o.created_at at time zone tz)::date as dia from public.orders o
     where o.status in ('pago','enviado','entregue') and o.created_at > now() - make_interval(days => p_days + 1)),
  days as (select g::date as d from generate_series(d0 - (p_days - 1), d0, interval '1 day') g)
  select jsonb_build_object(
    'hoje',   (select jsonb_build_object('pedidos', count(*), 'receita', coalesce(sum(total), 0)) from paid where dia = d0),
    'd7',     (select jsonb_build_object('pedidos', count(*), 'receita', coalesce(sum(total), 0)) from paid where dia > d0 - 7),
    'periodo',(select jsonb_build_object('pedidos', count(*), 'receita', coalesce(sum(total), 0),
                       'ticket', coalesce(round(avg(total), 2), 0)) from paid where dia > d0 - p_days),
    'diario', (select jsonb_agg(jsonb_build_object('d', d, 'pedidos', coalesce(x.n, 0), 'receita', coalesce(x.v, 0)) order by d)
                 from days left join (select dia, count(*) n, sum(total) v from paid group by dia) x on x.dia = days.d),
    'top',    (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
                 select i->>'name' as nome, sum(coalesce((i->>'qty')::int, 1)) as qtd,
                        sum(coalesce((i->>'qty')::int, 1) * coalesce(nullif(i->>'unit', '')::numeric, 0)) as receita
                   from paid, jsonb_array_elements(case when jsonb_typeof(paid.items) = 'array' then paid.items else '[]'::jsonb end) i
                  where paid.dia > d0 - p_days group by 1 order by 2 desc limit 8) t),
    'fila',   jsonb_build_object(
                 'aguardando_pagamento', (select count(*) from public.orders where status = 'novo' and coalesce(payment_status,'pending') <> 'approved' and created_at > now() - interval '2 days'),
                 'a_enviar',   (select count(*) from public.orders where status in ('pago','confirmado')),
                 'atrasados',  (select count(*) from public.orders where status in ('pago','confirmado') and created_at < now() - interval '24 hours')),
    'catalogo', jsonb_build_object(
                 'ativos',          (select count(*) from public.products where active),
                 'sem_foto',        (select count(*) from public.products where active and coalesce(image_url, '') = ''),
                 'sem_categoria',   (select count(*) from public.products where active and coalesce(category_slug, '') = ''),
                 'sem_sku',         (select count(*) from public.products where active and coalesce(sku, '') = ''),
                 'sem_preco',       (select count(*) from public.products where active and coalesce(price, 0) = 0),
                 'inativos',        (select count(*) from public.products where not active),
                 'estoque_baixo',   (select count(*) from public.admin_low_stock)),
    'views',  (select coalesce(sum(1), 0) from public.product_views where created_at > now() - make_interval(days => p_days))
  ) into res;
  return res;
end $fn$;

-- DIAGNÓSTICO: confirma que cron/pg_net/triggers estão como o sistema espera (admin)
create or replace function public.plb_diagnostics() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare jobs jsonb := '[]'::jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if to_regclass('cron.job') is not null then
    execute 'select coalesce(jsonb_agg(jsonb_build_object(''name'', jobname, ''schedule'', schedule, ''active'', active)), ''[]''::jsonb) from cron.job where jobname like ''plb-%''' into jobs;
  end if;
  return jsonb_build_object(
    'pg_cron', exists (select 1 from pg_extension where extname = 'pg_cron'),
    'pg_net',  exists (select 1 from pg_extension where extname = 'pg_net'),
    'cron_jobs', jobs,
    'triggers_proprios', (select coalesce(jsonb_agg(c.relname || '.' || t.tgname order by c.relname, t.tgname), '[]'::jsonb)
                            from pg_trigger t join pg_class c on c.oid = t.tgrelid
                           where not t.tgisinternal and c.relnamespace = 'public'::regnamespace and t.tgname like 'plb\_%'),
    'triggers_de_terceiros', (select coalesce(jsonb_agg(c.relname || '.' || t.tgname order by c.relname, t.tgname), '[]'::jsonb)
                            from pg_trigger t join pg_class c on c.oid = t.tgrelid
                           where not t.tgisinternal and c.relnamespace = 'public'::regnamespace
                             and c.relname in ('orders','product_stock','products') and t.tgname not like 'plb\_%'),
    'auditoria_registros', (select count(*) from public.audit_log));
end $fn$;

revoke execute on function public.admin_dashboard(int), public.plb_diagnostics() from public, anon;
grant  execute on function public.admin_dashboard(int), public.plb_diagnostics() to authenticated;

-- limpeza automática (mantém o banco leve): visualizações > 180 dias, auditoria > 1 ano
do $$ begin
  perform cron.schedule('plb-prune-misc', '30 3 * * *', $c$delete from public.product_views where created_at < now() - interval '180 days';
                                                          delete from public.audit_log where at < now() - interval '365 days'$c$);
exception when others then raise notice 'Limpeza agendada não criada (pg_cron indisponível): %', sqlerrm; end $$;

-- Conferências úteis:
--   select u.email, a.user_id from public.admins a join auth.users u on u.id = a.user_id;
--   select tgname, tgrelid::regclass from pg_trigger where not tgisinternal and tgrelid in ('public.orders'::regclass,'public.product_stock'::regclass);
--   select * from cron.job;
