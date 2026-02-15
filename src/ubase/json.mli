(* Unison file synchronizer: src/ubase/json.mli *)
(* Minimal JSON encoder/decoder for JSON-RPC communication *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | Array of t list
  | Object of (string * t) list

val to_string : t -> string
val of_string : string -> t

val get : string -> t -> t
val get_opt : string -> t -> t option
val get_string : string -> t -> string
val get_string_opt : string -> t -> string option
val get_int : string -> t -> int
val get_bool : string -> t -> bool
val get_list : string -> t -> t list
