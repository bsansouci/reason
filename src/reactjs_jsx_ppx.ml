(* transform `div props1::a props2::b children::[foo, bar] () [@JSX]` into
  `ReactDOMRe.createElement "div" props::[%bs.obj {props1: 1, props2: b}] [|foo, bar|]`.
  If the function call ends with an underscore, e.g. foo_, turn it into
  `ReactRe.createElement foo_ props::[%bs.obj {props1: 1, props2: b}] [|foo, bar|]`.
  Don't transform the upper-cased case: `Foo.createElement foo::bar children::[] () [@JSX]`.
*)

(* Why do we need a transform, instead of just using the original format?
Because that one currently doesn't work well for the existing React.js *)
open Ast_mapper
open Ast_helper
open Asttypes
open Parsetree
open Longident

let rec listToArray' lst accum =
  (* not in the sense of converting a list to an array; convert the AST
    reprensentation of a list to the AST reprensentation of an array *)
  match lst with
  | {pexp_desc = Pexp_construct ({txt = Lident "[]"}, None)} -> accum
  | {
      pexp_desc = Pexp_construct (
        {txt = Lident "::"},
        Some {pexp_desc = Pexp_tuple (v::acc::[])}
      )
  } -> listToArray' acc (v::accum)
  | _ -> raise (
    Invalid_argument "JSX: the `children` prop must be a literal list (of react elements)."
  )

let listToArray lst = listToArray' lst [] |> List.rev

(* turn bla::1 blaa::2 into [%bs.obj {bla: 1, blaa: 2}] *)
let functionCallWithLabelsToBSObj ~loc callWithLabels =
  (* structure *)
  let record = callWithLabels
    |> List.map (fun (label, expression) ->
      ({loc; txt = Lident label}, expression)
    )
  in
  Exp.extension ~loc (
    {loc; txt = "bs.obj"},
    PStr [Str.eval ~loc (Exp.record ~loc record None)]
  )

let extractChildrenForDOMElements ?(removeLastPositionUnit=false) ~loc propsAndChildren =
  let rec allButLast_ lst acc = match lst with
    | [] -> []
    | ("", {pexp_desc = Pexp_construct ({txt = Lident "()"}, None)})::[] -> acc
    | ("", _)::rest -> raise (Invalid_argument "JSX: found non-labelled argument before the last position")
    | arg::rest -> allButLast_ rest (arg::acc)
  in
  let allButLast lst = allButLast_ lst [] |> List.rev in
  match (List.partition (fun (label, expr) -> label = "children") propsAndChildren) with
  | ((label, childrenExpr)::[], props) ->
    (childrenExpr, if removeLastPositionUnit then allButLast props else props)
  | ([], props) ->
    (* no children provided? Place a placeholder list (don't forgot we're talking about DOM element conversion here only) *)
    (Exp.construct ~loc {loc; txt = Lident "[]"} None, if removeLastPositionUnit then allButLast props else props)
  | (moreThanOneChild, props) -> raise (Invalid_argument "JSX: somehow there's more than one `children` label")

(* TODO: some line number might still be wrong *)
let jsxMapper argv = {
  default_mapper with
  expr = (fun mapper expression -> match expression with
    (* spotted a function application! Does it have the @JSX attribute? *)
    | {
        pexp_desc = Pexp_apply ({pexp_desc = createElementWrap} as wrap, propsAndChildren);
        pexp_attributes
      } when Syntax_util.attribute_exists "JSX" pexp_attributes ->
        (match createElementWrap with
        | Pexp_ident caller ->
          (match caller with
          | {txt = Lident "createElement"} ->
            raise (Invalid_argument "JSX: `createElement` should be preceeded by a module name.")
          (* Foo.createElement prop1::foo prop2:bar children::[] () *)
          (* no change *)
          | {loc; txt = Ldot (moduleNames, "createElement")} ->
            let attrs = pexp_attributes |> List.filter (fun (attribute, _) -> attribute.txt <> "JSX") in
            Exp.apply
              ~loc
              ~attrs
              wrap
              (
                propsAndChildren |> List.map (fun (label, expr) -> (label, mapper.expr mapper expr))
              )
          | {loc; txt = Lident lowercaseIdentifier} ->
            let isComposite = (String.get lowercaseIdentifier (String.length lowercaseIdentifier - 1)) = '_' in
            if isComposite then
              (* foo_ prop1::foo prop2:bar children::[bla] () *)
              (* turn that into ReactRe.createElement foo_ props::[%bs.obj {prop1: foo, prop2: bar}] [|bla|] *)
              let (children, propsWithLabels) =
                extractChildrenForDOMElements ~removeLastPositionUnit:true ~loc propsAndChildren
              in
              let componentNameExpr = Exp.ident ~loc {loc; txt = Lident lowercaseIdentifier} in
              let childrenExpr = Exp.array (
                listToArray children |> List.map (fun a -> mapper.expr mapper a)
              )
              in
              let args = match propsWithLabels with
              | [] ->
                (* no prop (beside the unit, which got removed) *)
                [
                  (* fooComponentEscapeHatch_ *)
                  ("", componentNameExpr);
                  (* [|moreCreateElementCallsHere|] *)
                  ("", childrenExpr)
                ]
              | props ->
                [
                  (* fooComponentEscapeHatch_ *)
                  ("", componentNameExpr);
                  (* props::[bs.obj {foo: bar, baz: qux}] *)
                  ("props", functionCallWithLabelsToBSObj ~loc (
                    props |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression))
                  ));
                  (* [|moreCreateElementCallsHere|] *)
                  ("", childrenExpr)
                ]
              in
              Exp.apply
                ~loc
                (* throw away the [@JSX] attribute and keep the others, if any *)
                ~attrs:(pexp_attributes |> List.filter (fun (attribute, _) -> attribute.txt <> "JSX"))
                (* ReactRe.createCompositeElement *)
                (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactRe", "createElement")})
                args
            else
              (* div prop1::foo prop2:bar children::[bla] () *)
              (* turn that into ReactDOMRe.createElement props::(ReactDOMRe.props props1::foo props2::bar ()) [|bla|] *)
              let (children, propsWithLabels) =
                extractChildrenForDOMElements ~loc propsAndChildren
              in
              let componentNameExpr =
                Exp.constant ~loc (Const_string (lowercaseIdentifier, None))
              in
              let childrenExpr =
                Exp.array (
                  listToArray children |> List.map (fun a -> mapper.expr mapper a)
                )
              in
              let args = match propsWithLabels with
              | [theUnitArgumentAtEnd] ->
                [
                  (* "div" *)
                  ("", componentNameExpr);
                  (* [|moreCreateElementCallsHere|] *)
                  ("", childrenExpr)
                ]
              | nonEmptyProps ->
                let propsCall =
                  Exp.apply
                    ~loc
                    (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "props")})
                    (nonEmptyProps |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)))
                in
                [
                  (* "div" *)
                  ("", componentNameExpr);
                  (* ReactDOMRe.props className:blabla foo::bar () *)
                  ("props", propsCall);
                  (* [|moreCreateElementCallsHere|] *)
                  ("", childrenExpr)
                ]
              in
              Exp.apply
                ~loc
                (* throw away the [@JSX] attribute and keep the others, if any *)
                ~attrs:(pexp_attributes |> List.filter (fun (attribute, _) -> attribute.txt <> "JSX"))
                (* ReactDOMRe.createDOMElement *)
                (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "createElement")})
                args
          | {txt = Ldot (_, anythingNotCreateElement)} ->
            raise (
              Invalid_argument
                ("JSX: the JSX attribute should be attached to a `YourModuleName.createElement` call. We saw `"
                  ^ anythingNotCreateElement
                  ^ "` instead"
                )
            )
          | {txt = Lapply _} ->
            (* don't think there's ever a case where this is reached *)
            raise (
              Invalid_argument "JSX: encountered a weird case while processing the code. Please report this!"
            )
          )
        | anythingElseThanIdent ->
          raise (
            Invalid_argument "JSX: `createElement` should be preceeded by a simple, direct module name."
          )
        )
    (* Delegate to the default mapper, a deep identity traversal *)
    | x -> default_mapper.expr mapper x)
}

let () = register "JSX" jsxMapper
