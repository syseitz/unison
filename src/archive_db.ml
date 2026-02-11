(* Unison file synchronizer: src/archive_db.ml *)
(* Copyright 2025, Unison contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*)

(* SQLite-backed key-value storage for low-memory archive mode. *)

let debug = Trace.debug "archivedb"

type t = {
  db : Sqlite3.db;
  mutable stmt_load : Sqlite3.stmt;
  mutable stmt_store : Sqlite3.stmt;
  mutable stmt_delete : Sqlite3.stmt;
  mutable stmt_delete_sub : Sqlite3.stmt;
  mutable stmt_meta_load : Sqlite3.stmt;
  mutable stmt_meta_store : Sqlite3.stmt;
}

let check_rc db rc =
  if rc <> Sqlite3.Rc.OK && rc <> Sqlite3.Rc.DONE then
    raise (Util.Fatal
      (Printf.sprintf "SQLite error: %s (%s)"
        (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db)))

let open_db path =
  debug (fun () -> Util.msg "Opening archive database: %s\n" path);
  let db = Sqlite3.db_open ~mutex:`FULL path in
  (* WAL mode for better read concurrency *)
  check_rc db (Sqlite3.exec db "PRAGMA journal_mode=WAL");
  (* Synchronous NORMAL is safe with WAL *)
  check_rc db (Sqlite3.exec db "PRAGMA synchronous=NORMAL");
  (* Memory-map the database file for faster reads *)
  check_rc db (Sqlite3.exec db "PRAGMA mmap_size=268435456");
  (* Increase page cache to 10MB *)
  check_rc db (Sqlite3.exec db "PRAGMA cache_size=-10000");
  (* Create tables *)
  check_rc db (Sqlite3.exec db
    "CREATE TABLE IF NOT EXISTS dirs (
       path TEXT PRIMARY KEY,
       data BLOB NOT NULL
     )");
  check_rc db (Sqlite3.exec db
    "CREATE TABLE IF NOT EXISTS meta (
       key TEXT PRIMARY KEY,
       value TEXT NOT NULL
     )");
  (* Store a schema version for future migration *)
  check_rc db (Sqlite3.exec db
    "INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1')");
  (* Prepare statements *)
  let stmt_load = Sqlite3.prepare db
    "SELECT data FROM dirs WHERE path = ?" in
  let stmt_store = Sqlite3.prepare db
    "INSERT OR REPLACE INTO dirs (path, data) VALUES (?, ?)" in
  let stmt_delete = Sqlite3.prepare db
    "DELETE FROM dirs WHERE path = ?" in
  let stmt_delete_sub = Sqlite3.prepare db
    "DELETE FROM dirs WHERE path = ? OR path LIKE ? ESCAPE '\\'" in
  let stmt_meta_load = Sqlite3.prepare db
    "SELECT value FROM meta WHERE key = ?" in
  let stmt_meta_store = Sqlite3.prepare db
    "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)" in
  { db; stmt_load; stmt_store; stmt_delete; stmt_delete_sub;
    stmt_meta_load; stmt_meta_store }

let close_db t =
  debug (fun () -> Util.msg "Closing archive database\n");
  ignore (Sqlite3.finalize t.stmt_load);
  ignore (Sqlite3.finalize t.stmt_store);
  ignore (Sqlite3.finalize t.stmt_delete);
  ignore (Sqlite3.finalize t.stmt_delete_sub);
  ignore (Sqlite3.finalize t.stmt_meta_load);
  ignore (Sqlite3.finalize t.stmt_meta_store);
  ignore (Sqlite3.db_close t.db)

(* Escape special characters in LIKE patterns *)
let escape_like s =
  let buf = Buffer.create (String.length s + 4) in
  String.iter (fun c ->
    match c with
    | '%' | '_' | '\\' ->
        Buffer.add_char buf '\\'; Buffer.add_char buf c
    | _ -> Buffer.add_char buf c) s;
  Buffer.contents buf

let load t path =
  let stmt = t.stmt_load in
  ignore (Sqlite3.reset stmt);
  check_rc t.db (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT path));
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
      let data = Sqlite3.column stmt 0 in
      (match data with
       | Sqlite3.Data.BLOB s -> Some s
       | _ -> None)
  | _ -> None

let store t path data =
  let stmt = t.stmt_store in
  ignore (Sqlite3.reset stmt);
  check_rc t.db (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT path));
  check_rc t.db (Sqlite3.bind stmt 2 (Sqlite3.Data.BLOB data));
  check_rc t.db (Sqlite3.step stmt)

let delete t path =
  let stmt = t.stmt_delete in
  ignore (Sqlite3.reset stmt);
  check_rc t.db (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT path));
  check_rc t.db (Sqlite3.step stmt)

let delete_subtree t path =
  let stmt = t.stmt_delete_sub in
  ignore (Sqlite3.reset stmt);
  check_rc t.db (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT path));
  let like_pattern =
    if path = "" then "%"
    else (escape_like path) ^ "/%" in
  check_rc t.db (Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT like_pattern));
  check_rc t.db (Sqlite3.step stmt)

let begin_transaction t =
  check_rc t.db (Sqlite3.exec t.db "BEGIN IMMEDIATE")

let commit_transaction t =
  check_rc t.db (Sqlite3.exec t.db "COMMIT")

let store_meta t key value =
  let stmt = t.stmt_meta_store in
  ignore (Sqlite3.reset stmt);
  check_rc t.db (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT key));
  check_rc t.db (Sqlite3.bind stmt 2 (Sqlite3.Data.TEXT value));
  check_rc t.db (Sqlite3.step stmt)

let load_meta t key =
  let stmt = t.stmt_meta_load in
  ignore (Sqlite3.reset stmt);
  check_rc t.db (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT key));
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
      let data = Sqlite3.column stmt 0 in
      (match data with
       | Sqlite3.Data.TEXT s -> Some s
       | _ -> None)
  | _ -> None

let load_all t =
  let stmt = Sqlite3.prepare t.db "SELECT path, data FROM dirs" in
  let results = ref [] in
  let continue = ref true in
  while !continue do
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
        let path = match Sqlite3.column stmt 0 with
          | Sqlite3.Data.TEXT s -> s
          | _ -> "" in
        let data = match Sqlite3.column stmt 1 with
          | Sqlite3.Data.BLOB s -> s
          | _ -> "" in
        results := (path, data) :: !results
    | _ -> continue := false
  done;
  ignore (Sqlite3.finalize stmt);
  !results

let is_valid path =
  try
    if not (Sys.file_exists path) then false
    else begin
      let db = Sqlite3.db_open ~mode:`READONLY path in
      let valid = ref false in
      ignore (Sqlite3.exec db
        ~cb:(fun _ _ -> valid := true)
        "SELECT 1 FROM meta WHERE key = 'schema_version' AND value = '1'");
      ignore (Sqlite3.db_close db);
      !valid
    end
  with _ -> false
