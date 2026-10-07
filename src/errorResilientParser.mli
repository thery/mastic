val debug : bool ref

type 'token tok = { s : string; t : 'token; b : Lexing.position; e : Lexing.position }

type ('token, 'production) recovery_action =
  | TurnIntoError
  | TurnIntoThisError of Error.t
  | GenerateHole
  | GenerateToken of 'token tok
  | Reduce of 'production

(** What [handle_unexpected_token] sees ahead, the input being lexed upfront
    (see [MakeLookahead]). *)
type ('token, 'production) lookahead = {
  tokens : 'token tok array;  (** all the tokens of the input, [EOF] last *)
  position : int;
      (** the index in [tokens] of the first token not read yet: [next_token]
          and [pending] come just before (when [pending = []] and [next_token]
          comes from the input, it is [tokens.(position - 1)]) *)
  pending : 'token tok list;
      (** the tokens read but not consumed after [next_token], e.g. the token
          of the input before which the recovery inserted [next_token] *)
  simulate : limit:int -> ('token, 'production) recovery_action list -> int;
      (** [simulate ~limit actions] tries a repair, without effect on the real
          parse: the parser goes on from the current error, the [n]-th error
          met (the current one first) being answered by the [n]-th action;
          the simulation stops at the first error after the last action, or
          when [limit] tokens of the input have been shifted, or at the end of
          the input. The result is the number of tokens of the input shifted
          ([limit] when the parse completes), or [-1] if an action could not
          be applied. The semantic actions run: they had better be pure. *)
}

val ahead : ('token, 'production) lookahead -> int -> 'token tok
(** [ahead la k] the [k]-th token after [next_token] ([k = 0] is the next
    one), [EOF] past the end *)

module type RecoveryCommon = sig
  type token

  val show_token : token -> string
  (** for debugging *)

  type 'a symbol
  type xsymbol

  val pp_symbol : 'a option -> Format.formatter -> 'a symbol -> unit
  (** for debugging *)

  type 'a terminal
  type 'a env
  type production

  val match_error_token : token -> Error.t option
  (** identify the [ERROR_TOKEN] *)

  val build_error_token : Error.t -> token
  (** build the [ERROR_TOKEN] *)

  val is_eof_token : token -> bool
  (** identify the [EOF] token *)

  val token_of_terminal : 'a terminal -> (string * token) option
  (** used to generate [~acceptable_tokens] for [handle_unexpected_token] *)

  val reduce_as_parse_error : 'a -> 'a symbol -> Lexing.position -> Lexing.position -> token
  (** store in the error token an ast using the [build_token] api, eg
      [ERROR_TOKEN (Ast.Expr.build_token (Mastic.Error.loc x b e))] *)
end

module type Recovery = sig
  include RecoveryCommon

  val handle_unexpected_token :
    productions:(xsymbol * xsymbol list * production * int) list ->
    next_token:token tok ->
    acceptable_tokens:token tok list ->
    reducible_productions:production list ->
    generation_streak:int ->
    (token, production) recovery_action
  (** called when [next_token] does not fit *)
end

(** A recovery that also sees the tokens ahead *)
module type RecoveryLookahead = sig
  include RecoveryCommon

  val handle_unexpected_token :
    productions:(xsymbol * xsymbol list * production * int) list ->
    next_token:token tok ->
    acceptable_tokens:token tok list ->
    reducible_productions:production list ->
    generation_streak:int ->
    lookahead:(token, production) lookahead ->
    (token, production) recovery_action
  (** called when [next_token] does not fit *)
end

module type IncrementalParser = sig
  type ast
  type 'a checkpoint

  val main : Lexing.position -> ast checkpoint

  type token

  val token : Lexing.lexbuf -> token
end

type error =
  | LexError of (Lexing.position * string)
  | ParseError of (Lexing.position * int)

type completion = Lexing.position * string

(** The input is lexed upfront (up to [EOF]), and the recovery sees the
    tokens ahead *)
module MakeLookahead : functor
  (I : MenhirLib.IncrementalEngine.EVERYTHING)
  (M : IncrementalParser with type 'a checkpoint = 'a I.checkpoint and type token = I.token)
  (_ : RecoveryLookahead
         with type token = I.token
          and type 'a symbol = 'a I.symbol
          and type xsymbol = I.xsymbol
          and type 'a terminal = 'a I.terminal
          and type 'a env = 'a I.env
          and type production = I.production)
  -> sig
  val lex : Lexing.lexbuf -> I.token tok array
  (** all the tokens, with [M.token], up to [EOF] included *)

  val parse_tokens : Lexing.position -> I.token tok array -> error list * completion list * M.ast
  (** parse tokens (ending with [EOF]), the position is the start of the input *)

  val parse : Lexing.lexbuf -> error list * completion list * M.ast
  (** [parse_tokens] of [lex] *)
end

(** The recovery does not look ahead; same as [MakeLookahead] *)
module Make : functor
  (I : MenhirLib.IncrementalEngine.EVERYTHING)
  (M : IncrementalParser with type 'a checkpoint = 'a I.checkpoint and type token = I.token)
  (_ : Recovery
         with type token = I.token
          and type 'a symbol = 'a I.symbol
          and type xsymbol = I.xsymbol
          and type 'a terminal = 'a I.terminal
          and type 'a env = 'a I.env
          and type production = I.production)
  -> sig
  val parse : Lexing.lexbuf -> error list * completion list * M.ast
end
