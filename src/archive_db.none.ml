(* Unison file synchronizer: src/archive_db_none.ml *)
(* Stub implementation when sqlite3-ocaml is not available.
   All database operations raise a fatal error. *)

let available = false

type t = unit

let no_sqlite3 () =
  raise (Util.Fatal
    "Low-memory mode requires SQLite3 support which was not \
     compiled in. Please install the sqlite3-ocaml package and rebuild Unison.")

let open_db _ = no_sqlite3 ()
let reset_stmts _ = ()
let close_db _ = ()

let load _ _ = no_sqlite3 ()
let store _ _ _ = no_sqlite3 ()
let delete _ _ = no_sqlite3 ()
let delete_subtree _ _ = no_sqlite3 ()

let begin_transaction _ = no_sqlite3 ()
let commit_transaction _ = no_sqlite3 ()

let store_meta _ _ _ = no_sqlite3 ()
let load_meta _ _ = no_sqlite3 ()

let iter_all _ _ = no_sqlite3 ()

let iter_path_sizes _ _ = no_sqlite3 ()

let is_valid _ = false
