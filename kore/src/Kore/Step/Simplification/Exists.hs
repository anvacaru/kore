{-|
Module      : Kore.Step.Simplification.Exists
Description : Tools for Exists pattern simplification.
Copyright   : (c) Runtime Verification, 2018
License     : NCSA
Maintainer  : virgil.serbanuta@runtimeverification.com
Stability   : experimental
Portability : portable
-}
module Kore.Step.Simplification.Exists
    ( simplify
    , makeEvaluate
    ) where

import           Data.Map.Strict
                 ( Map )
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import           Kore.AST.Pure
import           Kore.AST.Valid
import           Kore.IndexedModule.MetadataTools
                 ( MetadataTools )
import           Kore.Predicate.Predicate
                 ( Predicate, makeExistsPredicate, makeTruePredicate,
                 unwrapPredicate )
import           Kore.Step.Axiom.Data
                 ( BuiltinAndAxiomSimplifierMap )
import           Kore.Step.Pattern
import           Kore.Step.Representation.ExpandedPattern
                 ( ExpandedPattern, Predicated (..) )
import qualified Kore.Step.Representation.ExpandedPattern as ExpandedPattern
                 ( toMLPattern )
import qualified Kore.Step.Representation.MultiOr as MultiOr
                 ( make, traverseFlattenWithPairs )
import           Kore.Step.Representation.OrOfExpandedPattern
                 ( OrOfExpandedPattern )
import qualified Kore.Step.Representation.OrOfExpandedPattern as OrOfExpandedPattern
                 ( isFalse, isTrue )
import           Kore.Step.Simplification.Data
                 ( PredicateSubstitutionSimplifier, SimplificationProof (..),
                 Simplifier, StepPatternSimplifier )
import qualified Kore.Step.Simplification.ExpandedPattern as ExpandedPattern
                 ( simplify )
import           Kore.Step.StepperAttributes
                 ( StepperAttributes )
import           Kore.Unification.Substitution
                 ( Substitution )
import qualified Kore.Unification.Substitution as Substitution
import           Kore.Unparser
import           Kore.Variables.Free
                 ( freePureVariables )
import           Kore.Variables.Fresh


-- TODO: Move Exists up in the other simplifiers or something similar. Note
-- that it messes up top/bottom testing so moving it up must be done
-- immediately after evaluating the children.
{-|'simplify' simplifies an 'Exists' pattern with an 'OrOfExpandedPattern'
child.

The simplification of exists x . (pat and pred and subst) is equivalent to:

* If the subst contains an assignment for x, then substitute that in pat and
  pred, reevaluate them and return
  (reevaluated-pat and reevaluated-pred and subst-without-x).
* Otherwise, if x does not occur free in pat and pred, return
  (pat and pred and subst)
* Otherwise, if x does not occur free in pat, return
  (pat and (exists x . pred) and subst)
* Otherwise, if x does not occur free in pred, return
  ((exists x . pat) and pred and subst)
* Otherwise return
  ((exists x . pat and pred) and subst)
-}
simplify
    ::  ( MetaOrObject level
        , Ord (variable level)
        , Show (variable level)
        , Unparse (variable level)
        , OrdMetaOrObject variable
        , ShowMetaOrObject variable
        , FreshVariable variable
        , SortedVariable variable
        )
    => MetadataTools level StepperAttributes
    -> PredicateSubstitutionSimplifier level
    -> StepPatternSimplifier level
    -- ^ Simplifies patterns.
    -> BuiltinAndAxiomSimplifierMap level
    -- ^ Map from axiom IDs to axiom evaluators
    -> Exists level variable (OrOfExpandedPattern level variable)
    -> Simplifier
        ( OrOfExpandedPattern level variable
        , SimplificationProof level
        )
simplify
    tools
    substitutionSimplifier
    simplifier
    axiomIdToSimplifier
    Exists { existsVariable = variable, existsChild = child }
  =
    simplifyEvaluated
        tools
        substitutionSimplifier
        simplifier
        axiomIdToSimplifier
        variable
        child

{- TODO (virgil): Preserve pattern sorts under simplification.

One way to preserve the required sort annotations is to make 'simplifyEvaluated'
take an argument of type

> CofreeF (Exists level) (Valid level) (OrOfExpandedPattern level variable)

instead of a 'variable level' and an 'OrOfExpandedPattern' argument. The type of
'makeEvaluate' may be changed analogously. The 'Valid' annotation will
eventually cache information besides the pattern sort, which will make it even
more useful to carry around.

-}
simplifyEvaluated
    ::  ( MetaOrObject level
        , Ord (variable level)
        , Show (variable level)
        , Unparse (variable level)
        , OrdMetaOrObject variable
        , ShowMetaOrObject variable
        , FreshVariable variable
        , SortedVariable variable
        )
    => MetadataTools level StepperAttributes
    -> PredicateSubstitutionSimplifier level
    -> StepPatternSimplifier level
    -- ^ Simplifies patterns.
    -> BuiltinAndAxiomSimplifierMap level
    -- ^ Map from axiom IDs to axiom evaluators
    -> variable level
    -> OrOfExpandedPattern level variable
    -> Simplifier
        (OrOfExpandedPattern level variable, SimplificationProof level)
simplifyEvaluated
    tools
    substitutionSimplifier
    simplifier
    axiomIdToSimplifier
    variable
    simplified
  | OrOfExpandedPattern.isTrue simplified =
    return (simplified, SimplificationProof)
  | OrOfExpandedPattern.isFalse simplified =
    return (simplified, SimplificationProof)
  | otherwise = do
    (evaluated, _proofs) <-
        MultiOr.traverseFlattenWithPairs
            (makeEvaluate
                tools
                substitutionSimplifier
                simplifier
                axiomIdToSimplifier
                variable
            )
            simplified
    return ( evaluated, SimplificationProof )

{-| evaluates an 'Exists' given its two 'ExpandedPattern' children.

See 'simplify' for detailed documentation.
-}
makeEvaluate
    ::  ( MetaOrObject level
        , Ord (variable level)
        , Show (variable level)
        , Unparse (variable level)
        , OrdMetaOrObject variable
        , ShowMetaOrObject variable
        , FreshVariable variable
        , SortedVariable variable
        )
    => MetadataTools level StepperAttributes
    -> PredicateSubstitutionSimplifier level
    -> StepPatternSimplifier level
    -- ^ Simplifies patterns.
    -> BuiltinAndAxiomSimplifierMap level
    -- ^ Map from axiom IDs to axiom evaluators
    -> variable level
    -> ExpandedPattern level variable
    -> Simplifier
        (OrOfExpandedPattern level variable, SimplificationProof level)
makeEvaluate
    tools
    substitutionSimplifier
    simplifier
    axiomIdToSimplifier
    variable
    patt@Predicated { term, predicate, substitution }
  =
    case localSubstitution of
        [] ->
            return (makeEvaluateNoFreeVarInSubstitution variable patt)
        _ -> do
            (substitutedPat, _proof) <-
                substituteTermPredicate
                    term
                    predicate
                    localSubstitutionList
                    (Substitution.wrap globalSubstitution)
            (result, _proof) <-
                ExpandedPattern.simplify
                    tools
                    substitutionSimplifier
                    simplifier
                    axiomIdToSimplifier
                    substitutedPat
            return (result , SimplificationProof)
  where
    (Local localSubstitution, Global globalSubstitution) =
        splitSubstitutionByVariable variable $ Substitution.unwrap substitution
    localSubstitutionList =
        Map.fromList localSubstitution

makeEvaluateNoFreeVarInSubstitution
    ::  ( MetaOrObject level
        , SortedVariable variable
        , Ord (variable level)
        , Show (variable level)
        , Unparse (variable level)
        , OrdMetaOrObject variable
        , ShowMetaOrObject variable
        )
    => variable level
    -> ExpandedPattern level variable
    -> (OrOfExpandedPattern level variable, SimplificationProof level)
makeEvaluateNoFreeVarInSubstitution
    variable
    patt@Predicated { term, predicate, substitution }
  =
    (MultiOr.make [simplifiedPattern], SimplificationProof)
  where
    termHasVariable =
        Set.member variable (freePureVariables term)
    predicateHasVariable =
        Set.member variable (freePureVariables $ unwrapPredicate predicate)
    simplifiedPattern = case (termHasVariable, predicateHasVariable) of
        (False, False) -> patt
        (False, True) ->
            let
                predicate' = makeExistsPredicate variable predicate
            in
                Predicated
                    { term = term
                    , predicate = predicate'
                    , substitution = substitution
                    }
        (True, False) ->
            Predicated
                { term = mkExists variable term
                , predicate = predicate
                , substitution = substitution
                }
        (True, True) ->
            Predicated
                { term =
                    mkExists variable
                        (ExpandedPattern.toMLPattern
                            Predicated
                                { term = term
                                , predicate = predicate
                                , substitution = mempty
                                }
                        )
                , predicate = makeTruePredicate
                , substitution = substitution
                }

substituteTermPredicate
    ::  ( MetaOrObject level
        , Ord (variable level)
        , Show (variable level)
        , OrdMetaOrObject variable
        , ShowMetaOrObject variable
        , FreshVariable variable
        , SortedVariable variable
        )
    => StepPattern level variable
    -> Predicate level variable
    -> Map (variable level) (StepPattern level variable)
    -> Substitution level variable
    -> Simplifier
        (ExpandedPattern level variable, SimplificationProof level)
substituteTermPredicate term predicate substitution globalSubstitution =
    return
        ( Predicated
            { term = substitute substitution term
            , predicate = substitute substitution <$> predicate
            , substitution = globalSubstitution
            }
        , SimplificationProof
        )

newtype Local a = Local a
newtype Global a = Global a

splitSubstitutionByVariable
    :: Eq (variable level)
    => variable level
    -> [(variable level, StepPattern level variable)]
    ->  ( Local [(variable level, StepPattern level variable)]
        , Global [(variable level, StepPattern level variable)]
        )
splitSubstitutionByVariable _ [] =
    (Local mempty, Global mempty)
splitSubstitutionByVariable variable ((var, term) : substs)
  | var == variable =
    (Local [(var, term)], Global substs)
  | otherwise =
    (local, Global ((var, term) : global))
  where
    (local, Global global) = splitSubstitutionByVariable variable substs
