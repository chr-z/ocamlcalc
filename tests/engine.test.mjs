import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/(\w):/, '$1:')), '..');

// ---- boot the real OCaml bundle -------------------------------------------
globalThis.window = globalThis;
await import('../js/app.js');

test('bundle exposes the excalc API', () => {
  assert.equal(typeof globalThis.excalcLoan, 'function');
  assert.equal(typeof globalThis.excalcSavings, 'function');
  assert.equal(typeof globalThis.excalcCompound, 'function');
  assert.equal(typeof globalThis.excalcMoney, 'function');
  assert.equal(globalThis.excalcVersion(), '1.0.0');
});

// ---- goldens (Python decimal ROUND_HALF_EVEN oracle) -----------------------
const goldens = JSON.parse(fs.readFileSync(path.join(ROOT, 'tests', 'goldens.json'), 'utf8'));

function callFor(name) {
  switch (name) {
    case 'loan_basic_100k_12pc_24m': return () => excalcLoan('100000', '12', '24');
    case 'loan_zero_rate': return () => excalcLoan('50000', '0', '12');
    case 'loan_odd_months': return () => excalcLoan('12345.67', '13.37', '37');
    case 'loan_half_even_probe': return () => excalcLoan('100', '2.5', '3');
    case 'loan_big_950m': return () => excalcLoan('950000000', '7.77', '360');
    case 'savings_basic': return () => excalcSavings('1000', '200', '10', '5');
    case 'savings_no_init': return () => excalcSavings('0', '50', '6.25', '3');
    case 'compound_quarterly': return () => excalcCompound('25000', '8.5', '10', '4');
    case 'compound_daily': return () => excalcCompound('10000', '5.25', '7', '365');
    default: throw new Error('no caller for ' + name);
  }
}

for (const [name, expected] of Object.entries(goldens)) {
  test(`golden ${name} matches decimal oracle byte-a-byte`, () => {
    const got = JSON.parse(callFor(name)());
    assert.deepEqual(got, expected);
  });
}

// ---- error contract ---------------------------------------------------------
const E = (code) => JSON.stringify({ ok: false, error: code });

test('input validation errors are stable codes', () => {
  assert.equal(excalcLoan('abc', '10', '12'), E('amount_format'));
  assert.equal(excalcLoan('', '10', '12'), E('amount_empty'));
  assert.equal(excalcLoan('10000000000000000', '10', '12'), E('amount_range'));
  assert.equal(excalcLoan('1000', '1.2.3', '12'), E('rate_format'));
  assert.equal(excalcLoan('1000', '', '12'), E('rate_empty'));
  assert.equal(excalcLoan('1000', '100001', '12'), E('rate_range'));
  assert.equal(excalcLoan('1000', '10', ''), E('months_empty'));
  assert.equal(excalcLoan('1000', '10', 'x'), E('months_format'));
  assert.equal(excalcLoan('1000', '10', '1201'), E('months_range'));
  assert.equal(excalcSavings('0', '50', '10', '101'), E('years_range'));
  assert.equal(excalcSavings('a', '50', '10', '5'), E('initial_format'));
  assert.equal(excalcSavings('0', '-999999999999999999', '10', '5'), E('deposit_range'));
  assert.equal(excalcCompound('100', '10', '5', '366'), E('periods_range'));
  assert.equal(excalcMoney('1.5', '$', '.', ','), E('cents_format'));
});

// ---- money formatting -------------------------------------------------------
test('money formatter groups, localizes and signs', () => {
  const r1 = JSON.parse(excalcMoney('123456789', 'R$', ',', '.'));
  assert.equal(r1.text, 'R$1.234.567,89');
  const r2 = JSON.parse(excalcMoney('-1050', '$', '.', ','));
  assert.equal(r2.text, '-$10.50');
  const r3 = JSON.parse(excalcMoney('5', '€', ',', '.'));
  assert.equal(r3.text, '€0,05');
  const r4 = JSON.parse(excalcMoney('100000000', '\u00A5', '.', ' '));
  assert.equal(r4.text, '¥1 000 000.00');
});

// ---- half-even spot probes through public API -------------------------------
test('payment rounding is half-even on exact ties (big-int rationals)', () => {
  // 2-year loan of 0.02 at 0% -> pay he(2/24)=he(0.083..)=0 ; use cents scale:
  // amount=2.04 months=24 rate=0 => pay = he(204/24)=he(8.5)=8 (ties->even)
  const g = JSON.parse(excalC_loan('2.04', '0', '24'));
  function excalC_loan(a, r, m) { return globalThis.excalcLoan(a, r, m); }
  assert.equal(g.payment, '8');
  // 206/24 = 8.583.. -> 9
  const g2 = JSON.parse(globalThis.excalcLoan('2.06', '0', '24'));
  assert.equal(g2.payment, '9');
});

// ---- i18n parity + HTML coverage -------------------------------------------
const locales = JSON.parse(fs.readFileSync(path.join(ROOT, 'locales', 'i18n.json'), 'utf8'));

test('locales have identical key sets', () => {
  const en = Object.keys(locales.en).sort();
  const pt = Object.keys(locales['pt-BR']).sort();
  assert.deepEqual(en, pt);
});

test('every data-i18n key in index.html exists in both locales', () => {
  const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
  const keys = new Set();
  for (const m of html.matchAll(/data-i18n(?:-attr)?="[^"]*:([^"]+)"/g)) keys.add(m[1]);
  for (const m of html.matchAll(/data-i18n="([^"]+)"/g)) keys.add(m[1]);
  assert.ok(keys.size >= 20, `expected many i18n keys, got ${keys.size}`);
  for (const k of keys) {
    assert.ok(k in locales.en, `missing en key ${k}`);
    assert.ok(k in locales['pt-BR'], `missing pt-BR key ${k}`);
  }
});

// ---- PWA sanity --------------------------------------------------------------
test('sw precache lists existing files', () => {
  const sw = fs.readFileSync(path.join(ROOT, 'sw.js'), 'utf8');
  const list = [...sw.matchAll(/'\.\/([^']+)'/g)].map((m) => m[1]);
  assert.ok(list.length >= 6);
  for (const f of list) {
    if (f === '') continue;
    assert.ok(fs.existsSync(path.join(ROOT, f)), `missing precache file ${f}`);
  }
  assert.match(sw, /__OC_CACHE_VERSION__/);
});

test('manifest and icon are present and valid', () => {
  const mf = JSON.parse(fs.readFileSync(path.join(ROOT, 'manifest.json'), 'utf8'));
  assert.ok(mf.name && mf.start_url);
  const svg = fs.readFileSync(path.join(ROOT, 'assets/icons/icon.svg'), 'utf8');
  assert.match(svg, /<svg/);
});
