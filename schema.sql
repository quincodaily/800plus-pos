-- 800+ Pharmacy POS: Supabase schema. Safe to run once in Supabase > SQL Editor.
create extension if not exists pgcrypto;

create table public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null, name text,
  role text not null default 'cashier' check (role in ('admin','cashier')),
  active boolean not null default true, created_at timestamptz not null default now());

create table public.suppliers(
  id uuid primary key default gen_random_uuid(), name text not null,
  contact text, phone text, email text, created_at timestamptz not null default now());

create table public.products(
  id uuid primary key default gen_random_uuid(), name text not null, generic text, category text, barcode text,
  price numeric(12,2) not null check (price >= 0), stock integer not null default 0,
  reorder integer not null default 0, expiry date,
  supplier_id uuid references public.suppliers(id) on delete set null,
  rx boolean not null default false, created_at timestamptz not null default now());
create unique index products_barcode_uq on public.products(barcode) where barcode is not null and barcode <> '';

create table public.sales(
  id uuid primary key,                       -- generated on the cashier's computer: makes retries idempotent
  sold_at timestamptz not null, created_at timestamptz not null default now(),
  cashier_id uuid references public.profiles(id), cashier text,
  items jsonb not null, subtotal numeric(12,2) not null, discount_type text, discount_value text, id_no text,
  discount numeric(12,2) not null default 0, total numeric(12,2) not null, pay text, cash numeric(12,2), change numeric(12,2),
  rx boolean not null default false, offline boolean not null default false,
  oversold boolean not null default false,
  review_status text not null default 'none' check (review_status in ('none','pending','resolved')));
create index sales_sold_at_idx on public.sales(sold_at desc);

create table public.sale_items(
  id bigserial primary key, sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text, qty integer not null, price numeric(12,2) not null, oversold_qty integer not null default 0);

create table public.stock_ins(
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(),
  product_id uuid references public.products(id) on delete set null, name text, qty integer not null,
  supplier_id uuid references public.suppliers(id) on delete set null, by_user uuid);

-- helpers
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id = auth.uid() and role='admin' and active) $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id = auth.uid() and active) $$;

-- row level security
alter table public.profiles enable row level security;
alter table public.suppliers enable row level security;
alter table public.products enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.stock_ins enable row level security;

create policy profiles_read on public.profiles for select to authenticated using (id = auth.uid() or public.is_admin());
create policy suppliers_read on public.suppliers for select to authenticated using (public.is_staff());
create policy suppliers_admin on public.suppliers for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy products_read on public.products for select to authenticated using (public.is_staff());
create policy products_admin on public.products for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy sales_read on public.sales for select to authenticated using (public.is_admin() or cashier_id = auth.uid());
create policy sale_items_read on public.sale_items for select to authenticated
  using (public.is_admin() or exists(select 1 from public.sales s where s.id = sale_id and s.cashier_id = auth.uid()));
create policy stock_ins_read on public.stock_ins for select to authenticated using (public.is_admin());
-- No insert/update/delete policies on sales, sale_items, stock_ins: they change only through the functions below.

revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;

-- record a sale atomically; calling it twice with the same id does nothing the second time
create or replace function public.process_sale(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare sid uuid := (p->>'id')::uuid; uid uuid := auth.uid(); offl boolean := coalesce((p->>'offline')::boolean,false);
  it jsonb; pr products%rowtype; q int; oq int; ov boolean := false; uname text; ins uuid;
begin
  select username into uname from profiles where id = uid and active;
  if uname is null then raise exception 'Not allowed'; end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'Empty sale'; end if;
  insert into sales(id,sold_at,cashier_id,cashier,items,subtotal,discount_type,discount_value,id_no,discount,total,pay,cash,change,rx,offline)
  values(sid, to_timestamp((p->>'ts')::bigint/1000.0), uid, uname, p->'items', (p->>'subtotal')::numeric, p->>'discType', p->>'discVal', p->>'idNo',
    coalesce((p->>'discount')::numeric,0), (p->>'total')::numeric, p->>'pay', (p->>'cash')::numeric, (p->>'change')::numeric,
    coalesce((p->>'rx')::boolean,false), offl)
  on conflict (id) do nothing returning id into ins;
  if ins is null then return jsonb_build_object('id',sid,'duplicate',true); end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    q := (it->>'qty')::int; oq := 0;
    if q <= 0 then raise exception 'Bad quantity'; end if;
    select * into pr from products where id = (it->>'id')::uuid for update;   -- row lock: simultaneous sales queue up here
    if not found then
      if not offl then raise exception 'Product no longer exists: %', it->>'name'; end if;
      oq := q;
    else
      if not offl then
        if pr.stock < q then raise exception 'Not enough stock: % (only % left)', pr.name, pr.stock; end if;
        if pr.expiry is not null and pr.expiry < current_date then raise exception 'Expired: %', pr.name; end if;
        if pr.price <> (it->>'price')::numeric then raise exception 'Price changed for %, refresh and try again', pr.name; end if;
      else
        oq := greatest(0, q - greatest(pr.stock,0));
      end if;
      update products set stock = stock - q where id = pr.id;
    end if;
    if oq > 0 then ov := true; end if;
    insert into sale_items(sale_id,product_id,name,qty,price,oversold_qty)
    values(sid, case when found then pr.id end, it->>'name', q, (it->>'price')::numeric, oq);
  end loop;
  if ov then update sales set oversold = true, review_status = 'pending' where id = sid; end if;
  return jsonb_build_object('id',sid,'oversold',ov);
end $$;

create or replace function public.stock_in(pid uuid, qty int, exp date, sup uuid) returns void language plpgsql security definer set search_path=public as $$
declare pn text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if qty <= 0 then raise exception 'Quantity must be positive'; end if;
  update products set stock = stock + qty, expiry = coalesce(exp, expiry), supplier_id = coalesce(sup, supplier_id)
    where id = pid returning name into pn;
  if pn is null then raise exception 'Product not found'; end if;
  insert into stock_ins(product_id,name,qty,supplier_id,by_user) values(pid,pn,qty,sup,auth.uid());
end $$;

create or replace function public.resolve_oversold(sid uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update sales set review_status = 'resolved' where id = sid and oversold;
end $$;

revoke all on function public.process_sale(jsonb), public.stock_in(uuid,int,date,uuid), public.resolve_oversold(uuid) from public, anon;
grant execute on function public.process_sale(jsonb), public.stock_in(uuid,int,date,uuid), public.resolve_oversold(uuid) to authenticated;

-- realtime
alter publication supabase_realtime add table public.products, public.suppliers, public.sales, public.stock_ins, public.profiles;

-- import of your existing data (1 product; no suppliers or sales existed). Skips it if the barcode is already there.
insert into public.products(name,generic,category,barcode,price,stock,reorder,expiry,rx)
select 'Tempra Drops 15mL','Paracetamol','Medicine','8995201800455',99,10,10,'2028-08-08',false
where not exists (select 1 from public.products where barcode='8995201800455');

-- link the admin login you created (Authentication > Users: admin@800plus.pos). Re-run this block if it says 0 rows.
insert into public.profiles(id,username,name,role)
select id,'admin','Administrator','admin' from auth.users where email='admin@800plus.pos'
on conflict (id) do nothing;

select (select count(*) from products) as products, (select count(*) from profiles where role='admin') as admins;
