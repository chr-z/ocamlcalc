(* Exglue — exposes the exact engine to JavaScript.
 *
 * Convention mirrors the house style (NimNote nn_api): plain strings in,
 * single-line JSON out, one global per operation. All arguments are strings;
 * the engine owns every parse/validation decision. No ## sugar (ppx-free),
 * only Js.Unsafe.set — see POLYGLOT_ONDA3_LOG gotchas.
 *)

open Js_of_ocaml

let js_str f : Js.js_string Js.t = Js.string f

let () =
  Js.Unsafe.set Js.Unsafe.global (Js.string "excalcLoan")
    (Js.wrap_callback (fun a b c ->
         js_str (Excore.loan_json (Js.to_string a) (Js.to_string b)
                   (Js.to_string c))));
  Js.Unsafe.set Js.Unsafe.global (Js.string "excalcSavings")
    (Js.wrap_callback (fun a b c d ->
         js_str (Excore.savings_json (Js.to_string a) (Js.to_string b)
                   (Js.to_string c) (Js.to_string d))));
  Js.Unsafe.set Js.Unsafe.global (Js.string "excalcCompound")
    (Js.wrap_callback (fun a b c d ->
         js_str (Excore.compound_json (Js.to_string a) (Js.to_string b)
                   (Js.to_string c) (Js.to_string d))));
  Js.Unsafe.set Js.Unsafe.global (Js.string "excalcMoney")
    (Js.wrap_callback (fun a b c d ->
         js_str (Excore.money_json (Js.to_string a) (Js.to_string b)
                   (Js.to_string c) (Js.to_string d))));
  Js.Unsafe.set Js.Unsafe.global (Js.string "excalcVersion")
    (Js.wrap_callback (fun () -> js_str (Excore.version ())))
