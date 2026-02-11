(* Unison file synchronizer: src/archive_db.mli *)
(* SQLite-backed key-value storage for low-memory archive mode.
   Stores one blob per directory path. The archive-specific
   serialization is handled by the caller (update.ml). *)

type t

val open_db : string -> t
val close_db : t -> unit

(* Directory blob storage: one row per directory path.
   Path key is the string representation of the directory path,
   "" for the root directory. *)
val load : t -> string -> string option
val store : t -> string -> string -> unit
val delete : t -> string -> unit
val delete_subtree : t -> string -> unit

(* Transaction management *)
val begin_transaction : t -> unit
val commit_transaction : t -> unit

(* Metadata key-value pairs (separate table) *)
val store_meta : t -> string -> string -> unit
val load_meta : t -> string -> string option

(* Load all directory entries in one query.
   Returns list of (path, data) pairs. Much faster than
   individual loads when all entries are needed. *)
val load_all : t -> (string * string) list

(* Check if a valid database exists at the given path *)
val is_valid : string -> bool
