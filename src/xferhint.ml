(* Unison file synchronizer: src/xferhint.ml *)
(* Copyright 1999-2020, Benjamin C. Pierce

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


let debug = Trace.debug "xferhint"

let xferbycopying =
  Prefs.createBool "xferbycopying" true
    ~category:(`Advanced `Remote)
    "optimize transfers using local copies"
    ("When this preference is set, Unison will try to avoid transferring "
   ^ "file contents across the network by recognizing when a file with the "
   ^ "required contents already exists in the target replica.  This usually "
   ^ "allows file moves to be propagated very quickly.  The default value is "
   ^ "\\texttt{true}.  ")

module FPMap =
  Hashtbl.Make
    (struct
       type t = Os.fullfingerprint
       let hash = Os.fullfingerprintHash
       let equal = Os.fullfingerprintEqual
     end)

type handle = Os.fullfingerprint

(* map(fingerprint, path) *)
let fingerprint2pathMap = FPMap.create 10000

(* Maximum number of entries in low-memory mode.
   The xferhint is a pure optimization (copy-by-move detection),
   not required for correctness. *)
let lowMemMaxEntries = 100000

(* Reference to lowmemory pref, set by Update module to break dependency *)
let lowMemoryMode : (unit -> bool) ref = ref (fun () -> false)

let deleteEntry fp =
  debug (fun () ->
    Util.msg "deleteEntry: fp=%s\n" (Os.fullfingerprint_to_string fp));
  FPMap.remove fingerprint2pathMap fp

let lookup fp =
  assert (Prefs.read xferbycopying);
  debug (fun () ->
    Util.msg "lookup: fp = %s\n" (Os.fullfingerprint_to_string fp));
  try
    let (fspath, path) = FPMap.find fingerprint2pathMap fp in
    Some (fspath, path, fp)
  with Not_found ->
    None

let insertEntry fspath path fp =
  if Prefs.read xferbycopying && not (Os.isPseudoFingerprint fp) then begin
    (* In low-memory mode, limit the FPMap size *)
    if !lowMemoryMode () && FPMap.length fingerprint2pathMap >= lowMemMaxEntries
    then begin
      debug (fun () ->
        Util.msg "Low-memory mode: clearing xferhint map (exceeded %d entries)\n"
          lowMemMaxEntries);
      FPMap.clear fingerprint2pathMap
    end;
    debug (fun () ->
      Util.msg "insertEntry: fspath=%s, path=%s, fp=%s\n"
        (Fspath.toDebugString fspath)
        (Path.toString path) (Os.fullfingerprint_to_string fp));
    FPMap.replace fingerprint2pathMap fp (fspath, path)
  end
