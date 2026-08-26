/* Functional E2E over the REAL bundle + UI in a real DOM (jsdom).
 * Boots index.html, runs all page scripts, drives the three calculators,
 * switches language, asserts on-screen values. */
import { JSDOM } from 'jsdom';
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/(\w):/, '$1:')), '..');
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

// serve relative fetches (XHR) for locales/i18n.json from disk
const dom = new JSDOM(html, {
  url: 'http://localhost/',
  runScripts: 'outside-only',
  pretendToBeVisual: true,
});
const { window } = dom;

// minimal localStorage (jsdom has it) + eval order: engine, i18n, ui
window.eval(fs.readFileSync(path.join(ROOT, 'js', 'app.js'), 'utf8'));
window.eval(fs.readFileSync(path.join(ROOT, 'js', 'i18n.js'), 'utf8'));

// stub the XHR used by i18n loader with the locale file contents
const localeSrc = fs.readFileSync(path.join(ROOT, 'locales', 'i18n.json'), 'utf8');
window.XMLHttpRequest = class {
  open(m, u) { this._u = u; }
  send() {
    setTimeout(() => {
      this.readyState = 4;
      this.status = 200;
      this.responseText = localeSrc;
      if (this.onload) this.onload();
    }, 0);
  }
};

let pass = 0;
let fail = 0;
function ck(name, cond) {
  if (cond) { pass++; }
  else { fail++; console.log('FAIL', name); }
}

await new Promise((res) => {
  window.NN_I18N.load(res);
});

window.eval(fs.readFileSync(path.join(ROOT, 'js', 'ui.js'), 'utf8'));
const doc = window.document;
const $ = (id) => doc.getElementById(id);

// --- loan sample flow -------------------------------------------------------
$('lSample').click();
ck('loan visible', !$('loanOut').hidden);
ck('loan payment on screen', $('loPay').textContent.includes('4,707.35'));
ck('loan total interest', $('loInt').textContent.includes('12,976.34'));
ck('schedule rows = 24', $('loTable').querySelectorAll('tbody tr').length === 24);
ck('last balance zero', /[\d,.]*0\.00$/.test($('loTable').querySelector('tbody tr:last-child td:last-child').textContent));

// half-even probe through the UI: 2.04 @ 0% x24 -> pay 8 cents = $0.08
$('lAmount').value = '2.04';
$('lRate').value = '0';
$('lMonths').value = '24';
$('lGo').click();
ck('half-even pay $0.08', $('loPay').textContent.replace(/\u00a0/g, ' ').includes('0.08'));

// validation surfaces localized-ish error, output stays hidden
$('lAmount').value = 'abc';
$('lGo').click();
ck('error shown for abc', !$('loanErr').hidden && $('loanErr').textContent.length > 3);

// --- savings -----------------------------------------------------------------
$('sInit').value = '1000';
$('sDep').value = '200';
$('sRate').value = '10';
$('sYears').value = '5';
$('sGo').click();
ck('savings balance', $('svBal').textContent.includes('17,261.77'));
ck('savings interest', $('svInt').textContent.includes('4,261.77'));

// --- compound -----------------------------------------------------------------
$('cPrincipal').value = '25000';
$('cRate').value = '8.5';
$('cYears').value = '10';
$('cPery').value = '4';
$('cGo').click();
ck('compound final', $('cvFinal').textContent.includes('57,972.60'));
ck('compound AER', $('cvAer').textContent.startsWith('8.774796172119%'));

// --- language toggle without reload --------------------------------------------
window.NN_I18N.setLang('pt-BR');
await new Promise((r) => setTimeout(r, 30));
ck('hero in pt-BR', $('tab-loan').textContent === 'Empréstimo' || doc.querySelector('[data-i18n="ui.tabLoan"]').textContent === 'Empréstimo');
window.NN_I18N.setLang('en');
await new Promise((r) => setTimeout(r, 30));

console.log(`E2E: ${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
