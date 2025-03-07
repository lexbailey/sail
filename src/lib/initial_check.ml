(****************************************************************************)
(*     Sail                                                                 *)
(*                                                                          *)
(*  Sail and the Sail architecture models here, comprising all files and    *)
(*  directories except the ASL-derived Sail code in the aarch64 directory,  *)
(*  are subject to the BSD two-clause licence below.                        *)
(*                                                                          *)
(*  The ASL derived parts of the ARMv8.3 specification in                   *)
(*  aarch64/no_vector and aarch64/full are copyright ARM Ltd.               *)
(*                                                                          *)
(*  Copyright (c) 2013-2021                                                 *)
(*    Kathyrn Gray                                                          *)
(*    Shaked Flur                                                           *)
(*    Stephen Kell                                                          *)
(*    Gabriel Kerneis                                                       *)
(*    Robert Norton-Wright                                                  *)
(*    Christopher Pulte                                                     *)
(*    Peter Sewell                                                          *)
(*    Alasdair Armstrong                                                    *)
(*    Brian Campbell                                                        *)
(*    Thomas Bauereiss                                                      *)
(*    Anthony Fox                                                           *)
(*    Jon French                                                            *)
(*    Dominic Mulligan                                                      *)
(*    Stephen Kell                                                          *)
(*    Mark Wassell                                                          *)
(*    Alastair Reid (Arm Ltd)                                               *)
(*                                                                          *)
(*  All rights reserved.                                                    *)
(*                                                                          *)
(*  This work was partially supported by EPSRC grant EP/K008528/1 <a        *)
(*  href="http://www.cl.cam.ac.uk/users/pes20/rems">REMS: Rigorous          *)
(*  Engineering for Mainstream Systems</a>, an ARM iCASE award, EPSRC IAA   *)
(*  KTF funding, and donations from Arm.  This project has received         *)
(*  funding from the European Research Council (ERC) under the European     *)
(*  Union’s Horizon 2020 research and innovation programme (grant           *)
(*  agreement No 789108, ELVER).                                            *)
(*                                                                          *)
(*  This software was developed by SRI International and the University of  *)
(*  Cambridge Computer Laboratory (Department of Computer Science and       *)
(*  Technology) under DARPA/AFRL contracts FA8650-18-C-7809 ("CIFV")        *)
(*  and FA8750-10-C-0237 ("CTSRD").                                         *)
(*                                                                          *)
(*  SPDX-License-Identifier: BSD-2-Clause                                   *)
(****************************************************************************)

open Ast
open Ast_defs
open Ast_util
open Util
open Printf
module Big_int = Nat_big_num

module P = Parse_ast

(* See mli file for details on what these flags do *)
let opt_fast_undefined = ref false
let opt_magic_hash = ref false
let opt_abstract_types = ref false
let opt_strict_bitvector = ref false

let abstract_type_error = "Abstract types are currently experimental, use the --abstract-types flag to enable"

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

(* These are types that are defined in Sail, but we rely on them
   having specific definitions, so we only allow them to be defined in
   $sail_internal marked files in the prelude. *)
let reserved_type_ids = IdSet.of_list [mk_id "result"; mk_id "option"]

type type_constructor = P.kind_aux list * P.kind_aux

type ctx = {
  kinds : (kind_aux * P.l) KBindings.t;
  function_type_variables : (kind_aux * P.l) KBindings.t Bindings.t;
  type_constructors : type_constructor Bindings.t;
  scattereds : (P.typquant * ctx) Bindings.t;
  fixities : (prec * int) Bindings.t;
  internal_files : StringSet.t;
  target_sets : string list StringMap.t;
}

type 'a ctx_out = 'a * ctx

let rec equal_ctx ctx1 ctx2 =
  KBindings.equal ( = ) ctx1.kinds ctx2.kinds
  && Bindings.equal (KBindings.equal ( = )) ctx1.function_type_variables ctx2.function_type_variables
  && Bindings.equal ( = ) ctx1.type_constructors ctx2.type_constructors
  && Bindings.equal
       (fun (typq1, ctx1) (typq2, ctx2) -> typq1 = typq2 && equal_ctx ctx1 ctx2)
       ctx1.scattereds ctx2.scattereds
  && Bindings.equal ( = ) ctx1.fixities ctx2.fixities
  && StringSet.equal ctx1.internal_files ctx2.internal_files
  && StringMap.equal ( = ) ctx1.target_sets ctx2.target_sets

let merge_ctx l ctx1 ctx2 =
  let compatible equal err k x y =
    match (x, y) with
    | None, None -> None
    | Some x, None -> Some x
    | None, Some y -> Some y
    | Some x, Some y -> if equal x y then Some x else raise (Reporting.err_general l (err k))
  in
  {
    kinds =
      KBindings.merge
        (compatible ( = ) (fun v -> "Mismatching kinds for type variable " ^ string_of_kid v))
        ctx1.kinds ctx2.kinds;
    function_type_variables =
      Bindings.merge
        (compatible (KBindings.equal ( = )) (fun id ->
             "Different type variable environments for " ^ string_of_id id ^ " found"
         )
        )
        ctx1.function_type_variables ctx2.function_type_variables;
    type_constructors =
      Bindings.merge
        (compatible ( = ) (fun id -> "Different definitions for type constructor " ^ string_of_id id ^ " found"))
        ctx1.type_constructors ctx2.type_constructors;
    scattereds =
      Bindings.merge
        (compatible
           (fun (typq1, ctx1) (typq2, ctx2) -> typq1 = typq2 && equal_ctx ctx1 ctx2)
           (fun id -> "Scattered definition " ^ string_of_id id ^ " found with mismatching context")
        )
        ctx1.scattereds ctx2.scattereds;
    fixities =
      Bindings.merge
        (compatible ( = ) (fun id -> "Operator " ^ string_of_id id ^ " declared with multiple fixities"))
        ctx1.fixities ctx2.fixities;
    internal_files = StringSet.union ctx1.internal_files ctx2.internal_files;
    target_sets =
      StringMap.merge
        (compatible ( = ) (fun s -> "Mismatching target set " ^ s ^ " found"))
        ctx1.target_sets ctx2.target_sets;
  }

let string_of_parse_id_aux = function P.Id v -> v | P.Operator v -> v

let string_of_parse_id (P.Id_aux (id, l)) = string_of_parse_id_aux id

let parse_id_loc (P.Id_aux (_, l)) = l

let string_contains str char =
  try
    ignore (String.index str char);
    true
  with Not_found -> false

let to_ast_kind_aux = function
  | P.K_type -> Some K_type
  | P.K_int -> Some K_int
  | P.K_nat -> Some K_int
  | P.K_order -> None
  | P.K_bool -> Some K_bool

let to_ast_kind (P.K_aux (k, l)) =
  match k with
  | P.K_type -> Some (K_aux (K_type, l))
  | P.K_int -> Some (K_aux (K_int, l))
  | P.K_nat -> Some (K_aux (K_int, l))
  | P.K_order -> None
  | P.K_bool -> Some (K_aux (K_bool, l))

let parse_kind_constraint l v = function
  | P.K_nat when !opt_strict_bitvector ->
      let v = Nexp_aux (Nexp_var v, kid_loc v) in
      Some (NC_aux (NC_ge (v, Nexp_aux (Nexp_constant Big_int.zero, l)), l))
  | _ -> None

let not_order_kind = function P.K_order -> false | _ -> true

let filter_order_kinds kinds = List.filter not_order_kind kinds

let string_of_parse_kind_aux = function
  | P.K_order -> "Order"
  | P.K_int -> "Int"
  | P.K_nat -> if !opt_strict_bitvector then "Nat" else "Int"
  | P.K_bool -> "Bool"
  | P.K_type -> "Type"

(* Used for error messages involving lists of kinds *)
let format_parse_kind_aux_list = function
  | [kind] -> string_of_parse_kind_aux kind
  | kinds -> "(" ^ Util.string_of_list ", " string_of_parse_kind_aux kinds ^ ")"

let format_kind_aux_list = function
  | [kind] -> string_of_kind_aux kind
  | kinds -> "(" ^ Util.string_of_list ", " string_of_kind_aux kinds ^ ")"

let to_parse_kind = function
  | Some K_int -> P.K_int
  | Some K_bool -> P.K_bool
  | Some K_type -> P.K_type
  | None -> P.K_order

let unaux_parse_kind (P.K_aux (aux, _)) = aux

let to_ast_id ctx (P.Id_aux (id, l)) =
  let to_ast_id' id = Id_aux ((match id with P.Id x -> Id x | P.Operator x -> Operator x), l) in
  if string_contains (string_of_parse_id_aux id) '#' then begin
    match Reporting.loc_file l with
    | Some file when !opt_magic_hash || StringSet.mem file ctx.internal_files -> to_ast_id' id
    | None -> to_ast_id' id
    | _ -> raise (Reporting.err_general l "Identifier contains hash character and -dmagic_hash is unset")
  end
  else to_ast_id' id

let to_infix_parser_op =
  let open Infix_parser in
  function
  | Infix, 0, x -> Op0 x
  | InfixL, 0, x -> Op0l x
  | InfixR, 0, x -> Op0r x
  | Infix, 1, x -> Op1 x
  | InfixL, 1, x -> Op1l x
  | InfixR, 1, x -> Op1r x
  | Infix, 2, x -> Op2 x
  | InfixL, 2, x -> Op2l x
  | InfixR, 2, x -> Op2r x
  | Infix, 3, x -> Op3 x
  | InfixL, 3, x -> Op3l x
  | InfixR, 3, x -> Op3r x
  | Infix, 4, x -> Op4 x
  | InfixL, 4, x -> Op4l x
  | InfixR, 4, x -> Op4r x
  | Infix, 5, x -> Op5 x
  | InfixL, 5, x -> Op5l x
  | InfixR, 5, x -> Op5r x
  | Infix, 6, x -> Op6 x
  | InfixL, 6, x -> Op6l x
  | InfixR, 6, x -> Op6r x
  | Infix, 7, x -> Op7 x
  | InfixL, 7, x -> Op7l x
  | InfixR, 7, x -> Op7r x
  | Infix, 8, x -> Op8 x
  | InfixL, 8, x -> Op8l x
  | InfixR, 8, x -> Op8r x
  | Infix, 9, x -> Op9 x
  | InfixL, 9, x -> Op9l x
  | InfixR, 9, x -> Op9r x
  | _ -> Reporting.unreachable P.Unknown __POS__ "Invalid fixity"

let parse_infix :
      'a 'b.
      P.l ->
      ctx ->
      ('a P.infix_token * Lexing.position * Lexing.position) list ->
      ('a -> Infix_parser.token) ->
      'b Infix_parser.MenhirInterpreter.checkpoint ->
      'b =
 fun l ctx infix_tokens mk_primary checkpoint ->
  let open Infix_parser in
  let tokens =
    ref
      (List.map
         (function
           | P.IT_primary x, s, e -> (mk_primary x, s, e)
           | P.IT_prefix id, s, e -> (
               match id with
               | Id_aux (Id "pow2", _) -> (TwoCaret, s, e)
               | Id_aux (Id "negate", _) -> (Minus, s, e)
               | Id_aux (Id "__deref", _) -> (Star, s, e)
               | _ -> raise (Reporting.err_general (P.Range (s, e)) "Unknown prefix operator")
             )
           | P.IT_op id, s, e -> (
               match id with
               | Id_aux (Id "+", _) -> (Plus, s, e)
               | Id_aux (Id "-", _) -> (Minus, s, e)
               | Id_aux (Id "*", _) -> (Star, s, e)
               | Id_aux (Id "<", _) -> (Lt, s, e)
               | Id_aux (Id ">", _) -> (Gt, s, e)
               | Id_aux (Id "<=", _) -> (LtEq, s, e)
               | Id_aux (Id ">=", _) -> (GtEq, s, e)
               | Id_aux (Id "::", _) -> (ColonColon, s, e)
               | Id_aux (Id "@", _) -> (At, s, e)
               | Id_aux (Id "in", _) -> (In, s, e)
               | _ -> (
                   match Bindings.find_opt (to_ast_id ctx id) ctx.fixities with
                   | Some (prec, level) -> (to_infix_parser_op (prec, level, id), s, e)
                   | None ->
                       raise
                         (Reporting.err_general
                            (P.Range (s, e))
                            ("Undeclared fixity for operator " ^ string_of_parse_id id)
                         )
                 )
             )
           )
         infix_tokens
      )
  in
  let supplier () : token * Lexing.position * Lexing.position =
    match !tokens with
    | [((_, _, e) as token)] ->
        tokens := [(Infix_parser.Eof, e, e)];
        token
    | token :: rest ->
        tokens := rest;
        token
    | [] -> assert false
  in
  try MenhirInterpreter.loop supplier checkpoint
  with Infix_parser.Error -> raise (Reporting.err_syntax_loc l "Failed to parse infix expression")

let parse_infix_exp ctx = function
  | P.E_aux (P.E_infix infix_tokens, l) -> (
      match infix_tokens with
      | (_, s, _) :: _ ->
          parse_infix l ctx infix_tokens (fun exp -> Infix_parser.Exp exp) (Infix_parser.Incremental.exp_eof s)
      | [] -> Reporting.unreachable l __POS__ "Found empty infix expression"
    )
  | exp -> exp

let parse_infix_atyp ctx = function
  | P.ATyp_aux (P.ATyp_infix infix_tokens, l) -> (
      match infix_tokens with
      | (_, s, _) :: _ ->
          parse_infix l ctx infix_tokens (fun typ -> Infix_parser.Typ typ) (Infix_parser.Incremental.typ_eof s)
      | [] -> Reporting.unreachable l __POS__ "Found empty infix type"
    )
  | atyp -> atyp

let to_ast_var (P.Kid_aux (P.Var v, l)) = Kid_aux (Var v, l)

(** The [KindInference] module implements a type-inference module for
    kind (types of types).

    The algorithm used is essentially Hindley-Milner style, athough
    because the language of types is very simple, some things can be
    simple. *)
module KindInference = struct
  (** This is the kind for a variable during kind inference. Either it
      can be [Unknown], or it can be a [Known] kind. *)
  type unification_kind = Unknown | Known of P.kind_aux * l

  (** This type is similar to the [unification_kind] type, but the
      [Unknown] kinds are represented as variables. When checking a
      kind-polymorphic type constructor (e.g. operator ==) in types we
      want to have something like:
      {v
      ∀α. (α, α) -> Bool
      v}
      To do this we create a new fresh variable for [α], which would
      be a [Kind_var], and [Bool] would be an explicit [Kind]. *)
  type inference_kind = Kind_var of int | Kind of P.kind_aux * l

  (* This is the typing environment for the kind-inference
     algorithm. *)
  type env = { sets : (IntSet.t * unification_kind) list; next_unknown : int; vars : int KBindings.t list }

  (* The typing rules in this module are defined in terms of a state
     monad over the typing environment. *)
  include Util.State_monad (struct
    type t = env
  end)

  let get_var v env =
    let rec go = function
      | [] -> (None, env)
      | top :: stack -> (
          match KBindings.find_opt v top with
          | Some n ->
              let uk = snd (List.find (fun (set, _) -> IntSet.mem n set) env.sets) in
              (Some (n, uk), env)
          | None -> go stack
        )
    in
    go env.vars

  let update n uk env =
    let rec go = function
      | [] -> []
      | (set, old_uk) :: sets -> if IntSet.mem n set then (set, uk) :: sets else (set, old_uk) :: go sets
    in
    ((), { env with sets = go env.sets })

  let unify_kind kind l kind' l' =
    match (kind, kind') with
    | P.K_nat, P.K_int | P.K_int, P.K_nat -> P.K_nat
    | P.K_int, P.K_int | P.K_nat, P.K_nat | P.K_bool, P.K_bool | P.K_type, P.K_type | P.K_order, P.K_order -> kind
    | _ ->
        raise
          (Reporting.err_typ
             (Hint ("Inferred kind " ^ string_of_parse_kind_aux kind' ^ " from this", l', l))
             ("Expected this type to have kind " ^ string_of_parse_kind_aux kind' ^ " but found kind "
            ^ string_of_parse_kind_aux kind
             )
          )

  let merge_unification_kind k1 k2 =
    match (k1, k2) with
    | Unknown, Unknown -> Unknown
    | Unknown, known | known, Unknown -> known
    | Known (kind, l), Known (kind', l') ->
        let kind'' = unify_kind kind l kind' l' in
        Known (kind'', l)

  let unify n m env =
    let n_sets, other_sets = List.partition (fun (set, _) -> IntSet.mem n set) env.sets in
    let n_set, nk = List.hd n_sets in
    if IntSet.mem m n_set then ((), env)
    else (
      let m_sets, other_sets = List.partition (fun (set, _) -> IntSet.mem m set) other_sets in
      let m_set, mk = List.hd m_sets in
      ((), { env with sets = (IntSet.union n_set m_set, merge_unification_kind nk mk) :: other_sets })
    )

  let abstract_unknown env =
    ( env.next_unknown,
      { env with sets = (IntSet.singleton env.next_unknown, Unknown) :: env.sets; next_unknown = env.next_unknown + 1 }
    )

  let abstract =
    let* u = abstract_unknown in
    return (Kind_var u)

  let add_vars kopts =
    let* env = get_state in
    let unknowns = ref env.next_unknown in
    let sets = ref [] in
    let vars = ref KBindings.empty in
    let kopts =
      List.map
        (fun (P.KOpt_aux (P.KOpt_kind (attr, vs, kind_opt, _), l)) ->
          let u = !unknowns in
          incr unknowns;
          begin
            match kind_opt with
            | Some k -> sets := (IntSet.singleton u, Known (unaux_parse_kind k, l)) :: !sets
            | None -> sets := (IntSet.singleton u, Unknown) :: !sets
          end;
          List.iter (fun v -> vars := KBindings.add (to_ast_var v) u !vars) vs;
          P.KOpt_aux (P.KOpt_kind (attr, vs, kind_opt, Some u), l)
        )
        kopts
    in
    let* () = put_state { sets = !sets @ env.sets; next_unknown = !unknowns; vars = !vars :: env.vars } in
    return kopts

  let resolve ~at:l kind ik env =
    match ik with
    | Kind_var n ->
        let n_sets, other_sets = List.partition (fun (set, _) -> IntSet.mem n set) env.sets in
        let n_set, nk = List.hd n_sets in
        ((), { env with sets = (n_set, merge_unification_kind nk (Known (kind, l))) :: env.sets })
    | Kind (kind', l') ->
        let _ = unify_kind kind l kind' l' in
        ((), env)

  let atyp_loc (P.ATyp_aux (_, l)) = l

  let rec check ctx (P.ATyp_aux (aux, l) as atyp) ik =
    let wrap aux = return (P.ATyp_aux (aux, l)) in
    match aux with
    | P.ATyp_id id ->
        let id' = to_ast_id ctx id in
        let* () =
          match Bindings.find_opt id' ctx.type_constructors with
          | None -> return ()
          | Some ([], ret_kind) -> resolve ~at:l ret_kind ik
          | Some (kind_opts, _) -> raise (ksprintf (Reporting.err_typ l) "%s is not a constant" (string_of_id id'))
        in
        return atyp
    | P.ATyp_var v -> begin
        let v = to_ast_var v in
        let* var_info = get_var v in
        let* () =
          match (ik, var_info) with
          | Kind_var n, Some (m, _) -> unify n m
          | Kind (kind, l), Some (m, uk) ->
              let uk = merge_unification_kind (Known (kind, l)) uk in
              update m uk
          | _, None -> begin
              match KBindings.find_opt v ctx.kinds with
              | None -> return ()
              | Some (bound_kind, bound_loc) ->
                  resolve ~at:(Hint ("bound here", bound_loc, l)) (to_parse_kind (Some bound_kind)) ik
            end
        in
        return atyp
      end
    | P.ATyp_if ((P.ATyp_aux (_, i_l) as i), t, e) ->
        let* i = check ctx i (Kind (P.K_bool, i_l)) in
        let* t = check ctx t ik in
        let* e = check ctx e ik in
        wrap (P.ATyp_if (i, t, e))
    | P.ATyp_app ((P.Id_aux (P.Operator ("==" | "!="), _) as id), [t1; t2]) ->
        let* () = resolve ~at:l P.K_bool ik in
        let* a = abstract in
        let* t1 = check ctx t1 a in
        let* t2 = check ctx t2 a in
        wrap (P.ATyp_app (id, [t1; t2]))
    | P.ATyp_app ((P.Id_aux (P.Operator (">=" | "<=" | ">" | "<"), _) as id), [t1; t2]) ->
        let* () = resolve ~at:l P.K_bool ik in
        let kind = Kind (P.K_int, l) in
        let* t1 = check ctx t1 kind in
        let* t2 = check ctx t2 kind in
        wrap (P.ATyp_app (id, [t1; t2]))
    | P.ATyp_app ((P.Id_aux (P.Operator ("&" | "|"), _) as id), [t1; t2]) ->
        let* () = resolve ~at:l P.K_bool ik in
        let kind = Kind (P.K_bool, l) in
        let* t1 = check ctx t1 kind in
        let* t2 = check ctx t2 kind in
        wrap (P.ATyp_app (id, [t1; t2]))
    | P.ATyp_app ((P.Id_aux (P.Id "int", _) as id), [arg]) ->
        let* () = resolve ~at:l K_type ik in
        let* arg = check ctx arg (Kind (P.K_int, atyp_loc arg)) in
        wrap (P.ATyp_app (id, [arg]))
    | P.ATyp_app ((P.Id_aux (P.Id "bool", _) as id), [arg]) ->
        let* () = resolve ~at:l K_type ik in
        let* arg = check ctx arg (Kind (P.K_bool, atyp_loc arg)) in
        wrap (P.ATyp_app (id, [arg]))
    | P.ATyp_sum (t1, t2) ->
        let* () = resolve ~at:l K_int ik in
        let* t1 = check ctx t1 (Kind (P.K_int, atyp_loc t1)) in
        let* t2 = check ctx t2 (Kind (P.K_int, atyp_loc t2)) in
        wrap (P.ATyp_sum (t1, t2))
    | P.ATyp_times (t1, t2) -> begin
        (* Special case N * M when either N or M is a constant > 0, in
           which case we can infer that if N * M is a Nat then the
           non-constant case is also a Nat *)
        match (t1, t2) with
        | P.ATyp_aux (P.ATyp_lit (P.L_aux (P.L_num n, _)), _), _ when Big_int.greater n Big_int.zero ->
            let* t2 = check ctx t2 ik in
            wrap (P.ATyp_times (t1, t2))
        | _, P.ATyp_aux (P.ATyp_lit (P.L_aux (P.L_num n, _)), _) when Big_int.greater n Big_int.zero ->
            let* t1 = check ctx t1 ik in
            wrap (P.ATyp_times (t1, t2))
        | _ ->
            let* () = resolve ~at:l K_int ik in
            let* t1 = check ctx t1 (Kind (P.K_int, atyp_loc t1)) in
            let* t2 = check ctx t2 (Kind (P.K_int, atyp_loc t2)) in
            wrap (P.ATyp_times (t1, t2))
      end
    | P.ATyp_minus (t1, t2) ->
        let* () = resolve ~at:l K_int ik in
        let* t1 = check ctx t1 (Kind (P.K_int, atyp_loc t1)) in
        let* t2 = check ctx t2 (Kind (P.K_int, atyp_loc t2)) in
        wrap (P.ATyp_minus (t1, t2))
    | P.ATyp_exp t ->
        let* () = resolve ~at:l K_int ik in
        let* t = check ctx t (Kind (P.K_int, atyp_loc t)) in
        wrap (P.ATyp_exp t)
    | P.ATyp_neg t ->
        let* t = check ctx t ik in
        wrap (P.ATyp_neg t)
    | P.ATyp_app (id, args) ->
        let id' = to_ast_id ctx id in
        let* args =
          match Bindings.find_opt id' ctx.type_constructors with
          | None ->
              raise (ksprintf (Reporting.err_typ l) "Unknown type level operator or function %s" (string_of_id id'))
          | Some (kinds, ret_kind) ->
              let* () = resolve ~at:l ret_kind ik in
              let args_len = List.length args in
              let kinds = if args_len = List.length kinds then kinds else filter_order_kinds kinds in
              if List.compare_lengths args kinds <> 0 then
                raise
                  (Reporting.err_typ l
                     (sprintf "%s : %s -> Type expected %d arguments, given %d" (string_of_id id')
                        (format_parse_kind_aux_list (filter_order_kinds kinds))
                        (List.length kinds) (List.length args)
                     )
                  );
              mapM (function arg, kind -> check ctx arg (Kind (kind, id_loc id'))) (List.combine args kinds)
        in
        wrap (P.ATyp_app (id, args))
    | P.ATyp_lit (P.L_aux (aux, _)) ->
        let* () =
          match aux with
          | P.L_num _ -> resolve ~at:l P.K_int ik
          | P.L_true | P.L_false -> resolve ~at:l K_bool ik
          | _ -> raise (Reporting.err_typ l "Unexpected literal in type")
        in
        return atyp
    | P.ATyp_parens atyp ->
        let* atyp = check ctx atyp ik in
        wrap (P.ATyp_parens atyp)
    | P.ATyp_tuple ts ->
        let* () = resolve ~at:l P.K_type ik in
        let* ts = mapM (fun (P.ATyp_aux (_, l) as t) -> check ctx t (Kind (K_type, l))) ts in
        wrap (P.ATyp_tuple ts)
    | P.ATyp_in (n, set) ->
        let* () = resolve ~at:l P.K_bool ik in
        let* n = check ctx n (Kind (P.K_int, l)) in
        wrap (P.ATyp_in (n, set))
    | P.ATyp_infix _ ->
        let atyp = parse_infix_atyp ctx atyp in
        check ctx atyp ik
    | P.ATyp_nset ts ->
        let* () = resolve ~at:l K_type ik in
        wrap (P.ATyp_nset ts)
    | P.ATyp_exist (kopts, nc, atyp) ->
        let* () = resolve ~at:l K_type ik in
        let* env = get_state in
        let unknowns = ref env.next_unknown in
        let sets = ref [] in
        let vars = ref KBindings.empty in
        let kopts =
          List.map
            (fun (P.KOpt_aux (P.KOpt_kind (attr, vs, kind_opt, _), l)) ->
              let u = !unknowns in
              incr unknowns;
              begin
                match kind_opt with
                | Some k -> sets := (IntSet.singleton u, Known (unaux_parse_kind k, l)) :: !sets
                | None -> sets := (IntSet.singleton u, Unknown) :: !sets
              end;
              List.iter (fun v -> vars := KBindings.add (to_ast_var v) u !vars) vs;
              P.KOpt_aux (P.KOpt_kind (attr, vs, kind_opt, Some u), l)
            )
            kopts
        in
        let* () = put_state { sets = !sets @ env.sets; next_unknown = !unknowns; vars = !vars :: env.vars } in
        let* nc = check ctx nc (Kind (P.K_bool, l)) in
        let* atyp = check ctx atyp (Kind (P.K_type, l)) in
        let* env = get_state in
        let* () = put_state { env with vars = List.tl env.vars } in
        wrap (P.ATyp_exist (kopts, nc, atyp))
    | P.ATyp_inc | P.ATyp_dec ->
        let* () = resolve ~at:l P.K_order ik in
        return atyp
    | P.ATyp_set _ -> Reporting.unreachable l __POS__ "Unexpected element in type expression inference"
    | P.ATyp_wild -> raise (Reporting.err_typ l "Wildcard type not allowed here")
    | P.ATyp_fn (from_atyp, to_atyp, effects) ->
        let* from_atyp = check ctx from_atyp (Kind (P.K_type, l)) in
        let* to_atyp = check ctx to_atyp (Kind (P.K_type, l)) in
        wrap (P.ATyp_fn (from_atyp, to_atyp, effects))
    | P.ATyp_bidir (atyp1, atyp2, effects) ->
        let* atyp1 = check ctx atyp1 (Kind (P.K_type, l)) in
        let* atyp2 = check ctx atyp2 (Kind (P.K_type, l)) in
        wrap (P.ATyp_bidir (atyp1, atyp2, effects))

  let infer_quant_item ctx = function
    | P.QI_aux (P.QI_constraint nc, l) ->
        let* nc = check ctx nc (Kind (P.K_bool, l)) in
        return (P.QI_aux (P.QI_constraint nc, l))
    | P.QI_aux (P.QI_id kopt, l) ->
        let* kopt = fmap List.hd (add_vars [kopt]) in
        return (P.QI_aux (P.QI_id kopt, l))

  let infer_typquant ctx (P.TypQ_aux (aux, l)) =
    match aux with
    | P.TypQ_no_forall -> return (P.TypQ_aux (P.TypQ_no_forall, l))
    | P.TypQ_tq quants ->
        let* quants = mapM (infer_quant_item ctx) quants in
        return (P.TypQ_aux (P.TypQ_tq quants, l))

  let infer_tannot_opt ctx (P.Typ_annot_opt_aux (tp, l)) =
    match tp with
    | P.Typ_annot_opt_none -> return (P.Typ_annot_opt_aux (P.Typ_annot_opt_none, l))
    | P.Typ_annot_opt_some (tq, (ATyp_aux (_, t_l) as typ)) ->
        let* tq = infer_typquant ctx tq in
        let* typ = check ctx typ (Kind (P.K_type, t_l)) in
        return (P.Typ_annot_opt_aux (P.Typ_annot_opt_some (tq, typ), l))

  let rec infer_pat ctx (P.P_aux (aux, l) as pat) =
    let wrap aux = return (P.P_aux (aux, l)) in
    match aux with
    | P.P_lit _ | P.P_wild | P.P_id _ | P.P_vector_subrange _ -> return pat
    | P.P_typ (atyp, pat) ->
        let* pat = infer_pat ctx pat in
        let* atyp = check ctx atyp (Kind (P.K_type, l)) in
        wrap (P.P_typ (atyp, pat))
    | P.P_var (pat, atyp) ->
        let* pat = infer_pat ctx pat in
        let* atyp = check ctx atyp (Kind (P.K_type, l)) in
        wrap (P.P_var (pat, atyp))
    | P.P_app (id, pats) ->
        let* pats = mapM (infer_pat ctx) pats in
        wrap (P.P_app (id, pats))
    | P.P_vector pats ->
        let* pats = mapM (infer_pat ctx) pats in
        wrap (P.P_vector pats)
    | P.P_vector_concat pats ->
        let* pats = mapM (infer_pat ctx) pats in
        wrap (P.P_vector_concat pats)
    | P.P_tuple pats ->
        let* pats = mapM (infer_pat ctx) pats in
        wrap (P.P_tuple pats)
    | P.P_list pats ->
        let* pats = mapM (infer_pat ctx) pats in
        wrap (P.P_list pats)
    | P.P_cons (hd_pat, tl_pat) ->
        let* hd_pat = infer_pat ctx hd_pat in
        let* tl_pat = infer_pat ctx tl_pat in
        wrap (P.P_cons (hd_pat, tl_pat))
    | P.P_string_append pats ->
        let* pats = mapM (infer_pat ctx) pats in
        wrap (P.P_string_append pats)
    | P.P_struct fpats ->
        let* fpats =
          mapM
            (fun (P.FP_aux (aux, l)) ->
              match aux with
              | P.FP_wild -> return (P.FP_aux (P.FP_wild, l))
              | P.FP_field (field, pat) ->
                  let* pat = infer_pat ctx pat in
                  return (P.FP_aux (P.FP_field (field, pat), l))
            )
            fpats
        in
        wrap (P.P_struct fpats)
    | P.P_attribute (attr, arg, pat) ->
        let* pat = infer_pat ctx pat in
        wrap (P.P_attribute (attr, arg, pat))

  let rec infer_case ctx (P.Pat_aux (pexp, l)) =
    let wrap aux = return (P.Pat_aux (aux, l)) in
    match pexp with
    | P.Pat_attribute (attr, arg, pexp) ->
        let* pexp = infer_case ctx pexp in
        wrap (P.Pat_attribute (attr, arg, pexp))
    | P.Pat_exp (pat, exp) ->
        let* pat = infer_pat ctx pat in
        wrap (P.Pat_exp (pat, exp))
    | P.Pat_when (pat, guard, exp) ->
        let* pat = infer_pat ctx pat in
        wrap (P.Pat_when (pat, guard, exp))

  let rec infer_funcl ctx (P.FCL_aux (fcl, l)) =
    let wrap aux = return (P.FCL_aux (aux, l)) in
    match fcl with
    | P.FCL_private fcl ->
        let* fcl = infer_funcl ctx fcl in
        wrap (P.FCL_private fcl)
    | P.FCL_attribute (attr, arg, fcl) ->
        let* fcl = infer_funcl ctx fcl in
        wrap (P.FCL_attribute (attr, arg, fcl))
    | P.FCL_doc (doc_comment, fcl) ->
        let* fcl = infer_funcl ctx fcl in
        wrap (P.FCL_doc (doc_comment, fcl))
    | P.FCL_funcl (id, case) ->
        let* case = infer_case ctx case in
        wrap (P.FCL_funcl (id, case))

  let infer_fundef ctx (P.FD_aux (P.FD_function (rec_opt, tannot_opt, funcls), l)) =
    let* tannot_opt = infer_tannot_opt ctx tannot_opt in
    let* funcls = mapM (infer_funcl ctx) funcls in
    return (P.FD_aux (P.FD_function (rec_opt, tannot_opt, funcls), l))

  let rec infer_constructor ctx (P.Tu_aux (aux, l)) =
    let wrap aux = return (P.Tu_aux (aux, l)) in
    match aux with
    | P.Tu_private tu ->
        let* tu = infer_constructor ctx tu in
        wrap (P.Tu_private tu)
    | P.Tu_attribute (attr, arg, tu) ->
        let* tu = infer_constructor ctx tu in
        wrap (P.Tu_attribute (attr, arg, tu))
    | P.Tu_doc (doc_comment, tu) ->
        let* tu = infer_constructor ctx tu in
        wrap (P.Tu_doc (doc_comment, tu))
    | P.Tu_ty_id (atyp, id) ->
        let* atyp = check ctx atyp (Kind (P.K_type, atyp_loc atyp)) in
        wrap (P.Tu_ty_id (atyp, id))
    | P.Tu_ty_anon_rec (fields, id) ->
        let* fields =
          mapM
            (fun (atyp, field) ->
              let* atyp = check ctx atyp (Kind (P.K_type, atyp_loc atyp)) in
              return (atyp, field)
            )
            fields
        in
        wrap (P.Tu_ty_anon_rec (fields, id))

  let infer_union ctx typq constructors =
    let* typq = infer_typquant ctx typq in
    let* constructors = mapM (infer_constructor ctx) constructors in
    return (typq, constructors)

  let get_kind ~at:l n env =
    match List.find_opt (fun (set, _) -> IntSet.mem n set) env.sets with
    | Some (_, Unknown) -> None
    | Some (_, Known (kind, _)) -> Some kind
    | None -> Reporting.unreachable l __POS__ (sprintf "Failed to find kind inference variable %d" n)

  let check_bind ctx typq (P.ATyp_aux (_, l) as typ) kind_opt =
    let* typq = infer_typquant ctx typq in
    let* typ, kind =
      match kind_opt with
      | Some (P.K_aux (k, l)) ->
          let* typ = check ctx typ (Kind (k, l)) in
          return (typ, P.K_aux (k, l))
      | None -> (
          let* u = abstract_unknown in
          let* typ = check ctx typ (Kind_var u) in
          let* env = get_state in
          match get_kind ~at:l u env with
          | Some k -> return (typ, P.K_aux (k, gen_loc l))
          | None -> raise (Reporting.err_typ l "Failed to infer kind for this type")
        )
    in
    return (typq, typ, kind)

  let initial_env = { sets = []; next_unknown = 0; vars = [] }
end

module ConvertType = struct
  let to_ast_kopts kenv ctx (P.KOpt_aux (aux, l)) =
    let open Util.Option_monad in
    let mk_kopt v (P.K_aux (aux, _) as k) =
      let v = to_ast_var v in
      let* k = to_ast_kind k in
      Some
        ( KOpt_aux (KOpt_kind (k, v), l),
          parse_kind_constraint l v aux,
          { ctx with kinds = KBindings.add v (unaux_kind k, l) ctx.kinds }
        )
    in
    let fold_vars vs k =
      List.fold_left
        (fun (kopts, constrs, ctx) v ->
          match mk_kopt v k with
          | Some (kopt, None, ctx) -> (kopt :: kopts, constrs, ctx)
          | Some (kopt, Some constr, ctx) -> (kopt :: kopts, constr :: constrs, ctx)
          | None -> (kopts, constrs, ctx)
        )
        ([], [], ctx) vs
    in
    match aux with
    | P.KOpt_kind (attr, vs, None, Some u) ->
        let k =
          match KindInference.get_kind ~at:l u kenv with
          | Some k -> P.K_aux (k, gen_loc l)
          | None -> raise (Reporting.err_typ l "Could not infer Kind for this type variable")
        in
        (fold_vars vs k, attr)
    | P.KOpt_kind (attr, vs, None, None) ->
        let k = P.K_aux (P.K_int, gen_loc l) in
        (fold_vars vs k, attr)
    | P.KOpt_kind (attr, vs, Some k, _) -> (fold_vars vs k, attr)

  let get_inference_kinds kenv = function
    | P.TypQ_aux (P.TypQ_no_forall, _) -> []
    | P.TypQ_aux (P.TypQ_tq qis, _) ->
        let qi_kinds = function
          | P.QI_aux (P.QI_id (P.KOpt_aux (P.KOpt_kind (_, vs, None, Some u), l)), _) -> begin
              match KindInference.get_kind ~at:l u kenv with
              | Some k -> List.init (List.length vs) (fun _ -> k)
              | None -> raise (Reporting.err_typ l "Could not infer Kind for this type variable")
            end
          | P.QI_aux (P.QI_id (P.KOpt_aux (P.KOpt_kind (_, vs, Some (P.K_aux (k, _)), _), _)), _) ->
              List.init (List.length vs) (fun _ -> k)
          | _ -> []
        in
        List.concat (List.map qi_kinds qis)

  let rec to_ast_typ kenv ctx atyp =
    let (P.ATyp_aux (aux, l)) = parse_infix_atyp ctx atyp in
    match aux with
    | P.ATyp_id id -> Typ_aux (Typ_id (to_ast_id ctx id), l)
    | P.ATyp_var v -> Typ_aux (Typ_var (to_ast_var v), l)
    | P.ATyp_fn (from_typ, to_typ, _) ->
        let from_typs =
          match from_typ with
          | P.ATyp_aux (P.ATyp_tuple typs, _) -> List.map (to_ast_typ kenv ctx) typs
          | _ -> [to_ast_typ kenv ctx from_typ]
        in
        Typ_aux (Typ_fn (from_typs, to_ast_typ kenv ctx to_typ), l)
    | P.ATyp_bidir (typ1, typ2, _) -> Typ_aux (Typ_bidir (to_ast_typ kenv ctx typ1, to_ast_typ kenv ctx typ2), l)
    | P.ATyp_nset nums ->
        let n = Kid_aux (Var "'n", gen_loc l) in
        Typ_aux (Typ_exist ([mk_kopt ~loc:l K_int n], nc_set (nvar n) nums, atom_typ (nvar n)), l)
    | P.ATyp_tuple typs -> Typ_aux (Typ_tuple (List.map (to_ast_typ kenv ctx) typs), l)
    | P.ATyp_app (P.Id_aux (P.Id "int", il), [n]) ->
        Typ_aux (Typ_app (Id_aux (Id "atom", il), [to_ast_typ_arg kenv ctx n K_int]), l)
    | P.ATyp_app (P.Id_aux (P.Id "bool", il), [n]) ->
        Typ_aux (Typ_app (Id_aux (Id "atom_bool", il), [to_ast_typ_arg kenv ctx n K_bool]), l)
    | P.ATyp_app (id, args) ->
        let id = to_ast_id ctx id in
        begin
          match Bindings.find_opt id ctx.type_constructors with
          | None -> raise (Reporting.err_typ l (sprintf "Could not find type constructor %s" (string_of_id id)))
          | Some (kinds, _) ->
              let non_order_kinds = List.filter_map to_ast_kind_aux kinds in
              let kinds = List.map to_ast_kind_aux kinds in
              let args_len = List.length args in
              if args_len = List.length non_order_kinds then
                Typ_aux (Typ_app (id, List.map2 (to_ast_typ_arg kenv ctx) args non_order_kinds), l)
              else if args_len = List.length kinds then
                Typ_aux
                  ( Typ_app
                      ( id,
                        Util.option_these (List.map2 (fun arg -> Option.map (to_ast_typ_arg kenv ctx arg)) args kinds)
                      ),
                    l
                  )
              else
                raise
                  (Reporting.err_typ l
                     (sprintf "%s : %s -> Type expected %d arguments, given %d" (string_of_id id)
                        (format_kind_aux_list non_order_kinds) (List.length kinds) (List.length args)
                     )
                  )
        end
    | P.ATyp_exist (kopts, nc, atyp) ->
        let atyp = parse_infix_atyp ctx atyp in
        let kopts, ctx =
          List.fold_right
            (fun kopt (kopts, ctx) ->
              let (kopts', _, ctx), attr = to_ast_kopts kenv ctx kopt in
              match attr with
              | None -> (kopts' @ kopts, ctx)
              | Some attr ->
                  raise (Reporting.err_typ l (sprintf "Attribute %s cannot appear within an existential type" attr))
            )
            kopts ([], ctx)
        in
        Typ_aux (Typ_exist (kopts, to_ast_constraint kenv ctx nc, to_ast_typ kenv ctx atyp), l)
    | P.ATyp_parens atyp -> to_ast_typ kenv ctx atyp
    | _ -> raise (Reporting.err_typ l "Invalid type")

  and to_ast_typ_arg kenv ctx (ATyp_aux (_, l) as atyp) = function
    | K_type -> A_aux (A_typ (to_ast_typ kenv ctx atyp), l)
    | K_int -> A_aux (A_nexp (to_ast_nexp kenv ctx atyp), l)
    | K_bool -> A_aux (A_bool (to_ast_constraint kenv ctx atyp), l)

  and to_ast_nexp kenv ctx atyp =
    let (P.ATyp_aux (aux, l)) = parse_infix_atyp ctx atyp in
    match aux with
    | P.ATyp_id id -> Nexp_aux (Nexp_id (to_ast_id ctx id), l)
    | P.ATyp_var v -> Nexp_aux (Nexp_var (to_ast_var v), l)
    | P.ATyp_lit (P.L_aux (P.L_num c, _)) -> Nexp_aux (Nexp_constant c, l)
    | P.ATyp_sum (t1, t2) -> Nexp_aux (Nexp_sum (to_ast_nexp kenv ctx t1, to_ast_nexp kenv ctx t2), l)
    | P.ATyp_exp t1 -> Nexp_aux (Nexp_exp (to_ast_nexp kenv ctx t1), l)
    | P.ATyp_neg t1 -> Nexp_aux (Nexp_neg (to_ast_nexp kenv ctx t1), l)
    | P.ATyp_times (t1, t2) -> Nexp_aux (Nexp_times (to_ast_nexp kenv ctx t1, to_ast_nexp kenv ctx t2), l)
    | P.ATyp_minus (t1, t2) -> Nexp_aux (Nexp_minus (to_ast_nexp kenv ctx t1, to_ast_nexp kenv ctx t2), l)
    | P.ATyp_app (id, ts) -> Nexp_aux (Nexp_app (to_ast_id ctx id, List.map (to_ast_nexp kenv ctx) ts), l)
    | P.ATyp_parens atyp -> to_ast_nexp kenv ctx atyp
    | P.ATyp_if (i, t, e) ->
        Nexp_aux (Nexp_if (to_ast_constraint kenv ctx i, to_ast_nexp kenv ctx t, to_ast_nexp kenv ctx e), l)
    | _ -> raise (Reporting.err_typ l "Invalid numeric expression in type")

  and to_ast_bitfield_index_nexp ctx atyp =
    let (P.ATyp_aux (aux, l)) = parse_infix_atyp ctx atyp in
    match aux with
    | P.ATyp_id id -> Nexp_aux (Nexp_id (to_ast_id ctx id), l)
    | P.ATyp_lit (P.L_aux (P.L_num c, _)) -> Nexp_aux (Nexp_constant c, l)
    | P.ATyp_sum (t1, t2) ->
        Nexp_aux (Nexp_sum (to_ast_bitfield_index_nexp ctx t1, to_ast_bitfield_index_nexp ctx t2), l)
    | P.ATyp_exp t1 -> Nexp_aux (Nexp_exp (to_ast_bitfield_index_nexp ctx t1), l)
    | P.ATyp_neg t1 -> Nexp_aux (Nexp_neg (to_ast_bitfield_index_nexp ctx t1), l)
    | P.ATyp_times (t1, t2) ->
        Nexp_aux (Nexp_times (to_ast_bitfield_index_nexp ctx t1, to_ast_bitfield_index_nexp ctx t2), l)
    | P.ATyp_minus (t1, t2) ->
        Nexp_aux (Nexp_minus (to_ast_bitfield_index_nexp ctx t1, to_ast_bitfield_index_nexp ctx t2), l)
    | P.ATyp_app (id, ts) -> Nexp_aux (Nexp_app (to_ast_id ctx id, List.map (to_ast_bitfield_index_nexp ctx) ts), l)
    | P.ATyp_parens atyp -> to_ast_bitfield_index_nexp ctx atyp
    | _ -> raise (Reporting.err_typ l "Invalid numeric expression in field index")

  and to_ast_order ctx (P.ATyp_aux (aux, l)) =
    match aux with
    | P.ATyp_inc -> Ord_aux (Ord_inc, l)
    | P.ATyp_dec -> Ord_aux (Ord_dec, l)
    | P.ATyp_parens atyp -> to_ast_order ctx atyp
    | _ -> raise (Reporting.err_typ l "Invalid order in type")

  and to_ast_constraint kenv ctx atyp =
    let (P.ATyp_aux (aux, l)) = parse_infix_atyp ctx atyp in
    match aux with
    | P.ATyp_parens atyp -> to_ast_constraint kenv ctx atyp
    | _ ->
        let aux =
          match aux with
          | P.ATyp_app ((Id_aux (Operator op, _) as id), [t1; t2]) -> begin
              match op with
              | "==" -> NC_equal (to_ast_typ_arg kenv ctx t1 K_int, to_ast_typ_arg kenv ctx t2 K_int)
              | "!=" -> NC_not_equal (to_ast_typ_arg kenv ctx t1 K_int, to_ast_typ_arg kenv ctx t2 K_int)
              | ">=" -> NC_ge (to_ast_nexp kenv ctx t1, to_ast_nexp kenv ctx t2)
              | "<=" -> NC_le (to_ast_nexp kenv ctx t1, to_ast_nexp kenv ctx t2)
              | ">" -> NC_gt (to_ast_nexp kenv ctx t1, to_ast_nexp kenv ctx t2)
              | "<" -> NC_lt (to_ast_nexp kenv ctx t1, to_ast_nexp kenv ctx t2)
              | "&" -> NC_and (to_ast_constraint kenv ctx t1, to_ast_constraint kenv ctx t2)
              | "|" -> NC_or (to_ast_constraint kenv ctx t1, to_ast_constraint kenv ctx t2)
              | _ -> (
                  let id = to_ast_id ctx id in
                  match Bindings.find_opt id ctx.type_constructors with
                  | None -> raise (Reporting.err_typ l (sprintf "Could not find type constructor %s" (string_of_id id)))
                  | Some (kinds, _) ->
                      let non_order_kinds = List.filter_map to_ast_kind_aux kinds in
                      if List.length non_order_kinds = 2 then
                        NC_app (id, List.map2 (to_ast_typ_arg kenv ctx) [t1; t2] non_order_kinds)
                      else
                        raise
                          (Reporting.err_typ l
                             (sprintf "%s : %s -> Bool expected %d arguments, given 2" (string_of_id id)
                                (format_kind_aux_list non_order_kinds) (List.length non_order_kinds)
                             )
                          )
                )
            end
          | P.ATyp_app (id, args) ->
              let id = to_ast_id ctx id in
              begin
                match Bindings.find_opt id ctx.type_constructors with
                | None -> raise (Reporting.err_typ l (sprintf "Could not find type constructor %s" (string_of_id id)))
                | Some (kinds, _) ->
                    let non_order_kinds = List.filter_map to_ast_kind_aux kinds in
                    if List.length args = List.length non_order_kinds then
                      NC_app (id, List.map2 (to_ast_typ_arg kenv ctx) args non_order_kinds)
                    else
                      raise
                        (Reporting.err_typ l
                           (sprintf "%s : %s -> Bool expected %d arguments, given %d" (string_of_id id)
                              (format_kind_aux_list non_order_kinds) (List.length non_order_kinds) (List.length args)
                           )
                        )
              end
          | P.ATyp_id id -> NC_id (to_ast_id ctx id)
          | P.ATyp_var v -> NC_var (to_ast_var v)
          | P.ATyp_lit (P.L_aux (P.L_true, _)) -> NC_true
          | P.ATyp_lit (P.L_aux (P.L_false, _)) -> NC_false
          | P.ATyp_in (n, P.ATyp_aux (P.ATyp_nset bounds, _)) -> NC_set (to_ast_nexp kenv ctx n, bounds)
          | _ -> raise (Reporting.err_typ l "Invalid constraint")
        in
        NC_aux (aux, l)

  let to_ast_quant_items kenv ctx (P.QI_aux (aux, l)) =
    match aux with
    | P.QI_constraint nc -> ([QI_aux (QI_constraint (to_ast_constraint kenv ctx nc), l)], ctx)
    | P.QI_id kopt ->
        let (kopts, constrs, ctx), attr = to_ast_kopts kenv ctx kopt in
        begin
          match attr with
          | Some "constant" -> Reporting.warn "Deprecated" l "constant type variable attribute no longer used"
          | Some attr -> raise (Reporting.err_typ l (sprintf "Unknown attribute %s" attr))
          | None -> ()
        end;
        ( List.map (fun c -> QI_aux (QI_constraint c, l)) constrs @ List.map (fun kopt -> QI_aux (QI_id kopt, l)) kopts,
          ctx
        )

  let to_ast_typquant kenv ctx (P.TypQ_aux (aux, l)) =
    match aux with
    | P.TypQ_no_forall -> (TypQ_aux (TypQ_no_forall, l), ctx)
    | P.TypQ_tq quants ->
        let quants, ctx =
          List.fold_left
            (fun (qis, ctx) qi ->
              let qis', ctx = to_ast_quant_items kenv ctx qi in
              (qis' @ qis, ctx)
            )
            ([], ctx) quants
        in
        (TypQ_aux (TypQ_tq (List.rev quants), l), ctx)

  let to_ast_tannot_opt kenv ctx (P.Typ_annot_opt_aux (tp, l)) : tannot_opt ctx_out =
    match tp with
    | P.Typ_annot_opt_none -> (Typ_annot_opt_aux (Typ_annot_opt_none, l), ctx)
    | P.Typ_annot_opt_some (tq, typ) ->
        let tq, ctx = to_ast_typquant kenv ctx tq in
        (Typ_annot_opt_aux (Typ_annot_opt_some (tq, to_ast_typ kenv ctx typ), l), ctx)

  let rec to_ast_type_union kenv doc attrs vis ctx = function
    | P.Tu_aux (P.Tu_private tu, l) -> begin
        match vis with
        | Some _ -> raise (Reporting.err_general l "Union constructor has multiple visibility modifiers")
        | None -> to_ast_type_union kenv doc attrs (Some (Private l)) ctx tu
      end
    | P.Tu_aux (P.Tu_doc (doc_comment, tu), l) -> begin
        match doc with
        | Some _ -> raise (Reporting.err_general l "Union constructor has multiple documentation comments")
        | None -> to_ast_type_union kenv (Some doc_comment) attrs vis ctx tu
      end
    | P.Tu_aux (P.Tu_attribute (attr, arg, tu), l) -> to_ast_type_union kenv doc (attrs @ [(l, attr, arg)]) vis ctx tu
    | P.Tu_aux (P.Tu_ty_id (atyp, id), l) ->
        let typ = to_ast_typ kenv ctx atyp in
        Tu_aux (Tu_ty_id (typ, to_ast_id ctx id), mk_def_annot ?doc ~attrs ?visibility:vis l ())
    | P.Tu_aux (_, l) ->
        raise (Reporting.err_unreachable l __POS__ "Anonymous record type should have been rewritten by now")
end

let to_ast_typ ctx (P.ATyp_aux (_, l) as atyp) =
  let open KindInference in
  let atyp, kenv = check ctx atyp (Kind (P.K_type, l)) initial_env in
  ConvertType.to_ast_typ kenv ctx atyp

let to_ast_typ_arg kind ctx (P.ATyp_aux (_, l) as atyp) =
  let open KindInference in
  let atyp, kenv = check ctx atyp (Kind (to_parse_kind (Some kind), l)) initial_env in
  ConvertType.to_ast_typ_arg kenv ctx atyp kind

let to_ast_constraint = ConvertType.to_ast_constraint KindInference.initial_env

let to_ast_order = ConvertType.to_ast_order

let to_ast_nexp = ConvertType.to_ast_nexp KindInference.initial_env

let to_ast_bitfield_index_nexp = ConvertType.to_ast_bitfield_index_nexp

let to_ast_kopts = ConvertType.to_ast_kopts KindInference.initial_env

let to_ast_typquant = ConvertType.to_ast_typquant KindInference.initial_env

let to_ast_type_union = ConvertType.to_ast_type_union KindInference.initial_env

let to_ast_bind ctx typq atyp kind_opt =
  let open KindInference in
  let (typq, atyp, kind), kenv = check_bind ctx typq atyp kind_opt initial_env in
  let inference_kinds = ConvertType.get_inference_kinds kenv typq in
  let typq, ctx = ConvertType.to_ast_typquant kenv ctx typq in
  match to_ast_kind kind with
  | None -> None
  | Some kind ->
      let typ_arg = ConvertType.to_ast_typ_arg kenv ctx atyp (unaux_kind kind) in
      Some (typq, typ_arg, kind, inference_kinds)

let to_ast_typschm ctx (P.TypSchm_aux (P.TypSchm_ts (typq, typ), l)) =
  let open KindInference in
  let (typq, typ, _), kenv = check_bind ctx typq typ (Some (P.K_aux (P.K_type, l))) initial_env in
  let typq, ctx = ConvertType.to_ast_typquant kenv ctx typq in
  let typ = ConvertType.to_ast_typ kenv ctx typ in
  (TypSchm_aux (TypSchm_ts (typq, typ), l), ctx)

let to_ast_tannot_opt = ConvertType.to_ast_tannot_opt KindInference.initial_env

let to_ast_typschm_opt ctx (P.TypSchm_opt_aux (aux, l)) : tannot_opt ctx_out =
  match aux with
  | P.TypSchm_opt_none -> (Typ_annot_opt_aux (Typ_annot_opt_none, l), ctx)
  | P.TypSchm_opt_some (P.TypSchm_aux (P.TypSchm_ts (tq, typ), l)) ->
      let open KindInference in
      let (tq, typ, _), kenv = check_bind ctx tq typ (Some (P.K_aux (P.K_type, l))) initial_env in
      let tq, ctx = ConvertType.to_ast_typquant kenv ctx tq in
      (Typ_annot_opt_aux (Typ_annot_opt_some (tq, ConvertType.to_ast_typ kenv ctx typ), l), ctx)

let to_ast_lit (P.L_aux (lit, l)) =
  L_aux
    ( ( match lit with
      | P.L_unit -> L_unit
      | P.L_zero -> L_zero
      | P.L_one -> L_one
      | P.L_true -> L_true
      | P.L_false -> L_false
      | P.L_undef -> L_undef
      | P.L_num i -> L_num i
      | P.L_hex h -> L_hex h
      | P.L_bin b -> L_bin b
      | P.L_real r -> L_real r
      | P.L_string s -> L_string s
      ),
      l
    )

let rec to_ast_typ_pat ctx (P.ATyp_aux (aux, l)) =
  match aux with
  | P.ATyp_wild -> TP_aux (TP_wild, l)
  | P.ATyp_var kid -> TP_aux (TP_var (to_ast_var kid), l)
  | P.ATyp_app (P.Id_aux (P.Id "int", il), typs) ->
      TP_aux (TP_app (Id_aux (Id "atom", il), List.map (to_ast_typ_pat ctx) typs), l)
  | P.ATyp_app (P.Id_aux (P.Id "bool", il), typs) ->
      TP_aux (TP_app (Id_aux (Id "atom_bool", il), List.map (to_ast_typ_pat ctx) typs), l)
  | P.ATyp_app (f, typs) -> TP_aux (TP_app (to_ast_id ctx f, List.map (to_ast_typ_pat ctx) typs), l)
  | P.ATyp_parens atyp -> to_ast_typ_pat ctx atyp
  | _ -> raise (Reporting.err_typ l "Unexpected type in type pattern")

let is_wild_fpat = function P.FP_aux (P.FP_wild, _) -> true | _ -> false

let check_duplicate_fields ~error ~field_id fields =
  List.fold_left
    (fun seen field ->
      let id = field_id field in
      match IdSet.find_opt id seen with
      | Some seen_id ->
          raise
            (Reporting.err_general (Hint ("Previous field here", id_loc seen_id, id_loc id)) (error (string_of_id id)))
      | None -> IdSet.add id seen
    )
    IdSet.empty fields
  |> ignore

let rec to_ast_pat ctx (P.P_aux (aux, l)) =
  match aux with
  | P.P_attribute (attr, arg, pat) ->
      let (P_aux (aux, (pat_l, annot))) = to_ast_pat ctx pat in
      (* The location of an E_attribute node is just the attribute by itself *)
      let annot = add_attribute l attr arg annot in
      P_aux (aux, (pat_l, annot))
  | _ ->
      let aux =
        match aux with
        | P.P_attribute _ -> assert false
        | P.P_lit lit -> P_lit (to_ast_lit lit)
        | P.P_wild -> P_wild
        | P.P_var (pat, P.ATyp_aux (P.ATyp_id id, _)) -> P_as (to_ast_pat ctx pat, to_ast_id ctx id)
        | P.P_typ (typ, pat) -> P_typ (to_ast_typ ctx typ, to_ast_pat ctx pat)
        | P.P_id id -> P_id (to_ast_id ctx id)
        | P.P_var (pat, typ) -> P_var (to_ast_pat ctx pat, to_ast_typ_pat ctx typ)
        | P.P_app (id, []) -> P_id (to_ast_id ctx id)
        | P.P_app (id, pats) ->
            if List.length pats == 1 && string_of_parse_id id = "~" then P_not (to_ast_pat ctx (List.hd pats))
            else P_app (to_ast_id ctx id, List.map (to_ast_pat ctx) pats)
        | P.P_vector pats -> P_vector (List.map (to_ast_pat ctx) pats)
        | P.P_vector_concat pats -> P_vector_concat (List.map (to_ast_pat ctx) pats)
        | P.P_vector_subrange (id, n, m) -> P_vector_subrange (to_ast_id ctx id, n, m)
        | P.P_tuple pats -> P_tuple (List.map (to_ast_pat ctx) pats)
        | P.P_list pats -> P_list (List.map (to_ast_pat ctx) pats)
        | P.P_cons (pat1, pat2) -> P_cons (to_ast_pat ctx pat1, to_ast_pat ctx pat2)
        | P.P_string_append pats -> P_string_append (List.map (to_ast_pat ctx) pats)
        | P.P_struct fpats ->
            let wild_fpats, fpats = List.partition is_wild_fpat fpats in
            let field_wildcard =
              match wild_fpats with
              | FP_aux (_, l1) :: FP_aux (_, l2) :: _ ->
                  raise
                    (Reporting.err_general
                       (Parse_ast.Hint ("previous field wildcard here", l1, l2))
                       "Duplicate field wildcards in struct pattern"
                    )
              | [FP_aux (_, l)] -> FP_wild l
              | [] -> FP_no_wild
            in
            let fpats = List.map (to_ast_fpat ctx) fpats in
            check_duplicate_fields ~error:(fun f -> "Duplicate field " ^ f ^ " in struct pattern") ~field_id:fst fpats;
            P_struct (fpats, field_wildcard)
      in
      P_aux (aux, (l, empty_uannot))

and to_ast_fpat ctx (P.FP_aux (aux, l)) =
  match aux with
  | FP_field (field, pat) -> (to_ast_id ctx field, to_ast_pat ctx pat)
  | FP_wild -> Reporting.unreachable l __POS__ "Unexpected field wildcard"

let rec to_ast_letbind ctx (P.LB_aux (lb, l) : P.letbind) : uannot letbind =
  LB_aux ((match lb with P.LB_val (pat, exp) -> LB_val (to_ast_pat ctx pat, to_ast_exp ctx exp)), (l, empty_uannot))

and to_ast_exp ctx exp =
  let (P.E_aux (exp, l)) = parse_infix_exp ctx exp in
  match exp with
  | P.E_attribute (attr, arg, exp) ->
      let (E_aux (exp, (exp_l, annot))) = to_ast_exp ctx exp in
      (* The location of an E_attribute node is just the attribute itself *)
      let annot = add_attribute l attr arg annot in
      E_aux (exp, (exp_l, annot))
  | _ ->
      let aux =
        match exp with
        | P.E_attribute _ | P.E_infix _ -> assert false
        | P.E_block exps -> (
            match to_ast_fexps false ctx exps with
            | Some fexps -> E_struct fexps
            | None -> E_block (List.map (to_ast_exp ctx) exps)
          )
        | P.E_id id ->
            (* We support identifiers the same as __LOC__, __FILE__ and
               __LINE__ in the OCaml standard library, and similar
               constructs in C *)
            let id_str = string_of_parse_id id in
            if id_str = "__LOC__" then E_lit (L_aux (L_string (Reporting.short_loc_to_string l), l))
            else if id_str = "__FILE__" then (
              let file = match Reporting.simp_loc l with Some (p, _) -> p.pos_fname | None -> "unknown file" in
              E_lit (L_aux (L_string file, l))
            )
            else if id_str = "__LINE__" then (
              let lnum = match Reporting.simp_loc l with Some (p, _) -> p.pos_lnum | None -> -1 in
              E_lit (L_aux (L_num (Big_int.of_int lnum), l))
            )
            else E_id (to_ast_id ctx id)
        | P.E_ref id -> E_ref (to_ast_id ctx id)
        | P.E_lit lit -> E_lit (to_ast_lit lit)
        | P.E_typ (typ, exp) -> E_typ (to_ast_typ ctx typ, to_ast_exp ctx exp)
        | P.E_app (f, args) -> (
            match List.map (to_ast_exp ctx) args with
            | [] -> E_app (to_ast_id ctx f, [])
            | exps -> E_app (to_ast_id ctx f, exps)
          )
        | P.E_app_infix (left, op, right) -> E_app_infix (to_ast_exp ctx left, to_ast_id ctx op, to_ast_exp ctx right)
        | P.E_tuple exps -> E_tuple (List.map (to_ast_exp ctx) exps)
        | P.E_if (e1, e2, e3, _) -> E_if (to_ast_exp ctx e1, to_ast_exp ctx e2, to_ast_exp ctx e3)
        | P.E_for (id, e1, e2, e3, atyp, e4) ->
            E_for
              ( to_ast_id ctx id,
                to_ast_exp ctx e1,
                to_ast_exp ctx e2,
                to_ast_exp ctx e3,
                to_ast_order ctx atyp,
                to_ast_exp ctx e4
              )
        | P.E_loop (P.While, m, e1, e2) -> E_loop (While, to_ast_measure ctx m, to_ast_exp ctx e1, to_ast_exp ctx e2)
        | P.E_loop (P.Until, m, e1, e2) -> E_loop (Until, to_ast_measure ctx m, to_ast_exp ctx e1, to_ast_exp ctx e2)
        | P.E_vector exps -> E_vector (List.map (to_ast_exp ctx) exps)
        | P.E_vector_access (vexp, exp) -> E_vector_access (to_ast_exp ctx vexp, to_ast_exp ctx exp)
        | P.E_vector_subrange (vex, exp1, exp2) ->
            E_vector_subrange (to_ast_exp ctx vex, to_ast_exp ctx exp1, to_ast_exp ctx exp2)
        | P.E_vector_update (vex, exp1, exp2) ->
            E_vector_update (to_ast_exp ctx vex, to_ast_exp ctx exp1, to_ast_exp ctx exp2)
        | P.E_vector_update_subrange (vex, e1, e2, e3) ->
            E_vector_update_subrange (to_ast_exp ctx vex, to_ast_exp ctx e1, to_ast_exp ctx e2, to_ast_exp ctx e3)
        | P.E_vector_append (e1, e2) -> E_vector_append (to_ast_exp ctx e1, to_ast_exp ctx e2)
        | P.E_list exps -> E_list (List.map (to_ast_exp ctx) exps)
        | P.E_cons (e1, e2) -> E_cons (to_ast_exp ctx e1, to_ast_exp ctx e2)
        | P.E_struct fexps -> (
            match to_ast_fexps true ctx fexps with
            | Some fexps -> E_struct fexps
            | None -> raise (Reporting.err_unreachable l __POS__ "to_ast_fexps with true returned none")
          )
        | P.E_struct_update (exp, fexps) -> (
            match to_ast_fexps true ctx fexps with
            | Some fexps -> E_struct_update (to_ast_exp ctx exp, fexps)
            | _ -> raise (Reporting.err_unreachable l __POS__ "to_ast_fexps with true returned none")
          )
        | P.E_field (exp, id) -> E_field (to_ast_exp ctx exp, to_ast_id ctx id)
        | P.E_match (exp, pexps) -> E_match (to_ast_exp ctx exp, List.map (to_ast_case ctx) pexps)
        | P.E_try (exp, pexps) -> E_try (to_ast_exp ctx exp, List.map (to_ast_case ctx) pexps)
        | P.E_let (leb, exp) -> E_let (to_ast_letbind ctx leb, to_ast_exp ctx exp)
        | P.E_assign (lexp, exp) -> E_assign (to_ast_lexp ctx lexp, to_ast_exp ctx exp)
        | P.E_var (lexp, exp1, exp2) -> E_var (to_ast_lexp ctx lexp, to_ast_exp ctx exp1, to_ast_exp ctx exp2)
        | P.E_sizeof nexp -> E_sizeof (to_ast_nexp ctx nexp)
        | P.E_constraint nc -> E_constraint (to_ast_constraint ctx nc)
        | P.E_exit exp -> E_exit (to_ast_exp ctx exp)
        | P.E_throw exp -> E_throw (to_ast_exp ctx exp)
        | P.E_return exp -> E_return (to_ast_exp ctx exp)
        | P.E_assert (cond, msg) -> E_assert (to_ast_exp ctx cond, to_ast_exp ctx msg)
        | P.E_internal_plet (pat, exp1, exp2) ->
            if !opt_magic_hash then E_internal_plet (to_ast_pat ctx pat, to_ast_exp ctx exp1, to_ast_exp ctx exp2)
            else raise (Reporting.err_general l "Internal plet construct found without -dmagic_hash")
        | P.E_internal_return exp ->
            if !opt_magic_hash then E_internal_return (to_ast_exp ctx exp)
            else raise (Reporting.err_general l "Internal return construct found without -dmagic_hash")
        | P.E_internal_assume (nc, exp) ->
            if !opt_magic_hash then E_internal_assume (to_ast_constraint ctx nc, to_ast_exp ctx exp)
            else raise (Reporting.err_general l "Internal assume construct found without -dmagic_hash")
        | P.E_deref exp -> E_app (Id_aux (Id "__deref", l), [to_ast_exp ctx exp])
      in
      E_aux (aux, (l, empty_uannot))

and to_ast_measure ctx (P.Measure_aux (m, l)) : uannot internal_loop_measure =
  let m =
    match m with
    | P.Measure_none -> Measure_none
    | P.Measure_some exp ->
        if !opt_magic_hash then Measure_some (to_ast_exp ctx exp)
        else raise (Reporting.err_general l "Internal loop termination measure found without -dmagic_hash")
  in
  Measure_aux (m, l)

and to_ast_lexp ctx exp =
  let (P.E_aux (exp, l)) = parse_infix_exp ctx exp in
  let lexp =
    match exp with
    | P.E_id id -> LE_id (to_ast_id ctx id)
    | P.E_deref exp -> LE_deref (to_ast_exp ctx exp)
    | P.E_typ (typ, P.E_aux (P.E_id id, l')) -> LE_typ (to_ast_typ ctx typ, to_ast_id ctx id)
    | P.E_tuple tups ->
        let ltups = List.map (to_ast_lexp ctx) tups in
        let is_ok_in_tup (LE_aux (le, (l, _))) =
          match le with
          | LE_id _ | LE_typ _ | LE_vector _ | LE_vector_concat _ | LE_field _ | LE_vector_range _ | LE_tuple _ -> ()
          | LE_app _ | LE_deref _ ->
              raise (Reporting.err_typ l "only identifiers, fields, and vectors may be set in a tuple")
        in
        List.iter is_ok_in_tup ltups;
        LE_tuple ltups
    | P.E_app ((P.Id_aux (f, l') as f'), args) -> begin
        match f with
        | P.Id id -> (
            match List.map (to_ast_exp ctx) args with
            | [E_aux (E_lit (L_aux (L_unit, _)), _)] -> LE_app (to_ast_id ctx f', [])
            | [E_aux (E_tuple exps, _)] -> LE_app (to_ast_id ctx f', exps)
            | args -> LE_app (to_ast_id ctx f', args)
          )
        | _ -> raise (Reporting.err_typ l' "memory call on lefthand side of assignment must begin with an id")
      end
    | P.E_vector_append (exp1, exp2) -> LE_vector_concat (to_ast_lexp ctx exp1 :: to_ast_lexp_vector_concat ctx exp2)
    | P.E_vector_access (vexp, exp) -> LE_vector (to_ast_lexp ctx vexp, to_ast_exp ctx exp)
    | P.E_vector_subrange (vexp, exp1, exp2) ->
        LE_vector_range (to_ast_lexp ctx vexp, to_ast_exp ctx exp1, to_ast_exp ctx exp2)
    | P.E_field (fexp, id) -> LE_field (to_ast_lexp ctx fexp, to_ast_id ctx id)
    | _ ->
        raise
          (Reporting.err_typ l
             "Only identifiers, cast identifiers, vector accesses, vector slices, and fields can be on the lefthand \
              side of an assignment"
          )
  in
  LE_aux (lexp, (l, empty_uannot))

and to_ast_lexp_vector_concat ctx (P.E_aux (exp_aux, l) as exp) =
  match exp_aux with
  | P.E_vector_append (exp1, exp2) -> to_ast_lexp ctx exp1 :: to_ast_lexp_vector_concat ctx exp2
  | _ -> [to_ast_lexp ctx exp]

and to_ast_case ctx (P.Pat_aux (pexp_aux, l) : P.pexp) : uannot pexp =
  match pexp_aux with
  | P.Pat_attribute (attr, arg, pexp) ->
      let (Pat_aux (pexp, (pexp_l, annot))) = to_ast_case ctx pexp in
      let annot = add_attribute l attr arg annot in
      Pat_aux (pexp, (pexp_l, annot))
  | P.Pat_exp (pat, exp) -> Pat_aux (Pat_exp (to_ast_pat ctx pat, to_ast_exp ctx exp), (l, empty_uannot))
  | P.Pat_when (pat, guard, exp) ->
      Pat_aux (Pat_when (to_ast_pat ctx pat, to_ast_exp ctx guard, to_ast_exp ctx exp), (l, empty_uannot))

and to_ast_fexps (fail_on_error : bool) ctx (exps : P.exp list) : uannot fexp list option =
  match exps with
  | [] -> Some []
  | fexp :: exps -> (
      let maybe_fexp, maybe_error = to_ast_record_try ctx fexp in
      match (maybe_fexp, maybe_error) with
      | Some fexp, None -> (
          match to_ast_fexps fail_on_error ctx exps with Some fexps -> Some (fexp :: fexps) | _ -> None
        )
      | None, Some (l, msg) -> if fail_on_error then raise (Reporting.err_typ l msg) else None
      | _ -> None
    )

and to_ast_record_try ctx (P.E_aux (exp, l) : P.exp) : uannot fexp option * (l * string) option =
  match exp with
  | P.E_app_infix (left, op, r) -> (
      match (left, op) with
      | P.E_aux (P.E_id id, li), P.Id_aux (P.Id "=", leq) ->
          (Some (FE_aux (FE_fexp (to_ast_id ctx id, to_ast_exp ctx r), (l, empty_uannot))), None)
      | P.E_aux (_, li), P.Id_aux (P.Id "=", leq) ->
          (None, Some (li, "Expected an identifier to begin this field assignment"))
      | P.E_aux (P.E_id id, li), P.Id_aux (_, leq) ->
          (None, Some (leq, "Expected a field assignment to be identifier = expression"))
      | P.E_aux (_, li), P.Id_aux (_, leq) ->
          (None, Some (l, "Expected a field assignment to be identifier = expression"))
    )
  | _ -> (None, Some (l, "Expected a field assignment to be identifier = expression"))

let to_ast_default ctx (default : P.default_typing_spec) : default_spec ctx_out =
  match default with
  | P.DT_aux (P.DT_order (P.K_aux (P.K_order, _), o), l) -> (
      match o with
      | P.ATyp_aux (P.ATyp_inc, lo) ->
          let default_order = Ord_aux (Ord_inc, lo) in
          (DT_aux (DT_order default_order, l), ctx)
      | P.ATyp_aux (P.ATyp_dec, lo) ->
          let default_order = Ord_aux (Ord_dec, lo) in
          (DT_aux (DT_order default_order, l), ctx)
      | _ -> raise (Reporting.err_typ l "default Order must be inc or dec")
    )
  | P.DT_aux (_, l) -> raise (Reporting.err_typ l "default must specify Order")

let to_ast_extern (ext : P.extern) : extern = { pure = ext.pure; bindings = ext.bindings }

let to_ast_spec ctx (P.VS_aux (P.VS_val_spec (ts, id, ext), l)) =
  let typschm, ts_ctx = to_ast_typschm ctx ts in
  let id = to_ast_id ctx id in
  let ext = Option.map to_ast_extern ext in
  let ctx = { ctx with function_type_variables = Bindings.add id ts_ctx.kinds ctx.function_type_variables } in
  (VS_aux (VS_val_spec (typschm, id, ext), (l, empty_uannot)), ctx)

let to_ast_outcome ctx (ev : P.outcome_spec) : outcome_spec ctx_out =
  match ev with
  | P.OV_aux (P.OV_outcome (id, typschm, outcome_args), l) ->
      let outcome_args, inner_ctx =
        List.fold_left
          (fun (args, ctx) arg ->
            let (arg, _, ctx), _ = to_ast_kopts ctx arg in
            (arg @ args, ctx)
          )
          ([], ctx) outcome_args
      in
      let typschm, _ = to_ast_typschm inner_ctx typschm in
      (OV_aux (OV_outcome (to_ast_id ctx id, typschm, List.rev outcome_args), l), inner_ctx)

let rec to_ast_range ctx (P.BF_aux (r, l)) =
  (* TODO add check that ranges are sensible for some definition of sensible *)
  BF_aux
    ( ( match r with
      | P.BF_single i -> BF_single (to_ast_bitfield_index_nexp ctx i)
      | P.BF_range (i1, i2) -> BF_range (to_ast_bitfield_index_nexp ctx i1, to_ast_bitfield_index_nexp ctx i2)
      | P.BF_concat (ir1, ir2) -> BF_concat (to_ast_range ctx ir1, to_ast_range ctx ir2)
      ),
      l
    )

let add_constructor id typq kind ctx =
  let kinds = List.map (fun kopt -> to_parse_kind (Some (unaux_kind (kopt_kind kopt)))) (quant_kopts typq) in
  { ctx with type_constructors = Bindings.add id (kinds, to_parse_kind (Some kind)) ctx.type_constructors }

let anon_rec_constructor_typ record_id = function
  | P.TypQ_aux (P.TypQ_no_forall, l) -> P.ATyp_aux (P.ATyp_id record_id, Generated l)
  | P.TypQ_aux (P.TypQ_tq quants, l) -> (
      let quant_arg = function
        | P.QI_aux (P.QI_id (P.KOpt_aux (P.KOpt_kind (_, vs, _, _), l)), _) ->
            List.map (fun v -> P.ATyp_aux (P.ATyp_var v, Generated l)) vs
        | P.QI_aux (P.QI_constraint _, _) -> []
      in
      match List.concat (List.map quant_arg quants) with
      | [] -> P.ATyp_aux (P.ATyp_id record_id, Generated l)
      | args -> P.ATyp_aux (P.ATyp_app (record_id, args), Generated l)
    )

(* Strip attributes and doc comment from a type union *)
let rec type_union_strip = function
  | P.Tu_aux (P.Tu_private tu, l) ->
      let unstrip, tu = type_union_strip tu in
      ((fun tu -> P.Tu_aux (P.Tu_private (unstrip tu), l)), tu)
  | P.Tu_aux (P.Tu_attribute (attr, arg, tu), l) ->
      let unstrip, tu = type_union_strip tu in
      ((fun tu -> P.Tu_aux (P.Tu_attribute (attr, arg, unstrip tu), l)), tu)
  | P.Tu_aux (P.Tu_doc (doc, tu), l) ->
      let unstrip, tu = type_union_strip tu in
      ((fun tu -> P.Tu_aux (P.Tu_doc (doc, unstrip tu), l)), tu)
  | tu -> ((fun tu -> tu), tu)

let realize_union_anon_rec_arm union_id typq (P.Tu_aux (_, l) as tu) =
  match type_union_strip tu with
  | unstrip, (P.Tu_aux (P.Tu_ty_id _, _) as arm) -> (None, unstrip arm)
  | unstrip, P.Tu_aux (P.Tu_ty_anon_rec (fields, id), l) ->
      let open Parse_ast in
      let record_str = "_" ^ string_of_parse_id union_id ^ "_" ^ string_of_parse_id id ^ "_record" in
      let record_id = Id_aux (Id record_str, Generated l) in
      let new_arm = Tu_aux (Tu_ty_id (anon_rec_constructor_typ record_id typq, id), Generated l) in
      (Some (record_id, fields, l), unstrip new_arm)
  | _, _ -> Reporting.unreachable l __POS__ "Impossible base type union case"

let rec realize_union_anon_rec_types orig_union arms =
  match orig_union with
  | P.TD_variant (union_id, typq, _) -> begin
      match arms with
      | [] -> []
      | arm :: arms ->
          let realized =
            match realize_union_anon_rec_arm union_id typq arm with
            | Some (record_id, fields, l), new_arm ->
                (Some (P.TD_aux (P.TD_record (record_id, typq, fields), Generated l)), new_arm)
            | None, arm -> (None, arm)
          in
          realized :: realize_union_anon_rec_types orig_union arms
    end
  | _ ->
      raise
        (Reporting.err_unreachable Parse_ast.Unknown __POS__
           "Non union type-definition passed to realise_union_anon_rec_typs"
        )

let generate_enum_functions l ctx enum_id fns exps =
  let get_exp i = function
    | Some (P.E_aux (P.E_tuple exps, _)) -> List.nth exps i
    | Some exp -> exp
    | None -> Reporting.unreachable l __POS__ "get_exp called without expression"
  in
  let num_exps = function Some (P.E_aux (P.E_tuple exps, _)) -> List.length exps | Some _ -> 1 | None -> 0 in
  let num_fns = List.length fns in
  List.iter
    (fun (id, exp) ->
      let n = num_exps exp in
      if n <> num_fns then (
        let l = match exp with Some (P.E_aux (_, l)) -> l | None -> parse_id_loc id in
        raise
          (Reporting.err_general l
             (sprintf
                "Each enumeration clause for %s must define exactly %d expressions for the functions %s\n\
                 %s expressions have been given here" (string_of_id enum_id) num_fns
                (string_of_list ", " string_of_parse_id (List.map fst fns))
                (if n = 0 then "No" else if n > num_fns then "Too many" else "Too few")
             )
          )
      )
    )
    exps;
  List.mapi
    (fun i (id, typ) ->
      let typ = to_ast_typ ctx typ in
      let name = mk_id (string_of_id enum_id ^ "_" ^ string_of_parse_id id) in
      [
        mk_fundef
          [
            mk_funcl name
              (mk_pat (P_id (mk_id "arg#")))
              (mk_exp
                 (E_match
                    ( mk_exp (E_id (mk_id "arg#")),
                      List.map
                        (fun (id, exps) ->
                          let id = to_ast_id ctx id in
                          let exp = to_ast_exp ctx (get_exp i exps) in
                          mk_pexp (Pat_exp (mk_pat (P_id id), exp))
                        )
                        exps
                    )
                 )
              );
          ];
        mk_val_spec (VS_val_spec (mk_typschm (mk_typquant []) (function_typ [mk_id_typ enum_id] typ), name, None));
      ]
    )
    fns
  |> List.concat

(* When desugaring a type definition, we check that the type does not have a reserved name *)
let to_ast_reserved_type_id ctx id =
  let id = to_ast_id ctx id in
  if IdSet.mem id reserved_type_ids then begin
    match Reporting.loc_file (id_loc id) with
    | Some file when !opt_magic_hash || StringSet.mem file ctx.internal_files -> id
    | None -> id
    | Some file -> raise (Reporting.err_general (id_loc id) (sprintf "The type name %s is reserved" (string_of_id id)))
  end
  else id

let to_ast_record ctx id typq fields =
  let id = to_ast_reserved_type_id ctx id in
  let infer typq fields =
    let open KindInference in
    let* typq = infer_typquant ctx typq in
    let* fields =
      mapM
        (fun ((P.ATyp_aux (_, l) as atyp), id) ->
          let* atyp = check ctx atyp (Kind (P.K_type, l)) in
          return (atyp, id)
        )
        fields
    in
    return (typq, fields)
  in
  let (typq, fields), kenv = infer typq fields KindInference.initial_env in
  let typq, typq_ctx = ConvertType.to_ast_typquant kenv ctx typq in
  let fields = List.map (fun (atyp, id) -> (ConvertType.to_ast_typ kenv typq_ctx atyp, to_ast_id ctx id)) fields in
  (id, typq, fields, add_constructor id typq K_type ctx)

let rec to_ast_typedef ctx def_annot (P.TD_aux (aux, l) : P.type_def) : untyped_def list ctx_out =
  match aux with
  | P.TD_abbrev (id, typq, kind_opt, atyp) ->
      let id = to_ast_reserved_type_id ctx id in
      begin
        match to_ast_bind ctx typq atyp kind_opt with
        | Some (typq, typ_arg, kind, inference_kinds) ->
            ( [DEF_aux (DEF_type (TD_aux (TD_abbrev (id, typq, typ_arg), (l, empty_uannot))), def_annot)],
              {
                ctx with
                type_constructors =
                  Bindings.add id (inference_kinds, to_parse_kind (Some (unaux_kind kind))) ctx.type_constructors;
              }
            )
        | None ->
            raise
              (Reporting.err_general l
                 "Type synonyms cannot have kind Order, as ordering type parameters are deprecated"
              )
      end
  | P.TD_record (id, typq, fields) ->
      let id, typq, fields, ctx = to_ast_record ctx id typq fields in
      ([DEF_aux (DEF_type (TD_aux (TD_record (id, typq, fields, false), (l, empty_uannot))), def_annot)], ctx)
  | P.TD_variant (id, typq, arms) as union ->
      let (typq, arms), kenv = KindInference.infer_union ctx typq arms KindInference.initial_env in
      (* First generate auxilliary record types for anonymous records in constructors *)
      let records_and_arms = realize_union_anon_rec_types union arms in
      let rec filter_records = function
        | [] -> []
        | Some x :: xs -> x :: filter_records xs
        | None :: xs -> filter_records xs
      in
      let generated_records = filter_records (List.map fst records_and_arms) in
      let generated_records, ctx =
        List.fold_left
          (fun (prev, ctx) td ->
            let td, ctx = to_ast_typedef ctx (mk_def_annot (gen_loc l) ()) td in
            (prev @ td, ctx)
          )
          ([], ctx) generated_records
      in
      let arms = List.map snd records_and_arms in
      (* Now generate the AST union type *)
      let id = to_ast_reserved_type_id ctx id in
      let typq, typq_ctx = ConvertType.to_ast_typquant kenv ctx typq in
      let arms =
        List.map (ConvertType.to_ast_type_union kenv None [] None (add_constructor id typq K_type typq_ctx)) arms
      in
      ( [DEF_aux (DEF_type (TD_aux (TD_variant (id, typq, arms, false), (l, empty_uannot))), def_annot)]
        @ generated_records,
        add_constructor id typq K_type ctx
      )
  | P.TD_enum (id, fns, enums) ->
      let id = to_ast_reserved_type_id ctx id in
      let ctx = { ctx with type_constructors = Bindings.add id ([], P.K_type) ctx.type_constructors } in
      let fns = generate_enum_functions l ctx id fns enums in
      let enums = List.map (fun e -> to_ast_id ctx (fst e)) enums in
      ( fns @ [DEF_aux (DEF_type (TD_aux (TD_enum (id, enums, false), (l, empty_uannot))), def_annot)],
        { ctx with type_constructors = Bindings.add id ([], P.K_type) ctx.type_constructors }
      )
  | P.TD_abstract (id, kind) ->
      if not !opt_abstract_types then raise (Reporting.err_general l abstract_type_error);
      let id = to_ast_reserved_type_id ctx id in
      begin
        match to_ast_kind kind with
        | Some kind ->
            ( [DEF_aux (DEF_type (TD_aux (TD_abstract (id, kind), (l, empty_uannot))), def_annot)],
              {
                ctx with
                type_constructors = Bindings.add id ([], to_parse_kind (Some (unaux_kind kind))) ctx.type_constructors;
              }
            )
        | None -> raise (Reporting.err_general l "Abstract type cannot have Order kind")
      end
  | P.TD_bitfield (id, typ, ranges) ->
      let id = to_ast_reserved_type_id ctx id in
      let typ = to_ast_typ ctx typ in
      let ranges = List.map (fun (id, range) -> (to_ast_id ctx id, to_ast_range ctx range)) ranges in
      ( [DEF_aux (DEF_type (TD_aux (TD_bitfield (id, typ, ranges), (l, empty_uannot))), def_annot)],
        { ctx with type_constructors = Bindings.add id ([], P.K_type) ctx.type_constructors }
      )

let to_ast_rec ctx (P.Rec_aux (r, l) : P.rec_opt) : uannot rec_opt =
  Rec_aux
    ( ( match r with
      | P.Rec_none -> Rec_nonrec
      | P.Rec_measure (p, e) -> Rec_measure (to_ast_pat ctx p, to_ast_exp ctx e)
      ),
      l
    )

let use_function_type_variables id ctx =
  match Bindings.find_opt id ctx.function_type_variables with
  | None -> ctx
  | Some vars ->
      let merge_var v on_function from_valspec =
        match (on_function, from_valspec) with
        | None, None -> None
        | None, Some k -> Some k
        | Some k, None -> Some k
        | Some (k, l), Some (k', l') -> begin
            match (k, k') with
            | K_int, K_int -> Some (k, l)
            | K_bool, K_bool -> Some (k, l)
            | K_type, K_type -> Some (k, l)
            | _, _ ->
                let v = string_of_kid v in
                raise
                  (Reporting.err_typ
                     (Hint (sprintf "%s defined with kind %s here" v (string_of_kind_aux k'), l', l))
                     (sprintf
                        "%s defined here with kind %s in the function body, which is inconsistent with the function \
                         header"
                        v (string_of_kind_aux k)
                     )
                  )
          end
      in
      { ctx with kinds = KBindings.merge merge_var ctx.kinds vars }

let rec to_ast_funcl doc attrs ctx (P.FCL_aux (fcl, l) : P.funcl) : uannot funcl =
  match fcl with
  | P.FCL_private fcl -> raise (Reporting.err_general l "private visibility modifier on function clause")
  | P.FCL_attribute (attr, arg, fcl) -> to_ast_funcl doc (attrs @ [(l, attr, arg)]) ctx fcl
  | P.FCL_doc (doc_comment, fcl) -> begin
      match doc with
      | Some _ -> raise (Reporting.err_general l "Function clause has multiple documentation comments")
      | None -> to_ast_funcl (Some doc_comment) attrs ctx fcl
    end
  | P.FCL_funcl (id, pexp) ->
      let id = to_ast_id ctx id in
      let ctx = use_function_type_variables id ctx in
      FCL_aux (FCL_funcl (id, to_ast_case ctx pexp), (mk_def_annot ?doc ~attrs l (), empty_uannot))

let to_ast_impl_funcls ctx (P.FCL_aux (fcl, l) : P.funcl) : uannot funcl list =
  match fcl with
  | P.FCL_funcl (id, pexp) -> (
      match StringMap.find_opt (string_of_parse_id id) ctx.target_sets with
      | Some targets ->
          List.map
            (fun target ->
              FCL_aux
                ( FCL_funcl (Id_aux (Id target, parse_id_loc id), to_ast_case ctx pexp),
                  (mk_def_annot l (), empty_uannot)
                )
            )
            targets
      | None -> [FCL_aux (FCL_funcl (to_ast_id ctx id, to_ast_case ctx pexp), (mk_def_annot l (), empty_uannot))]
    )
  | _ -> raise (Reporting.err_general l "Attributes or documentation comment not permitted here")

let to_ast_fundef ctx fdef =
  let P.FD_aux (P.FD_function (rec_opt, tannot_opt, funcls), l), kenv =
    KindInference.infer_fundef ctx fdef KindInference.initial_env
  in
  let tannot_opt, ctx = ConvertType.to_ast_tannot_opt kenv ctx tannot_opt in
  FD_aux
    (FD_function (to_ast_rec ctx rec_opt, tannot_opt, List.map (to_ast_funcl None [] ctx) funcls), (l, empty_uannot))

let rec to_ast_mpat ctx (P.MP_aux (mpat, l)) =
  MP_aux
    ( ( match mpat with
      | P.MP_lit lit -> MP_lit (to_ast_lit lit)
      | P.MP_id id -> MP_id (to_ast_id ctx id)
      | P.MP_as (mpat, id) -> MP_as (to_ast_mpat ctx mpat, to_ast_id ctx id)
      | P.MP_app (id, mpats) ->
          if mpats = [] then MP_id (to_ast_id ctx id) else MP_app (to_ast_id ctx id, List.map (to_ast_mpat ctx) mpats)
      | P.MP_vector mpats -> MP_vector (List.map (to_ast_mpat ctx) mpats)
      | P.MP_vector_concat mpats -> MP_vector_concat (List.map (to_ast_mpat ctx) mpats)
      | P.MP_vector_subrange (id, n, m) -> MP_vector_subrange (to_ast_id ctx id, n, m)
      | P.MP_tuple mpats -> MP_tuple (List.map (to_ast_mpat ctx) mpats)
      | P.MP_list mpats -> MP_list (List.map (to_ast_mpat ctx) mpats)
      | P.MP_cons (pat1, pat2) -> MP_cons (to_ast_mpat ctx pat1, to_ast_mpat ctx pat2)
      | P.MP_string_append pats -> MP_string_append (List.map (to_ast_mpat ctx) pats)
      | P.MP_typ (mpat, typ) -> MP_typ (to_ast_mpat ctx mpat, to_ast_typ ctx typ)
      | P.MP_struct fmpats ->
          MP_struct (List.map (fun (field, mpat) -> (to_ast_id ctx field, to_ast_mpat ctx mpat)) fmpats)
      ),
      (l, empty_uannot)
    )

let to_ast_mpexp ctx (P.MPat_aux (mpexp, l)) =
  match mpexp with
  | P.MPat_pat mpat -> MPat_aux (MPat_pat (to_ast_mpat ctx mpat), (l, empty_uannot))
  | P.MPat_when (mpat, exp) -> MPat_aux (MPat_when (to_ast_mpat ctx mpat, to_ast_exp ctx exp), (l, empty_uannot))

let pexp_of_mpexp (MPat_aux (aux, annot)) exp =
  match aux with
  | MPat_pat mpat -> Pat_aux (Pat_exp (pat_of_mpat mpat, exp), annot)
  | MPat_when (mpat, guard) -> Pat_aux (Pat_when (pat_of_mpat mpat, guard, exp), annot)

let rec to_ast_mapcl doc attrs ctx (P.MCL_aux (mapcl, l)) =
  match mapcl with
  | P.MCL_attribute (attr, arg, mcl) -> to_ast_mapcl doc (attrs @ [(l, attr, arg)]) ctx mcl
  | P.MCL_doc (doc_comment, mcl) -> begin
      match doc with
      | Some _ -> raise (Reporting.err_general l "Function clause has multiple documentation comments")
      | None -> to_ast_mapcl (Some doc_comment) attrs ctx mcl
    end
  | P.MCL_bidir (mpexp1, mpexp2) ->
      MCL_aux
        (MCL_bidir (to_ast_mpexp ctx mpexp1, to_ast_mpexp ctx mpexp2), (mk_def_annot ?doc ~attrs l (), empty_uannot))
  | P.MCL_forwards_deprecated (mpexp, exp) ->
      let mpexp = to_ast_mpexp ctx mpexp in
      let exp = to_ast_exp ctx exp in
      MCL_aux (MCL_forwards (pexp_of_mpexp mpexp exp), (mk_def_annot ?doc ~attrs l (), empty_uannot))
  | P.MCL_forwards pexp -> MCL_aux (MCL_forwards (to_ast_case ctx pexp), (mk_def_annot ?doc ~attrs l (), empty_uannot))
  | P.MCL_backwards pexp -> MCL_aux (MCL_backwards (to_ast_case ctx pexp), (mk_def_annot ?doc ~attrs l (), empty_uannot))

let to_ast_mapdef ctx (P.MD_aux (md, l) : P.mapdef) : uannot mapdef =
  match md with
  | P.MD_mapping (id, typschm_opt, mapcls) ->
      let tannot_opt, ctx = to_ast_typschm_opt ctx typschm_opt in
      MD_aux (MD_mapping (to_ast_id ctx id, tannot_opt, List.map (to_ast_mapcl None [] ctx) mapcls), (l, empty_uannot))

let to_ast_dec ctx (P.DEC_aux (regdec, l)) =
  DEC_aux
    ( ( match regdec with
      | P.DEC_reg (typ, id, opt_exp) ->
          let opt_exp = match opt_exp with None -> None | Some exp -> Some (to_ast_exp ctx exp) in
          DEC_reg (to_ast_typ ctx typ, to_ast_id ctx id, opt_exp)
      ),
      (l, empty_uannot)
    )

let to_ast_scattered ctx (P.SD_aux (aux, l)) =
  let extra_def, aux, ctx =
    match aux with
    | P.SD_function (id, tannot_opt) ->
        let id = to_ast_id ctx id in
        let tannot_opt, _ = to_ast_tannot_opt ctx tannot_opt in
        (None, SD_function (id, tannot_opt), ctx)
    | P.SD_funcl funcl -> (None, SD_funcl (to_ast_funcl None [] ctx funcl), ctx)
    | P.SD_variant (id, parse_typq) ->
        let id = to_ast_id ctx id in
        let typq, typq_ctx = to_ast_typquant ctx parse_typq in
        ( None,
          SD_variant (id, typq),
          add_constructor id typq K_type { ctx with scattereds = Bindings.add id (parse_typq, typq_ctx) ctx.scattereds }
        )
    | P.SD_unioncl (union_id, tu) ->
        let id = to_ast_id ctx union_id in
        begin
          match Bindings.find_opt id ctx.scattereds with
          | Some (typq, scattered_ctx) ->
              let anon_rec_opt, tu = realize_union_anon_rec_arm union_id typq tu in
              let extra_def, scattered_ctx =
                match anon_rec_opt with
                | Some (record_id, fields, l) ->
                    let l = gen_loc l in
                    let record_id, typq, fields, scattered_ctx = to_ast_record scattered_ctx record_id typq fields in
                    ( Some
                        (DEF_aux
                           ( DEF_scattered
                               (SD_aux (SD_internal_unioncl_record (id, record_id, typq, fields), (l, empty_uannot))),
                             mk_def_annot l ()
                           )
                        ),
                      scattered_ctx
                    )
                | None -> (None, scattered_ctx)
              in
              let tu = to_ast_type_union None [] None scattered_ctx tu in
              (extra_def, SD_unioncl (id, tu), ctx)
          | None -> raise (Reporting.err_typ l ("No scattered union declaration found for " ^ string_of_id id))
        end
    | P.SD_end id -> (None, SD_end (to_ast_id ctx id), ctx)
    | P.SD_mapping (id, tannot_opt) ->
        let id = to_ast_id ctx id in
        let tannot_opt, _ = to_ast_tannot_opt ctx tannot_opt in
        (None, SD_mapping (id, tannot_opt), ctx)
    | P.SD_mapcl (id, mapcl) ->
        let id = to_ast_id ctx id in
        let mapcl = to_ast_mapcl None [] ctx mapcl in
        (None, SD_mapcl (id, mapcl), ctx)
    | P.SD_enum id ->
        let id = to_ast_id ctx id in
        (None, SD_enum id, ctx)
    | P.SD_enumcl (id, member) ->
        let id = to_ast_id ctx id in
        let member = to_ast_id ctx member in
        (None, SD_enumcl (id, member), ctx)
  in
  (extra_def, SD_aux (aux, (l, empty_uannot)), ctx)

let to_ast_prec = function P.Infix -> Infix | P.InfixL -> InfixL | P.InfixR -> InfixR

let to_ast_subst ctx = function
  | P.IS_aux (P.IS_id (id_from, id_to), l) -> IS_aux (IS_id (to_ast_id ctx id_from, to_ast_id ctx id_to), l)
  | P.IS_aux (P.IS_typ (kid, typ), l) -> IS_aux (IS_typ (to_ast_var kid, to_ast_typ ctx typ), l)

(* To avoid awkward dependencies, loop measures don't have any annotations except locations. *)
let to_ast_loop_measure ctx = function
  | P.Loop (P.While, exp) -> (While, map_exp_annot (fun (l, _) -> (l, ())) @@ to_ast_exp ctx exp)
  | P.Loop (P.Until, exp) -> (Until, map_exp_annot (fun (l, _) -> (l, ())) @@ to_ast_exp ctx exp)

let pragma_arg_loc pragma arg_left_trim l =
  let open Lexing in
  Reporting.map_loc_range
    (fun p1 p2 ->
      let left_trim = String.length pragma + arg_left_trim + 1 in
      let p1 = { p1 with pos_cnum = p1.pos_cnum + left_trim } in
      let p2 = { p2 with pos_cnum = p2.pos_cnum - 1; pos_bol = p1.pos_bol; pos_lnum = p1.pos_lnum } in
      (p1, p2)
    )
    l

let rec to_ast_def doc attrs vis ctx (P.DEF_aux (def, l)) : untyped_def list ctx_out =
  let annot = mk_def_annot ?doc ~attrs ?visibility:vis l () in
  match def with
  | P.DEF_private def -> begin
      match vis with
      | Some _ -> raise (Reporting.err_general l "Toplevel definition has multiple visibility modifiers")
      | None -> to_ast_def doc attrs (Some (Private l)) ctx def
    end
  | P.DEF_attribute (attr, arg, def) -> to_ast_def doc (attrs @ [(l, attr, arg)]) vis ctx def
  | P.DEF_doc (doc_comment, def) -> begin
      match doc with
      | Some _ -> raise (Reporting.err_general l "Toplevel definition has multiple documentation comments")
      | None -> to_ast_def (Some doc_comment) attrs vis ctx def
    end
  | P.DEF_overload (id, ids) -> ([DEF_aux (DEF_overload (to_ast_id ctx id, List.map (to_ast_id ctx) ids), annot)], ctx)
  | P.DEF_fixity (prec, n, op) ->
      let op = to_ast_id ctx op in
      let prec = to_ast_prec prec in
      ( [DEF_aux (DEF_fixity (prec, n, op), annot)],
        { ctx with fixities = Bindings.add op (prec, Big_int.to_int n) ctx.fixities }
      )
  | P.DEF_type t_def -> to_ast_typedef ctx annot t_def
  | P.DEF_fundef f_def ->
      let fd = to_ast_fundef ctx f_def in
      ([DEF_aux (DEF_fundef fd, annot)], ctx)
  | P.DEF_mapdef m_def ->
      let md = to_ast_mapdef ctx m_def in
      ([DEF_aux (DEF_mapdef md, annot)], ctx)
  | P.DEF_impl funcl ->
      let funcls = to_ast_impl_funcls ctx funcl in
      (List.map (fun funcl -> DEF_aux (DEF_impl funcl, annot)) funcls, ctx)
  | P.DEF_let lb ->
      let lb = to_ast_letbind ctx lb in
      ([DEF_aux (DEF_let lb, annot)], ctx)
  | P.DEF_val val_spec ->
      let vs, ctx = to_ast_spec ctx val_spec in
      ([DEF_aux (DEF_val vs, annot)], ctx)
  | P.DEF_outcome (outcome_spec, defs) ->
      let outcome_spec, inner_ctx = to_ast_outcome ctx outcome_spec in
      let defs, _ =
        List.fold_left
          (fun (defs, ctx) def ->
            let def, ctx = to_ast_def None [] None ctx def in
            (def @ defs, ctx)
          )
          ([], inner_ctx) defs
      in
      ([DEF_aux (DEF_outcome (outcome_spec, List.rev defs), annot)], ctx)
  | P.DEF_instantiation (id, substs) ->
      let id = to_ast_id ctx id in
      ( [
          DEF_aux
            (DEF_instantiation (IN_aux (IN_id id, (id_loc id, empty_uannot)), List.map (to_ast_subst ctx) substs), annot);
        ],
        ctx
      )
  | P.DEF_default typ_spec ->
      let default, ctx = to_ast_default ctx typ_spec in
      ([DEF_aux (DEF_default default, annot)], ctx)
  | P.DEF_register dec ->
      let d = to_ast_dec ctx dec in
      ([DEF_aux (DEF_register d, annot)], ctx)
  | P.DEF_constraint nc ->
      if not !opt_abstract_types then raise (Reporting.err_general l abstract_type_error);
      let nc = to_ast_constraint ctx nc in
      ([DEF_aux (DEF_constraint nc, annot)], ctx)
  | P.DEF_pragma (pragma, arg, ltrim) ->
      let l = pragma_arg_loc pragma ltrim l in
      begin
        match pragma with
        | "sail_internal" -> begin
            match Reporting.loc_file l with
            | Some file ->
                ( [DEF_aux (DEF_pragma ("sail_internal", arg, l), annot)],
                  { ctx with internal_files = StringSet.add file ctx.internal_files }
                )
            | None -> ([DEF_aux (DEF_pragma ("sail_internal", arg, l), annot)], ctx)
          end
        | "target_set" ->
            let args = String.split_on_char ' ' arg |> List.filter (fun s -> String.length s > 0) in
            begin
              match args with
              | set :: targets ->
                  ( [DEF_aux (DEF_pragma ("target_set", arg, l), annot)],
                    { ctx with target_sets = StringMap.add set targets ctx.target_sets }
                  )
              | [] -> raise (Reporting.err_general l "No arguments provided to target set directive")
            end
        | _ -> ([DEF_aux (DEF_pragma (pragma, arg, l), annot)], ctx)
      end
  | P.DEF_internal_mutrec _ ->
      (* Should never occur because of remove_mutrec *)
      raise (Reporting.err_unreachable l __POS__ "Internal mutual block found when processing scattered defs")
  | P.DEF_scattered sdef ->
      let extra_def, sdef, ctx = to_ast_scattered ctx sdef in
      ([DEF_aux (DEF_scattered sdef, annot)] @ Option.to_list extra_def, ctx)
  | P.DEF_measure (id, pat, exp) ->
      ([DEF_aux (DEF_measure (to_ast_id ctx id, to_ast_pat ctx pat, to_ast_exp ctx exp), annot)], ctx)
  | P.DEF_loop_measures (id, measures) ->
      ([DEF_aux (DEF_loop_measures (to_ast_id ctx id, List.map (to_ast_loop_measure ctx) measures), annot)], ctx)

let rec remove_mutrec = function
  | [] -> []
  | P.DEF_aux (P.DEF_internal_mutrec fundefs, _) :: defs ->
      List.map (fun (P.FD_aux (_, l) as fdef) -> P.DEF_aux (P.DEF_fundef fdef, l)) fundefs @ remove_mutrec defs
  | def :: defs -> def :: remove_mutrec defs

let to_ast ctx (P.Defs files) =
  let to_ast_defs ctx (_, defs) =
    let defs = remove_mutrec defs in
    let defs, ctx =
      List.fold_left
        (fun (defs, ctx) def ->
          let new_defs, ctx = to_ast_def None [] None ctx def in
          (new_defs @ defs, ctx)
        )
        ([], ctx) defs
    in
    (List.rev defs, ctx)
  in
  let wrap_file file defs =
    [mk_def (DEF_pragma ("file_start", file, P.Unknown)) ()]
    @ defs
    @ [mk_def (DEF_pragma ("file_end", file, P.Unknown)) ()]
  in
  let defs, ctx =
    List.fold_left
      (fun (defs, ctx) file ->
        let defs', ctx = to_ast_defs ctx file in
        (defs @ wrap_file (fst file) defs', ctx)
      )
      ([], ctx) files
  in
  ({ defs; comments = [] }, ctx)

let initial_ctx =
  {
    type_constructors =
      List.fold_left
        (fun m (k, v) -> Bindings.add (mk_id k) v m)
        Bindings.empty
        [
          ("bool", ([], P.K_type));
          ("nat", ([], P.K_type));
          ("int", ([], P.K_type));
          ("unit", ([], P.K_type));
          ("bit", ([], P.K_type));
          ("string", ([], P.K_type));
          ("string_literal", ([], P.K_type));
          ("real", ([], P.K_type));
          ("list", ([P.K_type], P.K_type));
          ("register", ([P.K_type], P.K_type));
          ("range", ([P.K_int; P.K_int], P.K_type));
          ("bitvector", ([P.K_nat; P.K_order], P.K_type));
          ("vector", ([P.K_nat; P.K_order; P.K_type], P.K_type));
          ("atom", ([P.K_int], P.K_type));
          ("atom_bool", ([P.K_bool], P.K_type));
          ("implicit", ([P.K_int], P.K_type));
          ("itself", ([P.K_int], P.K_type));
          ("not", ([P.K_bool], P.K_bool));
          ("ite", ([P.K_bool; P.K_int; P.K_int], P.K_int));
          ("abs", ([P.K_int], P.K_int));
          ("mod", ([P.K_int; P.K_int], P.K_int));
          ("div", ([P.K_int; P.K_int], P.K_int));
          ("float16", ([], P.K_type));
          ("float32", ([], P.K_type));
          ("float64", ([], P.K_type));
          ("float128", ([], P.K_type));
          ("float_rounding_mode", ([], P.K_type));
        ];
    function_type_variables = Bindings.empty;
    kinds = KBindings.empty;
    scattereds = Bindings.empty;
    fixities =
      List.fold_left
        (fun m (k, prec, level) -> Bindings.add (mk_id k) (prec, level) m)
        Bindings.empty
        [
          ("^", InfixR, 8);
          ("|", InfixR, 2);
          ("&", InfixR, 3);
          ("==", Infix, 4);
          ("!=", Infix, 4);
          ("/", InfixL, 7);
          ("%", InfixL, 7);
        ];
    internal_files = StringSet.empty;
    target_sets = StringMap.empty;
  }

let inline_lexbuf lexbuf inline =
  (* Note that OCaml >= 4.11 has a much less hacky way of doing this *)
  let open Lexing in
  match inline with
  | Some p ->
      lexbuf.lex_curr_p <- p;
      lexbuf.lex_abs_pos <- p.pos_cnum
  | None -> ()

let parse_from_string action ?inline str =
  let lexbuf = Lexing.from_string str in
  try
    inline_lexbuf lexbuf inline;
    action lexbuf
  with Parser.Error ->
    let pos = Lexing.lexeme_start_p lexbuf in
    let tok = Lexing.lexeme lexbuf in
    raise (Reporting.err_syntax pos (Printf.sprintf "Failed to parse '%s' at token '%s'" str tok))

let exp_of_string =
  parse_from_string (fun lexbuf ->
      let exp = Parser.exp_eof (Lexer.token (ref [])) lexbuf in
      to_ast_exp initial_ctx exp
  )

let typschm_of_string =
  parse_from_string (fun lexbuf ->
      let typschm = Parser.typschm_eof (Lexer.token (ref [])) lexbuf in
      let typschm, _ = to_ast_typschm initial_ctx typschm in
      typschm
  )

let typ_of_string =
  parse_from_string (fun lexbuf ->
      let typ = Parser.typ_eof (Lexer.token (ref [])) lexbuf in
      to_ast_typ initial_ctx typ
  )

let constraint_of_string =
  parse_from_string (fun lexbuf ->
      let atyp = Parser.typ_eof (Lexer.token (ref [])) lexbuf in
      to_ast_constraint initial_ctx atyp
  )

let extern_of_string ?(pure = false) id str =
  VS_val_spec (typschm_of_string str, id, Some { pure; bindings = [("_", string_of_id id)] }) |> mk_val_spec

let val_spec_of_string id str = mk_val_spec (VS_val_spec (typschm_of_string str, id, None))

let quant_item_param_typ = function
  | QI_aux (QI_id kopt, _) when is_int_kopt kopt ->
      [(prepend_id "atom_" (id_of_kid (kopt_kid kopt)), atom_typ (nvar (kopt_kid kopt)))]
  | QI_aux (QI_id kopt, _) when is_typ_kopt kopt ->
      [(prepend_id "typ_" (id_of_kid (kopt_kid kopt)), mk_typ (Typ_var (kopt_kid kopt)))]
  | _ -> []

let quant_item_param qi = List.map fst (quant_item_param_typ qi)

let quant_item_typ qi = List.map snd (quant_item_param_typ qi)

let quant_item_arg = function
  | QI_aux (QI_id kopt, _) when is_int_kopt kopt -> [mk_typ_arg (A_nexp (nvar (kopt_kid kopt)))]
  | QI_aux (QI_id kopt, _) when is_typ_kopt kopt -> [mk_typ_arg (A_typ (mk_typ (Typ_var (kopt_kid kopt))))]
  | _ -> []

let undefined_typschm id typq =
  let qis = quant_items typq in
  if qis = [] then mk_typschm typq (function_typ [unit_typ] (mk_typ (Typ_id id)))
  else (
    let arg_typs = List.concat (List.map quant_item_typ qis) in
    let ret_typ = app_typ id (List.concat (List.map quant_item_arg qis)) in
    mk_typschm typq (function_typ arg_typs ret_typ)
  )

let generate_undefined_record_context typq =
  quant_items typq |> List.map (fun qi -> quant_item_param_typ qi) |> List.concat

let generate_undefined_record id typq fields =
  let p_tup = function [pat] -> pat | pats -> mk_pat (P_tuple pats) in
  let pat =
    p_tup (quant_items typq |> List.map quant_item_param |> List.concat |> List.map (fun id -> mk_pat (P_id id)))
  in
  [
    mk_val_spec (VS_val_spec (undefined_typschm id typq, prepend_id "undefined_" id, None));
    mk_fundef
      [
        mk_funcl (prepend_id "undefined_" id) pat
          (mk_exp (E_struct (List.map (fun (_, id) -> mk_fexp id (mk_lit_exp L_undef)) fields)));
      ];
  ]

let generate_undefined_enum id ids =
  let typschm = typschm_of_string ("unit -> " ^ string_of_id id) in
  [
    mk_val_spec (VS_val_spec (typschm, prepend_id "undefined_" id, None));
    mk_fundef
      [
        mk_funcl (prepend_id "undefined_" id)
          (mk_pat (P_lit (mk_lit L_unit)))
          ( if !opt_fast_undefined && List.length ids > 0 then mk_exp (E_id (List.hd ids))
            else mk_exp (E_app (mk_id "internal_pick", [mk_exp (E_list (List.map (fun id -> mk_exp (E_id id)) ids))]))
          );
      ];
  ]

let undefined_builtin_val_specs () =
  [
    extern_of_string (mk_id "internal_pick") "forall ('a:Type). list('a) -> 'a";
    extern_of_string (mk_id "undefined_bool") "unit -> bool";
    extern_of_string (mk_id "undefined_bit") "unit -> bit";
    extern_of_string (mk_id "undefined_int") "unit -> int";
    extern_of_string (mk_id "undefined_nat") "unit -> nat";
    extern_of_string (mk_id "undefined_real") "unit -> real";
    extern_of_string (mk_id "undefined_string") "unit -> string";
    extern_of_string (mk_id "undefined_list") "forall ('a:Type). 'a -> list('a)";
    extern_of_string (mk_id "undefined_range") "forall 'n 'm. (atom('n), atom('m)) -> range('n,'m)";
    extern_of_string (mk_id "undefined_vector")
      "forall 'n ('a:Type) ('ord : Order). (atom('n), 'a) -> vector('n, 'ord,'a)";
    extern_of_string (mk_id "undefined_bitvector") "forall 'n. atom('n) -> bitvector('n)";
    extern_of_string (mk_id "undefined_unit") "unit -> unit";
  ]

let make_global (DEF_aux (def, def_annot)) =
  DEF_aux (def, add_def_attribute (gen_loc def_annot.loc) "global" None def_annot)

let generate_undefineds vs_ids =
  List.filter (fun def -> IdSet.is_empty (IdSet.inter vs_ids (ids_of_def def))) (undefined_builtin_val_specs ())

let rec get_uninitialized_registers = function
  | DEF_aux (DEF_register (DEC_aux (DEC_reg (typ, id, None), _)), _) :: defs -> begin
      match typ with
      | Typ_aux (Typ_app (Id_aux (Id "option", _), [_]), _) -> get_uninitialized_registers defs
      | _ -> (id, typ) :: get_uninitialized_registers defs
    end
  | _ :: defs -> get_uninitialized_registers defs
  | [] -> []

let generate_initialize_registers vs_ids regs =
  let initialize_registers =
    if IdSet.mem (mk_id "initialize_registers") vs_ids then []
    else if regs = [] then
      [
        val_spec_of_string (mk_id "initialize_registers") "unit -> unit";
        mk_fundef
          [mk_funcl (mk_id "initialize_registers") (mk_pat (P_lit (mk_lit L_unit))) (mk_exp (E_lit (mk_lit L_unit)))];
      ]
    else
      [
        val_spec_of_string (mk_id "initialize_registers") "unit -> unit";
        mk_fundef
          [
            mk_funcl (mk_id "initialize_registers")
              (mk_pat (P_lit (mk_lit L_unit)))
              (mk_exp
                 (E_block (List.map (fun (id, typ) -> mk_exp (E_assign (mk_lexp (LE_id id), mk_lit_exp L_undef))) regs))
              );
          ];
      ]
  in
  List.map make_global initialize_registers

let update_def_annot f (DEF_aux (def, annot)) = DEF_aux (def, f annot)

let generate_enum_number_conversions defs =
  let vs_ids = val_spec_ids defs in
  let rec gen_enums acc = function
    | (DEF_aux (DEF_type (TD_aux (TD_enum (id, elems, _), _)), def_annot) as enum) :: defs -> begin
        match get_def_attribute "no_enum_number_conversions" def_annot with
        | Some _ -> gen_enums (enum :: acc) defs
        | None ->
            let attr_opt = get_def_attribute "enum_number_conversions" def_annot in
            let names =
              let open Util.Option_monad in
              let* fields = Option.bind (Option.join (Option.map snd attr_opt)) attribute_data_object in
              let* to_enum, to_l = Option.bind (List.assoc_opt "to_enum" fields) attribute_data_string_with_loc in
              let* from_enum, from_l = Option.bind (List.assoc_opt "from_enum" fields) attribute_data_string_with_loc in
              Some (mk_id ~loc:to_l to_enum, mk_id ~loc:from_l from_enum)
            in
            let l, to_enum_name, from_enum_name =
              match (attr_opt, names) with
              | Some (l, _), None -> raise (Reporting.err_general l "Expected to_enum and from_enum fields in attribute")
              | None, Some _ -> Reporting.unreachable def_annot.loc __POS__ "Have attribute fields with no attribute!"
              | Some (l, _), Some (id1, id2) -> (gen_loc l, id1, id2)
              | None, None -> (gen_loc def_annot.loc, append_id id "_of_num", prepend_id "num_of_" id)
            in

            let enum_val_spec name quants typ =
              mk_val_spec (VS_val_spec (mk_typschm (mk_typquant quants) typ, name, None))
            in
            let range_constraint kid =
              nc_and (nc_lteq (nint 0) (nvar kid)) (nc_lteq (nvar kid) (nint (List.length elems - 1)))
            in

            let already_defined name =
              let original_id = IdSet.find name vs_ids in
              Reporting.warn
                (Printf.sprintf "Cannot generate %s for enum" (string_of_id name))
                (Hint ("Function with the same name defined here", id_loc original_id, def_annot.loc))
                (Printf.sprintf
                   "Could not generate an automatic conversion function for enum %s, as a function with the same name \
                    (%s) already exists.\n\
                    Use the $[no_enum_number_conversions] attribute to suppress the automatic generation, or rename \
                    one of the functions."
                   (string_of_id id) (string_of_id name)
                );
              []
            in

            (* Create a function that converts a number to an enum. *)
            let to_enum =
              let name = to_enum_name in
              if IdSet.mem name vs_ids then already_defined name
              else (
                let kid = mk_kid "e" in
                let pexp n id =
                  let pat =
                    if n = List.length elems - 1 then mk_pat P_wild
                    else mk_pat (P_lit (mk_lit (L_num (Big_int.of_int n))))
                  in
                  let pat = locate_pat (unknown_to l) pat in
                  mk_pexp (Pat_exp (pat, mk_exp ~loc:l (E_id id)))
                in
                let funcl =
                  mk_funcl name
                    (mk_pat (P_id (mk_id "arg#")))
                    (mk_exp (E_match (mk_exp (E_id (mk_id "arg#")), List.mapi pexp elems)))
                in
                [
                  enum_val_spec name
                    [mk_qi_id K_int kid; mk_qi_nc (range_constraint kid)]
                    (function_typ [atom_typ (nvar kid)] (mk_typ (Typ_id id)));
                  mk_fundef [funcl];
                ]
              )
            in

            (* Create a function that converts from an enum to a number. *)
            let from_enum =
              let name = from_enum_name in
              if IdSet.mem name vs_ids then already_defined name
              else (
                let kid = mk_kid "e" in
                let to_typ = mk_typ (Typ_exist ([mk_kopt K_int kid], range_constraint kid, atom_typ (nvar kid))) in
                let pexp n id = mk_pexp (Pat_exp (mk_pat (P_id id), mk_lit_exp (L_num (Big_int.of_int n)))) in
                let funcl =
                  mk_funcl name
                    (mk_pat (P_id (mk_id "arg#")))
                    (mk_exp (E_match (mk_exp (E_id (mk_id "arg#")), List.mapi pexp elems)))
                in
                [enum_val_spec name [] (function_typ [mk_typ (Typ_id id)] to_typ); mk_fundef [funcl]]
              )
            in

            let enum =
              update_def_annot (add_def_attribute (gen_loc (id_loc id)) "no_enum_number_conversions" None) enum
            in

            gen_enums (List.rev ((enum :: to_enum) @ from_enum) @ acc) defs
      end
    | def :: defs -> gen_enums (def :: acc) defs
    | [] -> List.rev acc
  in
  gen_enums [] defs

let process_ast ctx ast =
  let ast, ctx = to_ast ctx ast in
  ({ ast with defs = generate_enum_number_conversions ast.defs }, ctx)

let generate ast =
  let vs_ids = val_spec_ids ast.defs in
  let regs = get_uninitialized_registers ast.defs in
  { ast with defs = generate_undefineds vs_ids @ ast.defs @ generate_initialize_registers vs_ids regs }

let ast_of_def_string_with ?inline ocaml_pos ctx f str =
  let lexbuf = Lexing.from_string str in
  lexbuf.lex_curr_p <- { pos_fname = ""; pos_lnum = 1; pos_bol = 0; pos_cnum = 0 };
  inline_lexbuf lexbuf inline;
  let internal = !opt_magic_hash in
  opt_magic_hash := true;
  let def =
    try Parser.def_eof (Lexer.token (ref [])) lexbuf
    with Parser.Error ->
      let pos = Lexing.lexeme_start_p lexbuf in
      let tok = Lexing.lexeme lexbuf in
      raise (Reporting.err_syntax pos ("current token: " ^ tok))
  in
  let ast, ctx = Reporting.forbid_errors ocaml_pos (fun ast -> process_ast ctx ast) (P.Defs [("", f [def])]) in
  opt_magic_hash := internal;
  (ast, ctx)

let ast_of_def_string ?inline ocaml_pos ctx str = ast_of_def_string_with ?inline ocaml_pos ctx (fun x -> x) str

let defs_of_string ocaml_pos ctx str =
  let ast, ctx = ast_of_def_string ocaml_pos ctx str in
  (ast.defs, ctx)

let get_lexbuf_from_string ~filename:f ~contents:s =
  let lexbuf = Lexing.from_string s in
  lexbuf.Lexing.lex_curr_p <- { Lexing.pos_fname = f; Lexing.pos_lnum = 1; Lexing.pos_bol = 0; Lexing.pos_cnum = 0 };
  lexbuf

let get_lexbuf f =
  let handle = Sail_file.open_file f in
  get_lexbuf_from_string ~filename:f ~contents:(Sail_file.contents handle)

let parse_file ?loc:(l = Parse_ast.Unknown) (f : string) : Lexer.comment list * Parse_ast.def list =
  try
    let lexbuf = get_lexbuf f in
    begin
      try
        let comments = ref [] in
        let defs = Parser.file (Lexer.token comments) lexbuf in
        (!comments, defs)
      with Parser.Error ->
        let pos = Lexing.lexeme_start_p lexbuf in
        let tok = Lexing.lexeme lexbuf in
        raise (Reporting.err_syntax pos ("current token: " ^ tok))
    end
  with Sys_error err -> raise (Reporting.err_general l err)

let parse_file_from_string ~filename:f ~contents:s =
  let lexbuf = get_lexbuf_from_string ~filename:f ~contents:s in
  try
    let comments = ref [] in
    let defs = Parser.file (Lexer.token comments) lexbuf in
    (!comments, defs)
  with Parser.Error ->
    let pos = Lexing.lexeme_start_p lexbuf in
    let tok = Lexing.lexeme lexbuf in
    raise (Reporting.err_syntax pos ("current token: " ^ tok))

let parse_project ?inline ?filename:f ~contents:s () =
  let open Project in
  let open Lexing in
  let lexbuf = from_string s in
  if Option.is_none inline then
    lexbuf.lex_curr_p <- { pos_fname = Option.get f; pos_lnum = 1; pos_bol = 0; pos_cnum = 0 };
  inline_lexbuf lexbuf inline;

  try Project_parser.file Project_lexer.token lexbuf
  with Project_parser.Error ->
    let pos = lexeme_start_p lexbuf in
    let tok = lexeme lexbuf in
    raise (Reporting.err_syntax pos ("current token: " ^ tok))
