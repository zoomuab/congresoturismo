# Congreso Nacional Moxeña 2026

Landing pública y panel de administración del IX Congreso Nacional Moxeña.

## Páginas

- `moxena-congreso-v2.html`: landing e inscripción pública.
- `admin-moxena.html`: administración, estados de pago y exportación CSV.

## Sincronización

1. Ejecuta `supabase/schema.sql` en un proyecto Supabase exclusivo para el congreso.
2. Configura `SUPABASE_URL` y `SUPABASE_PUBLISHABLE_KEY` como variables de entorno en Vercel.
3. Crea el usuario administrador en Supabase Auth y asigna `app_metadata.role = "admin"`.

El comando `npm run build` genera la configuración pública dentro de `dist/`. La
clave publicable puede usarse en el navegador porque las tablas tienen RLS; no
guardes una clave secreta o `service_role` en GitHub ni en el frontend.

## Vercel

- Framework Preset: `Other`
- Build Command: `npm run build`
- Output Directory: `dist`
- Landing: `/`
- Administración: `/admin`
