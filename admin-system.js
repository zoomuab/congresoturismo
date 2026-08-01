(function () {
  'use strict';

  const cfg = window.MOXENA_CONFIG || {};
  const STORAGE_KEY = 'moxena_registrations_v1';
  const table = cfg.registrationsTable || 'congreso_registrations';
  const remoteEnabled = Boolean(cfg.supabaseUrl && cfg.supabasePublishableKey);
  const SESSION_KEY = 'moxena_admin_session_v1';

  function getSession() {
    try { return JSON.parse(localStorage.getItem(SESSION_KEY) || 'null'); }
    catch (_) { return null; }
  }

  function showLogin() {
    if (document.getElementById('admin-login-overlay')) return;
    const overlay = document.createElement('div');
    overlay.id = 'admin-login-overlay';
    overlay.style.cssText = 'position:fixed;inset:0;z-index:1000;background:rgba(8,24,19,.94);display:grid;place-items:center;padding:20px';
    overlay.innerHTML = `<form id="admin-login-form" style="width:min(420px,100%);background:#fff;border:1px solid #EFE2BC;border-radius:20px;padding:30px;box-shadow:0 24px 70px rgba(0,0,0,.35)">
      <h2 style="font-family:var(--serif);color:var(--jungle-dk);margin:0 0 8px">Acceso administrativo</h2>
      <p style="color:#6b5b3e;font-size:.86rem;margin:0 0 22px">Ingresa con el usuario autorizado del congreso.</p>
      <label style="display:block;font-size:.78rem;font-weight:800;margin-bottom:6px">Correo</label>
      <input name="email" type="email" required autocomplete="username" style="width:100%;padding:12px 14px;border:1px solid #E4D6AE;border-radius:10px;margin-bottom:14px;font:inherit">
      <label style="display:block;font-size:.78rem;font-weight:800;margin-bottom:6px">Contraseña</label>
      <input name="password" type="password" required autocomplete="current-password" style="width:100%;padding:12px 14px;border:1px solid #E4D6AE;border-radius:10px;margin-bottom:18px;font:inherit">
      <button class="btn btn-gold" type="submit" style="width:100%;justify-content:center">Ingresar</button>
      <p id="admin-login-error" role="alert" style="display:none;color:var(--brick);font-size:.8rem;margin:14px 0 0"></p>
    </form>`;
    document.body.appendChild(overlay);
    overlay.querySelector('form').addEventListener('submit', login);
  }

  async function login(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const errorBox = form.querySelector('#admin-login-error');
    const button = form.querySelector('button');
    button.disabled = true;
    errorBox.style.display = 'none';
    try {
      const response = await fetch(`${cfg.supabaseUrl}/auth/v1/token?grant_type=password`, {
        method: 'POST',
        headers: { apikey: cfg.supabasePublishableKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: form.email.value, password: form.password.value })
      });
      const payload = await response.json();
      if (!response.ok) throw new Error('Correo o contraseña incorrectos.');
      localStorage.setItem(SESSION_KEY, JSON.stringify(payload));
      document.getElementById('admin-login-overlay')?.remove();
      await refresh();
    } catch (error) {
      errorBox.textContent = error.message;
      errorBox.style.display = 'block';
    } finally { button.disabled = false; }
  }

  const normalize = (row) => ({
    id: row.id,
    code: row.code,
    name: row.full_name ?? row.name ?? '',
    email: row.email ?? '',
    phone: row.phone ?? '',
    institution: row.institution ?? '',
    category: row.category ?? 'Externo',
    amount: Number(row.amount) || 0,
    pricingType: row.pricing_type ?? row.pricingType ?? 'vigente',
    registeredAt: row.registered_at ?? row.registeredAt ?? new Date().toISOString(),
    paymentStatus: row.payment_status ?? row.paymentStatus ?? 'pendiente'
  });

  function readLocal() {
    try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]').map(normalize); }
    catch (_) { return []; }
  }

  function writeLocal() {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(registrations));
  }

  async function syncAll() {
    writeLocal();
    if (!remoteEnabled || !getSession()?.access_token || !registrations.length) return;
    const payload = registrations.map((record) => ({
      code: record.code,
      full_name: record.name,
      email: record.email || null,
      phone: record.phone || null,
      institution: record.institution || null,
      category: record.category,
      amount: record.amount,
      pricing_type: record.pricingType || 'vigente',
      payment_status: record.paymentStatus || 'pendiente',
      registered_at: record.registeredAt
    }));
    await request(table, {
      method: 'POST',
      headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(payload)
    });
  }

  async function request(path, options = {}) {
    const session = getSession();
    if (remoteEnabled && !session?.access_token) {
      showLogin();
      throw new Error('Se requiere iniciar sesión');
    }
    const response = await fetch(`${cfg.supabaseUrl}/rest/v1/${path}`, {
      ...options,
      headers: {
        apikey: cfg.supabasePublishableKey,
        Authorization: `Bearer ${session?.access_token || cfg.supabasePublishableKey}`,
        'Content-Type': 'application/json',
        ...(options.headers || {})
      }
    });
    if (!response.ok) throw new Error(await response.text());
    return response.status === 204 ? null : response.json();
  }

  async function refresh() {
    try {
      if (remoteEnabled) {
        if (!getSession()?.access_token) { showLogin(); return; }
        const rows = await request(`${table}?select=*&order=registered_at.desc`);
        registrations = rows.map(normalize);
      } else {
        registrations = readLocal();
      }
      document.querySelectorAll('.badge-demo').forEach((el) => { el.textContent = remoteEnabled ? 'Sincronizado' : 'Modo local'; });
      renderTable();
      renderStats();
    } catch (error) {
      console.error(error);
      registrations = readLocal();
      renderTable();
      renderStats();
      toast('Sin conexión: mostrando datos locales');
    }
  }

  document.getElementById('reg-tbody').addEventListener('click', async (event) => {
    const button = event.target.closest('button');
    if (!button) return;
    setTimeout(async () => {
      writeLocal();
      if (!remoteEnabled) return;
      const record = registrations[Number(button.dataset.idx)];
      try {
        if (button.dataset.action === 'delete') {
          const code = button.closest('tr')?.querySelector('.code-cell')?.textContent.trim();
          if (code) await request(`${table}?code=eq.${encodeURIComponent(code)}`, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
        } else if (record) {
          await request(`${table}?code=eq.${encodeURIComponent(record.code)}`, {
            method: 'PATCH',
            headers: { Prefer: 'return=minimal' },
            body: JSON.stringify({ payment_status: record.paymentStatus })
          });
        }
      } catch (error) { console.error(error); toast('No se pudo sincronizar el cambio'); }
    }, 0);
  }, true);

  window.addEventListener('moxena:registrations-changed', refresh);
  window.addEventListener('storage', (event) => { if (event.key === STORAGE_KEY) refresh(); });
  document.getElementById('add-manual').addEventListener('click', () => {
    setTimeout(() => syncAll().catch((error) => { console.error(error); toast('Guardado localmente; falta sincronizar'); }), 0);
  }, true);
  document.getElementById('file-input').addEventListener('change', () => {
    setTimeout(() => syncAll().catch((error) => { console.error(error); toast('Importado localmente; falta sincronizar'); }), 1200);
  });
  ['cfg-cutoff', 'cfg-event-date', 'cfg-goal', 'cfg-whatsapp', 'group-discount'].forEach((id) => {
    document.getElementById(id)?.addEventListener('change', () => {
      const settings = {};
      ['cfg-cutoff', 'cfg-event-date', 'cfg-goal', 'cfg-whatsapp', 'group-discount'].forEach((settingId) => {
        settings[settingId] = document.getElementById(settingId)?.value;
      });
      localStorage.setItem('moxena_settings_v1', JSON.stringify(settings));
    });
  });
  try {
    const settings = JSON.parse(localStorage.getItem('moxena_settings_v1') || '{}');
    Object.entries(settings).forEach(([id, value]) => { const input = document.getElementById(id); if (input) input.value = value; });
  } catch (_) { /* keep defaults */ }
  setInterval(refresh, remoteEnabled ? 30000 : 5000);
  refresh();
})();
