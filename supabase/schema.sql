create table if not exists public.congreso_registrations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  full_name text not null check (char_length(full_name) between 2 and 160),
  email text,
  phone text,
  institution text,
  category text not null check (category in ('Afiliado a CONALTUR', 'Profesional en Turismo', 'Externo')),
  amount numeric(10,2) not null default 0 check (amount >= 0),
  pricing_type text not null default 'vigente',
  payment_status text not null default 'pendiente' check (payment_status in ('pendiente', 'pagado', 'cancelado')),
  registered_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create or replace function public.set_congreso_registration_defaults()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.payment_status := 'pendiente';
  if current_date <= date '2026-08-10' then
    new.pricing_type := 'promocion';
    new.amount := case new.category
      when 'Afiliado a CONALTUR' then 500
      when 'Profesional en Turismo' then 550
      else 600
    end;
  else
    new.pricing_type := 'regular';
    new.amount := case new.category
      when 'Afiliado a CONALTUR' then 600
      when 'Profesional en Turismo' then 650
      else 700
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists congreso_registration_defaults on public.congreso_registrations;
create trigger congreso_registration_defaults
before insert on public.congreso_registrations
for each row execute function public.set_congreso_registration_defaults();

alter table public.congreso_registrations enable row level security;
revoke all on public.congreso_registrations from anon, authenticated;
grant insert on public.congreso_registrations to anon;
grant select, insert, update, delete on public.congreso_registrations to authenticated;

drop policy if exists "public can register" on public.congreso_registrations;
create policy "public can register"
on public.congreso_registrations for insert
to anon
with check (payment_status = 'pendiente');

drop policy if exists "admins can read registrations" on public.congreso_registrations;
create policy "admins can read registrations"
on public.congreso_registrations for select
to authenticated
using ((select auth.jwt()->'app_metadata'->>'role') = 'admin');

drop policy if exists "admins can insert registrations" on public.congreso_registrations;
create policy "admins can insert registrations"
on public.congreso_registrations for insert
to authenticated
with check ((select auth.jwt()->'app_metadata'->>'role') = 'admin');

drop policy if exists "admins can update registrations" on public.congreso_registrations;
create policy "admins can update registrations"
on public.congreso_registrations for update
to authenticated
using ((select auth.jwt()->'app_metadata'->>'role') = 'admin')
with check ((select auth.jwt()->'app_metadata'->>'role') = 'admin');

drop policy if exists "admins can delete registrations" on public.congreso_registrations;
create policy "admins can delete registrations"
on public.congreso_registrations for delete
to authenticated
using ((select auth.jwt()->'app_metadata'->>'role') = 'admin');

create index if not exists congreso_registrations_registered_at_idx
on public.congreso_registrations (registered_at desc);

create index if not exists congreso_registrations_payment_status_idx
on public.congreso_registrations (payment_status);
