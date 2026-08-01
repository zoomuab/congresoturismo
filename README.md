# Congreso Nacional Moxeña 2026

Landing pública y panel de administración del IX Congreso Nacional Moxeña.

## Páginas

- `moxena-congreso-v2.html`: landing e inscripción pública.
- `admin-moxena.html`: administración, estados de pago y exportación CSV.

## Sincronización

El sistema funciona localmente con almacenamiento del navegador. Para sincronización real entre dispositivos:

1. Ejecuta `supabase/schema.sql` en un proyecto Supabase exclusivo para el congreso.
2. Copia la URL del proyecto y la clave publicable en `moxena-config.js`.
3. Crea el usuario administrador en Supabase Auth y asigna `app_metadata.role = "admin"`.

No uses una clave `service_role` en estos archivos públicos.
