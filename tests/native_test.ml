(* Native parity suite: exact-engine outputs vs Python-decimal goldens. *)
let fails = ref 0
let total = ref 0

let ck name cond =
  incr total;
  if not cond then (
    incr fails;
    Printf.printf "FAIL %s\n%!" name)

let inputs : (string * string list) list =
  [
    ("loan_basic_100k_12pc_24m", [ "loan"; "100000"; "12"; "24" ]);
    ("loan_zero_rate", [ "loan"; "50000"; "0"; "12" ]);
    ("loan_odd_months", [ "loan"; "12345.67"; "13.37"; "37" ]);
    ("loan_half_even_probe", [ "loan"; "100"; "2.5"; "3" ]);
    ("loan_big_950m", [ "loan"; "950000000"; "7.77"; "360" ]);
    ("savings_basic", [ "savings"; "1000"; "200"; "10"; "5" ]);
    ("savings_no_init", [ "savings"; "0"; "50"; "6.25"; "3" ]);
    ("compound_quarterly", [ "compound"; "25000"; "8.5"; "10"; "4" ]);
    ("compound_daily", [ "compound"; "10000"; "5.25"; "7"; "365" ]);
  ]

let call = function
  | "loan" :: a :: r :: m :: [] -> Excore.loan_json a r m
  | "savings" :: i :: d :: r :: y :: [] -> Excore.savings_json i d r y
  | "compound" :: p :: r :: y :: q :: [] -> Excore.compound_json p r y q
  | _ -> invalid_arg "call"

let () =
  List.iter
    (fun (name, args) ->
      let expected = List.assoc name Goldens.goldens in
      let got = call args in
      ck ("golden:" ^ name) (String.equal expected got);
      if not (String.equal expected got) then (
        print_endline ("exp: " ^ expected);
        print_endline ("got: " ^ got)))
    inputs;
  let is_err e code =
    String.equal e ("{\"ok\":false,\"error\":\"" ^ code ^ "\"}")
  in
  ck "err:amount_format"
    (is_err (Excore.loan_json "abc" "10" "12") "amount_format");
  ck "err:amount_empty" (is_err (Excore.loan_json "" "10" "12") "amount_empty");
  ck "err:amount_range"
    (is_err (Excore.loan_json "10000000000000000" "10" "12") "amount_range");
  ck "err:months_range"
    (is_err (Excore.loan_json "1000" "10" "1201") "months_range");
  ck "err:rate_format" (is_err (Excore.loan_json "1000" "1.2.3" "12") "rate_format");
  ck "err:years_range"
    (is_err (Excore.savings_json "0" "50" "10" "101") "years_range");
  ck "err:periods_range"
    (is_err (Excore.compound_json "100" "10" "5" "366") "periods_range");
  ck "err:cents_lossy" (is_err (Excore.money_json "1.5" "$" "." ",") "cents_format");
  let mj = Excore.money_json "123456789" "R$" "," "." in
  ck "fmt:grouping" (String.equal mj "{\"ok\":true,\"text\":\"R$1.234.567,89\"}");
  let mn = Excore.money_json "-1050" "$" "." "," in
  ck "fmt:negative" (String.equal mn "{\"ok\":true,\"text\":\"-$10.50\"}");
  Printf.printf "native suite: %d checks, %d failures\n%!" !total !fails;
  if !fails > 0 then exit 1
