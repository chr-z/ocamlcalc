# OCamlCalc

> Exact financial calculator — loans, savings and compound interest computed by an
> **OCaml engine compiled to JavaScript** with js_of_ocaml. Zero floats. Zero
> rounding surprises. 100% offline, free, no signup.

[![CI](https://github.com/chr-z/ocamlcalc/actions/workflows/ci.yml/badge.svg)](https://github.com/chr-z/ocamlcalc/actions/workflows/ci.yml)
[![Deploy](https://github.com/chr-z/ocamlcalc/actions/workflows/deploy.yml/badge.svg)](https://github.com/chr-z/ocamlcalc/actions/workflows/deploy.yml)
[![Engine](https://img.shields.io/badge/engine-OCaml%204.14-orange)](https://ocaml.org)
[![Compiler](https://img.shields.io/badge/js_of_ocaml-5.x-blue)](https://ocsigen.org/js_of_ocaml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**Demo: https://chr-z.github.io/ocamlcalc/**

## Why OCaml?

Because money math is *the* textbook case for a statically-typed functional
language with exact arithmetic — and because shipping it as plain JavaScript
proves the point end-to-end:

- **No floats, ever.** `0.1` is not representable in IEEE-754, so this app does
  not use floating point at all. Amounts are integer cents; rates are integers
  scaled by 10²⁴; every power (`(1+r)^n`) becomes an exact ratio of big
  integers computed by our own pure-OCaml bignum (`engine/big.ml`, base-10⁴
  limbs sized so every product stays below 2^53 under jsoo's JS-number
  semantics).
- **Banker's rounding on exact rationals.** Every monetary result is rounded
  half-to-even applied to the *exact* value — never to an approximation of it.
  That's the standard real accounting systems use.
- **Triple parity, enforced in CI.** A Python `decimal` oracle
  (`scripts/gen_goldens.py`) generates golden results → the same engine source
  must reproduce them **byte-for-byte as a native binary** → then the compiled
  JS bundle must reproduce them again in the Node test suite. Native binary,
  JS bundle and oracle can never drift apart.
- **Strong types, boring correctness.** The engine is ~450 lines of OCaml with
  sum types for parse results and one exception type for domain errors. The ML
  type system plus exhaustive matching makes entire bug classes unrepresentable.

## What it does

| Calculator | Details |
| --- | --- |
| **Loan** | Annuity payment, total interest, total paid and the full amortization schedule (interest / principal / balance per month) |
| **Savings** | Monthly deposits + monthly-compounded interest: final balance, total deposited, interest earned |
| **Compound** | Discrete compounding (any periods/year up to daily) with final value and exact effective annual rate to 12 decimals |

Plus: EN / pt-BR interface with instant switch, currency formatting
(symbol, decimal and grouping separators), sample data buttons, keyboard-first
flow, PWA offline mode, dark warm-amber UI.

## Exactness you can audit

The loan schedule shows every month's interest and principal in integer cents —
and the last month absorbs the residual so the balance lands on exactly zero.
Try the half-even probe: a 2.04 loan over 24 months at 0% rounds the payment to
8 (ties go to even), while 2.06 rounds to 9.

## Development

```bash
# regenerate goldens (Python ≥3.9, stdlib only)
python scripts/gen_goldens.py

# compile the engine: native parity suite first, then the JS bundle
bash scripts/build_engine.sh        # needs ocamlfind + js_of_ocaml, or Docker:

docker run --rm -v "$(pwd):/w" -w /w ubuntu:24.04 bash scripts/build_engine.sh

# JS test suite against the real compiled bundle
npm test
```

Layout: `engine/big.ml` (pure-OCaml bignum) · `engine/excore.ml` (exact money
core) · `exglue/exglue.ml` (JS bindings via `Js.Unsafe.set`) · `js/ui.js`
(vanilla UI) · `tests/native_test.ml` (native golden suite) ·
`tests/engine.test.mjs` (Node suite: goldens, error contract, formatting,
i18n parity, PWA sanity).

## Stack

`OCaml 4.14` → `js_of_ocaml 5.x` → plain JS bundle (~160 KB, zero runtime deps).
UI: vanilla ES5-compatible JS + CSS. Hosting: GitHub Pages.

## License

MIT — see [LICENSE](LICENSE).

Built by [@chr-z](https://github.com/chr-z).
