(lang dune 3.6)

(name topup)
(version 0.1.0)

(generate_opam_files true)

(authors "Cuihtlauac ALVARADO <cuihtlauac@tarides.com>")
(maintainers "Cuihtlauac ALVARADO <cuihtlauac@tarides.com>")
(license ISC)

(package
 (name topup)
 (synopsis "An OCaml toplevel exposed as an MCP server")
 (description
  "topup wraps the OCaml toplevel as a Model Context Protocol server, letting an LLM keep typed working memory across conversation turns. Bindings persist between eval calls; the model carries only names and types in its context.")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.6))
  ocamlfind
  yojson))
