(* Copyright (C) 2015--2016  Petter A. Urkedal <paurkedal@gmail.com>
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version, with the OCaml static compilation exception.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 *)

open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience

let deriver = "random"


(* Imports from Prime *)

let ( *< ) f g x = f (g x)

module Option = struct
  let map f = function None -> None | Some x -> Some (f x)
end

module List = struct
  include List

  let rec fold f xs accu =
    match xs with
    | [] -> accu
    | x :: xs' -> fold f xs' (f x accu)

  let fmap f xs =
    let rec loop ys = function
      | [] -> ys
      | x :: xs -> loop (match f x with None -> ys | Some y -> (y :: ys)) xs in
    rev (loop [] xs)
end


(* Parse Tree and PPX Helpers *)

let raise_errorf = Ppx_deriving.raise_errorf

let parse_options = List.iter @@ fun (name, pexp) ->
  match name with
  | _ ->
    raise_errorf ~loc:pexp.pexp_loc
                 "The %s deriver takes no option %s." deriver name

let tuple_opt = function
  | [] -> None
  | [arg] -> Some arg
  | args -> Some (Exp.tuple args)

let mapped_expr e =
  Ok (Ppx_deriving.mapper.Ast_mapper.expr Ppx_deriving.mapper e)

let get_random_fun attrs =
  attrs |> Ppx_deriving.attr ~deriver "random"
        |> Ppx_deriving.Arg.(get_attr ~deriver mapped_expr)

let get_weight attrs =
  let conv x = match x with
    | {pexp_desc = Pexp_constant (Pconst_integer(n,_))} -> Ok (`Int(x,int_of_string n))
    | {pexp_desc = Pexp_function _ }
    | {pexp_desc = Pexp_fun _ } -> Ok (`Fun x)
    | _ -> Ok (`Float x)
  in
  attrs |> Ppx_deriving.attr ~deriver "weight"
        |> Ppx_deriving.Arg.(get_attr ~deriver conv)

let get_weight_float attrs rng =
  match get_weight attrs with
  | None -> [%expr 1.0]
  | Some (`Int(x,_)) -> [%expr float_of_int([%e x])]
  | Some (`Fun f)    -> [%expr ([%e f]) ([%e rng])]
  | Some (`Float x)  -> x

let weight_is_one attrs =
  match get_weight attrs with
  | None -> true
  | Some (`Int(_,n)) when n = 1 -> true
  | _ -> false

let pcd_attributes pcd = pcd.pcd_attributes

let rowfield_attributes = function
  | Rtag (_, a, _, _)
  | Rinherit {ptyp_attributes = a} -> a


(* Generator Type *)

let random_type_of_decl ~options ~path type_decl =
  parse_options options;
  let typ = Ppx_deriving.core_type_of_type_decl type_decl in
  let typ =
    match type_decl.ptype_manifest with
    | Some {ptyp_desc = Ptyp_variant (_, Closed, _)} ->
      let ptyp_desc = Ptyp_variant ([Rinherit typ], Open, None) in
      {ptyp_desc; ptyp_loc = Location.none; ptyp_attributes = []}
    | _ -> typ in
  Ppx_deriving.poly_arrow_of_type_decl
    (fun var -> [%type: PPX_Random.state -> [%t var]])
    type_decl
    [%type: PPX_Random.state -> [%t typ]]


(* Generator Function *)

let cumulative get_attrs cs rng =
  let cs = List.map (fun pcd -> get_weight_float (get_attrs pcd) rng, pcd) cs in
  let total_exp = List.fold (fun (w,_) sofar -> [%expr [%e w] +. [%e sofar]]) cs [%expr 0.0] in
  let prelude e =
    [%expr 
      let c_norm = [%e total_exp] in
      let normalize w =
        let x = int_of_float (ldexp (w /. c_norm) 30) in
        (* On 32 bit platforms, 1.0 ± ε will be mapped to min_int. *)
        if x < 0 then max_int else x in
      [%e e]
    ]
  in    
  let cs = cs |> List.map (fun (w,pcd) -> ([%expr normalize([%e w])],pcd)) in
  let aux (w,pcd) (acc, rem) =
    let e = [%expr [%e rem] - ([%e w])] in
    (e,pcd) :: acc, e
  in
  prelude, fst @@ List.fold aux cs ([], [%expr 1 lsl 30])

let invalid_case =
  Exp.case [%pat? i]
    [%expr
      failwith (Printf.sprintf "Value %d from PPX_Random.case is out of range." i)]

let rec expr_of_typ typ =
  let expr_of_rowfield = function
    | Rtag (label, _, true, []) -> Exp.variant label.Location.txt None
    | Rtag (label, _, false, typs) ->
      Exp.variant label.Location.txt
        (tuple_opt (List.map (fun typ -> [%expr [%e expr_of_typ typ]]) typs))
    | Rinherit typ -> expr_of_typ typ
    | _ ->
      raise_errorf ~loc:typ.ptyp_loc "Cannot derive %s for %s."
        deriver (Ppx_deriving.string_of_core_type typ)
  in
  match get_random_fun typ.ptyp_attributes with
  | Some f -> app f [[%expr rng]]
  | None ->
    match typ with
    | [%type: unit] -> [%expr ()]
    | {ptyp_desc = Ptyp_constr ({txt = lid}, typs)} ->
      let f =
        Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Prefix "random") lid)) in
      let args =
        List.map (fun typ -> [%expr fun rng -> [%e expr_of_typ typ]]) typs in
      app f (args @ [[%expr (PPX_Random.deepen rng)]])
    | {ptyp_desc = Ptyp_tuple typs} -> Exp.tuple (List.map expr_of_typ typs)
    | {ptyp_desc = Ptyp_variant (fields, _, _); ptyp_loc}
          when List.for_all (weight_is_one *< rowfield_attributes) fields ->
      let cases =
        fields |> List.mapi @@ fun j field ->
          let result = expr_of_rowfield field in
          Exp.case (Pat.constant (Pconst_integer(string_of_int j,None))) result in
      Exp.match_
        [%expr PPX_Random.case [%e Exp.constant (Pconst_integer(string_of_int(List.length cases),None))] rng]
        (cases @ [invalid_case])
    | {ptyp_desc = Ptyp_variant (fields, _, _); ptyp_loc} ->
      let branch (iexp, field) cont =
        [%expr if w > [%e iexp]
               then [%e expr_of_rowfield field]
               else [%e cont] ] in
      let prelude,l = cumulative rowfield_attributes fields [%expr rng] in
      begin
        match l with
        | [] -> assert false (* There's at least one constructor *)
        | (_, field) :: fields ->
          prelude (
            [%expr let w = rng |> PPX_Random.case_30b in
              [%e List.fold branch fields (expr_of_rowfield field)]])
      end
    | {ptyp_desc = Ptyp_var name} -> [%expr [%e evar ("poly_" ^ name)] rng]
    | {ptyp_desc = Ptyp_alias (typ, _)} -> expr_of_typ typ
    | {ptyp_loc} ->
      raise_errorf ~loc:ptyp_loc "Cannot derive %s for %s."
                   deriver (Ppx_deriving.string_of_core_type typ)

let expr_of_type_decl ({ptype_loc = loc} as type_decl) =
  let expr_of_constr pcd =
    match pcd.pcd_args with
    | Parsetree.Pcstr_tuple l ->
      Exp.construct {txt = Lident pcd.pcd_name.txt; loc = pcd.pcd_name.loc}
        (tuple_opt (List.map expr_of_typ l))
    | Pcstr_record _ -> raise_errorf ~loc "Cannot derive %s for fully abstract type." deriver
  in
  match type_decl.ptype_kind, type_decl.ptype_manifest with
  | Ptype_abstract, Some manifest ->
    [%expr fun rng -> [%e expr_of_typ manifest]]
  | Ptype_variant constrs, _
        when List.for_all (weight_is_one *< pcd_attributes) constrs ->
    let make_case j pcd =
      Exp.case (Pat.constant (Pconst_integer(string_of_int j,None))) (expr_of_constr pcd) in
    let cases = List.mapi make_case constrs in
    let case_count = Exp.constant (Pconst_integer(string_of_int(List.length cases),None)) in
    [%expr fun rng ->
           [%e Exp.match_ [%expr PPX_Random.case [%e case_count] rng]
                          (cases @ [invalid_case])] ]
  | Ptype_variant cs, _ ->
    let branch (iexp, pcd) cont =
      [%expr if w > [%e iexp]
             then [%e expr_of_constr pcd]
             else [%e cont] ] in
    let prelude,l = cumulative pcd_attributes cs [%expr rng] in
    begin match l with
    | [] -> assert false (* There's at least one constructor *)
    | (_, pcd) :: cs ->
      [%expr fun rng ->
        [%e prelude
            [%expr let w = rng |> PPX_Random.case_30b in
              [%e List.fold branch cs (expr_of_constr pcd)] ]]]
    end
  | Ptype_record fields, _ ->
    let fields = fields |> List.map @@ fun pld ->
      {txt = Lident pld.pld_name.txt; loc = pld.pld_name.loc},
      expr_of_typ pld.pld_type in
    [%expr fun rng -> [%e Exp.record fields None]]
  | Ptype_abstract, None ->
    raise_errorf ~loc "Cannot derive %s for fully abstract type." deriver
  | Ptype_open, _ ->
    raise_errorf ~loc "Cannot derive %s for open type." deriver


(* Signature and Structure Components *)

let sig_of_type ~options ~path type_decl =
  parse_options options;
  [Sig.value
    (Val.mk
      (mknoloc (Ppx_deriving.mangle_type_decl (`Prefix "random") type_decl))
      (random_type_of_decl ~options ~path type_decl))]

let str_of_type ~options ~path type_decl =
  parse_options options;
  let path = Ppx_deriving.path_of_type_decl ~path type_decl in
  let random_func = expr_of_type_decl type_decl in
  let random_type = random_type_of_decl ~options ~path type_decl in
  let random_var =
    pvar (Ppx_deriving.mangle_type_decl (`Prefix "random") type_decl) in
  [Vb.mk (Pat.constraint_ random_var random_type)
         (Ppx_deriving.poly_fun_of_type_decl type_decl random_func)]

let () =
  Ppx_deriving.register @@
  Ppx_deriving.create deriver
    ~core_type: (fun typ -> [%expr fun rng -> [%e expr_of_typ typ]])
    ~type_decl_str: (fun ~options ~path type_decls ->
      [Str.value Recursive
        (List.concat (List.map (str_of_type ~options ~path) type_decls))])
    ~type_decl_sig: (fun ~options ~path type_decls ->
      List.concat (List.map (sig_of_type ~options ~path) type_decls))
    ()
