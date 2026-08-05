# Sistema de Inscripción + Certificados — Guía de Arquitectura (reutilizable)

Documento técnico para **reutilizar este sistema en otro proyecto**: inscripción pública,
comprobante de registro con QR, cobro por QR bancario, panel de administración,
emisión de certificados, verificación pública y envío de certificado por correo.

Todo funciona **sin servidor propio**: un frontend estático + Supabase (base de datos,
autenticación, storage y edge functions) + despliegue en Vercel.

---

## 1. Visión general

```
┌─────────────────────────┐         ┌──────────────────────────────────────┐
│   FRONTEND (estático)    │  HTTPS  │              SUPABASE                 │
│   HTML + JS vanilla      │────────▶│                                       │
│   Desplegado en Vercel   │         │  • PostgreSQL + RLS                    │
│                          │         │  • Auth (email/password)              │
│  - landing (inscripción) │         │  • Storage (bucket público de imágenes)│
│  - admin (gestión)       │         │  • Edge Functions (Deno)              │
│  - verificar / certificado│        │  • RPC (funciones SECURITY DEFINER)   │
└─────────────────────────┘         └──────────────────────────────────────┘
```

**Idea clave de seguridad:** el público (rol `anon`) **solo puede insertar** una
inscripción (con validaciones fuertes) y **llamar funciones de verificación**. No
puede leer la tabla ni modificar nada. Todo lo administrativo requiere iniciar
sesión (rol `authenticated`).

### Stack
- **Frontend:** HTML + JavaScript vanilla (sin framework). Librerías por CDN:
  `qrcodejs` (QR), `html2canvas` (comprobante/certificado como imagen), `jspdf` (PDF).
- **Backend:** Supabase (PostgREST para REST, GoTrue para auth, Storage, Edge Functions).
- **Correo:** Gmail vía SMTP (contraseña de aplicación) o Brevo (API). Gratis.
- **Deploy:** Vercel (sitio estático; auto-deploy en cada push a `main`).

---

## 2. Componentes / archivos del frontend

| Archivo | Rol |
|---|---|
| `moxena-congreso-v2.html` | **Landing**: presentación, costos, formulario de inscripción, comprobante con QR, paso de pago. |
| `admin-moxena.html` | **Panel admin** (maquetación, CMS, precios, reporte, usuarios, modales). |
| `admin-system.js` | **Lógica del admin**: login, tabla de inscritos, marcar pago, emitir/revocar certificado, sincronización, envío de correo. |
| `verificar.html` | Búsqueda pública de certificado por **código** o **carnet**. |
| `certificado.html` | Render del certificado sobre una **plantilla** (imagen de fondo) + descarga en PDF. |
| `moxena-config.js` | Config del cliente: `supabaseUrl`, `supabasePublishableKey`, nombres de tablas. Generado en build a partir de variables de entorno. |
| `scripts/generate-site.mjs` | Build: copia archivos a `dist/` e inyecta `moxena-config.js` desde `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY`. |
| `vercel.json` | `cleanUrls` + rewrites (`/verificar`, `/certificado`, `/admin`). |

---

## 3. Base de datos

### 3.1 Tabla de inscripciones

```sql
create table public.congreso_registrations (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null,                 -- código de inscripción (ej. MOX-2026-6228)
  full_name             text not null,
  email                 text,
  phone                 text,
  institution           text,
  category              text not null,                 -- categoría de precio
  amount                numeric not null default 0,    -- lo calcula el trigger
  pricing_type          text not null default 'vigente',
  payment_status        text not null default 'pendiente',   -- 'pendiente' | 'pagado'
  registered_at         timestamptz not null default now(),
  created_at            timestamptz not null default now(),
  identity_document     text,                          -- carnet de identidad (CI)
  name_confirmed        boolean not null default false,
  certificate_code      text,                          -- ej. MOX-CERT-2026-9999
  certificate_issued    boolean not null default false,
  certificate_issued_at timestamptz,
  certificate_hours     integer not null default 24,
  updated_at            timestamptz not null default now()
);

alter table public.congreso_registrations enable row level security;
```

### 3.2 Tabla de contenido editable (CMS)

Un patrón simple: una fila por “sección”, con un `jsonb` de pares clave→valor.

```sql
create table public.congreso_site_content (
  section_key text primary key,   -- 'landing' | 'pricing'
  content     jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);
alter table public.congreso_site_content enable row level security;
```

- **`landing`**: textos (`site_title`, `hero_title_main`, `hero_dates`…), datos bancarios
  (`bank_titular`, `bank_name`, `bank_account`, `bank_glosa`), y URLs de imágenes
  (`img_logo`, `img_hero_bg`, `img_qr`, `img_cert_template`, `img_favicon`, `img_city_1..3`),
  y posición del texto del certificado (`cert_name_top`, `cert_code_top/bottom/left/right/size`).
- **`pricing`**: `{ "cutoff": "2026-08-10", "Externo": {"promo":600,"regular":700}, ... }`.

---

## 4. Seguridad (RLS + GRANTs) — el corazón del sistema

### 4.1 Privilegios de tabla

```sql
-- El público solo puede INSERTAR (registrarse). No puede leer datos de otros.
grant insert on public.congreso_registrations to anon;
-- Los usuarios logueados gestionan todo.
grant select, insert, update, delete on public.congreso_registrations to authenticated;
grant select on public.congreso_site_content to anon;              -- leer textos/imágenes
grant select, insert, update, delete on public.congreso_site_content to authenticated;
```

### 4.2 Políticas RLS de inscripciones

```sql
-- Inscripción pública: validación fuerte en la propia política.
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

-- Admin (logueado): acceso total.
create policy "auth can read registrations"   on public.congreso_registrations for select to authenticated using (true);
create policy "auth can insert registrations" on public.congreso_registrations for insert to authenticated with check (true);
create policy "auth can update registrations" on public.congreso_registrations for update to authenticated using (true) with check (true);
create policy "auth can delete registrations" on public.congreso_registrations for delete to authenticated using (true);
```

> **Nota:** las políticas `using(true)` para usuarios logueados son intencionales:
> es un sistema pequeño sin datos ultra-sensibles y cualquier usuario autorizado
> (al que le das acceso) puede gestionar todo. Si necesitas roles, reemplaza
> `true` por comprobaciones sobre `auth.jwt()`/`auth.uid()`.

### 4.3 Políticas del CMS y del Storage

```sql
create policy "auth manage site content" on public.congreso_site_content
  for all to authenticated using (true) with check (true);

-- Storage: bucket 'sitio' público de lectura; escritura por Edge Function (ver §6).
insert into storage.buckets (id, name, public) values ('sitio','sitio', true)
  on conflict (id) do nothing;
```

---

## 5. Trigger de valores por defecto (precio + estado seguro)

Se ejecuta **BEFORE INSERT**. Hace dos cosas:
1. **Fuerza un estado seguro**: nadie puede inyectar una inscripción ya “pagada” o con
   certificado emitido (aunque manipule el request).
2. **Calcula el precio** según la categoría y la fecha límite de promoción (leída del CMS).

```sql
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
  begin cut := coalesce(nullif(cfg->>'cutoff','')::date, date '2026-08-10');
  exception when others then cut := date '2026-08-10'; end;

  if current_date <= cut then
    new.pricing_type := 'promocion';
    new.amount := coalesce(nullif(cfg->(new.category)->>'promo','')::numeric,
      case new.category when 'Afiliado a CONALTUR' then 500 when 'Profesional en Turismo' then 550 else 600 end);
  else
    new.pricing_type := 'regular';
    new.amount := coalesce(nullif(cfg->(new.category)->>'regular','')::numeric,
      case new.category when 'Afiliado a CONALTUR' then 600 when 'Profesional en Turismo' then 650 else 700 end);
  end if;
  return new;
end; $$;

create trigger congreso_registration_defaults
  before insert on public.congreso_registrations
  for each row execute function public.set_congreso_registration_defaults();

-- Mantener updated_at en cada UPDATE (NO toca los campos de certificado).
create or replace function public.touch_congreso_registration()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

create trigger touch_congreso_registration
  before update on public.congreso_registrations
  for each row execute function public.touch_congreso_registration();
```

> **Clave de diseño:** el trigger de defaults es **solo INSERT**. La emisión del
> certificado se hace por **UPDATE** desde el admin, así el trigger no la pisa.

---

## 6. Funciones RPC de verificación (públicas y seguras)

`SECURITY DEFINER` + `search_path=''` para que el público pueda verificar sin tener
acceso de lectura a la tabla. Solo exponen datos de certificados **emitidos y pagados**.

```sql
-- Verificar por CÓDIGO de certificado
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

-- Verificar por CARNET / documento de identidad
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
```

---

## 7. Edge Functions (Deno)

### 7.1 `subir-imagen` — subida de imágenes sin problemas de permisos
El navegador choca con las reglas de Storage al subir directo. Solución: una función
que **valida la sesión** del que sube y **escribe con `service_role`** (salta RLS).

```ts
// verify_jwt = false (validamos manualmente con getUser)
import { createClient } from "jsr:@supabase/supabase-js@2";
Deno.serve(async (req) => {
  // ...CORS...
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const token = (req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  const { data:{ user } } = await admin.auth.getUser(token);
  if (!user) return json({ error:"Sesión inválida" }, 401);   // solo logueados
  const bytes = new Uint8Array(await req.arrayBuffer());
  const path  = `${req.headers.get("x-image-key")}-${Date.now()}.${req.headers.get("x-file-ext")}`;
  await admin.storage.from("sitio").upload(path, bytes, { contentType: req.headers.get("content-type"), upsert:true });
  const { data:pub } = admin.storage.from("sitio").getPublicUrl(path);
  return json({ url: pub.publicUrl });
});
```

### 7.2 `enviar-certificado` — correo automático al emitir
Valida la sesión, busca la inscripción por `code`, y envía un correo HTML con el
código y el enlace de descarga. Soporta **Gmail (SMTP)** o **Brevo (API)**.

```ts
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
// ... valida sesión con getUser ...
// ... busca reg por code (service_role) ...
if (GMAIL_USER && GMAIL_APP_PASSWORD) {
  const client = new SMTPClient({ connection:{ hostname:"smtp.gmail.com", port:465, tls:true,
    auth:{ username:GMAIL_USER, password:GMAIL_APP_PASSWORD } } });
  await client.send({ from:`${SENDER_NAME} <${GMAIL_USER}>`, to:reg.email, subject, html });
  await client.close();
}
```

**Secrets necesarios** (en Supabase → Edge Functions → Secrets):
`GMAIL_USER`, `GMAIL_APP_PASSWORD` (contraseña de aplicación de Google) **o**
`BREVO_API_KEY` + `BREVO_SENDER_EMAIL`. `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY`
ya vienen inyectados por la plataforma.

---

## 8. Flujo de INSCRIPCIÓN (público)

```
Usuario llena el formulario (nombre, carnet, celular, correo, categoría)
        │  valida en el cliente (longitudes, formato de carnet, confirmación de nombre)
        ▼
POST /rest/v1/congreso_registrations   (apikey = publishable key, Prefer: return=minimal)
   body: { code, full_name, email, phone, institution, category, identity_document, name_confirmed:true }
        │
        ▼  (RLS "public can register" valida  +  trigger calcula precio y estado)
Fila creada  →  el cliente muestra el COMPROBANTE
```

Código de inscripción generado en el cliente: `MOX-2026-` + 4 dígitos aleatorios.

---

## 9. Flujo del COMPROBANTE de registro

La tarjeta del comprobante muestra: **código, nombre, carnet, categoría, monto,
contacto** y **dos elementos gráficos**:

1. **QR de verificación** (en la tarjeta): enlaza a
   `\`${location.origin}/verificar?codigo=<carnet>\`` — antes del evento avisa que el
   certificado no está disponible; después de emitirlo, abre el certificado.
2. **QR de pago** (paso de pago): imagen `img_qr` del CMS (QR bancario real).

Acciones del comprobante:
- **Enviar por WhatsApp**: abre `wa.me/<número>` con los datos pre-escritos.
- **Descargar comprobante (imagen)**: `html2canvas` → PNG (en iPhone usa `navigator.share`).
- **Imprimir / Guardar PDF**: CSS `@media print` aislando la tarjeta a tamaño carta.

---

## 10. Flujo del CERTIFICADO

```
ADMIN (logueado)
  1. Marca payment_status='pagado'            (PATCH)
  2. "Emitir certificado":                    (PATCH)
       certificate_issued = true
       certificate_code   = 'XXX-CERT-2026-NNNN'
       certificate_issued_at = now()
  3. Automático → llama Edge Function "enviar-certificado" → correo al participante
        │
        ▼
PARTICIPANTE
  - /verificar        → escribe código o carnet → RPC → muestra datos
  - /certificado?codigo=CODE → RPC verify → dibuja nombre+código sobre la PLANTILLA
        → "Descargar": html2canvas + jsPDF → PDF carta horizontal (1 página)
```

**Render del certificado:** una imagen de fondo (`img_cert_template` o un JPG por
defecto) con dos capas de texto posicionadas en %: el **nombre** (fuente manuscrita,
auto-ajuste si es largo) y el **código** (píldora discreta). Las posiciones son
configurables desde el CMS, para adaptarse a cualquier plantilla.

---

## 11. Panel de administración (resumen funcional)

- **Login** por email/password (`/auth/v1/token?grant_type=password`); la sesión se
  guarda en `localStorage`. Un helper **renueva el token** con el `refresh_token`
  antes de que expire (evita 403 por token vencido).
- **Tabla de inscritos** con filtros/estadísticas; marcar pago; emitir/revocar
  certificado; eliminar (con confirmación con estilo del sitio).
- **Registro manual** (modal con todos los campos).
- **CMS**: editar textos, subir imágenes (vía `subir-imagen`), editar precios y fecha
  de promoción.
- **Reporte por categoría** imprimible.
- **Crear usuarios admin** (Edge Function con `service_role`).

---

## 12. Cómo REUTILIZARLO en otro proyecto (checklist)

1. **Crear proyecto Supabase.** Copiar `Project URL` y la `publishable key`.
2. **Aplicar el SQL** de las secciones §3–§6 (tabla, CMS, grants, políticas, trigger,
   funciones). Renombra `congreso_*` a lo que necesites.
3. **Crear el bucket `sitio`** (público) y **desplegar las 2 Edge Functions** (§7).
4. **Configurar secrets** de correo (Gmail o Brevo) en las Edge Functions.
5. **Sembrar contenido** inicial:
   ```sql
   insert into public.congreso_site_content(section_key, content) values
     ('pricing', '{"cutoff":"2026-08-10","Externo":{"promo":600,"regular":700}}'::jsonb),
     ('landing', '{"site_title":"Mi Evento"}'::jsonb);
   ```
6. **Frontend**: ajusta textos/plantilla; define variables de entorno
   `SUPABASE_URL` y `SUPABASE_PUBLISHABLE_KEY`; corre `npm run build`.
7. **Desplegar en Vercel** (o cualquier hosting estático). Configura los rewrites.
8. **Crear el primer usuario admin** desde el panel de Supabase (Auth → Add user).

---

## 13. Variables de entorno y secrets

| Dónde | Nombre | Uso |
|---|---|---|
| Build del frontend | `SUPABASE_URL` | URL del proyecto |
| Build del frontend | `SUPABASE_PUBLISHABLE_KEY` | clave pública (segura para el cliente) |
| Edge Functions | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | inyectadas por Supabase |
| Edge Functions | `GMAIL_USER`, `GMAIL_APP_PASSWORD` | correo vía Gmail |
| Edge Functions | `BREVO_API_KEY`, `BREVO_SENDER_EMAIL` | correo vía Brevo (alternativa) |
| Edge Functions | `SENDER_NAME` | nombre del remitente |

> **Nunca** pongas la `service_role key`, contraseñas o API keys en el frontend ni
> en el repositorio. Van solo como secrets de Edge Functions.

---

## 14. Cuotas gratuitas (referencia)

- **Supabase Free**: 500 MB DB · 1 GB Storage · **5 GB egress/mes** · 50k usuarios/mes ·
  2M invocaciones de Edge Functions. Vigila el egress → usa **imágenes livianas**.
- **Gmail**: ~500 correos/día (emite certificados por tandas).
- **Vercel Hobby**: 100 GB de ancho de banda/mes.

---

## 15. Decisiones de diseño que vale la pena conservar

- **`anon` solo INSERT** + validación en la política RLS = registro público seguro
  sin exponer datos.
- **Trigger BEFORE INSERT** que fuerza estado seguro y calcula precio = imposible
  falsear pago/certificado o precio desde el cliente.
- **Emisión por UPDATE** (no INSERT) = separada del trigger de defaults.
- **RPC SECURITY DEFINER** = verificación pública sin dar lectura de la tabla.
- **Edge Function con `service_role`** para subir imágenes = evita todos los líos
  de permisos de Storage desde el navegador.
- **CMS `jsonb` por secciones** = editar textos, imágenes y precios sin tocar código.
