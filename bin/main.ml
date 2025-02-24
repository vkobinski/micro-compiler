type stream = {
  mutable chr : char option;
  mutable line_num : int;
  chan : in_channel;
}

let open_stream file = { chr = None; line_num = 1; chan = open_in file }
let close_stream stm = close_in stm.chan

let read_char stm =
  match stm.chr with
  | None ->
      let c = input_char stm.chan in
      if c = '\n' then
        let _ = stm.line_num <- stm.line_num + 1 in
        c
      else c
  | Some c ->
      stm.chr <- None;
      c

let unread_char stm c = stm.chr <- Some c

let is_digit c =
  let code = Char.code c in
  code >= Char.code '0' && code <= Char.code '9'

let is_alpha c =
  let code = Char.code c in
  (code >= Char.code 'A' && code <= Char.code 'Z')
  || (code >= Char.code 'a' && code <= Char.code 'z')

type token =
  | Begin
  | End
  | Identifier of string
  | Read
  | Write
  | Literal of int
  | Assign
  | LeftParen
  | RightParen
  | AddOp
  | SubOp
  | Comma
  | Semicolon

type scanner = { mutable last_token : token option; stm : stream }

exception Syntax_error of string

let syntax_error s msg =
  raise (Syntax_error (msg ^ " on line " ^ string_of_int s.stm.line_num))

let rec skip_blank_chars stm =
  let c = read_char stm in
  if c = ' ' || c = '\t' || c = '\r' || c = '\n' then skip_blank_chars stm
  else unread_char stm c;
  ()

let scan s =
  let stm = s.stm in
  let c = read_char stm in
  let rec scan_iden acc =
    let nc = read_char stm in
    if is_alpha nc || is_digit nc || nc = '_' then
      scan_iden (acc ^ Char.escaped nc)
    else
      let _ = unread_char stm nc in
      let lc = String.lowercase_ascii acc in
      if lc = "begin" then Begin
      else if lc = "end" then End
      else if lc = "read" then Read
      else if lc = "write" then Write
      else Identifier acc
  in
  let rec scan_lit acc =
    let nc = read_char stm in
    if is_digit nc then scan_lit (acc ^ Char.escaped nc)
    else
      let _ = unread_char stm nc in
      Literal (int_of_string acc)
  in
  if is_alpha c then scan_iden (Char.escaped c)
  else if is_digit c then scan_lit (Char.escaped c)
  else if c = '+' then AddOp
  else if c = '-' then SubOp
  else if c = ',' then Comma
  else if c = ';' then Semicolon
  else if c = '(' then LeftParen
  else if c = ')' then RightParen
  else if c = ':' && read_char stm = '=' then Assign
  else syntax_error s "couldn't identify the token"

let new_scanner stm = { last_token = None; stm }

let match_next s =
  match s.last_token with
  | None ->
      let _ = skip_blank_chars s.stm in
      scan s
  | Some tn ->
      s.last_token <- None;
      tn

let match_token s t = match_next s = t

let next_token s =
  match s.last_token with
  | None ->
      skip_blank_chars s.stm;
      let t = scan s in
      s.last_token <- Some t;
      t
  | Some t -> t

type generator = {
  vars : (string, int) Hashtbl.t;
  file : string;
  chan : out_channel;
}

let new_generator file =
  let fs = Filename.chop_extension file ^ ".s" in
  { vars = Hashtbl.create 100; file = fs; chan = open_out fs }

let close_generator g = close_out g.chan

let gen g v =
  output_string g.chan v;
  output_string g.chan "\n"

let bottom_var _ g =
  Hashtbl.fold (fun _ v c -> if v >= c then v + 4 else c) g.vars 0

let empty_var s g i = bottom_var s g + (4 * (i - 1))

let var_addr s g v =
  if String.length v > 6 && String.sub v 0 6 = "__temp" then
    let i = String.sub v 6 (String.length v - 6) in
    "[esp+" ^ i ^ "]"
  else
    try "[esp+" ^ string_of_int (Hashtbl.find g.vars v) ^ "]"
    with Not_found -> syntax_error s ("identifier " ^ v ^ " not defined")

let var s g v = "dword " ^ var_addr s g v
let temp_var s g i = Identifier ("__temp" ^ string_of_int (empty_var s g i))
let is_alloc_var _ g v = Hashtbl.mem g.vars v

let alloc_var s g v =
  if is_alloc_var s g v then var s g v
  else
    let _ = Hashtbl.replace g.vars v (empty_var s g 1) in
    var s g v

let token_var s g v =
  match v with
  | Identifier i -> var s g i
  | _ -> syntax_error s "identifier expected"

let op g opcode a = gen g ("    " ^ opcode ^ " " ^ a)
let op2 g opcode a b = gen g ("    " ^ opcode ^ " " ^ a ^ ", " ^ b)
let push g a = op g "push" a

let compile file =
  try
    let g = new_generator file in
    let stm = open_stream file in
    let out = Filename.chop_extension file in
    parse stm g;
    close_stream stm;
    close_generator g;
    let _ = Sys.command ("nasm -f elf " ^ g.file) in
    let _ = Sys.command ("gcc -o " ^ out ^ " " ^ out ^ ".o") in
    ()
  with
  | Syntax_error e ->
      Format.printf "syntax error: %s\n" e;
      Format.print_flush ()
  | Sys_error _ -> print_string "no such file found\n"

let help () = print_string "micro <file>\n"

let () =
  if Array.length Sys.argv = 1 then help ()
  else
    let file = Array.get Sys.argv 1 in
    Format.printf "compiling %s\n" file;
    Format.print_flush ();
    compile file

let parse stm g =
  let s = new_scanner stm in
  try program s g
  with End_of_file ->
    syntax_error s "program reached end of file before end keyword"

let program s g =
  if match_token s Begin then
    let _ = generate_begin s g in
    let _ = statements s g in
    if match_token s End then
      let _ = generate_end s g in
      ()
    else syntax_error s "program should end with end keyword"
  else syntax_error s "program should start with begin keyword"

let rec statements s g = if statement s g then statements s g else ()

let statement s g =
  let t = next_token s in
  if
    match t with
    | Read -> read s g
    | Write -> write s g
    | Identifier i -> assignment s g
    | _ -> false
  then
    if match_token s Semicolon then true
    else syntax_error s "Statement must end with semicolon"
  else false

let assignment s g =
  let id = match_next s in
  match id with
  | Identifier i ->
      if match_token s Assign then
        let new_var = if is_alloc_var s g i then 0 else 1 in
        let id2 = expression s g (1 + new_var) in
        match id2 with
        | Literal i2 ->
            let _ = generate_assign s g id id2 in
            true
        | Identifier i2 ->
            let _ = generate_assign s g id id2 in
            true
        | _ -> syntax_error s "literal or identifier expected"
      else syntax_error s "assign symbol expected"
  | _ -> syntax_error s "identifier expected"

let rec expression s g d =
  let primary s =
    match next_token s with
    | LeftParen ->
        let _ = match_token s LeftParen in
        let e = expression s g (d + 1) in
        if match_token s RightParen then Some e
        else syntax_error s "right paren expected in expression"
    | Identifier i ->
        let _ = match_token s (Identifier i) in
        Some (Identifier i)
    | Literal l ->
        let _ = match_token s (Literal l) in
        Some (Literal l)
    | _ -> None
  in

  let lp = primary s in
  match lp with
  | Some l -> (
      match next_token s with
      | AddOp ->
          let _ = match_token s AddOp in
          addop s g d l (expression s g (d + 1))
      | SubOp ->
          let _ = match_token s SubOp in
          subop s g d l (expression s g (d + 1))
      | _ -> l)
  | None -> syntax_error s "literal or identifier expected"

let addop s g d l r =
  match (l, r) with
  | Literal l1, Literal l2 -> Literal (l1 + l2)
  | Identifier i1, Literal l2 -> generate_add s g d l r
  | Literal l1, Identifier i2 -> generate_add s g d r l
  | _ -> syntax_error s "expected literal or identifier for add operation"

let subop s g d l r =
  match (l, r) with
  | Literal l1, Literal l2 -> Literal (l1 - l2)
  | Identifier i1, Literal l2 -> generate_sub s g d l r
  | Literal l1, Identifier i2 -> generate_sub s g d l r
  | _ -> syntax_error s "expected literal or identifier for sub operation"
