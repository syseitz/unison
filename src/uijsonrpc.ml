(* Unison file synchronizer: src/uijsonrpc.ml *)
(* JSON-RPC 2.0 UI implementation over stdin/stdout *)

open Common

(* --- Internal state --- *)

type state = {
  mutable reconItems : reconItem array;
  mutable connected : bool;
  mutable propagating : bool;
}

let make_state () = {
  reconItems = [||];
  connected = false;
  propagating = false;
}

(* --- JSON-RPC wire protocol --- *)

let send_json obj =
  output_string stdout (Json.to_string obj);
  output_char stdout '\n';
  flush stdout

let send_response id result =
  send_json (Json.Object [
    "jsonrpc", Json.String "2.0";
    "id", id;
    "result", result;
  ])

let send_error id code message =
  send_json (Json.Object [
    "jsonrpc", Json.String "2.0";
    "id", id;
    "error", Json.Object [
      "code", Json.Int code;
      "message", Json.String message;
    ];
  ])

let send_notification method_ params =
  send_json (Json.Object [
    "jsonrpc", Json.String "2.0";
    "method", Json.String method_;
    "params", params;
  ])

(* --- Direction helpers --- *)

let direction_to_string = function
  | Replica1ToReplica2 -> "toRight"
  | Replica2ToReplica1 -> "toLeft"
  | Conflict reason     -> "conflict:" ^ reason
  | Merge               -> "merge"

let string_to_direction = function
  | "toRight" -> `Replica1ToReplica2
  | "toLeft"  -> `Replica2ToReplica1
  | "merge"   -> `Merge
  | "skip"    -> `Skip
  | s -> failwith ("Unknown direction: " ^ s)

let action_to_string = function
  | Uicommon.AError   -> "error"
  | Uicommon.ASkip _  -> "skip"
  | Uicommon.ALtoR _  -> "toRight"
  | Uicommon.ARtoL _  -> "toLeft"
  | Uicommon.AMerge   -> "merge"

(* --- reconItem serialization --- *)

let reconitem_to_json index ri =
  let path = Path.toString ri.path1 in
  let (left, action, right, display_path) =
    Uicommon.reconItem2stringList Path.empty ri in
  let direction = match ri.replicas with
    | Different diff -> direction_to_string diff.direction
    | Problem s -> "error:" ^ s in
  let default_direction = match ri.replicas with
    | Different diff -> direction_to_string diff.default_direction
    | Problem _ -> "error" in
  Json.Object [
    "index", Json.Int index;
    "path", Json.String path;
    "displayPath", Json.String display_path;
    "direction", Json.String direction;
    "defaultDirection", Json.String default_direction;
    "action", Json.String (action_to_string action);
    "left", Json.String left;
    "right", Json.String right;
  ]

(* --- Transport state item --- *)

type stateItem = {
  ri : reconItem;
  mutable bytesTransferred : Uutil.Filesize.t;
  mutable bytesToTransfer : Uutil.Filesize.t;
}

(* --- Root helpers --- *)

let root_to_string (host, fspath) =
  match host with
  | Local -> Fspath.toString fspath
  | Remote h -> "ssh://" ^ h ^ "/" ^ Fspath.toString fspath

(* --- Method handlers --- *)

let handle_initialize state params =
  let profile = Json.get_string "profile" params in
  begin try
    Uicommon.initPrefs ~profileName:profile
      ~promptForRoots:(fun () -> None) ();
    Uicommon.connectRoots
      ~displayWaitMessage:(fun () ->
        send_notification "status"
          (Json.Object ["message", Json.String "Connecting to server..."]))
      ();
    state.connected <- true;
    let (root1, root2) = Globals.roots () in
    Json.Object [
      "profile", Json.String profile;
      "roots", Json.Array [
        Json.String (root_to_string root1);
        Json.String (root_to_string root2);
      ];
    ]
  with
  | Util.Fatal s -> failwith s
  | e -> failwith (Uicommon.exn2string e)
  end

let handle_scan state _params =
  if not state.connected then
    failwith "Not connected. Call initialize first.";

  Trace.statusFormatter := (fun major minor ->
    send_notification "scanProgress"
      (Json.Object [
        "status", Json.String major;
        "progress", Json.String minor;
      ]);
    major ^ " " ^ minor
  );

  Uicommon.connectRoots
    ~displayWaitMessage:(fun () -> ())
    ();
  Trace.status "Looking for changes";
  let updates = Update.findUpdates ~wantWatcher:false None in
  Uutil.setUpdateStatusPrinter None;

  let (reconItemList, _anyEqualUpdates, _dangerousPaths) =
    Recon.reconcileAll ~allowPartial:true updates in

  if not !Update.foundArchives then Update.commitUpdates ();
  state.reconItems <- Array.of_list reconItemList;

  let total = Array.length state.reconItems in
  let conflicts = Array.fold_left (fun acc ri ->
    match ri.replicas with
    | Different diff when isConflict diff.direction -> acc + 1
    | Problem _ -> acc + 1
    | _ -> acc
  ) 0 state.reconItems in

  Json.Object [
    "total", Json.Int total;
    "conflicts", Json.Int conflicts;
  ]

let handle_get_items state params =
  let offset = try Json.get_int "offset" params with _ -> 0 in
  let limit = try Json.get_int "limit" params with _ -> Array.length state.reconItems in
  let total = Array.length state.reconItems in
  let actual_end = min (offset + limit) total in
  let items = ref [] in
  for i = actual_end - 1 downto offset do
    items := reconitem_to_json i state.reconItems.(i) :: !items
  done;
  Json.Object [
    "items", Json.Array !items;
    "total", Json.Int total;
  ]

let handle_set_direction state params =
  let index = Json.get_int "index" params in
  let dir_str = Json.get_string "direction" params in
  if index < 0 || index >= Array.length state.reconItems then
    failwith (Printf.sprintf "Index %d out of range" index);
  let ri = state.reconItems.(index) in
  begin match string_to_direction dir_str with
  | `Skip ->
    begin match ri.replicas with
    | Different diff -> diff.direction <- Conflict "skipped by user"
    | _ -> ()
    end
  | `Replica1ToReplica2 ->
    Recon.setDirection ri `Replica1ToReplica2 `Force
  | `Replica2ToReplica1 ->
    Recon.setDirection ri `Replica2ToReplica1 `Force
  | `Merge ->
    Recon.setDirection ri `Merge `Force
  end;
  Json.Object ["ok", Json.Bool true]

let handle_set_direction_all state params =
  let dir_str = Json.get_string "direction" params in
  let filter = Json.get_string_opt "filter" params in
  let changed = ref 0 in
  Array.iter (fun ri ->
    let dominated = match filter with
      | Some "conflicts" ->
        begin match ri.replicas with
        | Different diff -> isConflict diff.direction
        | Problem _ -> true
        end
      | Some "nonconflicts" ->
        begin match ri.replicas with
        | Different diff -> not (isConflict diff.direction)
        | Problem _ -> false
        end
      | _ -> true
    in
    if dominated then begin
      begin match string_to_direction dir_str with
      | `Skip ->
        begin match ri.replicas with
        | Different diff ->
          diff.direction <- Conflict "skipped by user";
          incr changed
        | _ -> ()
        end
      | `Replica1ToReplica2 ->
        begin match ri.replicas with
        | Different _ ->
          Recon.setDirection ri `Replica1ToReplica2 `Force;
          incr changed
        | _ -> ()
        end
      | `Replica2ToReplica1 ->
        begin match ri.replicas with
        | Different _ ->
          Recon.setDirection ri `Replica2ToReplica1 `Force;
          incr changed
        | _ -> ()
        end
      | `Merge ->
        begin match ri.replicas with
        | Different _ ->
          Recon.setDirection ri `Merge `Force;
          incr changed
        | _ -> ()
        end
      end
    end
  ) state.reconItems;
  Json.Object ["changed", Json.Int !changed]

let handle_propagate state _params =
  if Array.length state.reconItems = 0 then
    failwith "No items to propagate. Call scan first.";

  state.propagating <- true;

  let stateItems = Array.map (fun ri ->
    { ri;
      bytesTransferred = Uutil.Filesize.zero;
      bytesToTransfer = Common.riLength ri }
  ) state.reconItems in

  (* Progress reporting *)
  Uutil.setProgressPrinter (fun file_id bytes _dbg ->
    let i = Uutil.File.toLine file_id in
    if i >= 0 && i < Array.length stateItems then begin
      let item = stateItems.(i) in
      item.bytesTransferred <- Uutil.Filesize.add item.bytesTransferred bytes;
      send_notification "transferProgress"
        (Json.Object [
          "index", Json.Int i;
          "bytes", Json.Int (Int64.to_int (Uutil.Filesize.toInt64 item.bytesTransferred));
          "total", Json.Int (Int64.to_int (Uutil.Filesize.toInt64 item.bytesToTransfer));
        ])
    end
  );

  let failed_count = ref 0 in
  let transferred_count = ref 0 in
  let skipped_count = ref 0 in

  let isSkip ri = problematic ri in

  Array.iter (fun item ->
    if isSkip item.ri then incr skipped_count
  ) stateItems;

  let uiWrapper i item =
    send_notification "transferStart"
      (Json.Object [
        "index", Json.Int i;
        "path", Json.String (Path.toString item.ri.path1);
        "direction", Json.String (
          match item.ri.replicas with
          | Different diff -> direction_to_string diff.direction
          | _ -> "unknown");
      ]);
    Lwt.try_bind
      (fun () ->
        Transport.transportItem item.ri
          (Uutil.File.ofLine i) (fun _ _ -> true))
      (fun () ->
        if not (isSkip item.ri) then
          incr transferred_count;
        send_notification "transferComplete"
          (Json.Object [
            "index", Json.Int i;
            "success", Json.Bool true;
          ]);
        Lwt.return ())
      (fun e ->
        begin match e with
        | Util.Transient s ->
          incr failed_count;
          send_notification "transferComplete"
            (Json.Object [
              "index", Json.Int i;
              "success", Json.Bool false;
              "error", Json.String s;
            ]);
          Lwt.return ()
        | _ ->
          Lwt.fail e
        end)
  in

  begin try
    Uicommon.transportStart ();
    Uicommon.transportItems stateItems
      (fun item -> not (Common.isDeletion item.ri))
      uiWrapper;
    Uicommon.transportItems stateItems
      (fun item -> Common.isDeletion item.ri)
      uiWrapper;
    Uicommon.transportFinish ();
  with e ->
    Uicommon.transportFinish ();
    state.propagating <- false;
    Uutil.setProgressPrinter (fun _ _ _ -> ());
    raise e
  end;

  Uutil.setProgressPrinter (fun _ _ _ -> ());
  state.propagating <- false;

  Trace.status "Saving synchronizer state";
  Update.commitUpdates ();

  Json.Object [
    "transferred", Json.Int !transferred_count;
    "skipped", Json.Int !skipped_count;
    "failed", Json.Int !failed_count;
  ]

let handle_batch_sync state params =
  let scan_result = handle_scan state params in
  let total = Json.get_int "total" scan_result in
  if total = 0 then
    Json.Object [
      "transferred", Json.Int 0;
      "skipped", Json.Int 0;
      "failed", Json.Int 0;
      "exitCode", Json.Int Uicommon.perfectExit;
    ]
  else begin
    let prop_result = handle_propagate state (Json.Object []) in
    let transferred = Json.get_int "transferred" prop_result in
    let skipped = Json.get_int "skipped" prop_result in
    let failed = Json.get_int "failed" prop_result in
    let exit_code = Uicommon.exitCode (skipped > 0, failed > 0) in
    Json.Object [
      "transferred", Json.Int transferred;
      "skipped", Json.Int skipped;
      "failed", Json.Int failed;
      "exitCode", Json.Int exit_code;
    ]
  end

let handle_get_details state params =
  let index = Json.get_int "index" params in
  if index < 0 || index >= Array.length state.reconItems then
    failwith (Printf.sprintf "Index %d out of range" index);
  let ri = state.reconItems.(index) in
  let path = Path.toString ri.path1 in
  let details = Uicommon.details2string ri "\n" in
  Json.Object [
    "index", Json.Int index;
    "path", Json.String path;
    "details", Json.String details;
  ]

let handle_get_diff state params =
  let index = Json.get_int "index" params in
  if index < 0 || index >= Array.length state.reconItems then
    failwith (Printf.sprintf "Index %d out of range" index);
  let ri = state.reconItems.(index) in
  let buf = Buffer.create 4096 in
  let err = ref "" in
  Uicommon.showDiffs ri
    (fun title text ->
       Buffer.add_string buf title;
       Buffer.add_char buf '\n';
       Buffer.add_string buf text)
    (fun s -> err := s)
    Uutil.File.dummy;
  if !err <> "" then
    Json.Object [
      "index", Json.Int index;
      "error", Json.String !err;
    ]
  else
    Json.Object [
      "index", Json.Int index;
      "diff", Json.String (Buffer.contents buf);
    ]

let handle_shutdown _state _params =
  Json.Object []

(* --- Dispatch --- *)

let dispatch state method_ params =
  match method_ with
  | "initialize"       -> handle_initialize state params
  | "scan"             -> handle_scan state params
  | "getItems"         -> handle_get_items state params
  | "setDirection"     -> handle_set_direction state params
  | "setDirectionAll"  -> handle_set_direction_all state params
  | "propagate"        -> handle_propagate state params
  | "batchSync"        -> handle_batch_sync state params
  | "getDetails"       -> handle_get_details state params
  | "getDiff"          -> handle_get_diff state params
  | "shutdown"         -> handle_shutdown state params
  | "cancel"           ->
    if state.propagating then Abort.all ();
    Json.Object ["ok", Json.Bool true]
  | _ ->
    failwith ("Method not found: " ^ method_)

(* --- Message loop --- *)

let rec message_loop state =
  let line =
    try Some (input_line stdin)
    with End_of_file -> None
  in
  match line with
  | None -> ()
  | Some line ->
    let line = String.trim line in
    if line = "" then message_loop state
    else begin
      let request =
        try Some (Json.of_string line)
        with Failure msg ->
          send_error Json.Null (-32700) ("Parse error: " ^ msg);
          None
      in
      begin match request with
      | None -> ()
      | Some request ->
        let id = match Json.get_opt "id" request with
          | Some id -> id
          | None -> Json.Null
        in
        begin try
          let method_ = Json.get_string "method" request in
          let params = match Json.get_opt "params" request with
            | Some p -> p
            | None -> Json.Object []
          in
          let result = dispatch state method_ params in
          if id <> Json.Null then
            send_response id result;
          if method_ = "shutdown" then
            exit 0
        with
        | Failure msg ->
          if id <> Json.Null then
            send_error id (-32603) msg
        | e ->
          if id <> Json.Null then
            send_error id (-32603) (Uicommon.exn2string e)
        end
      end;
      message_loop state
    end

(* --- UI Module --- *)

module Body : Uicommon.UI = struct
  let defaultUi = Uicommon.Jsonrpc

  let start _ =
    Sys.catch_break true;
    Os.createUnisonDir ();
    begin try
      match Uicommon.uiInitClRootsAndProfile () with
      | Ok (Some profileName) ->
        Uicommon.initPrefs ~profileName
          ~promptForRoots:(fun () -> None) ()
      | Ok None -> ()
      | Error s ->
        send_error (Json.Int 0) (-32603) s;
        exit 1
    with e ->
      send_error (Json.Int 0) (-32603) (Uicommon.exn2string e);
      exit 1
    end;
    Trace.sendLogMsgsToStderr := true;
    let state = make_state () in
    message_loop state
end
