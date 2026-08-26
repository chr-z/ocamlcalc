(* Excore — exact-decimal money engine for OCamlCalc.
 *
 * Amounts live in integer cents; rates are exact integers scaled by 10^24.
 * No floating point anywhere: powers become ratios of big integers (our own
 * pure-OCaml bignum, see big.ml) and every monetary result comes from
 * banker's rounding (half-even) applied to the EXACT rational.
 *
 * Parity contract with the Python-decimal oracle (scripts/gen_goldens.py):
 *   - money strings carry at most 2 fractional digits;
 *   - rate strings carry at most 24 fractional digits;
 *   - monthly interest = round_he(balance_cents * pct / 1200);
 *   - annuity payment = round_he(P * pct * a^n / (1200*scl*(a^n - b^n)))
 *     over exact big-int ratios, a = 1200*scl + pct, b = 1200*scl;
 *   - last amortization month absorbs the residual so final balance == 0.
 *)

let scl : Big.t = Big.shift_limbs Big.one 6 (* 10^24 = (10^4)^6 *)

let rec pow10 (k : int) : Big.t =
  if k <= 0 then Big.one else Big.mul_small (pow10 (k - 1)) 10

(* Round num/den to nearest integer, ties to even. Exact, any signs. *)
let round_he (num : Big.t) (den : Big.t) : Big.t =
  let nn = Big.abs num and dd = Big.abs den in
  let q, r = Big.mag_divmod nn dd in
  let two_r = Big.add r r in
  let c = Big.cmp two_r dd in
  let q =
    if c > 0 then Big.succ q
    else if c < 0 then q
    else if Big.is_even q then q
    else Big.succ q
  in
  if num.neg <> den.neg && not (Big.is_zero q) then { q with Big.neg = true }
  else q

let count_fracs (s : string) : int =
  match String.index_opt s '.' with
  | None -> 0
  | Some i -> String.length s - i - 1

exception Jerr of string

let need ?(prefix = "") (r : (Big.t, string) Result.t) : Big.t =
  match r with
  | Ok v -> v
  | Error e -> if prefix = "" then raise (Jerr e) else raise (Jerr (prefix ^ "_" ^ e))

let guard (bad : bool) (code : string) : unit = if bad then raise (Jerr code)

(* |money| < 10^17 cents (i.e. |string| < 10^15), rates |pct| <= 100000. *)
let amt_cap : Big.t = Big.mul (pow10 15) (Big.of_int 100)
let rate_cap : Big.t = Big.mul (pow10 5) scl

(* Parse a money string into integer CENTS (max 2 fractional digits). *)
let parse_money (prefix : string) (s : string) : Big.t =
  if String.length s = 0 then raise (Jerr (prefix ^ "_empty"));
  guard (count_fracs s > 2) (prefix ^ "_format");
  let scaled = need ~prefix (Big.of_decimal_string s 24) in
  (* <= 2 fractional digits => cents = scaled / 10^(24-2), exactly ONCE *)
  let q, r = Big.divmod scaled (pow10 22) in
  guard (not (Big.is_zero r)) (prefix ^ "_format");
  guard (Big.cmp (Big.abs q) amt_cap >= 0) (prefix ^ "_range");
  q

(* Parse a rate percent string into an exact scale-24 integer. *)
let parse_rate (s : string) : Big.t =
  if String.length s = 0 then raise (Jerr "rate_empty");
  let v = need ~prefix:"rate" (Big.of_decimal_string s 24) in
  guard (Big.cmp (Big.abs v) rate_cap > 0) "rate_range";
  v

(* Parse a plain count ("24"); saturates so ranges can reject safely. *)
let count_gen (pre : string) (s : string) : int =
  if String.length s = 0 then raise (Jerr (pre ^ "_empty"));
  let n = String.length s in
  let v = ref 0 in
  for i = 0 to n - 1 do
    let c = s.[i] in
    guard (c < '0' || c > '9') (pre ^ "_format");
    (* cap MUST stay below 2^30: OCaml ints are 31-bit under js_of_ocaml
       (63-bit on native), so a bigger saturation constant silently wraps *)
    v := min 999999999 ((!v * 10) + (Char.code c - Char.code '0'))
  done;
  !v

let months_of (s : string) : int = count_gen "months" s
let years_of (s : string) : int = count_gen "years" s
let periods_of (s : string) : int = count_gen "periods" s

(* Monthly interest in cents: he(balance_cents * rate / 1200). *)
let monthly_interest (bal : Big.t) (rate : Big.t) : Big.t =
  round_he (Big.mul bal rate) (Big.mul (Big.of_int 1200) scl)

type loan_row = { mth : int; intr : Big.t; princ : Big.t; bal : Big.t }

let rec bpow (x : Big.t) (n : int) : Big.t =
  if n = 0 then Big.one
  else if n land 1 = 0 then bpow (Big.mul x x) (n / 2)
  else Big.mul x (bpow x (n - 1))

let loan_calc (amount : Big.t) (rate : Big.t) (months : int) :
    Big.t * Big.t * Big.t * loan_row list =
  let b = Big.mul (Big.of_int 1200) scl in
  let pay =
    if Big.is_zero rate then round_he amount (Big.of_int months)
    else begin
      let a = Big.add b rate in
      let an = bpow a months in
      let ad = bpow b months in
      round_he
        (Big.mul (Big.mul amount rate) an)
        (Big.mul (Big.of_int 1200) (Big.mul scl (Big.sub an ad)))
    end
  in
  let bal = ref amount in
  let ti = ref Big.zero in
  let rows = ref [] in
  for m = 1 to months do
    let i = monthly_interest !bal rate in
    let princ, nb =
      if m = months then (!bal, Big.zero)
      else begin
        let p = Big.sub pay i in
        (p, Big.sub !bal p)
      end
    in
    bal := nb;
    ti := Big.add !ti i;
    rows := { mth = m; intr = i; princ; bal = !bal } :: !rows
  done;
  let rows = List.rev !rows in
  (pay, !ti, Big.add amount !ti, rows)

let savings_calc (init : Big.t) (dep : Big.t) (rate : Big.t) (years : int) :
    Big.t * Big.t * Big.t =
  let bal = ref init in
  let deposited = ref init in
  let ti = ref Big.zero in
  for _ = 1 to (years * 12) do
    bal := Big.add !bal dep;
    deposited := Big.add !deposited dep;
    let i = monthly_interest !bal rate in
    bal := Big.add !bal i;
    ti := Big.add !ti i
  done;
  (!bal, !deposited, !ti)

let compound_calc (principal : Big.t) (rate : Big.t) (years : int)
    (per_year : int) : Big.t * Big.t =
  (* den = 100*per_year scaled: growth factor (100py*scl + pct)/(100py*scl)
     equals the oracle's (D+pct)/D with D = 100*per_year on integer cents *)
  let den = Big.mul (Big.of_int (100 * per_year)) scl in
  let step = Big.add den rate in
  let v = ref principal in
  for _ = 1 to (years * per_year) do
    v := round_he (Big.mul !v step) den
  done;
  let gd = bpow den per_year in
  let gn = bpow step per_year in
  (* aer12 = he((growth - 1) * 100 * 10^12) exact *)
  let aer12 = round_he (Big.mul (Big.sub gn gd) (pow10 14)) gd in
  (!v, aer12)

(* Format integer cents as money: sym + grouped int part + ds + 2 decimals. *)
let money_fmt (cents : Big.t) (sym : string) (ds : string) (gs : string) :
    string =
  let neg = Big.sign cents < 0 in
  let s = Big.to_string (Big.abs cents) in
  let pad = String.make (max 0 (3 - String.length s)) '0' in
  let s = pad ^ s in
  let l = String.length s in
  let intpart = String.sub s 0 (l - 2) in
  let frac = String.sub s (l - 2) 2 in
  let buf = Buffer.create 32 in
  if neg then Buffer.add_char buf '-';
  Buffer.add_string buf sym;
  String.iteri
    (fun idx ch ->
      Buffer.add_char buf ch;
      let rest = l - 2 - 1 - idx in
      if rest > 0 && rest mod 3 = 0 && String.length gs > 0 then
        Buffer.add_string buf gs)
    intpart;
  Buffer.add_string buf ds;
  Buffer.add_string buf frac;
  Buffer.contents buf

(* ---------------- JSON emission ---------------- *)

let esc (s : string) : string =
  let b = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      if c = '"' || c = '\\' then (
        Buffer.add_char b '\\';
        Buffer.add_char b c)
      else if Char.code c < 32 then
        Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      else Buffer.add_char b c)
    s;
  Buffer.contents b

let err_json (code : string) : string =
  Printf.sprintf "{\"ok\":false,\"error\":\"%s\"}" (esc code)

let run (f : unit -> string) : string =
  try f () with Jerr code -> err_json code

let row_json (r : loan_row) : string =
  Printf.sprintf "{\"m\":%d,\"i\":\"%s\",\"p\":\"%s\",\"b\":\"%s\"}" r.mth
    (Big.to_string r.intr)
    (Big.to_string r.princ)
    (Big.to_string r.bal)

let loan_json (amt_s : string) (rate_s : string) (mon_s : string) : string =
  run (fun () ->
    let amount = parse_money "amount" amt_s in
    let rate = parse_rate rate_s in
    let months = months_of mon_s in
    guard (months < 1 || months > 1200) "months_range";
    let pay, ti, tp, rows = loan_calc amount rate months in
    let buf = Buffer.create (64 + (48 * List.length rows)) in
    Buffer.add_string buf "{\"ok\":true,\"payment\":\"";
    Buffer.add_string buf (Big.to_string pay);
    Buffer.add_string buf "\",\"totalInterest\":\"";
    Buffer.add_string buf (Big.to_string ti);
    Buffer.add_string buf "\",\"totalPaid\":\"";
    Buffer.add_string buf (Big.to_string tp);
    Buffer.add_string buf "\",\"schedule\":[";
    List.iteri
      (fun k r ->
        if k > 0 then Buffer.add_char buf ',';
        Buffer.add_string buf (row_json r))
      rows;
    Buffer.add_string buf "]}";
    Buffer.contents buf)

let savings_json (init_s : string) (dep_s : string) (rate_s : string)
    (years_s : string) : string =
  run (fun () ->
    let init = parse_money "initial" init_s in
    let dep = parse_money "deposit" dep_s in
    let rate = parse_rate rate_s in
    let years = years_of years_s in
    guard (years < 1 || years > 100) "years_range";
    let fb, td, ti = savings_calc init dep rate years in
    Printf.sprintf
      "{\"ok\":true,\"finalBalance\":\"%s\",\"totalDeposited\":\"%s\",\"totalInterest\":\"%s\"}"
      (Big.to_string fb) (Big.to_string td) (Big.to_string ti))

(* Render an integer scaled by 10^12 as a plain decimal string. *)
let fmt_scaled12 (v : Big.t) : string =
  let neg = Big.sign v < 0 in
  let a = Big.abs v in
  let q, r = Big.divmod a (pow10 12) in
  let fs = Big.to_string r in
  let pad = String.make (12 - String.length fs) '0' in
  (if neg then "-" else "") ^ Big.to_string q ^ "." ^ pad ^ fs

let compound_json (p_s : string) (rate_s : string) (years_s : string)
    (pery_s : string) : string =
  run (fun () ->
    let principal = parse_money "principal" p_s in
    let rate = parse_rate rate_s in
    let years = years_of years_s in
    guard (years < 1 || years > 100) "years_range";
    let pery = periods_of pery_s in
    guard (pery < 1 || pery > 365) "periods_range";
    let fv, aer12 = compound_calc principal rate years pery in
    Printf.sprintf
      "{\"ok\":true,\"finalValue\":\"%s\",\"effectiveAnnualPct12\":\"%s\"}"
      (Big.to_string fv) (fmt_scaled12 aer12))

let money_json (cents_s : string) (sym : string) (ds : string) (gs : string) :
    string =
  run (fun () ->
    if String.length cents_s = 0 then raise (Jerr "cents_empty");
    let scaled = need ~prefix:"cents" (Big.of_decimal_string cents_s 24) in
    let q, r = Big.divmod scaled scl in
    guard (not (Big.is_zero r)) "cents_format";
    Printf.sprintf "{\"ok\":true,\"text\":\"%s\"}"
      (esc (money_fmt q sym ds gs)))

let version () : string = "1.0.0"
