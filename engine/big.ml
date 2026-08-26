(* Big — minimal arbitrary-precision integers, pure OCaml, no C stubs.
 *
 * Written for js_of_ocaml: base-10^4 limbs keep every intermediate product
 * below 2^53 so the JS-number semantics of jsoo never lose precision.
 * Magnitudes are little-endian limb arrays; values are always normalized.
 *
 * This exists because Debian's zarith has no JavaScript runtime — and because
 * a money engine that refuses floats shouldn't outsource its integers either.
 *)

type t = { mutable neg : bool; mutable l : int array }

let base = 10000

let norm (a : t) : unit =
  let n = Array.length a.l in
  let m = ref n in
  while !m > 1 && a.l.(!m - 1) = 0 do
    decr m
  done;
  if !m <> n then a.l <- Array.sub a.l 0 !m;
  if !m = 1 && a.l.(0) = 0 then a.neg <- false

let zero : t = { neg = false; l = [| 0 |] }
let one : t = { neg = false; l = [| 1 |] }
let two : t = { neg = false; l = [| 2 |] }

let of_int (v : int) : t =
  let neg = v < 0 in
  let x = abs v in
  if x < base then { neg; l = [| x |] }
  else { neg; l = [| x mod base; x / base |] }

let make_limbs (len : int) : t = { neg = false; l = Array.make (max 1 len) 0 }

let mag_cmp (a : t) (b : t) : int =
  let la = Array.length a.l and lb = Array.length b.l in
  if la <> lb then compare la lb
  else
    let res = ref 0 in
    let i = ref (la - 1) in
    while !res = 0 && !i >= 0 do
      res := compare a.l.(!i) b.l.(!i);
      decr i
    done;
    !res

let cmp (a : t) (b : t) : int =
  match (a.neg, b.neg) with
  | true, false -> -1
  | false, true -> 1
  | false, false -> mag_cmp a b
  | true, true -> - (mag_cmp a b)

let sign (a : t) : int =
  if Array.length a.l = 1 && a.l.(0) = 0 then 0 else if a.neg then -1 else 1

let is_zero (a : t) : bool = sign a = 0
let is_even (a : t) : bool = a.l.(0) land 1 = 0

let neg (a : t) : t =
  if is_zero a then a else { neg = not a.neg; l = Array.copy a.l }

let abs (a : t) : t = if a.neg then { neg = false; l = Array.copy a.l } else a

(* magnitudes only; caller handles signs *)
let mag_add (a : t) (b : t) : t =
  let la = Array.length a.l and lb = Array.length b.l in
  let n = max la lb + 1 in
  let r = make_limbs n in
  let carry = ref 0 in
  for i = 0 to n - 2 do
    let x =
      (if i < la then a.l.(i) else 0) + (if i < lb then b.l.(i) else 0) + !carry
    in
    r.l.(i) <- x mod base;
    carry := x / base
  done;
  r.l.(n - 1) <- !carry;
  norm r;
  r

(* requires |a| >= |b| *)
let mag_sub (a : t) (b : t) : t =
  let la = Array.length a.l in
  let r = make_limbs la in
  let borrow = ref 0 in
  for i = 0 to la - 1 do
    let x = a.l.(i) - (if i < Array.length b.l then b.l.(i) else 0) - !borrow in
    if x < 0 then (
      r.l.(i) <- x + base;
      borrow := 1)
    else (
      r.l.(i) <- x;
      borrow := 0)
  done;
  norm r;
  r

let add (a : t) (b : t) : t =
  if a.neg = b.neg then
    let r = mag_add a b in
    r.neg <- a.neg;
    norm r;
    r
  else
    let c = mag_cmp a b in
    if c = 0 then zero
    else if c > 0 then
      let r = mag_sub a b in
      r.neg <- a.neg;
      norm r;
      r
    else
      let r = mag_sub b a in
      r.neg <- b.neg;
      norm r;
      r

let sub (a : t) (b : t) : t = add a (neg b)

let succ (a : t) : t = add a one

let mul (a : t) (b : t) : t =
  if is_zero a || is_zero b then zero
  else
    let la = Array.length a.l and lb = Array.length b.l in
    let acc = Array.make (la + lb) 0 in
    for i = 0 to la - 1 do
      let ai = a.l.(i) in
      if ai <> 0 then
        for j = 0 to lb - 1 do
          acc.(i + j) <- acc.(i + j) + (ai * b.l.(j))
        done
    done;
    (* column sums stay far below 2^53 given base 10^4 *)
    let carry = ref 0 in
    for i = 0 to la + lb - 1 do
      let x = acc.(i) + !carry in
      acc.(i) <- x mod base;
      carry := x / base
    done;
    let r = { neg = a.neg <> b.neg; l = acc } in
    norm r;
    r

(* multiply by a non-negative machine int (any size, decomposed by limbs) *)
let rec mul_small (a : t) (m : int) : t =
  if m = 0 || is_zero a then zero
  else if m < base then begin
    let la = Array.length a.l in
    let acc = Array.make (la + 1) 0 in
    let carry = ref 0 in
    for i = 0 to la - 1 do
      let x = (a.l.(i) * m) + !carry in
      acc.(i) <- x mod base;
      carry := x / base
    done;
    acc.(la) <- !carry;
    let r = { neg = a.neg; l = acc } in
    norm r;
    r
  end
  else
    let lo = m mod base and hi = m / base in
    add (mul_small a lo) (shift_limbs (mul_small a hi) 1)

(* append k zero limbs (multiply by base^k) *)
and shift_limbs (a : t) (k : int) : t =
  if k = 0 then a
  else if is_zero a then zero
  else
    let la = Array.length a.l in
    let l = Array.make (la + k) 0 in
    Array.blit a.l 0 l k la;
    let r = { neg = a.neg; l } in
    norm r;
    r

(* floor division of magnitudes: a >= 0, d > 0. Double-and-subtract method;
   exact quotient and remainder without general long division. *)
let mag_divmod (a : t) (d : t) : t * t =
  let c0 = mag_cmp a d in
  if c0 < 0 then (zero, a)
  else if c0 = 0 then (one, zero)
  else begin
    (* dbls.(i) = d * 2^i ascending while <= a *)
    let cap = ref 16 in
    let dbls = ref (Array.make !cap d) in
    let n = ref 1 in
    let growing = ref true in
    while !growing do
      let nxt = mag_add !dbls.(!n - 1) !dbls.(!n - 1) in
      if mag_cmp nxt a > 0 then growing := false
      else begin
        if !n >= !cap then begin
          cap := !cap * 2;
          let bigger = Array.make !cap zero in
          Array.blit !dbls 0 bigger 0 !n;
          dbls := bigger
        end;
        !dbls.(!n) <- nxt;
        incr n
      end
    done;
    (* pows.(i) = 2^i *)
    let pows = Array.make !n one in
    for i = 1 to !n - 1 do
      pows.(i) <- add pows.(i - 1) pows.(i - 1)
    done;
    let r = ref (abs a) in
    let q = ref zero in
    for i = !n - 1 downto 0 do
      if mag_cmp !r !dbls.(i) >= 0 then begin
        r := mag_sub !r !dbls.(i);
        q := add !q pows.(i)
      end
    done;
    (!q, !r)
  end

let divmod (a : t) (d : t) : t * t =
  if is_zero d then invalid_arg "Big.divmod by zero";
  let q, r = mag_divmod (abs a) (abs d) in
  let qneg = a.neg <> d.neg && not (is_zero q) in
  let rneg = a.neg && not (is_zero r) in
  ({ q with neg = qneg }, { r with neg = rneg })

(* exact decimal string *)
let to_string (a : t) : string =
  let n = Array.length a.l in
  let buf = Buffer.create ((n * 4) + 2) in
  if a.neg then Buffer.add_char buf '-';
  Buffer.add_string buf (string_of_int a.l.(n - 1));
  for i = n - 2 downto 0 do
    Buffer.add_string buf (Printf.sprintf "%04d" a.l.(i))
  done;
  Buffer.contents buf

let of_decimal_string (s : string) (frac_digits : int) : (t, string) Result.t =
  (* parse "-12345.67" into an integer scaled by 10^frac_digits *)
  let n = String.length s in
  if n = 0 then Error "empty"
  else
    let i = ref 0 in
    let neg = ref false in
    (if s.[0] = '-' || s.[0] = '+' then (
     neg := s.[0] = '-';
     incr i));
    let limbs = ref [] in
    (* collect decimal digits as a list of 4-digit groups, little-endian *)
    let digs = ref [] in
    (* decimal digits most-significant-first *)
    let ints = ref 0 and fracs = ref 0 and dot = ref false and bad = ref false in
    while (not !bad) && !i < n do
      let c = s.[!i] in
      if c = '.' then (
        if !dot then bad := true else dot := true)
      else if c >= '0' && c <= '9' then (
        digs := (Char.code c - Char.code '0') :: !digs;
        if !dot then incr fracs else incr ints;
        if !fracs > frac_digits then bad := true)
      else bad := true;
      incr i
    done;
    if !bad then Error "format"
    else if !ints = 0 && !fracs = 0 then Error "empty"
    else if List.hd !digs = 0 && String.length s > 1 && s.[0] = '0' && !ints > 0
             && List.length !digs = !fracs + 1 && List.nth !digs !fracs = 0
             && List.for_all (fun d -> d = 0) (List.filteri (fun k _ -> k < !fracs) !digs)
    then Error "empty"
    else begin
      (* pad right so total fractional digits == frac_digits *)
      let pad = frac_digits - !fracs in
      for _ = 1 to pad do
        digs := 0 :: !digs
      done;
      (* group into base-10^4 limbs, little-endian *)
      let arr = Array.of_list !digs in
      (* arr is reversed (least significant first) *)
      let len = Array.length arr in
      let nl = (len + 3) / 4 in
      for g = 0 to nl - 1 do
        let v = ref 0 in
        for k = 3 downto 0 do
          let idx = (g * 4) + k in
          v := (!v * 10) + (if idx < len then arr.(idx) else 0)
        done;
        limbs := !v :: !limbs
      done;
      let l = Array.of_list (List.rev !limbs) in
      let r = { neg = !neg; l } in
      norm r;
      Ok r
    end
