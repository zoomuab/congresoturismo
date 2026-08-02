-- Esquema del IX Congreso Nacional de Profesionales en Turismo.
-- Refleja el estado real del proyecto Supabase (inscripciones, contenido del
-- sitio y verificación pública de certificados). Ejecutar en un proyecto
-- Supabase exclusivo para el congreso.

-- =====================================================================
-- Tabla de inscripciones
-- =====================================================================
create table if not exists public.congreso_registrations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  full_name text not null check (char_length(full_name) between 2 and 160),
  email text,
  phone text,
  institution text,
  identity_document text,
  category text not null check (category in ('Afiliado a CONALTUR', 'Profesional en Turismo', 'Externo')),
  amount numeric(10,2) not null default 0 check (amount >= 0),
  pricing_type text not null default 'vigente',
  payment_status text not null default 'pendiente' check (payment_status in ('pendiente', 'pagado', 'cancelado')),
  name_confirmed boolean not null default false,
  certificate_code text,
  certificate_issued boolean not null default false,
  certificate_issued_at timestamptz,
  certificate_hours integer not null default 24,
  registered_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Normaliza los datos y fija precios/estados en cada inserción pública.
create or replace function public.set_congreso_registration_defaults()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.full_name := regexp_replace(trim(new.full_name), '\s+', ' ', 'g');
  new.identity_document := nullif(upper(trim(new.identity_document)), '');
  new.phone := nullif(trim(new.phone), '');
  new.email := nullif(lower(trim(new.email)), '');
  new.institution := nullif(trim(new.institution), '');
  new.payment_status := 'pendiente';
  new.name_confirmed := coalesce(new.name_confirmed, false);
  new.certificate_code := null;
  new.certificate_issued := false;
  new.certificate_issued_at := null;
  new.registered_at := now();
  new.created_at := now();
  new.updated_at := now();

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

-- Mantiene updated_at y la fecha de emisión del certificado en actualizaciones.
create or replace function public.touch_congreso_registration()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  if new.certificate_issued and not old.certificate_issued then
    new.certificate_issued_at := coalesce(new.certificate_issued_at, now());
  elsif not new.certificate_issued then
    new.certificate_issued_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists touch_congreso_registration on public.congreso_registrations;
create trigger touch_congreso_registration
before update on public.congreso_registrations
for each row execute function public.touch_congreso_registration();

alter table public.congreso_registrations enable row level security;
revoke all on public.congreso_registrations from anon, authenticated;
grant insert on public.congreso_registrations to anon;
grant select, insert, update, delete on public.congreso_registrations to authenticated;

-- El público solo puede registrarse con datos válidos y sin auto-emitir certificados.
drop policy if exists "public can register" on public.congreso_registrations;
create policy "public can register"
on public.congreso_registrations for insert
to anon
with check (
  payment_status = 'pendiente'
  and name_confirmed = true
  and char_length(trim(full_name)) between 5 and 160
  and char_length(trim(identity_document)) between 4 and 30
  and identity_document ~ '^[A-Za-z0-9.-]+$'
  and char_length(trim(phone)) between 7 and 30
  and certificate_issued = false
  and certificate_code is null
);

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

-- =====================================================================
-- Contenido editable del sitio (secciones de la landing)
-- =====================================================================
create table if not exists public.congreso_site_content (
  section_key text primary key,
  content jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

alter table public.congreso_site_content enable row level security;
revoke all on public.congreso_site_content from anon, authenticated;
grant select on public.congreso_site_content to anon;
grant select, insert, update, delete on public.congreso_site_content to authenticated;

-- Cualquiera puede leer el contenido publicado de la landing.
drop policy if exists "public can read site content" on public.congreso_site_content;
create policy "public can read site content"
on public.congreso_site_content for select
to anon, authenticated
using (true);

-- Solo los administradores pueden editar el contenido.
drop policy if exists "admins manage site content" on public.congreso_site_content;
create policy "admins manage site content"
on public.congreso_site_content for all
to authenticated
using ((select auth.jwt()->'app_metadata'->>'role') = 'admin')
with check ((select auth.jwt()->'app_metadata'->>'role') = 'admin');

-- =====================================================================
-- Verificación pública de certificados
-- =====================================================================
-- SECURITY DEFINER intencional: expone solo los datos necesarios para validar
-- un certificado (nombre, código, fecha y horas) de inscripciones pagadas con
-- certificado emitido. No revela datos de contacto ni de pago.
create or replace function public.verify_congreso_certificate(p_code text)
returns table (
  full_name text,
  certificate_code text,
  certificate_issued_at timestamptz,
  certificate_hours integer,
  event_title text,
  event_dates text,
  event_location text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    r.full_name,
    r.certificate_code,
    r.certificate_issued_at,
    r.certificate_hours,
    'IX Congreso Nacional de Profesionales en Turismo'::text,
    '3, 4 y 5 de septiembre de 2026'::text,
    'Trinidad, Beni - Bolivia'::text
  from public.congreso_registrations r
  where r.certificate_issued = true
    and r.payment_status = 'pagado'
    and upper(r.certificate_code) = upper(trim(p_code))
  limit 1;
$$;

-- La verificación de certificados es pública por diseño.
grant execute on function public.verify_congreso_certificate(text) to anon, authenticated;
