(function () {
  'use strict';

  const cfg = window.MOXENA_CONFIG || {};
  const STORAGE_KEY = 'moxena_registrations_v1';
  const table = cfg.registrationsTable || 'congreso_registrations';
  const remoteEnabled = Boolean(cfg.supabaseUrl && cfg.supabasePublishableKey);

  const readLocal = () => {
    try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]'); }
    catch (_) { return []; }
  };

  const saveLocal = (record) => {
    const rows = readLocal();
    const index = rows.findIndex((row) => row.code === record.code);
    if (index >= 0) rows[index] = { ...rows[index], ...record };
    else rows.push(record);
    localStorage.setItem(STORAGE_KEY, JSON.stringify(rows));
    window.dispatchEvent(new CustomEvent('moxena:registrations-changed'));
  };

  async function saveRemote(record) {
    if (!remoteEnabled) return;
    const response = await fetch(`${cfg.supabaseUrl}/rest/v1/${table}`, {
      method: 'POST',
      headers: {
        apikey: cfg.supabasePublishableKey,
        Authorization: `Bearer ${cfg.supabasePublishableKey}`,
        'Content-Type': 'application/json',
        Prefer: 'resolution=merge-duplicates,return=minimal'
      },
      body: JSON.stringify({
        code: record.code,
        full_name: record.name,
        email: record.email,
        phone: record.phone,
        institution: record.institution,
        category: record.category,
        amount: record.amount,
        pricing_type: record.pricingType,
        payment_status: record.paymentStatus || 'pendiente',
        registered_at: record.registeredAt
      })
    });
    if (!response.ok) throw new Error(await response.text());
  }

  function valueFrom(form, patterns) {
    const controls = Array.from(form.elements || []);
    const control = controls.find((el) => {
      const key = `${el.name || ''} ${el.id || ''} ${el.getAttribute('aria-label') || ''}`.toLowerCase();
      return patterns.some((pattern) => key.includes(pattern));
    });
    return control ? String(control.value || '').trim() : '';
  }

  function selectedText(form, patterns) {
    const controls = Array.from(form.elements || []);
    const control = controls.find((el) => {
      const key = `${el.name || ''} ${el.id || ''}`.toLowerCase();
      return patterns.some((pattern) => key.includes(pattern));
    });
    if (!control) return '';
    if (control.tagName === 'SELECT') return control.options[control.selectedIndex]?.textContent.trim() || control.value;
    return control.value || '';
  }

  function buildRecord(form) {
    const category = selectedText(form, ['categoria', 'category', 'tipo']);
    const amountText = valueFrom(form, ['monto', 'amount', 'precio']);
    return {
      code: `MOX-2026-${String(Date.now()).slice(-6)}`,
      name: valueFrom(form, ['nombre', 'name']),
      email: valueFrom(form, ['correo', 'email']),
      phone: valueFrom(form, ['celular', 'telefono', 'phone', 'whatsapp']),
      institution: valueFrom(form, ['institucion', 'institution', 'empresa']),
      category,
      amount: Number(String(amountText).replace(/[^0-9.]/g, '')) || 0,
      pricingType: 'vigente',
      registeredAt: new Date().toISOString(),
      paymentStatus: 'pendiente'
    };
  }

  document.addEventListener('submit', (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    const record = buildRecord(form);
    if (!record.name) return;
    setTimeout(async () => {
      const receiptText = document.querySelector('[data-code], #receipt-code, #registration-code, .receipt-code')?.textContent
        || document.body.innerText.match(/MOX-2026-[A-Z0-9-]+/i)?.[0]
        || '';
      const displayedAmount = document.querySelector('[data-amount], #receipt-amount, #registration-amount, .receipt-amount')?.textContent || '';
      if (receiptText) record.code = receiptText.trim();
      if (!record.amount && displayedAmount) record.amount = Number(displayedAmount.replace(/[^0-9.]/g, '')) || 0;
      saveLocal(record);
      try { await saveRemote(record); }
      catch (error) { console.error('No se pudo sincronizar la inscripción:', error); }
    }, 0);
  }, true);
})();
