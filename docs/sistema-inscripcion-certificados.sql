-- ============================================================================
--  SISTEMA DE INSCRIPCIÓN + CERTIFICADOS  —  Script completo para Supabase
--  Pega TODO este archivo en:  Supabase → SQL Editor → Run
--  Es idempotente: se puede volver a ejecutar sin romper nada.
--
--  Incluye: tablas, privilegios, RLS, triggers, funciones de verificación,
--  bucket de Storage y políticas de Storage.
--  Para reutilizar en otro proyecto solo renombra las tablas 'congreso_*'.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) TABLAS
-- ----------------------------------------------------------------------------
create table if not exists public.congreso_registrations (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null,
  full_name             text not null,
  email                 text,
  phone                 text,
  institution           text,
  category              text not null,
  amount                numeric not null default 0,
  pricing_type          text not null default 'vigente',
  payment_status        text not null default 'pendiente',
  registered_at         timestamptz not null default now(),
  created_at            timestamptz not null default now(),
  identity_document     text,
  name_confirmed        boolean not null default false,
  certificate_code      text,
  certificate_issued    boolean not null default false,
  certificate_issued_at timestamptz,
  certificate_hours     integer not null default 24,
  updated_at            timestamptz not null default now()
);

create index if not exists idx_congreso_reg_code        on public.congreso_registrations (code);
create index if not exists idx_congreso_reg_certcode    on public.congreso_registrations (upper(certificate_code));
create index if not exists idx_congreso_reg_document    on public.congreso_registrations (upper(identity_document));

create table if not exists public.congreso_site_content (
  section_key text primary key,
  content     jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

alter table public.congreso_registrations enable row level security;
alter table public.congreso_site_content  enable row level security;

-- ----------------------------------------------------------------------------
-- 2) PRIVILEGIOS DE TABLA
--    anon (público): SOLO puede insertar inscripciones y leer el contenido.
--    authenticated (admin logueado): gestiona todo.
-- ----------------------------------------------------------------------------
grant insert                          on public.congreso_registrations to anon;
grant select, insert, update, delete  on public.congreso_registrations to authenticated;
grant select                          on public.congreso_site_content  to anon;
grant select, insert, update, delete  on public.congreso_site_content  to authenticated;

-- ----------------------------------------------------------------------------
-- 3) POLÍTICAS RLS — INSCRIPCIONES
-- ----------------------------------------------------------------------------
drop policy if exists "public can register"          on public.congreso_registrations;
drop policy if exists "auth can read registrations"  on public.congreso_registrations;
drop policy if exists "auth can insert registrations" on public.congreso_registrations;
drop policy if exists "auth can update registrations" on public.congreso_registrations;
drop policy if exists "auth can delete registrations" on public.congreso_registrations;

-- Registro público con validación fuerte dentro de la política.
create policy "public can register" on public.congreso_registrations
  for insert to anon
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

-- Admin logueado: acceso total (cambia 'true' por checks de rol si lo necesitas).
create policy "auth can read registrations"   on public.congreso_registrations for select to authenticated using (true);
create policy "auth can insert registrations" on public.congreso_registrations for insert to authenticated with check (true);
create policy "auth can update registrations" on public.congreso_registrations for update to authenticated using (true) with check (true);
create policy "auth can delete registrations" on public.congreso_registrations for delete to authenticated using (true);

-- ----------------------------------------------------------------------------
-- 4) POLÍTICAS RLS — CONTENIDO / CMS
-- ----------------------------------------------------------------------------
drop policy if exists "public read site content" on public.congreso_site_content;
drop policy if exists "auth manage site content" on public.congreso_site_content;

create policy "public read site content" on public.congreso_site_content for select to anon using (true);
create policy "auth manage site content" on public.congreso_site_content for all to authenticated using (true) with check (true);

-- ----------------------------------------------------------------------------
-- 5) TRIGGERS
--    5a) BEFORE INSERT: fuerza estado seguro + calcula precio por categoría/fecha
--    5b) BEFORE UPDATE: mantiene updated_at (NO toca campos de certificado)
-- ----------------------------------------------------------------------------
create or replace function public.set_congreso_registration_defaults()
returns trigger language plpgsql set search_path to '' as $$
declare cfg jsonb; cut date;
begin
  new.full_name         := regexp_replace(trim(new.full_name), '\s+', ' ', 'g');
  new.identity_document := nullif(upper(trim(new.identity_document)), '');
  new.phone             := nullif(trim(new.phone), '');
  new.email             := nullif(lower(trim(new.email)), '');
  new.institution       := nullif(trim(new.institution), '');
  new.payment_status    := 'pendiente';
  new.name_confirmed    := coalesce(new.name_confirmed, false);
  new.certificate_code  := null;
  new.certificate_issued:= false;
  new.certificate_issued_at := null;
  new.registered_at := now(); new.created_at := now(); new.updated_at := now();

  select content into cfg from public.congreso_site_content where section_key = 'pricing';
  begin
    cut := coalesce(nullif(cfg->>'cutoff','')::date, date '2026-08-10');
  exception when others then
    cut := date '2026-08-10';
  end;

  if current_date <= cut then
    new.pricing_type := 'promocion';
    new.amount := coalesce(
      nullif(cfg->(new.category)->>'promo','')::numeric,
      case new.category when 'Afiliado a CONALTUR' then 500 when 'Profesional en Turismo' then 550 else 600 end
    );
  else
    new.pricing_type := 'regular';
    new.amount := coalesce(
      nullif(cfg->(new.category)->>'regular','')::numeric,
      case new.category when 'Afiliado a CONALTUR' then 600 when 'Profesional en Turismo' then 650 else 700 end
    );
  end if;
  return new;
end; $$;

drop trigger if exists congreso_registration_defaults on public.congreso_registrations;
create trigger congreso_registration_defaults
  before insert on public.congreso_registrations
  for each row execute function public.set_congreso_registration_defaults();

create or replace function public.touch_congreso_registration()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists touch_congreso_registration on public.congreso_registrations;
create trigger touch_congreso_registration
  before update on public.congreso_registrations
  for each row execute function public.touch_congreso_registration();

-- ----------------------------------------------------------------------------
-- 6) FUNCIONES DE VERIFICACIÓN PÚBLICA (SECURITY DEFINER)
--    Solo exponen certificados EMITIDOS y PAGADOS.
--    Ajusta los textos del evento a tu proyecto.
-- ----------------------------------------------------------------------------
create or replace function public.verify_congreso_certificate(p_code text)
returns table(full_name text, certificate_code text, certificate_issued_at timestamptz,
              certificate_hours integer, event_title text, event_dates text, event_location text)
language sql stable security definer set search_path to '' as $$
  select r.full_name, r.certificate_code, r.certificate_issued_at, r.certificate_hours,
         'IX Congreso Nacional de Profesionales en Turismo'::text,
         '3, 4 y 5 de septiembre de 2026'::text,
         'Trinidad, Beni - Bolivia'::text
  from public.congreso_registrations r
  where r.certificate_issued = true and r.payment_status = 'pagado'
    and upper(r.certificate_code) = upper(trim(p_code))
  limit 1;
$$;

create or replace function public.certificado_por_documento(p_doc text)
returns table(full_name text, certificate_code text, certificate_issued_at timestamptz,
              certificate_hours integer, event_title text, event_dates text, event_location text)
language sql stable security definer set search_path to '' as $$
  select r.full_name, r.certificate_code, r.certificate_issued_at, r.certificate_hours,
         'IX Congreso Nacional de Profesionales en Turismo'::text,
         '3, 4 y 5 de septiembre de 2026'::text,
         'Trinidad, Beni - Bolivia'::text
  from public.congreso_registrations r
  where r.certificate_issued = true and r.payment_status = 'pagado'
    and upper(regexp_replace(coalesce(r.identity_document,''),'\s','','g'))
      = upper(regexp_replace(trim(p_doc),'\s','','g'))
  order by r.certificate_issued_at desc nulls last
  limit 1;
$$;

grant execute on function public.verify_congreso_certificate(text) to anon, authenticated;
grant execute on function public.certificado_por_documento(text)  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 7) STORAGE — bucket público 'sitio' + escritura solo para logueados
--    (En producción, la subida se hace vía Edge Function con service_role;
--     estas políticas permiten además la escritura directa autenticada.)
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('sitio', 'sitio', true)
on conflict (id) do update set public = true;

drop policy if exists "admin upload sitio" on storage.objects;
drop policy if exists "admin update sitio" on storage.objects;
drop policy if exists "admin delete sitio" on storage.objects;

create policy "admin upload sitio" on storage.objects
  for insert to authenticated with check (bucket_id = 'sitio');
create policy "admin update sitio" on storage.objects
  for update to authenticated using (bucket_id = 'sitio') with check (bucket_id = 'sitio');
create policy "admin delete sitio" on storage.objects
  for delete to authenticated using (bucket_id = 'sitio');

-- ----------------------------------------------------------------------------
-- 8) CONTENIDO INICIAL (semilla) — edítalo luego desde el panel admin
-- ----------------------------------------------------------------------------
insert into public.congreso_site_content (section_key, content) values
  ('pricing', jsonb_build_object(
      'cutoff', '2026-08-10',
      'Afiliado a CONALTUR', jsonb_build_object('promo', 500, 'regular', 600),
      'Profesional en Turismo', jsonb_build_object('promo', 550, 'regular', 650),
      'Externo', jsonb_build_object('promo', 600, 'regular', 700)
  )),
  ('landing', jsonb_build_object(
      'site_title', 'IX Congreso Nacional de Profesionales en Turismo',
      'bank_name', 'Banco Unión S.A.',
      'bank_titular', 'Titular de la cuenta',
      'bank_account', '0000000000',
      'bank_glosa', 'Inscripción congreso'
  ))
on conflict (section_key) do nothing;

-- ============================================================================
--  FIN. Después de ejecutar:
--   1) Crea el primer usuario admin en  Auth → Users → Add user.
--   2) Despliega las Edge Functions 'subir-imagen' y 'enviar-certificado'.
--   3) Configura los secrets de correo (GMAIL_USER/GMAIL_APP_PASSWORD o BREVO_*).
-- ============================================================================
