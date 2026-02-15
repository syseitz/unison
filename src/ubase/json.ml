(* Unison file synchronizer: src/ubase/json.ml *)
(* Minimal JSON encoder/decoder for JSON-RPC communication *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | Array of t list
  | Object of (string * t) list

(* --- Encoder --- *)

let buf_add_escaped buf s =
  for i = 0 to Bytes.length (Bytes.of_string s) - 1 do
    match s.[i] with
    | '"'  -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 0x20 ->
      Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buf c
  done

let rec buf_add_json buf = function
  | Null -> Buffer.add_string buf "null"
  | Bool true -> Buffer.add_string buf "true"
  | Bool false -> Buffer.add_string buf "false"
  | Int i -> Buffer.add_string buf (string_of_int i)
  | Float f ->
    let s = Printf.sprintf "%.17g" f in
    Buffer.add_string buf s
  | String s ->
    Buffer.add_char buf '"';
    buf_add_escaped buf s;
    Buffer.add_char buf '"'
  | Array items ->
    Buffer.add_char buf '[';
    let first = ref true in
    List.iter (fun v ->
      if !first then first := false else Buffer.add_char buf ',';
      buf_add_json buf v
    ) items;
    Buffer.add_char buf ']'
  | Object pairs ->
    Buffer.add_char buf '{';
    let first = ref true in
    List.iter (fun (k, v) ->
      if !first then first := false else Buffer.add_char buf ',';
      Buffer.add_char buf '"';
      buf_add_escaped buf k;
      Buffer.add_string buf "\":";
      buf_add_json buf v
    ) pairs;
    Buffer.add_char buf '}'

let to_string v =
  let buf = Buffer.create 256 in
  buf_add_json buf v;
  Buffer.contents buf

(* --- Decoder --- *)

type parser_state = {
  s : string;
  mutable pos : int;
}

let parse_error ps msg =
  let context =
    let len = min 20 (String.length ps.s - ps.pos) in
    if len > 0 then String.sub ps.s ps.pos len else "<end>"
  in
  failwith (Printf.sprintf "JSON parse error at position %d near '%s': %s"
              ps.pos context msg)

let skip_ws ps =
  while ps.pos < String.length ps.s &&
        (let c = ps.s.[ps.pos] in c = ' ' || c = '\t' || c = '\n' || c = '\r')
  do
    ps.pos <- ps.pos + 1
  done

let peek ps =
  skip_ws ps;
  if ps.pos >= String.length ps.s then '\000'
  else ps.s.[ps.pos]

let expect_char ps c =
  skip_ws ps;
  if ps.pos >= String.length ps.s || ps.s.[ps.pos] <> c then
    parse_error ps (Printf.sprintf "expected '%c'" c);
  ps.pos <- ps.pos + 1

let expect_string ps expected =
  let len = String.length expected in
  if ps.pos + len > String.length ps.s ||
     String.sub ps.s ps.pos len <> expected then
    parse_error ps (Printf.sprintf "expected '%s'" expected);
  ps.pos <- ps.pos + len

let parse_hex_digit c =
  match c with
  | '0'..'9' -> Char.code c - Char.code '0'
  | 'a'..'f' -> Char.code c - Char.code 'a' + 10
  | 'A'..'F' -> Char.code c - Char.code 'A' + 10
  | _ -> failwith "invalid hex digit"

let parse_string_value ps =
  expect_char ps '"';
  let buf = Buffer.create 64 in
  let rec loop () =
    if ps.pos >= String.length ps.s then
      parse_error ps "unterminated string";
    match ps.s.[ps.pos] with
    | '"' ->
      ps.pos <- ps.pos + 1;
      Buffer.contents buf
    | '\\' ->
      ps.pos <- ps.pos + 1;
      if ps.pos >= String.length ps.s then
        parse_error ps "unterminated escape";
      let c = ps.s.[ps.pos] in
      ps.pos <- ps.pos + 1;
      begin match c with
        | '"' -> Buffer.add_char buf '"'
        | '\\' -> Buffer.add_char buf '\\'
        | '/' -> Buffer.add_char buf '/'
        | 'n' -> Buffer.add_char buf '\n'
        | 'r' -> Buffer.add_char buf '\r'
        | 't' -> Buffer.add_char buf '\t'
        | 'b' -> Buffer.add_char buf '\b'
        | 'f' -> Buffer.add_char buf (Char.chr 0x0C)
        | 'u' ->
          if ps.pos + 4 > String.length ps.s then
            parse_error ps "unterminated unicode escape";
          let code =
            (parse_hex_digit ps.s.[ps.pos]) lsl 12
            lor (parse_hex_digit ps.s.[ps.pos + 1]) lsl 8
            lor (parse_hex_digit ps.s.[ps.pos + 2]) lsl 4
            lor (parse_hex_digit ps.s.[ps.pos + 3])
          in
          ps.pos <- ps.pos + 4;
          (* Encode as UTF-8 *)
          if code < 0x80 then
            Buffer.add_char buf (Char.chr code)
          else if code < 0x800 then begin
            Buffer.add_char buf (Char.chr (0xC0 lor (code lsr 6)));
            Buffer.add_char buf (Char.chr (0x80 lor (code land 0x3F)))
          end else begin
            Buffer.add_char buf (Char.chr (0xE0 lor (code lsr 12)));
            Buffer.add_char buf (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
            Buffer.add_char buf (Char.chr (0x80 lor (code land 0x3F)))
          end
        | _ -> parse_error ps "invalid escape sequence"
      end;
      loop ()
    | c ->
      Buffer.add_char buf c;
      ps.pos <- ps.pos + 1;
      loop ()
  in
  loop ()

let parse_number ps =
  let start = ps.pos in
  let is_float = ref false in
  if ps.pos < String.length ps.s && ps.s.[ps.pos] = '-' then
    ps.pos <- ps.pos + 1;
  while ps.pos < String.length ps.s &&
        ps.s.[ps.pos] >= '0' && ps.s.[ps.pos] <= '9'
  do ps.pos <- ps.pos + 1 done;
  if ps.pos < String.length ps.s && ps.s.[ps.pos] = '.' then begin
    is_float := true;
    ps.pos <- ps.pos + 1;
    while ps.pos < String.length ps.s &&
          ps.s.[ps.pos] >= '0' && ps.s.[ps.pos] <= '9'
    do ps.pos <- ps.pos + 1 done
  end;
  if ps.pos < String.length ps.s &&
     (ps.s.[ps.pos] = 'e' || ps.s.[ps.pos] = 'E') then begin
    is_float := true;
    ps.pos <- ps.pos + 1;
    if ps.pos < String.length ps.s &&
       (ps.s.[ps.pos] = '+' || ps.s.[ps.pos] = '-') then
      ps.pos <- ps.pos + 1;
    while ps.pos < String.length ps.s &&
          ps.s.[ps.pos] >= '0' && ps.s.[ps.pos] <= '9'
    do ps.pos <- ps.pos + 1 done
  end;
  let s = String.sub ps.s start (ps.pos - start) in
  if !is_float then Float (float_of_string s)
  else Int (int_of_string s)

let rec parse_value ps =
  match peek ps with
  | '"' -> String (parse_string_value ps)
  | '{' -> parse_object ps
  | '[' -> parse_array ps
  | 't' -> expect_string ps "true"; Bool true
  | 'f' -> expect_string ps "false"; Bool false
  | 'n' -> expect_string ps "null"; Null
  | '-' | '0'..'9' -> parse_number ps
  | c -> parse_error ps (Printf.sprintf "unexpected character '%c'" c)

and parse_object ps =
  expect_char ps '{';
  if peek ps = '}' then begin
    ps.pos <- ps.pos + 1;
    Object []
  end else begin
    let pairs = ref [] in
    let rec loop () =
      let key = parse_string_value ps in
      expect_char ps ':';
      let value = parse_value ps in
      pairs := (key, value) :: !pairs;
      if peek ps = ',' then begin
        ps.pos <- ps.pos + 1;
        loop ()
      end
    in
    loop ();
    expect_char ps '}';
    Object (List.rev !pairs)
  end

and parse_array ps =
  expect_char ps '[';
  if peek ps = ']' then begin
    ps.pos <- ps.pos + 1;
    Array []
  end else begin
    let items = ref [] in
    let rec loop () =
      items := parse_value ps :: !items;
      if peek ps = ',' then begin
        ps.pos <- ps.pos + 1;
        loop ()
      end
    in
    loop ();
    expect_char ps ']';
    Array (List.rev !items)
  end

let of_string s =
  let ps = { s; pos = 0 } in
  let v = parse_value ps in
  skip_ws ps;
  v

(* --- Accessors --- *)

let get key = function
  | Object pairs ->
    (try List.assoc key pairs
     with Not_found -> failwith (Printf.sprintf "JSON field '%s' not found" key))
  | _ -> failwith (Printf.sprintf "JSON get '%s': not an object" key)

let get_opt key = function
  | Object pairs ->
    (try Some (List.assoc key pairs) with Not_found -> None)
  | _ -> None

let get_string key obj =
  match get key obj with
  | String s -> s
  | _ -> failwith (Printf.sprintf "JSON field '%s' is not a string" key)

let get_string_opt key obj =
  match get_opt key obj with
  | Some (String s) -> Some s
  | _ -> None

let get_int key obj =
  match get key obj with
  | Int i -> i
  | _ -> failwith (Printf.sprintf "JSON field '%s' is not an int" key)

let get_bool key obj =
  match get key obj with
  | Bool b -> b
  | _ -> failwith (Printf.sprintf "JSON field '%s' is not a bool" key)

let get_list key obj =
  match get key obj with
  | Array l -> l
  | _ -> failwith (Printf.sprintf "JSON field '%s' is not an array" key)
