#!/bin/bash
eval $(opam env --switch=default 2>/dev/null)
cd "$(dirname "$0")"
dune build src/linktext.exe 2>&1
