import { cp, mkdir, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const projectRoot = resolve(import.meta.dirname, '..');
const outputDirectory = resolve(projectRoot, 'dist');
const supabaseUrl = process.env.SUPABASE_URL?.trim();
const supabasePublishableKey = process.env.SUPABASE_PUBLISHABLE_KEY?.trim();

if (!supabaseUrl || !supabasePublishableKey) {
  throw new Error(
    'Faltan SUPABASE_URL o SUPABASE_PUBLISHABLE_KEY en las variables de entorno.'
  );
}

const publicFiles = [
  'moxena-congreso-v2.html',
  'admin-moxena.html',
  'presentacion.html',
  'recorridos.html',
  'moxena-system.js',
  'admin-system.js'
];

await rm(outputDirectory, { recursive: true, force: true });
await mkdir(outputDirectory, { recursive: true });

for (const file of publicFiles) {
  await cp(resolve(projectRoot, file), resolve(outputDirectory, file));
}

const clientConfig = `window.MOXENA_CONFIG = Object.freeze(${JSON.stringify(
  {
    supabaseUrl,
    supabasePublishableKey,
    registrationsTable: 'congreso_registrations',
    settingsTable: 'congreso_site_content'
  },
  null,
  2
)});\n`;

await writeFile(resolve(outputDirectory, 'moxena-config.js'), clientConfig, 'utf8');

console.log('Sitio preparado correctamente en dist/.');

