/-
Copyright (c) 2019 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Sebastian Ullrich

Elaboration of syntax quotations as terms and patterns (in `match_syntax`). See also `./Hygiene.lean` for the basic
hygiene workings and data types.
-/
import Lean.Syntax
import Lean.ResolveName
import Lean.Elab.Term

namespace Lean.Elab.Term.Quotation

open Lean.Syntax (isQuot isAntiquot isAntiquotSplice)
open Meta

def mkAntiquotNode (term : Syntax) (nesting := 0) (name : Option String := none) (kind := Name.anonymous) (splice := false) : Syntax :=
  let nesting := mkNullNode (mkArray nesting (mkAtom "$"))
  let term := match term.isIdent with
    | true  => term
    | false => mkNode `antiquotNestedExpr #[mkAtom "(", term, mkAtom ")"]
  let name := match name with
    | some name => mkNode `antiquotName #[mkAtom ":", mkAtom name]
    | none      => mkNullNode
  let splice := match splice with
    | true  => mkNullNode #[mkAtom "*"]
    | false => mkNullNode
  mkNode (kind ++ `antiquot) #[mkAtom "$", nesting, term, name, splice]

-- Antiquotations can be escaped as in `$$x`, which is useful for nesting macros. Also works for antiquotation scopes.
def isEscapedAntiquot (stx : Syntax) : Bool :=
  !stx[1].getArgs.isEmpty

-- Also works for antiquotation scopes.
def unescapeAntiquot (stx : Syntax) : Syntax :=
  if isAntiquot stx then
    stx.setArg 1 $ mkNullNode stx[1].getArgs.pop
  else
    stx

def getAntiquotTerm (stx : Syntax) : Syntax :=
  let e := stx[2]
  if e.isIdent then e
  else
    -- `e` is from `"(" >> termParser >> ")"`
    e[1]

def antiquotKind? : Syntax → Option SyntaxNodeKind
  | Syntax.node (Name.str k "antiquot" _) args =>
    if args[3].isOfKind `antiquotName then some k
    else
      -- we treat all antiquotations where the kind was left implicit (`$e`) the same (see `elimAntiquotChoices`)
      some Name.anonymous
  | _                                          => none

-- An "antiquotation scope" is something like `$[...]?` or `$[...]*`. Note that the latter could be of kind `many` or
-- `sepBy`, which have different implementations.
def antiquotScopeKind? : Syntax → Option SyntaxNodeKind
  | Syntax.node (Name.str k "antiquot_scope" _) args => some k
  | _                                                => none

def isAntiquotScope (stx : Syntax) : Bool :=
  antiquotScopeKind? stx |>.isSome

def getAntiquotScopeContents (stx : Syntax) : Array Syntax :=
  stx[3].getArgs

def getAntiquotScopeSuffix (stx : Syntax) : Syntax :=
  stx[5]

-- If any item of a `many` node is an antiquotation splice, its result should
-- be substituted into the `many` node's children
def isAntiquotSplicePat (stx : Syntax) : Bool :=
  stx.isOfKind nullKind && stx.getArgs.any fun arg => isAntiquotSplice arg && !isEscapedAntiquot arg

/-- `C[$(e)]` ~> `let a := e; C[$a]`. Used in the implementation of antiquot scopes. -/
private partial def floatOutAntiquotTerms : Syntax → StateT (Syntax → TermElabM Syntax) TermElabM Syntax
  | stx@(Syntax.node k args) => do
    if isAntiquot stx && !isEscapedAntiquot stx then
      let e := getAntiquotTerm stx
      if !e.isIdent then
        return ← withFreshMacroScope do
          let a ← `(a)
          modify (fun cont stx => (`(let $a:ident := $e; $stx) : TermElabM _))
          stx.setArg 2 a
    Syntax.node k (← args.mapM floatOutAntiquotTerms)
  | stx => pure stx

partial def getAntiquotationIds : Syntax → TermElabM (List Syntax)
  | stx@(Syntax.node k args) =>
    if isAntiquot stx && !isEscapedAntiquot stx then
      let anti := getAntiquotTerm stx
      if anti.isIdent then [anti]
      else throwErrorAt stx "complex antiquotation not allowed here"
    else
      List.join <$> args.toList.mapM getAntiquotationIds
  | _ => []

-- Elaborate the content of a syntax quotation term
private partial def quoteSyntax : Syntax → TermElabM Syntax
  | Syntax.ident info rawVal val preresolved => do
    -- Add global scopes at compilation time (now), add macro scope at runtime (in the quotation).
    -- See the paper for details.
    let r ← resolveGlobalName val
    let preresolved := r ++ preresolved
    let val := quote val
    -- `scp` is bound in stxQuot.expand
    `(Syntax.ident (SourceInfo.mk none none none) $(quote rawVal) (addMacroScope mainModule $val scp) $(quote preresolved))
  -- if antiquotation, insert contents as-is, else recurse
  | stx@(Syntax.node k _) => do
    if isAntiquot stx && !isEscapedAntiquot stx then
      -- splices must occur in a `many` node
      if isAntiquotSplice stx then throwErrorAt stx "unexpected antiquotation splice"
      else pure $ getAntiquotTerm stx
    else if isAntiquotScope stx && !isEscapedAntiquot stx then
      throwErrorAt stx "unexpected antiquotation splice"
    else
      let empty ← `(Array.empty);
      -- if escaped antiquotation, decrement by one escape level
      let stx := unescapeAntiquot stx
      let args ← stx.getArgs.foldlM (fun args arg =>
        if k == nullKind && isAntiquotSplice arg then
          -- antiquotation splice pattern: inject args array
          `(Array.appendCore $args $(getAntiquotTerm arg))
        else if k == nullKind && isAntiquotScope arg then do
          let k := antiquotScopeKind? arg
          let (arg, bindLets) ← floatOutAntiquotTerms arg |>.run pure
          let inner ← (getAntiquotScopeContents arg).mapM quoteSyntax
          let arr ← match (← getAntiquotationIds arg) with
            | [] => throwErrorAt stx "antiquotation scope must contain at least one antiquotation"
            | [id] => match k with
              | `optional => `(match $id:ident with
                | some $id:ident => $(quote inner)
                | none           => #[])
              | _ => `(Array.map (fun $id => $(inner[0])) $id)
            | [id1, id2] => match k with
              | `optional => `(match $id1:ident, $id2:ident with
                | some $id1:ident, some $id2:ident => $(quote inner)
                | _                                => #[])
              | _ => `(Array.zipWith $id1 $id2 fun $id1 $id2 => $(inner[0]))
            | _ => throwErrorAt stx "too many antiquotations in antiquotation scope; don't be greedy"
          let arr ←
            if k == `sepBy then
              let Syntax.atom _ sep ← (getAntiquotScopeSuffix arg)[0] | unreachable!
              `(mkSepArray $arr (mkAtom $(Syntax.mkStrLit sep)))
            else arr
          let arr ← bindLets arr
          `(Array.appendCore $args $arr)
        else do
          let arg ← quoteSyntax arg;
          `(Array.push $args $arg)) empty
      `(Syntax.node $(quote k) $args)
  | Syntax.atom info val =>
    `(Syntax.atom (SourceInfo.mk none none none) $(quote val))
  | Syntax.missing => unreachable!

def stxQuot.expand (stx : Syntax) (quotedOffset := 1) : TermElabM Syntax := do
  let quoted := stx[quotedOffset]
  /- Syntax quotations are monadic values depending on the current macro scope. For efficiency, we bind
     the macro scope once for each quotation, then build the syntax tree in a completely pure computation
     depending on this binding. Note that regular function calls do not introduce a new macro scope (i.e.
     we preserve referential transparency), so we can refer to this same `scp` inside `quoteSyntax` by
     including it literally in a syntax quotation. -/
  -- TODO: simplify to `(do scp ← getCurrMacroScope; pure $(quoteSyntax quoted))
  let stx ← quoteSyntax quoted;
  `(Bind.bind getCurrMacroScope (fun scp => Bind.bind getMainModule (fun mainModule => Pure.pure $stx)))
  /- NOTE: It may seem like the newly introduced binding `scp` may accidentally
     capture identifiers in an antiquotation introduced by `quoteSyntax`. However,
     note that the syntax quotation above enjoys the same hygiene guarantees as
     anywhere else in Lean; that is, we implement hygienic quotations by making
     use of the hygienic quotation support of the bootstrapped Lean compiler!

     Aside: While this might sound "dangerous", it is in fact less reliant on a
     "chain of trust" than other bootstrapping parts of Lean: because this
     implementation itself never uses `scp` (or any other identifier) both inside
     and outside quotations, it can actually correctly be compiled by an
     unhygienic (but otherwise correct) implementation of syntax quotations. As
     long as it is then compiled again with the resulting executable (i.e. up to
     stage 2), the result is a correct hygienic implementation. In this sense the
     implementation is "self-stabilizing". It was in fact originally compiled
     by an unhygienic prototype implementation. -/

@[builtinTermElab Parser.Level.quot] def elabLevelQuot : TermElab := adaptExpander stxQuot.expand
@[builtinTermElab Parser.Term.quot] def elabTermQuot : TermElab := adaptExpander stxQuot.expand
@[builtinTermElab Parser.Term.funBinder.quot] def elabfunBinderQuot : TermElab := adaptExpander stxQuot.expand
@[builtinTermElab Parser.Tactic.quot] def elabTacticQuot : TermElab := adaptExpander stxQuot.expand
@[builtinTermElab Parser.Tactic.quotSeq] def elabTacticQuotSeq : TermElab := adaptExpander stxQuot.expand
@[builtinTermElab Parser.Term.stx.quot] def elabStxQuot : TermElab := adaptExpander stxQuot.expand
@[builtinTermElab Parser.Term.doElem.quot] def elabDoElemQuot : TermElab := adaptExpander stxQuot.expand
@[builtinTermElab Parser.Term.dynamicQuot] def elabDynamicQuot : TermElab := adaptExpander (stxQuot.expand · 3)

/- match_syntax -/

-- an "alternative" of patterns plus right-hand side
private abbrev Alt := List Syntax × Syntax

/-- Information on a pattern's head that influences the compilation of a single
    match step. -/
structure BasicHeadInfo where
  -- Node kind to match, if any
  kind    : Option SyntaxNodeKind     := none
  -- Nested patterns for each argument, if any. In a single match step, we only
  -- check that the arity matches. The arity is usually implied by the node kind,
  -- but not in the case of `many` nodes.
  argPats : Option (Array Syntax)     := none
  -- Function to apply to the right-hand side in case the match succeeds. Used to
  -- bind pattern variables.
  rhsFn   : Syntax → TermElabM Syntax := pure

inductive HeadInfo where
  | basic (bhi : BasicHeadInfo)
  | antiquotScope (stx : Syntax)

open HeadInfo

instance : Inhabited HeadInfo := ⟨basic {}⟩

/-- `h1.generalizes h2` iff h1 is equal to or more general than h2, i.e. it matches all nodes
    h2 matches. This induces a partial ordering. -/
def HeadInfo.generalizes : HeadInfo → HeadInfo → Bool
  | basic { kind := none, .. }, _                      => true
  | basic { kind := some k1, argPats := none, .. },
    basic { kind := some k2, .. }                      => k1 == k2
  | basic { kind := some k1, argPats := some ps1, .. },
    basic { kind := some k2, argPats := some ps2, .. } => k1 == k2 && ps1.size == ps2.size
  -- roughmost approximation for now
  | antiquotScope stx1, antiquotScope stx2             => stx1 == stx2
  | _, _                                               => false

def mkTuple : Array Syntax → TermElabM Syntax
  | #[]  => `(())
  | #[e] => e
  | es   => `(($(es[0]), $(es.eraseIdx 0)*))

private def getHeadInfo (alt : Alt) : HeadInfo :=
  let pat := alt.fst.head!;
  let unconditional (rhsFn) := basic { rhsFn := rhsFn };
  -- variable pattern
  if pat.isIdent then unconditional $ fun rhs => `(let $pat := discr; $rhs)
  -- wildcard pattern
  else if pat.isOfKind `Lean.Parser.Term.hole then unconditional pure
  -- quotation pattern
  else if isQuot pat then
    let quoted := pat[1]
    if quoted.isAtom then
      -- We assume that atoms are uniquely determined by the node kind and never have to be checked
      unconditional pure
    else if isAntiquot quoted && !isEscapedAntiquot quoted then
      -- quotation contains a single antiquotation
      let k := antiquotKind? quoted;
      -- Antiquotation kinds like `$id:ident` influence the parser, but also need to be considered by
      -- match_syntax (but not by quotation terms). For example, `($id:ident) and `($e) are not
      -- distinguishable without checking the kind of the node to be captured. Note that some
      -- antiquotations like the latter one for terms do not correspond to any actual node kind
      -- (signified by `k == Name.anonymous`), so we would only check for `ident` here.
      --
      -- if stx.isOfKind `ident then
      --   let id := stx; ...
      -- else
      --   let e := stx; ...
      let kind := if k == Name.anonymous then none else k
      let anti := getAntiquotTerm quoted
      -- Splices should only appear inside a nullKind node, see next case
      if isAntiquotSplice quoted then unconditional $ fun _ => throwErrorAt quoted "unexpected antiquotation splice"
      else if isAntiquotScope quoted then unconditional $ fun _ => throwErrorAt quoted "unexpected antiquotation scope"
      else if anti.isIdent then basic { kind := kind, rhsFn :=  fun rhs => `(let $anti := discr; $rhs) }
      else unconditional fun _ => throwErrorAt! anti "match_syntax: antiquotation must be variable {anti}"
    else if isAntiquotSplicePat quoted && quoted.getArgs.size == 1 then
      -- quotation is a single antiquotation splice => bind args array
      let anti := getAntiquotTerm quoted[0]
      unconditional fun rhs => `(let $anti := Syntax.getArgs discr; $rhs)
      -- TODO: support for more complex antiquotation splices
    else if quoted.getArgs.size == 1 && isAntiquotScope quoted[0] then
      antiquotScope quoted[0]
    else
      -- not an antiquotation or escaped antiquotation: match head shape
      let quoted  := unescapeAntiquot quoted
      let argPats := quoted.getArgs.map (pat.setArg 1);
      basic { kind := quoted.getKind, argPats := argPats }
  else
    unconditional $ fun _ => throwErrorAt! pat "match_syntax: unexpected pattern kind {pat}"

-- Assuming that the first pattern of the alternative is taken, replace it with patterns (if any) for its
-- child nodes.
-- Ex: `($a + (- $b)) => `($a), `(+), `(- $b)
-- Note: The atom pattern `(+) will be discarded in a later step
private def explodeHeadPat (numArgs : Nat) : HeadInfo × Alt → TermElabM Alt
  | (basic info, (pat::pats, rhs)) => do
      let newPats := match info.argPats with
        | some argPats => argPats.toList
        | none         => List.replicate numArgs $ Unhygienic.run `(_)
      let rhs ← info.rhsFn rhs
      pure (newPats ++ pats, rhs)
  | (antiquotScope _, (pat::pats, rhs)) => (pats, rhs)
  | _ => unreachable!

private partial def compileStxMatch (discrs : List Syntax) (alts : List Alt) : TermElabM Syntax := do
  trace[Elab.match_syntax]! "match_syntax {discrs} with {alts}"
  match discrs, alts with
  | [],            ([], rhs)::_ => pure rhs  -- nothing left to match
  | _,             []           => throwError "non-exhaustive 'match_syntax'"
  | discr::discrs, alts         => do
    let alts := (alts.map getHeadInfo).zip alts;
    -- Choose a most specific pattern, ie. a minimal element according to `generalizes`.
    -- If there are multiple minimal elements, the choice does not matter.
    let (info, alt) := alts.tail!.foldl (fun (min : HeadInfo × Alt) (alt : HeadInfo × Alt) => if min.1.generalizes alt.1 then alt else min) alts.head!;
    -- introduce pattern matches on the discriminant's children if there are any nested patterns
    let newDiscrs ← match info with
      | basic { argPats := some pats, .. } => (List.range pats.size).mapM fun i => `(Syntax.getArg discr $(quote i))
      | _ => pure []
    -- collect matching alternatives and explode them
    let yesAlts := alts.filter fun (alt : HeadInfo × Alt) => alt.1.generalizes info
    let yesAlts ← yesAlts.mapM $ explodeHeadPat newDiscrs.length
    -- NOTE: use fresh macro scopes for recursive call so that different `discr`s introduced by the quotations below do not collide
    let yes ← withFreshMacroScope $ compileStxMatch (newDiscrs ++ discrs) yesAlts
    let mkNo := do
      let noAlts := (alts.filter $ fun (alt : HeadInfo × Alt) => !info.generalizes alt.1).map (·.2)
      withFreshMacroScope $ compileStxMatch (discr::discrs) noAlts
    match info with
    -- unconditional match step
    | basic { kind := none, .. } => `(let discr := $discr; $yes)
    -- conditional match step
    | basic { kind := some kind, argPats := pats, .. } =>
      let cond ← match pats with
      | some pats => `(and (Syntax.isOfKind discr $(quote kind)) (BEq.beq (Array.size (Syntax.getArgs discr)) $(quote pats.size)))
      | none      => `(Syntax.isOfKind discr $(quote kind))
      let no ← mkNo
      `(let discr := $discr; ite (Eq $cond true) $yes $no)
    -- terrifying match step
    | antiquotScope scope =>
      let k := antiquotScopeKind? scope
      let contents := getAntiquotScopeContents scope
      let ids ← getAntiquotationIds scope
      let no ← mkNo
      match k with
      | `optional =>
        let mut yesMatch := yes
        for id in ids do
          yesMatch ← `(let $id := some $id; $yesMatch)
        let mut yesNoMatch := yes
        for id in ids do
          yesNoMatch ← `(let $id := none; $yesNoMatch)
        `(let discr := $discr;
          if discr.isNone then $yesNoMatch
          else match_syntax discr with
            | `($(mkNullNode contents)) => $yesMatch
            | _                         => $no)
      | _ =>
        let mut discrs ← `(Syntax.getArgs $discr)
        if k == `sepBy then
          discrs ← `(Array.getSepElems $discrs)
        let ids := ids.toArray
        let tuple ← mkTuple ids
        let mut yes := yes
        let resId ← match ids with
          | #[id] => id
          | _     =>
            for i in [:ids.size] do
              let idx := Syntax.mkLit fieldIdxKind (toString (i + 1));
              yes ← `(let $(ids[i]) := tuples.map (·.$idx:fieldIdx); $yes)
            `(tuples)
        `(match ($(discrs).sequenceMap fun discr => match_syntax discr with
            | `($(contents[0])) => some $tuple
            | _                 => none) with
          | some $resId => $yes
          | none => $no)
  | _, _ => unreachable!

-- Get all pattern vars (as `Syntax.ident`s) in `stx`
partial def getPatternVars (stx : Syntax) : TermElabM (List Syntax) :=
  if isQuot stx then do
    let quoted := stx.getArg 1;
    getAntiquotationIds stx
  else if stx.isIdent then
    [stx]
  else []

-- Transform alternatives by binding all right-hand sides to outside the match_syntax in order to prevent
-- code duplication during match_syntax compilation
private def letBindRhss (cont : List Alt → TermElabM Syntax) : List Alt → List Alt → TermElabM Syntax
  | [],                altsRev' => cont altsRev'.reverse
  | (pats, rhs)::alts, altsRev' => do
    let vars ← List.join <$> pats.mapM getPatternVars
    match vars with
    -- no antiquotations => introduce Unit parameter to preserve evaluation order
    | [] =>
      -- NOTE: references binding below
      let rhs' ← `(rhs ())
      -- NOTE: new macro scope so that introduced bindings do not collide
      let stx ← withFreshMacroScope $ letBindRhss cont alts ((pats, rhs')::altsRev')
      `(let rhs := fun _ => $rhs; $stx)
    | _ =>
      -- rhs ← `(fun $vars* => $rhs)
      let rhs := Syntax.node `Lean.Parser.Term.fun #[mkAtom "fun", Syntax.node `null vars.toArray, mkAtom "=>", rhs]
      let rhs' ← `(rhs)
      let stx ← withFreshMacroScope $ letBindRhss cont alts ((pats, rhs')::altsRev')
      `(let rhs := $rhs; $stx)

def match_syntax.expand (stx : Syntax) : TermElabM Syntax := do
  let discr := stx[1]
  let alts  := stx[3][1]
  let alts ← alts.getSepArgs.mapM $ fun alt => do
    let pats := alt.getArg 0;
    let pat ←
      if pats.getArgs.size == 1 then pure pats[0]
      else throwError "match_syntax: expected exactly one pattern per alternative"
    let pat := if isQuot pat then pat.setArg 1 pat[1] else pat
    match pat.find? $ fun stx => stx.getKind == choiceKind with
    | some choiceStx => throwErrorAt choiceStx "invalid pattern, nested syntax has multiple interpretations"
    | none           =>
      let rhs := alt.getArg 2
      pure ([pat], rhs)
  -- letBindRhss (compileStxMatch stx [discr]) alts.toList []
  let stx ← compileStxMatch [discr] alts.toList
  trace[Elab.match_syntax.result]! "{stx}"
  stx

@[builtinTermElab «match_syntax»] def elabMatchSyntax : TermElab :=
  adaptExpander match_syntax.expand

builtin_initialize
  registerTraceClass `Elab.match_syntax
  registerTraceClass `Elab.match_syntax.result

end Lean.Elab.Term.Quotation
