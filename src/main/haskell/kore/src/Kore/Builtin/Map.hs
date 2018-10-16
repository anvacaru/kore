{- |
Module      : Kore.Builtin.Map
Description : Built-in key-value maps
Copyright   : (c) Runtime Verification, 2018
License     : NCSA
Maintainer  : thomas.tuegel@runtimeverification.com
Stability   : experimental
Portability : portable

This module is intended to be imported qualified, to avoid collision with other
builtin modules.

@
    import qualified Kore.Builtin.Map as Map
@
 -}
module Kore.Builtin.Map
    ( sort
    , sortDeclVerifiers
    , symbolVerifiers
    , builtinFunctions
    , Builtin
    , asPattern
    , asExpandedPattern
      -- * Symbols
    , lookupSymbolUnit
    , lookupSymbolUpdate
    , lookupSymbolLookup
    , lookupSymbolElement
    , lookupSymbolConcat
    , lookupSymbolInKeys
    , isSymbolConcat
    -- * Unification
    , unify
    ) where

import           Control.Applicative
                 ( Alternative (..) )
import qualified Control.Monad as Monad
import           Control.Monad.Except
                 ( ExceptT )
import qualified Control.Monad.Except as Except
import qualified Data.HashMap.Strict as HashMap
import           Data.Map.Strict
                 ( Map )
import qualified Data.Map.Strict as Map
import           Data.Reflection
                 ( Given, give )
import qualified Data.Set as Set
import           Data.Text
                 ( Text )

import           Data.Result
import           Kore.AST.Common
                 ( BuiltinDomain (BuiltinDomainMap), ConcretePurePattern,
                 PureMLPattern, Sort, SortedVariable, SymbolOrAlias )
import qualified Kore.AST.Common as Kore
import           Kore.AST.MetaOrObject
import qualified Kore.AST.PureML as Kore
import           Kore.ASTUtils.SmartPatterns as Kore
import qualified Kore.Builtin.Bool as Bool
import qualified Kore.Builtin.Builtin as Builtin
import           Kore.Builtin.Hook
                 ( Hook )
import qualified Kore.Error as Kore
import           Kore.IndexedModule.IndexedModule
                 ( KoreIndexedModule )
import           Kore.IndexedModule.MetadataTools
                 ( MetadataTools (..), SymbolOrAliasSorts )
import           Kore.Step.ExpandedPattern
                 ( ExpandedPattern, Predicated )
import qualified Kore.Step.ExpandedPattern as ExpandedPattern
import           Kore.Step.Function.Data
                 ( AttemptedFunction (..) )
import qualified Kore.Step.OrOfExpandedPattern as OrOfExpandedPattern
import           Kore.Step.Simplification.Data
                 ( SimplificationProof (..) )
import           Kore.Step.StepperAttributes
                 ( StepperAttributes )
import qualified Kore.Step.StepperAttributes as StepperAttributes
import           Kore.Step.Substitution
                 ( normalize )
import           Kore.Substitution.Class
                 ( Hashable )
import           Kore.Variables.Fresh

{- | Builtin name of the @Map@ sort.
 -}
sort :: Text
sort = "MAP.Map"

{- | Verify that the sort is hooked to the builtin @Int@ sort.

  See also: 'sort', 'Builtin.verifySort'

 -}
assertSort :: Builtin.SortVerifier
assertSort findSort = Builtin.verifySort findSort sort

{- | Verify that hooked sort declarations are well-formed.

  See also: 'Builtin.verifySortDecl'

 -}
sortDeclVerifiers :: Builtin.SortDeclVerifiers
sortDeclVerifiers = HashMap.fromList [ (sort, Builtin.verifySortDecl) ]

{- | Verify that hooked symbol declarations are well-formed.

  See also: 'Builtin.verifySymbol'

 -}
symbolVerifiers :: Builtin.SymbolVerifiers
symbolVerifiers =
    HashMap.fromList
    [ ( "MAP.concat"
      , Builtin.verifySymbol assertSort [assertSort , assertSort]
      )
    , ( "MAP.element"
      , Builtin.verifySymbol assertSort [anySort, anySort]
      )
    , ( "MAP.lookup"
      , Builtin.verifySymbol anySort [assertSort, anySort]
      )
    , ( "MAP.unit"
      , Builtin.verifySymbol assertSort []
      )
    , ( "MAP.update"
      , Builtin.verifySymbol assertSort [assertSort, anySort, anySort]
      )
    , ( "MAP.in_keys"
      , Builtin.verifySymbol Bool.assertSort [anySort, assertSort]
      )
    ]
  where
    anySort :: Builtin.SortVerifier
    anySort = const $ const $ Right ()

type Builtin variable =
    Map (Kore.ConcretePurePattern Object) (Kore.PureMLPattern Object variable)

{- | Abort function evaluation if the argument is not a Map domain value.

    If the operand pattern is not a domain value, the function is simply
    'NotApplicable'. If the operand is a domain value, but not represented
    by a 'BuiltinDomainMap', it is a bug.

 -}
expectBuiltinDomainMap
    :: Monad m
    => String  -- ^ Context for error message
    -> Kore.PureMLPattern Object variable  -- ^ Operand pattern
    -> ExceptT (AttemptedFunction Object variable) m (Builtin variable)
expectBuiltinDomainMap ctx _map =
    do
        case _map of
            Kore.DV_ _ domain ->
                case domain of
                    Kore.BuiltinDomainMap map' -> return map'
                    _ ->
                        Builtin.verifierBug
                            (ctx ++ ": Domain value is not a map")
            _ ->
                Except.throwError NotApplicable

returnMap
    :: Monad m
    => Kore.Sort Object
    -> Builtin variable
    -> m (AttemptedFunction Object variable)
returnMap resultSort map' =
    Builtin.appliedFunction
        $ ExpandedPattern.fromPurePattern
        $ asBuiltinDomainValue resultSort map'

evalLookup :: Builtin.Function
evalLookup =
    Builtin.functionEvaluator evalLookup0
  where
    evalLookup0 tools _ _ arguments =
        Builtin.getAttemptedFunction
        (do
            let (_map, _key) =
                    case arguments of
                        [_map, _key] -> (_map, _key)
                        _ -> Builtin.wrongArity "MAP.lookup"
            _key <- Builtin.expectNormalConcreteTerm tools _key
            _map <- expectBuiltinDomainMap "MAP.lookup" _map
            Builtin.appliedFunction
                $ maybe ExpandedPattern.bottom ExpandedPattern.fromPurePattern
                $ Map.lookup _key _map
        )

evalElement :: Builtin.Function
evalElement =
    Builtin.functionEvaluator evalElement0
  where
    evalElement0 tools _ resultSort = \arguments ->
        Builtin.getAttemptedFunction
        (do
            let (_key, _value) =
                    case arguments of
                        [_key, _value] -> (_key, _value)
                        _ -> Builtin.wrongArity "MAP.element"
            _key <- Builtin.expectNormalConcreteTerm tools _key
            returnMap resultSort (Map.singleton _key _value)
        )

evalConcat :: Builtin.Function
evalConcat =
    Builtin.functionEvaluator evalConcat0
  where
    evalConcat0 _ _ resultSort = \arguments ->
        Builtin.getAttemptedFunction
        (do
            let (_map1, _map2) =
                    case arguments of
                        [_map1, _map2] -> (_map1, _map2)
                        _ -> Builtin.wrongArity "MAP.concat"
            _map1 <- expectBuiltinDomainMap "MAP.concat" _map1
            _map2 <- expectBuiltinDomainMap "MAP.concat" _map2
            let overlapping =
                    (not . Set.null)
                    (Set.intersection (Map.keysSet _map1) (Map.keysSet _map2))
            -- Result is ‘\bottom{}()’ when there is overlap between the keys
            -- of the operands.
            (Monad.when overlapping . Except.throwError)
                (Applied $ OrOfExpandedPattern.make [ExpandedPattern.bottom])
            returnMap resultSort (Map.union _map1 _map2)
        )

evalUnit :: Builtin.Function
evalUnit =
    Builtin.functionEvaluator evalUnit0
  where
    evalUnit0 _ _ resultSort =
        \case
            [] -> returnMap resultSort Map.empty
            _ -> Builtin.wrongArity "MAP.unit"

evalUpdate :: Builtin.Function
evalUpdate =
    Builtin.functionEvaluator evalUpdate0
  where
    evalUpdate0 tools _ resultSort = \arguments ->
        Builtin.getAttemptedFunction
        (do
            let (_map, _key, value) =
                    case arguments of
                        [_map, _key, value'] -> (_map, _key, value')
                        _ -> Builtin.wrongArity "MAP.update"
            _key <- Builtin.expectNormalConcreteTerm tools _key
            _map <- expectBuiltinDomainMap "MAP.update" _map
            returnMap resultSort (Map.insert _key value _map)
        )

evalInKeys :: Builtin.Function
evalInKeys =
    Builtin.functionEvaluator evalInKeys0
  where
    evalInKeys0 tools _ resultSort = \arguments ->
        Builtin.getAttemptedFunction
        (do
            let (_key, _map) =
                    case arguments of
                        [_key, _map] -> (_key, _map)
                        _ -> Builtin.wrongArity "MAP.in_keys"
            _key <- Builtin.expectNormalConcreteTerm tools _key
            _map <- expectBuiltinDomainMap "MAP.in_keys" _map
            Builtin.appliedFunction
                $ Bool.asExpandedPattern resultSort
                $ Map.member _key _map
        )

{- | Implement builtin function evaluation.
 -}
builtinFunctions :: Map Text Builtin.Function
builtinFunctions =
    Map.fromList
        [ ("MAP.concat", evalConcat)
        , ("MAP.lookup", evalLookup)
        , ("MAP.element", evalElement)
        , ("MAP.unit", evalUnit)
        , ("MAP.update", evalUpdate)
        , ("MAP.in_keys", evalInKeys)
        ]

{- | Render a 'Map' as a domain value pattern of the given sort.

    The result sort should be hooked to the builtin @Map@ sort, but this is not
    checked.

    The constructed pattern will be valid in the contexed of the given indexed
    module. It is an error if the indexed module does not define symbols hooked
    to @MAP.unit@, @MAP.element@, and @MAP.concat@.

    See also: 'sort'

 -}
asPattern
    :: KoreIndexedModule attrs
    -- ^ indexed module where pattern would appear
    -> Kore.Sort Object
    -> Either
        (Kore.Error e)
        (Builtin variable -> Kore.PureMLPattern Object variable)
asPattern indexedModule _
  = do
    symbolUnit <- lookupSymbolUnit indexedModule
    let applyUnit = Kore.App_ symbolUnit []
    symbolElement <- lookupSymbolElement indexedModule
    let applyElement (key, value) =
            Kore.App_ symbolElement [Kore.fromConcretePurePattern key, value]
    symbolConcat <- lookupSymbolConcat indexedModule
    let applyConcat map1 map2 = Kore.App_ symbolConcat [map1, map2]
        asPattern0 result =
            foldr applyConcat applyUnit
                (applyElement <$> Map.toAscList result)
    return asPattern0

{- | Render a 'Map' as an extended domain value pattern.

    See also: 'asPattern'

 -}
asExpandedPattern
    :: KoreIndexedModule attrs
    -- ^ dictionary of Map constructor symbols
    -> Kore.Sort Object
    -> Either
        (Kore.Error e)
        (Builtin variable -> ExpandedPattern Object variable)
asExpandedPattern symbols resultSort =
    asExpandedPattern0 <$> asPattern symbols resultSort
  where
    asExpandedPattern0 = \asPattern0 builtin ->
        ExpandedPattern.fromPurePattern $ asPattern0 builtin

{- | Embed a 'Map' in a builtin domain value pattern.
 -}
asBuiltinDomainValue
    :: Kore.Sort Object
    -> Map (Kore.ConcretePurePattern Object) (Kore.PureMLPattern Object variable)
    -> Kore.PureMLPattern Object variable
asBuiltinDomainValue resultSort map' = DV_ resultSort (BuiltinDomainMap map')

{- | Find the symbol hooked to @MAP.unit@ in an indexed module.
 -}
lookupSymbolUnit
    :: KoreIndexedModule attrs
    -> Either (Kore.Error e) (Kore.SymbolOrAlias Object)
lookupSymbolUnit = Builtin.lookupSymbol "MAP.unit"

{- | Find the symbol hooked to @MAP.update@ in an indexed module.
 -}
lookupSymbolUpdate
    :: KoreIndexedModule attrs
    -> Either (Kore.Error e) (Kore.SymbolOrAlias Object)
lookupSymbolUpdate = Builtin.lookupSymbol "MAP.update"

{- | Find the symbol hooked to @MAP.lookup@ in an indexed module.
 -}
lookupSymbolLookup
    :: KoreIndexedModule attrs
    -> Either (Kore.Error e) (Kore.SymbolOrAlias Object)
lookupSymbolLookup = Builtin.lookupSymbol "MAP.lookup"

{- | Find the symbol hooked to @MAP.element@ in an indexed module.
 -}
lookupSymbolElement
    :: KoreIndexedModule attrs
    -> Either (Kore.Error e) (Kore.SymbolOrAlias Object)
lookupSymbolElement = Builtin.lookupSymbol "MAP.element"

{- | Find the symbol hooked to @MAP.concat@ in an indexed module.
 -}
lookupSymbolConcat
    :: KoreIndexedModule attrs
    -> Either (Kore.Error e) (Kore.SymbolOrAlias Object)
lookupSymbolConcat = Builtin.lookupSymbol "MAP.concat"

{- | Find the symbol hooked to @MAP.in_keys@ in an indexed module.
 -}
lookupSymbolInKeys
    :: KoreIndexedModule attrs
    -> Either (Kore.Error e) (Kore.SymbolOrAlias Object)
lookupSymbolInKeys = Builtin.lookupSymbol "MAP.in_keys"

{- | Check if the given symbol is hooked to @MAP.concat@.
 -}
isSymbolConcat :: MetadataTools Object Hook -> Kore.SymbolOrAlias Object -> Bool
isSymbolConcat = Builtin.isSymbol "MAP.concat"

{- | Simplify the conjunction of two concrete Map domain values.

The maps are assumed to have the same sort, but this is not checked. If
multiple sorts are hooked to the same builtin domain, the verifier should
reject the definition.

The most general form of the unification problem is
@
(m₁ + x₁) ∧ (m₂ + x₂)
@
where @+@ represents @concat@ and @m₁@, @m₂@ are concrete maps.
The solution is to introduce @qᵢ@ and @rᵢ@ such that
@
m₁ = q₁ + r₁
m₂ = q₂ + r₂
keys(q₁) = keys(q₂)
keys(r₁) ∧ keys(r₂) = ⊥
@
so that
@
(m₁ + x₁) ∧ (m₂ + x₂) = (q₁ ∧ q₂) + (r₁ + x₁) ∧ (r₂ + x₂).
@
When both @x₁@ and @x₂@ are present, we should check that @q₁ ∧ q₂@ is not
empty, otherwise this equation is just a trivial shuffling and does not actually
make progress toward simplification. We introduce special cases when @x₁@ and/or
@x₂@ is missing.
 -}
-- TODO (thomas.tuegel): Handle the case of two framed maps.
unify
    :: forall level variable m p expanded proof.
        ( OrdMetaOrObject variable, ShowMetaOrObject variable
        , SortedVariable variable
        , MonadCounter m
        , MetaOrObject level
        , Hashable variable
        , FreshVariable variable
        , p ~ PureMLPattern level variable
        , expanded ~ ExpandedPattern level variable
        , proof ~ SimplificationProof level
        )
    => MetadataTools level StepperAttributes
    -> (p -> p -> Result (m (expanded, proof)))
    -> (p -> p -> Result (m (expanded, proof)))
unify
    tools@MetadataTools { symbolOrAliasSorts }
    simplifyChild
  =
    unify0
  where
    hookTools = StepperAttributes.hook <$> tools

    {- | Take the intersection of two maps with different value types.

        Returns the left-over elements of each map along with the pairs of
        values in the intersection.
     -}
    heterogenousIntersection
        :: Ord k
        => Map k a
        -> Map k b
        ->  ( Map k a  -- left-over from first map
            , Map k (a, b)  -- pairs of values under common keys
            , Map k b  -- left-over from second map
            )
    heterogenousIntersection as bs =
        ( Map.difference as bs
        , Map.intersectionWith (,) as bs
        , Map.difference bs as
        )

    -- | Sequence the actions in a map to return a collection of proven expanded
    -- patterns.
    collectProvenExpandedPatterns
        :: Map k (m (expanded, proof))
        -> m (Map k (expanded, proof))
    collectProvenExpandedPatterns = sequence

    -- | Discard the proofs in a collection of proven expanded patterns.
    discardProofs :: Map k (expanded, proof) -> Map k expanded
    discardProofs = Map.map fst

    -- | Given a collection 't' of 'Predicated' values, propagate all the
    -- predicates to the top level, returning a 'Predicated' collection.
    propagatePredicates
        :: (level ~ Object, Given (SymbolOrAliasSorts level), Traversable t)
        => t (Predicated level variable a)
        -> Predicated level variable (t a)
    propagatePredicates = sequenceA

    -- | Unify the two argument patterns.
    unify0
        :: PureMLPattern level variable
        -> PureMLPattern level variable
        -> Result (m (expanded, proof))

    unify0
        (DV_ resultSort (BuiltinDomainMap map1))
        (DV_ _          (BuiltinDomainMap map2))
      =
        unifyConcrete resultSort map1 map2

    unify0
        (DV_ resultSort (BuiltinDomainMap map1))
        (App_ concat2 args2)
      | isSymbolConcat hookTools concat2 =
        -- Accept the arguments of concat in either order.
        case args2 of
            [ DV_ _ (BuiltinDomainMap map2), x@(Var_ _) ] ->
                unifyFramed1 resultSort map1 concat2 map2 x
            [ x@(Var_ _), DV_ _ (BuiltinDomainMap map2) ] ->
                unifyFramed1 resultSort map1 concat2 map2 x
            _ -> empty

    unify0 app_@(App_ _ _) dv_@(DV_ _ _) = unify0 dv_ app_

    unify0 _ _ = empty

    -- | Unify two concrete maps.
    unifyConcrete
        :: (level ~ Object, k ~ ConcretePurePattern Object)
        => Sort level  -- ^ result sort
        -> Map k (PureMLPattern level variable)
        -> Map k (PureMLPattern level variable)
        -> Result (m (expanded, proof))
    unifyConcrete resultSort map1 map2 = do
        let (diff1, _intersect, diff2) = heterogenousIntersection map1 map2
        _intersect <- traverse (uncurry simplifyChild) _intersect
        let
            unified = give symbolOrAliasSorts $ do
                _intersect <-
                    discardProofs <$> collectProvenExpandedPatterns _intersect
                let result
                        | not (Map.null diff1) =
                            -- There is nothing with which to unify the
                            -- remainder of map1.
                            ExpandedPattern.bottom
                        | not (Map.null diff2) =
                            -- There is nothing with which to unify the
                            -- remainder of map2.
                            ExpandedPattern.bottom
                        | otherwise = asBuiltinMap <$> propagatePredicates _intersect
                (,) <$> normalize tools result <*> pure SimplificationProof
        return unified
      where
        asBuiltinMap = asBuiltinDomainValue resultSort

    -- | Unify one concrete map with one framed concrete map.
    unifyFramed1
        :: (level ~ Object, k ~ ConcretePurePattern Object)
        => Sort level  -- ^ Sort of result
        -> Map k (PureMLPattern level variable)  -- ^ concrete map
        -> SymbolOrAlias level  -- ^ 'concat' symbol used for framing
        -> Map k (PureMLPattern level variable)  -- ^ framed concrete map
        -> PureMLPattern level variable  -- ^ framing variable
        -> Result (m (expanded, proof))
    unifyFramed1 resultSort map1 concat' map2 x = do
        let (_diff1, _intersect, diff2) = heterogenousIntersection map1 map2
        _intersect <- traverse (uncurry simplifyChild) _intersect
        -- The framing variable unifies with the remainder of map1.
        -- simplifyChild returns an action which returns the unified value.
        returnDiff1 <- simplifyChild x (asBuiltinMap _diff1)
        let
            unified = give symbolOrAliasSorts $ do
                _intersect <-
                    discardProofs <$> collectProvenExpandedPatterns _intersect
                let q = asBuiltinMap <$> propagatePredicates _intersect
                (_diff1, _) <- returnDiff1
                let result
                        | not (Map.null diff2) =
                            -- There is nothing with which to unify the
                            -- remainder of map2.
                            ExpandedPattern.bottom
                        | otherwise =
                            App_ concat' <$> propagatePredicates [q, _diff1]
                (,) <$> normalize tools result <*> pure SimplificationProof
        return unified
      where
        asBuiltinMap = asBuiltinDomainValue resultSort
