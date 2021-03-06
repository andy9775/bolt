open Ast.Ast_types
open Core
open Type_env
open Parsing

let get_superclass_defn class_name superclass class_defns =
  get_class_defn superclass class_defns Lexing.dummy_pos
  |> function
  | Ok superclass_defn -> Ok superclass_defn
  | Error _            ->
      Error
        (Error.of_string
           (Fmt.str "Type error: superclass %s for class %s doesn't exist@."
              (Class_name.to_string superclass)
              (Class_name.to_string class_name)))

let type_generics_inheritance class_name curr_class_maybe_generic
    (Parsed_ast.TClass (superclass_name, superclass_maybe_generic, _, _, _, _)) =
  match (curr_class_maybe_generic, superclass_maybe_generic) with
  | None, None | Some Generic, None | Some Generic, Some Generic -> Ok ()
  | None, Some Generic ->
      Error
        (Error.of_string
           (Fmt.str
              "Type error: class %s must be generic since superclass %s is generic@."
              (Class_name.to_string class_name)
              (Class_name.to_string superclass_name)))

let get_methods_type_sigs method_defns =
  List.map
    ~f:(fun (Parsed_ast.TMethod (meth_name, _, return_type, params, _, _)) ->
      (meth_name, return_type, get_params_types params))
    method_defns

let type_method_overriding class_name class_defns method_defns superclass_defn =
  let open Result in
  get_class_methods class_defns superclass_defn None Lexing.dummy_pos
  >>= fun inherited_methods ->
  get_methods_type_sigs method_defns
  |> fun methods_type_sigs ->
  get_methods_type_sigs inherited_methods
  |> fun inherited_methods_type_sigs ->
  List.filter
    ~f:(fun (meth_name, ret_type, param_types) ->
      List.exists
        ~f:(fun (inherited_meth_name, inherited_ret_type, inherited_param_types) ->
          meth_name = inherited_meth_name
          && param_types = inherited_param_types
          && not (ret_type = inherited_ret_type))
        inherited_methods_type_sigs)
    methods_type_sigs
  |> function
  | []                     -> Ok ()
  | (meth_name, _, _) :: _ ->
      Error
        (Error.of_string
           (Fmt.str "Type error: %s overrides method %s but has a different return type@."
              (Class_name.to_string class_name)
              (Method_name.to_string meth_name)))

let type_class_inheritance
    (Parsed_ast.TClass (class_name, maybe_generic, maybe_inherits, _, _, method_defns))
    class_defns =
  let open Result in
  match maybe_inherits with
  | None            -> Ok ()
  | Some superclass ->
      get_superclass_defn class_name superclass class_defns
      >>= fun superclass_defn ->
      type_generics_inheritance class_name maybe_generic superclass_defn
      >>= fun () ->
      type_method_overriding class_name class_defns method_defns superclass_defn
