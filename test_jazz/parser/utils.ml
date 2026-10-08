(* The part of Jasmin's Utils (compiler/src/utils.ml) used by the lexer and
   by syntax.ml. Jasmin's Utils is built on batteries; the few functions of
   batteries used here are reimplemented on the standard library. *)

module Hash = struct
  include Hashtbl
  let of_enum l = let h = create 97 in List.iter (fun (k, v) -> replace h k v) l; h
  let find_option = find_opt
end

module List = struct
  include Stdlib.List
  let enum l = l
end

module Option = struct
  include Stdlib.Option
  let default d = function Some x -> x | None -> d
end

module String = struct
  include Stdlib.String
  let count_char s c = fold_left (fun n c' -> if c = c' then n + 1 else n) 0 s
  let filter p s =
    let b = Buffer.create (length s) in
    iter (fun c -> if p c then Buffer.add_char b c) s;
    Buffer.contents b
end

(* -------------------------------------------------------------------- *)
type 'a pp = Format.formatter -> 'a -> unit

let rec pp_list sep pp fmt xs =
  let pp_list = pp_list sep pp in
  match xs with
  | []      -> ()
  | [x]     -> Format.fprintf fmt "%a" pp x
  | x :: xs -> Format.fprintf fmt "%a%(%)%a" pp x sep pp_list xs

let pp_string fmt s =
  Format.fprintf fmt "%s" s
