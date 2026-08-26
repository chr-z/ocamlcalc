/* OCamlCalc UI — vanilla, i18n-reactive, PWA. The engine lives in js/app.js
 * (OCaml via js_of_ocaml); this layer only formats and renders. */
(function () {
  'use strict';

  var LS_FMT = 'oc_fmt'; // {"sym","ds","gs"}

  function $(id) { return document.getElementById(id); }

  var fmt = { sym: '$', ds: '.', gs: ',' };
  try {
    var saved = JSON.parse(localStorage.getItem(LS_FMT) || 'null');
    if (saved && saved.sym) {
      fmt = saved;
      if (fmt.ds === ',') { fmt.ds = ','; fmt.gs = '.'; }
    }
  } catch (e) { /* private mode */ }

  function persistFmt() {
    try { localStorage.setItem(LS_FMT, JSON.stringify(fmt)); } catch (e) {}
  }

  function money(cents) {
    var r = globalThis.excalcMoney(String(cents), fmt.sym, fmt.ds, fmt.gs);
    if (!r) return String(cents);
    try { return JSON.parse(r).text; } catch (e) { return String(cents); }
  }

  function tr(key) { return window.NN_I18N.tr(key, key); }

  function showErr(el, payload) {
    var code = '';
    try { code = JSON.parse(payload).error || ''; } catch (e) { code = ''; }
    el.textContent = code ? tr('err.' + code) : payload;
    el.hidden = false;
  }

  /* ---------- tabs ---------- */
  var tabs = [
    ['tab-loan', 'panel-loan'],
    ['tab-savings', 'panel-savings'],
    ['tab-compound', 'panel-compound']
  ];
  tabs.forEach(function (pair) {
    $(pair[0]).addEventListener('click', function () {
      tabs.forEach(function (p) {
        var on = p[0] === pair[0];
        $(p[0]).classList.toggle('active', on);
        $(p[0]).setAttribute('aria-selected', on ? 'true' : 'false');
        $(p[1]).hidden = !on;
      });
    });
  });

  /* ---------- loan ---------- */
  $('lGo').addEventListener('click', function () {
    var out = $('loanOut');
    out.hidden = true;
    var r = globalThis.excalcLoan(
      $('lAmount').value.trim() || '',
      $('lRate').value.trim(),
      $('lMonths').value.trim());
    try {
      var p = JSON.parse(r);
      if (p.ok === false) return showErr($('loanErr'), r);
      $('loanErr').hidden = true;
      $('loPay').textContent = money(p.payment);
      $('loInt').textContent = money(p.totalInterest);
      $('loPaid').textContent = money(p.totalPaid);
      var tb = $('loTable').querySelector('tbody');
      tb.innerHTML = '';
      p.schedule.forEach(function (row) {
        var trr = document.createElement('tr');
        [String(row.m), money(row.i), money(row.p), money(row.b)].forEach(function (v) {
          var td = document.createElement('td');
          td.textContent = v;
          trr.appendChild(td);
        });
        tb.appendChild(trr);
      });
      out.hidden = false;
    } catch (e) {
      showErr($('loanErr'), r);
    }
  });
  $('lSample').addEventListener('click', function () {
    $('lAmount').value = '100000';
    $('lRate').value = '12';
    $('lMonths').value = '24';
    $('lGo').click();
  });

  /* ---------- savings ---------- */
  $('sGo').addEventListener('click', function () {
    $('savOut').hidden = true;
    var r = globalThis.excalcSavings(
      $('sInit').value.trim(),
      $('sDep').value.trim(),
      $('sRate').value.trim(),
      $('sYears').value.trim());
    try {
      var p = JSON.parse(r);
      if (p.ok === false) return showErr($('savErr'), r);
      $('savErr').hidden = true;
      $('svBal').textContent = money(p.finalBalance);
      $('svDep').textContent = money(p.totalDeposited);
      $('svInt').textContent = money(p.totalInterest);
      $('savOut').hidden = false;
    } catch (e) {
      showErr($('savErr'), r);
    }
  });
  $('sSample').addEventListener('click', function () {
    $('sInit').value = '1000';
    $('sDep').value = '200';
    $('sRate').value = '10';
    $('sYears').value = '5';
    $('sGo').click();
  });

  /* ---------- compound ---------- */
  $('cGo').addEventListener('click', function () {
    $('cmpOut').hidden = true;
    var r = globalThis.excalcCompound(
      $('cPrincipal').value.trim(),
      $('cRate').value.trim(),
      $('cYears').value.trim(),
      $('cPery').value.trim());
    try {
      var p = JSON.parse(r);
      if (p.ok === false) return showErr($('cmpErr'), r);
      $('cmpErr').hidden = true;
      $('cvFinal').textContent = money(p.finalValue);
      $('cvAer').textContent = p.effectiveAnnualPct12 + '%';
      var n = Number($('cYears').value || 0) * Number($('cPery').value || 0);
      $('cvN').textContent = isFinite(n) && n > 0 ? String(n) : '—';
      $('cmpOut').hidden = false;
    } catch (e) {
      showErr($('cmpErr'), r);
    }
  });
  $('cSample').addEventListener('click', function () {
    $('cPrincipal').value = '25000';
    $('cRate').value = '8.5';
    $('cYears').value = '10';
    $('cPery').value = '4';
    $('cGo').click();
  });

  /* ---------- language ---------- */
  var langSel = $('langSel');
  langSel.value = window.NN_I18N.getLang();
  langSel.addEventListener('change', function () {
    window.NN_I18N.setLang(langSel.value);
  });

  function applyStaticTexts() {
    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      el.textContent = tr(el.getAttribute('data-i18n'));
    });
  }

  window.NN_I18N.load(function () {
    applyStaticTexts();
    window.NN_I18N.onChange(applyStaticTexts);
  });

  $('ver').textContent = 'engine v' + globalThis.excalcVersion();

  /* keyboard: Enter submits the active panel */
  [['lAmount', 'lGo'], ['lRate', 'lGo'], ['lMonths', 'lGo'],
   ['sInit', 'sGo'], ['sDep', 'sGo'], ['sRate', 'sGo'], ['sYears', 'sGo'],
   ['cPrincipal', 'cGo'], ['cRate', 'cGo'], ['cYears', 'cGo'], ['cPery', 'cGo']]
    .forEach(function (pair) {
      $(pair[0]).addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter') $(pair[1]).click();
      });
    });
})();
