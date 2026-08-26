#!/usr/bin/env bash
# Build & verify the OCaml engine → JS bundle (js/app.js).
# Runs the NATIVE parity suite first (same goldens as the node suite),
# then emits the browser bundle via js_of_ocaml. Docker/CI-friendly:
# installs its own apt deps when missing. Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v ocamlfind >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq ocaml-nox js-of-ocaml libjs-of-ocaml-dev m4 >/dev/null
fi

echo "== native parity suite (OCaml vs python-decimal goldens) =="
ocamlfind ocamlopt -package js_of_ocaml -linkpkg \
  -I "$ROOT/engine" -I "$ROOT/tests" \
  "$ROOT/engine/big.ml" "$ROOT/engine/excore.ml" \
  "$ROOT/tests/goldens.ml" "$ROOT/tests/native_test.ml" \
  -o /tmp/ex_native 2>&1 | grep -v topdirs || true
/tmp/ex_native

echo "== bytecode -> js bundle =="
ocamlfind ocamlc -package js_of_ocaml,js_of_ocaml-compiler -linkpkg \
  -I "$ROOT/engine" -I "$ROOT/tests" \
  "$ROOT/engine/big.ml" "$ROOT/engine/excore.ml" "$ROOT/exglue/exglue.ml" \
  -o /tmp/ex_glue.bc 2>&1 | grep -v topdirs || true
mkdir -p "$ROOT/js"
js_of_ocaml compile --opt 2 /tmp/ex_glue.bc -o "$ROOT/js/app.js"
rm -f /tmp/ex_native /tmp/ex_native.o /tmp/ex_glue.bc /tmp/ex_glue.cmo /tmp/ex_glue.cmi
cmi_cleanup=$(ls "$ROOT"/engine/*.cmi "$ROOT"/engine/*.cmx "$ROOT"/engine/*.o "$ROOT"/tests/*.cmi "$ROOT"/tests/*.cmx "$ROOT"/tests/*.o "$ROOT"/exglue/*.cmi "$ROOT"/exglue/*.cmx "$ROOT"/exglue/*.o 2>/dev/null || true)
if [ -n "$cmi_cleanup" ]; then rm -f $cmi_cleanup; fi
echo "bundle: $(wc -c < "$ROOT/js/app.js") bytes"
