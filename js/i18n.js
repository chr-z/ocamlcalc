/* NimNote i18n — EN / pt-BR, localStorage-backed. */
(function (global) {
  'use strict';

  var LS_KEY = 'nn_lang';
  var cache = {};
  var listeners = [];

  function detect() {
    try {
      var saved = localStorage.getItem(LS_KEY);
      if (saved === 'en' || saved === 'pt-BR') return saved;
    } catch (e) { /* private mode */ }
    var nav = (navigator.languages && navigator.languages[0]) || navigator.language || 'en';
    return /^pt\b/i.test(nav) ? 'pt-BR' : 'en';
  }

  var current = detect();

  function load(lang, cb) {
    if (cache[lang]) { cb(cache[lang]); return; }
    var xhr = new XMLHttpRequest();
    xhr.open('GET', 'locales/i18n.json', true);
    xhr.onload = function () {
      var all = {};
      try { all = JSON.parse(xhr.responseText); } catch (e) { all = {}; }
      for (var k in all) {
        if (!cache[k]) cache[k] = all[k] || {};
      }
      cb(cache[lang] || {});
    };
    xhr.onerror = function () { cb({}); };
    xhr.send();
  }

  function tr(key, fallback) {
    var d = cache[current];
    if (d && Object.prototype.hasOwnProperty.call(d, key)) return d[key];
    var e = cache.en;
    if (e && Object.prototype.hasOwnProperty.call(e, key)) return e[key];
    return fallback !== undefined ? fallback : key;
  }

  function setLang(lang) {
    current = lang === 'pt-BR' ? 'pt-BR' : 'en';
    try { localStorage.setItem(LS_KEY, current); } catch (e) {}
    load(current, function () {
      listeners.forEach(function (fn) { fn(current); });
    });
  }

  function getLang() { return current; }
  function onChange(fn) { listeners.push(fn); }

  global.NN_I18N = {
    tr: tr,
    setLang: setLang,
    getLang: getLang,
    onChange: onChange,
    load: function (cb) { load(current, cb); }
  };
})(window);
