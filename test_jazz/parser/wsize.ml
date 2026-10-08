(* The two types of Jasmin's Wsize used by the parser. In Jasmin this module
   is extracted from the Coq/Rocq sources (proofs/lang/wsize.v); here only
   the types the parser needs are written by hand. *)
type wsize = U8 | U16 | U32 | U64 | U128 | U256
type signedness = Signed | Unsigned
