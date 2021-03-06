module Test.Kore.Step.Simplification.Application
    ( test_applicationSimplification
    ) where

import Test.Tasty
import Test.Tasty.HUnit

import qualified Data.List as List
import qualified Data.Map as Map
import           Data.Ord
                 ( comparing )
import qualified Data.Set as Set

import           Data.Sup
import qualified Kore.Annotation.Valid as Valid
import           Kore.AST.Pure
import           Kore.AST.Valid
import           Kore.IndexedModule.MetadataTools
                 ( MetadataTools )
import           Kore.Predicate.Predicate
                 ( makeAndPredicate, makeEqualsPredicate, makeTruePredicate )
import           Kore.Step.Axiom.Data
import qualified Kore.Step.Axiom.Data as AttemptedAxiom
                 ( AttemptedAxiom (..) )
import           Kore.Step.Axiom.EvaluationStrategy
                 ( firstFullEvaluation )
import qualified Kore.Step.Axiom.Identifier as AxiomIdentifier
                 ( AxiomIdentifier (..) )
import           Kore.Step.Pattern
import           Kore.Step.Representation.ExpandedPattern
                 ( ExpandedPattern, Predicated (..) )
import qualified Kore.Step.Representation.ExpandedPattern as ExpandedPattern
                 ( bottom )
import qualified Kore.Step.Representation.MultiOr as MultiOr
                 ( make )
import           Kore.Step.Representation.OrOfExpandedPattern
                 ( CommonOrOfExpandedPattern, OrOfExpandedPattern )
import           Kore.Step.Simplification.Application
                 ( simplify )
import           Kore.Step.Simplification.Data
                 ( SimplificationProof (..), StepPatternSimplifier,
                 evalSimplifier )
import           Kore.Step.StepperAttributes
                 ( StepperAttributes )
import qualified Kore.Unification.Substitution as Substitution
import           Kore.Unparser
                 ( Unparse )
import           Kore.Variables.Fresh
import qualified SMT

import           Test.Kore
import           Test.Kore.Comparators ()
import qualified Test.Kore.IndexedModule.MockMetadataTools as Mock
                 ( makeMetadataTools )
import qualified Test.Kore.Step.MockSimplifiers as Mock
import           Test.Kore.Step.MockSymbols
                 ( testSort )
import qualified Test.Kore.Step.MockSymbols as Mock
import           Test.Kore.Step.Simplifier
                 ( mockSimplifier )
import           Test.Tasty.HUnit.Extensions

test_applicationSimplification :: [TestTree]
test_applicationSimplification =
    [ testCase "Application - or distribution" $ do
        -- sigma(a or b, c or d) =
        --     sigma(b, d) or sigma(b, c) or sigma(a, d) or sigma(a, c)
        let expect =
                MultiOr.make
                    [ Predicated
                        { term = Mock.sigma Mock.a Mock.c
                        , predicate = makeTruePredicate
                        , substitution = mempty
                        }
                    , Predicated
                        { term = Mock.sigma Mock.a Mock.d
                        , predicate = makeTruePredicate
                        , substitution = mempty
                        }
                    , Predicated
                        { term = Mock.sigma Mock.b Mock.c
                        , predicate = makeTruePredicate
                        , substitution = mempty
                        }
                    ,  Predicated
                        { term = Mock.sigma Mock.b Mock.d
                        , predicate = makeTruePredicate
                        , substitution = mempty
                        }
                    ]
        actual <-
            evaluate
                mockMetadataTools
                (mockSimplifier noSimplification)
                Map.empty
                (makeApplication
                    testSort
                    Mock.sigmaSymbol
                    [ [aExpanded, bExpanded]
                    , [cExpanded, dExpanded]
                    ]
                )
        assertEqualWithExplanation "" expect actual

    , testCase "Application - bottom child makes everything bottom" $ do
        -- sigma(a or b, bottom) = bottom
        let expect = MultiOr.make [ ExpandedPattern.bottom ]
        actual <-
            evaluate
                mockMetadataTools
                (mockSimplifier noSimplification)
                Map.empty
                (makeApplication
                    testSort
                    Mock.sigmaSymbol
                    [ [aExpanded, bExpanded]
                    , []
                    ]
                )
        assertEqualWithExplanation "" expect actual

    , testCase "Applies functions" $ do
        -- f(a) evaluated to g(a).
        let expect = MultiOr.make [ gOfAExpanded ]
        actual <-
            evaluate
                mockMetadataTools
                (mockSimplifier noSimplification)
                (Map.singleton
                    (AxiomIdentifier.Application Mock.fId)
                    (simplificationEvaluator
                        [ BuiltinAndAxiomSimplifier
                            (const $ const $ const $ const $ const $ return
                                ( AttemptedAxiom.Applied AttemptedAxiomResults
                                    { results =
                                        MultiOr.make [gOfAExpanded]
                                    , remainders = MultiOr.make []
                                    }
                                , SimplificationProof
                                )
                            )
                        ]
                    )
                )
                (makeApplication
                    testSort
                    Mock.fSymbol
                    [[aExpanded]]
                )
        assertEqualWithExplanation "" expect actual

    , testGroup "Combines child predicates and substitutions"
        [ testCase "When not applying functions" $ do
            -- sigma(a and f(a)=f(b) and [x=f(a)], b and g(a)=g(b) and [y=g(a)])
            --    = sigma(a, b)
            --        and (f(a)=f(b) and g(a)=g(b))
            --        and [x=f(a), y=g(a)]
            let expect =
                    MultiOr.make
                        [ Predicated
                            { term = Mock.sigma Mock.a Mock.b
                            , predicate =
                                makeAndPredicate
                                    (makeEqualsPredicate fOfA fOfB)
                                    (makeEqualsPredicate gOfA gOfB)
                            , substitution = Substitution.unsafeWrap
                                [ (Mock.x, fOfA)
                                , (Mock.y, gOfA)
                                ]
                            }
                        ]
            actual <-
                evaluate
                    mockMetadataTools
                    (mockSimplifier noSimplification)
                    Map.empty
                    (makeApplication
                        testSort
                        Mock.sigmaSymbol
                        [   [ Predicated
                                { term = Mock.a
                                , predicate = makeEqualsPredicate fOfA fOfB
                                , substitution =
                                    Substitution.wrap [ (Mock.x, fOfA) ]
                                }
                            ]
                        ,   [ Predicated
                                { term = Mock.b
                                , predicate = makeEqualsPredicate gOfA gOfB
                                , substitution =
                                    Substitution.wrap [ (Mock.y, gOfA) ]
                                }
                            ]
                        ]
                    )
            assertEqualWithExplanation "" expect actual

        , testCase "When applying functions" $ do
            -- sigma(a and f(a)=f(b) and [x=f(a)], b and g(a)=g(b) and [y=g(a)])
            --    =
            --        f(a) and
            --        (f(a)=f(b) and g(a)=g(b) and f(a)=g(a)) and
            --        [x=f(a), y=g(a), z=f(b)]
            -- if sigma(a, b) => f(a) and f(a)=g(a) and [z=f(b)]
            let z' = Mock.z { variableCounter = Just (Element 1) }
                expect =
                    MultiOr.make
                        [ Predicated
                            { term = fOfA
                            , predicate =
                                makeAndPredicate
                                    (makeEqualsPredicate fOfA gOfA)
                                    (makeAndPredicate
                                        (makeEqualsPredicate fOfA fOfB)
                                        (makeEqualsPredicate gOfA gOfB)
                                    )
                            , substitution =
                                Substitution.unsafeWrap
                                $ List.sortBy (comparing fst)
                                    [ (z', gOfB)
                                    , (Mock.x, fOfA)
                                    , (Mock.y, gOfA)
                                    ]
                            }
                        ]
            actual <-
                let
                    zvar
                        :: forall variable
                        .   ( FreshVariable variable
                            , Ord (variable Object)
                            , SortedVariable variable
                            )
                        => variable Object
                    zvar = fromVariable z'
                    result
                        :: forall variable
                        .   ( FreshVariable variable
                            , Ord (variable Object)
                            , Show (variable Object)
                            , SortedVariable variable
                            , Unparse (variable Object)
                            )
                        => AttemptedAxiom Object variable
                    result = AttemptedAxiom.Applied AttemptedAxiomResults
                        { results = MultiOr.make
                            [ Predicated
                                { term = fOfA
                                , predicate = makeEqualsPredicate fOfA gOfA
                                , substitution =
                                    Substitution.wrap [ (zvar, gOfB) ]
                                }
                            ]
                        , remainders = MultiOr.make []
                        }
                in
                    evaluate
                        mockMetadataTools
                        (mockSimplifier noSimplification)
                        (Map.singleton
                            (AxiomIdentifier.Application Mock.sigmaId)
                            (simplificationEvaluator
                                [ BuiltinAndAxiomSimplifier
                                    (const $ const $ const $ const $ const $
                                        return (result, SimplificationProof)
                                    )
                                ]
                            )
                        )
                    (makeApplication
                        testSort
                        Mock.sigmaSymbol
                        [   [ Predicated
                                { term = Mock.a
                                , predicate = makeEqualsPredicate fOfA fOfB
                                , substitution =
                                    Substitution.wrap [ (Mock.x, fOfA) ]
                                }
                            ]
                        ,   [ Predicated
                                { term = Mock.b
                                , predicate = makeEqualsPredicate gOfA gOfB
                                , substitution =
                                    Substitution.wrap [ (Mock.y, gOfA) ]
                                }
                            ]
                        ]
                    )
            assertEqualWithExplanation "" expect actual
        ]
    ]
  where
    fOfA, fOfB :: Ord (variable Object) => StepPattern Object variable
    fOfA = Mock.f Mock.a
    fOfB = Mock.f Mock.b

    gOfA, gOfB :: Ord (variable Object) => StepPattern Object variable
    gOfA = Mock.g Mock.a
    gOfB = Mock.g Mock.b

    aExpanded = Predicated
        { term = Mock.a
        , predicate = makeTruePredicate
        , substitution = mempty
        }
    bExpanded = Predicated
        { term = Mock.b
        , predicate = makeTruePredicate
        , substitution = mempty
        }
    cExpanded = Predicated
        { term = Mock.c
        , predicate = makeTruePredicate
        , substitution = mempty
        }
    dExpanded = Predicated
        { term = Mock.d
        , predicate = makeTruePredicate
        , substitution = mempty
        }

    gOfAExpanded :: Ord (variable Object) => ExpandedPattern Object variable
    gOfAExpanded = Predicated
        { term = gOfA
        , predicate = makeTruePredicate
        , substitution = mempty
        }

    mockMetadataTools =
        Mock.makeMetadataTools
            Mock.attributesMapping
            Mock.headTypeMapping
            Mock.sortAttributesMapping
            Mock.subsorts

    noSimplification
        ::  [   ( StepPattern level Variable
                , ([ExpandedPattern level Variable], SimplificationProof level)
                )
            ]
    noSimplification = []

simplificationEvaluator
    :: [BuiltinAndAxiomSimplifier Object]
    -> BuiltinAndAxiomSimplifier Object
simplificationEvaluator = firstFullEvaluation

makeApplication
    :: (MetaOrObject level, Ord (variable level), HasCallStack)
    => Sort level
    -> SymbolOrAlias level
    -> [[ExpandedPattern level variable]]
    -> CofreeF
        (Application level)
        (Valid (variable level) level)
        (OrOfExpandedPattern level variable)
makeApplication patternSort symbol patterns =
    (:<)
        valid
        Application
            { applicationSymbolOrAlias = symbol
            , applicationChildren = map MultiOr.make patterns
            }
  where
    valid = Valid { patternSort, freeVariables }
    expandedFreeVariables = (<$>) (Valid.freeVariables . extract . term)
    freeVariables =
        Set.unions (Set.unions . expandedFreeVariables <$> patterns)

evaluate
    ::  ( MetaOrObject level)
    => MetadataTools level StepperAttributes
    -> StepPatternSimplifier level
    -- ^ Evaluates functions.
    -> BuiltinAndAxiomSimplifierMap level
    -- ^ Map from axiom IDs to axiom evaluators
    -> CofreeF
        (Application level)
        (Valid (Variable level) level)
        (CommonOrOfExpandedPattern level)
    -> IO (CommonOrOfExpandedPattern level)
evaluate
    tools
    simplifier
    axiomIdToEvaluator
    application
  =
    (<$>) fst
    $ SMT.runSMT SMT.defaultConfig
    $ evalSimplifier emptyLogger
    $ simplify
        tools
        (Mock.substitutionSimplifier tools)
        simplifier
        axiomIdToEvaluator
        application
