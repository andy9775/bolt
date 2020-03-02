open Core
open Type_data_races_expr
open Type_capability_annotations
open Type_subord_capabilities
open Type_function_borrowing
open Type_capability_constraints
open Desugaring.Desugared_ast
open Ast.Ast_types
open Data_race_checker_env

let type_capability_mode error_prefix (TCapability (mode, capability_name)) =
  match mode with
  | Linear | Read | Locked | ThreadLocal | Subordinate -> Ok ()
  | ThreadSafe | Encapsulated ->
      Error
        (Error.of_string
           (Fmt.str "%s Capability %s can't be assigned mode %s." error_prefix
              (Capability_name.to_string capability_name)
              (string_of_mode mode)))

let type_field_mode class_defns error_prefix
    (TCapability (capability_mode, capability_name))
    (TField (field_modifier, field_type, field_name, _)) =
  match (capability_mode, field_modifier, field_type) with
  (* If a capability has read mode then its fields must be const or have safe mode *)
  | Read, MVar, TEClass (field_class, _) ->
      if class_has_mode field_class ThreadSafe class_defns then Ok ()
      else
        Error
          (Error.of_string
             (Fmt.str "%s Field %s can't be in capability %s as it doesn't have mode %s@."
                error_prefix
                (Field_name.to_string field_name)
                (Capability_name.to_string capability_name)
                (string_of_mode ThreadSafe)))
  | Read, MConst, _ -> Ok ()
  | _ -> Ok ()

let type_field_defn class_defns class_name capabilities error_prefix
    (TField (_, field_type, field_name, field_capabilities) as field_defn) =
  let open Result in
  ( match field_type with
  | TEClass (_, Borrowed) ->
      Error
        (Error.of_string
           (Fmt.str "%s Field %s can't be assigned a borrowed type." error_prefix
              (Field_name.to_string field_name)))
  | _                     -> Ok () )
  >>= fun () ->
  type_field_capability_annotations class_name capabilities field_capabilities
  >>= fun field_capabilities ->
  Result.all_unit
    (List.map
       ~f:(fun capability ->
         type_field_mode class_defns error_prefix capability field_defn)
       field_capabilities)

(* check all fields in a capability have the same type *)
let type_fields_capability_types fields error_prefix (TCapability (_, cap_name)) =
  let capability_fields =
    List.filter
      ~f:(fun (TField (_, _, _, field_capabilities)) ->
        List.exists
          ~f:(fun field_capability -> field_capability = cap_name)
          field_capabilities)
      fields in
  let field_types =
    List.map ~f:(fun (TField (_, field_type, _, _)) -> field_type) capability_fields in
  match field_types with
  | []              ->
      Error
        (Error.of_string
           (Fmt.str "%s: capability %s is unused@." error_prefix
              (Capability_name.to_string cap_name)))
  | field_type :: _ ->
      if List.for_all ~f:(fun fd_type -> field_type = fd_type) field_types then Ok ()
      else
        Error
          (Error.of_string
             (Fmt.str "%scapability %s should have fields of the same type@." error_prefix
                (Capability_name.to_string cap_name)))

let type_data_races_method_defn class_name class_defns function_defns
    (TMethod (method_name, ret_type, params, capabilities_used, body_expr)) =
  let open Result in
  let param_obj_var_capabilities =
    params_to_obj_vars_and_capabilities class_defns params in
  type_params_capability_annotations class_defns params
  >>= fun () ->
  let error_prefix =
    Fmt.str "Potential data race in %s's method %s "
      (Class_name.to_string class_name)
      (Method_name.to_string method_name) in
  type_function_reverse_borrowing class_defns error_prefix ret_type body_expr
  >>= fun () ->
  type_subord_capabilities_method_prototype class_defns class_name method_name ret_type
    param_obj_var_capabilities
  >>= fun () ->
  type_param_capability_constraints
    ( (Var_name.of_string "this", class_name, capabilities_used)
    :: param_obj_var_capabilities )
    body_expr
  |> fun param_constrained_body_expr ->
  type_data_races_block_expr class_defns function_defns param_constrained_body_expr
    ( (Var_name.of_string "this", class_name, capabilities_used)
    :: param_obj_var_capabilities )
  >>| fun data_race_checked_body_expr ->
  TMethod (method_name, ret_type, params, capabilities_used, data_race_checked_body_expr)

let type_data_races_class_defn class_defns function_defns
    (TClass (class_name, capabilities, fields, method_defns)) =
  let open Result in
  (* All type error strings for a particular class have same prefix *)
  let error_prefix = Fmt.str "%s has a type error: " (Class_name.to_string class_name) in
  Result.all_unit (List.map ~f:(type_capability_mode error_prefix) capabilities)
  >>= fun () ->
  Result.all_unit
    (List.map ~f:(type_fields_capability_types fields error_prefix) capabilities)
  >>= fun () ->
  Result.all
    (List.map
       ~f:(type_field_defn class_defns class_name capabilities error_prefix)
       fields)
  >>= fun _ ->
  Result.all
    (List.map
       ~f:(type_data_races_method_defn class_name class_defns function_defns)
       method_defns)
  >>| fun data_race_checked_method_defns ->
  TClass (class_name, capabilities, fields, data_race_checked_method_defns)
