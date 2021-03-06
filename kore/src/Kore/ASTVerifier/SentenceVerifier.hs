{-|
Module      : Kore.ASTVerifier.SentenceVerifier
Description : Tools for verifying the wellformedness of a Kore 'Sentence'.
Copyright   : (c) Runtime Verification, 2018
License     : NCSA
Maintainer  : virgil.serbanuta@runtimeverification.com
Stability   : experimental
Portability : POSIX
-}
module Kore.ASTVerifier.SentenceVerifier
    ( verifyUniqueNames
    , verifySentences
    ) where

import           Control.Monad
                 ( foldM )
import qualified Data.Map as Map
import qualified Data.Set as Set
import           Data.Text
                 ( Text )
import qualified Data.Text as Text

import           Kore.AST.Error
import           Kore.AST.Kore
import           Kore.AST.Sentence
import           Kore.ASTVerifier.AttributesVerifier
import           Kore.ASTVerifier.Error
import           Kore.ASTVerifier.PatternVerifier as PatternVerifier
import           Kore.ASTVerifier.SortVerifier
import qualified Kore.Attribute.Parser as Attribute.Parser
import qualified Kore.Builtin as Builtin
import           Kore.Error
import           Kore.IndexedModule.IndexedModule
import           Kore.IndexedModule.Resolvers

{-|'verifyUniqueNames' verifies that names defined in a list of sentences are
unique both within the list and outside, using the provided name set.
-}
verifyUniqueNames
    :: [UnifiedSentence param pat]
    -> Map.Map Text AstLocation
    -- ^ Names that are already defined.
    -> Either (Error VerifyError) (Map.Map Text AstLocation)
    -- ^ On success returns the names that were previously defined together with
    -- the names defined in the given 'Module'.
verifyUniqueNames sentences existingNames =
    foldM verifyUniqueId existingNames definedNames
  where
    definedNames =
        concatMap definedNamesForSentence sentences

data UnparameterizedId = UnparameterizedId
    { unparameterizedIdName     :: String
    , unparameterizedIdLocation :: AstLocation
    }
    deriving (Show)


toUnparameterizedId :: Id level -> UnparameterizedId
toUnparameterizedId Id {getId = name, idLocation = location} =
    UnparameterizedId
        { unparameterizedIdName = Text.unpack name
        , unparameterizedIdLocation = location
        }

verifyUniqueId
    :: Map.Map Text AstLocation
    -> UnparameterizedId
    -> Either (Error VerifyError) (Map.Map Text AstLocation)
verifyUniqueId existing (UnparameterizedId name location) =
    case Map.lookup name' existing of
        Just location' ->
            koreFailWithLocations [location, location']
                ("Duplicated name: '" ++ name ++ "'.")
        _ -> Right (Map.insert name' location existing)
  where
    name' = Text.pack name

definedNamesForSentence :: UnifiedSentence param pat -> [UnparameterizedId]
definedNamesForSentence =
    applyUnifiedSentence
        definedNamesForObjectSentence
        definedNamesForObjectSentence

definedNamesForObjectSentence
    :: Sentence Object param pat -> [UnparameterizedId]
definedNamesForObjectSentence (SentenceAliasSentence sentenceAlias) =
    [ toUnparameterizedId (getSentenceSymbolOrAliasConstructor sentenceAlias) ]
definedNamesForObjectSentence (SentenceSymbolSentence sentenceSymbol) =
    [ toUnparameterizedId (getSentenceSymbolOrAliasConstructor sentenceSymbol) ]
definedNamesForObjectSentence (SentenceImportSentence _) = []
definedNamesForObjectSentence (SentenceAxiomSentence _)  = []
definedNamesForObjectSentence (SentenceClaimSentence _)  = []
definedNamesForObjectSentence (SentenceSortSentence sentenceSort) =
    [ toUnparameterizedId (sentenceSortName sentenceSort) ]
definedNamesForObjectSentence (SentenceHookSentence (SentenceHookedSort sentence))
  = definedNamesForObjectSentence (SentenceSortSentence sentence)
definedNamesForObjectSentence (SentenceHookSentence (SentenceHookedSymbol sentence))
  = definedNamesForObjectSentence (SentenceSymbolSentence sentence)

{-|'verifySentences' verifies the welformedness of a list of Kore 'Sentence's.
-}
verifySentences
    :: KoreIndexedModule declAtts axiomAtts
    -- ^ The module containing all definitions which are visible in this
    -- pattern.
    -> AttributesVerification declAtts axiomAtts
    -> Builtin.Verifiers
    -> [KoreSentence]
    -> Either (Error VerifyError) [VerifiedKoreSentence]
verifySentences indexedModule attributesVerification builtinVerifiers =
    traverse
        (verifySentence
            builtinVerifiers
            indexedModule
            attributesVerification
        )

verifySentence
    :: Builtin.Verifiers
    -> KoreIndexedModule declAtts axiomAtts
    -> AttributesVerification declAtts axiomAtts
    -> KoreSentence
    -> Either (Error VerifyError) VerifiedKoreSentence
verifySentence builtinVerifiers indexedModule attributesVerification =
    applyUnifiedSentence
        (verifyObjectSentence
            builtinVerifiers
            indexedModule
            attributesVerification
        )
        (verifyObjectSentence
            builtinVerifiers
            indexedModule
            attributesVerification
        )

verifyObjectSentence
    :: Builtin.Verifiers
    -> KoreIndexedModule declAtts axiomAtts
    -> AttributesVerification declAtts axiomAtts
    -> Sentence Object UnifiedSortVariable CommonKorePattern
    -> Either (Error VerifyError) VerifiedKoreSentence
verifyObjectSentence
    builtinVerifiers
    indexedModule
    attributesVerification
    sentence
  =
    withSentenceContext sentence (UnifiedObjectSentence <$> verifyObjectSentence0)
  where
    verifyObjectSentence0
        :: Either
            (Error VerifyError)
            (Sentence Meta UnifiedSortVariable VerifiedKorePattern)
    verifyObjectSentence0 = do
        verified <-
            case sentence of
                SentenceSymbolSentence symbolSentence ->
                    (<$>)
                        SentenceSymbolSentence
                        (verifySymbolSentence
                            indexedModule
                            symbolSentence
                        )
                SentenceAliasSentence aliasSentence ->
                    (<$>)
                        SentenceAliasSentence
                        (verifyAliasSentence
                            builtinVerifiers
                            indexedModule
                            aliasSentence
                        )
                SentenceAxiomSentence axiomSentence ->
                    (<$>)
                        SentenceAxiomSentence
                        (verifyAxiomSentence
                            axiomSentence
                            builtinVerifiers
                            indexedModule
                        )
                SentenceClaimSentence claimSentence ->
                    (<$>)
                        SentenceClaimSentence
                        (verifyAxiomSentence
                            claimSentence
                            builtinVerifiers
                            indexedModule
                        )
                SentenceImportSentence importSentence ->
                    -- Since we have an IndexedModule, we assume that imports
                    -- were already resolved, so there is nothing left to verify
                    -- here.
                    (<$>)
                        SentenceImportSentence
                        (traverse verifyNoPatterns importSentence)
                SentenceSortSentence sortSentence ->
                    (<$>)
                        SentenceSortSentence
                        (verifySortSentence sortSentence)
                SentenceHookSentence hookSentence ->
                    (<$>)
                        SentenceHookSentence
                        (verifyHookSentence
                            builtinVerifiers
                            indexedModule
                            attributesVerification
                            hookSentence
                        )
        verifySentenceAttributes
            attributesVerification
            sentence
        return verified

verifySentenceAttributes
    :: AttributesVerification declAtts axiomAtts
    -> Sentence level UnifiedSortVariable CommonKorePattern
    -> Either (Error VerifyError) VerifySuccess
verifySentenceAttributes attributesVerification sentence =
    do
        let attributes = sentenceAttributes sentence
        verifyAttributes attributes attributesVerification
        case sentence of
            SentenceHookSentence _ -> return ()
            _ -> verifyNoHookAttribute attributesVerification attributes
        verifySuccess

verifyHookSentence
    :: Builtin.Verifiers
    -> KoreIndexedModule declAtts axiomAtts
    -> AttributesVerification declAtts axiomAtts
    -> SentenceHook CommonKorePattern
    -> Either (Error VerifyError) (SentenceHook VerifiedKorePattern)
verifyHookSentence
    builtinVerifiers
    indexedModule
    attributesVerification
  =
    \case
        SentenceHookedSort s -> SentenceHookedSort <$> verifyHookedSort s
        SentenceHookedSymbol s -> SentenceHookedSymbol <$> verifyHookedSymbol s
  where
    verifyHookedSort
        sentence@SentenceSort { sentenceSortAttributes }
      = do
        verified <- verifySortSentence sentence
        hook <-
            verifySortHookAttribute
                indexedModule
                attributesVerification
                sentenceSortAttributes
        attrs <-
            Attribute.Parser.liftParser
            $ Attribute.Parser.parseAttributes sentenceSortAttributes
        Builtin.sortDeclVerifier
            builtinVerifiers
            hook
            (makeIndexedModuleAttributesNull indexedModule)
            sentence
            attrs
        return verified

    verifyHookedSymbol
        sentence@SentenceSymbol { sentenceSymbolAttributes }
      = do
        verified <- verifySymbolSentence indexedModule sentence
        hook <-
            verifySymbolHookAttribute
                attributesVerification
                sentenceSymbolAttributes
        Builtin.symbolVerifier builtinVerifiers hook findSort sentence
        return verified

    findSort = findIndexedSort indexedModule

verifySymbolSentence
    :: (MetaOrObject level)
    => KoreIndexedModule declAtts axiomAtts
    -> KoreSentenceSymbol level
    -> Either (Error VerifyError) (VerifiedKoreSentenceSymbol level)
verifySymbolSentence indexedModule sentence =
    do
        variables <- buildDeclaredSortVariables sortParams
        mapM_
            (verifySort findSort variables)
            (sentenceSymbolSorts sentence)
        verifySort
            findSort
            variables
            (sentenceSymbolResultSort sentence)
        traverse verifyNoPatterns sentence
  where
    findSort = findIndexedSort indexedModule
    sortParams = (symbolParams . sentenceSymbolSymbol) sentence

verifyAliasSentence
    :: (MetaOrObject level)
    => Builtin.Verifiers
    -> KoreIndexedModule declAtts axiomAtts
    -> KoreSentenceAlias level
    -> Either (Error VerifyError) (VerifiedKoreSentenceAlias level)
verifyAliasSentence builtinVerifiers indexedModule sentence =
    do
        variables <- buildDeclaredSortVariables sortParams
        mapM_ (verifySort findSort variables) sentenceAliasSorts
        verifySort findSort variables sentenceAliasResultSort
        let context =
                PatternVerifier.Context
                    { builtinDomainValueVerifiers =
                        Builtin.domainValueVerifiers builtinVerifiers
                    , indexedModule =
                        makeIndexedModuleAttributesNull indexedModule
                    , declaredSortVariables = variables
                    , declaredVariables = emptyDeclaredVariables
                    }
        runPatternVerifier context $ do
            (declaredVariables, verifiedLeftPattern) <-
                verifyAliasLeftPattern leftPattern
            verifiedRightPattern <-
                withDeclaredVariables declaredVariables
                $ verifyPattern (Just expectedSort) rightPattern
            return sentence
                { sentenceAliasLeftPattern = verifiedLeftPattern
                , sentenceAliasRightPattern = verifiedRightPattern
                }
  where
    SentenceAlias { sentenceAliasLeftPattern = leftPattern } = sentence
    SentenceAlias { sentenceAliasRightPattern = rightPattern } = sentence
    SentenceAlias { sentenceAliasSorts } = sentence
    SentenceAlias { sentenceAliasResultSort } = sentence
    findSort         = findIndexedSort indexedModule
    sortParams       = (aliasParams . sentenceAliasAlias) sentence
    expectedSort = asUnified sentenceAliasResultSort

verifyAxiomSentence
    :: KoreSentenceAxiom
    -> Builtin.Verifiers
    -> KoreIndexedModule declAtts axiomAtts
    -> Either (Error VerifyError) VerifiedKoreSentenceAxiom
verifyAxiomSentence axiom builtinVerifiers indexedModule =
    do
        variables <-
            buildDeclaredUnifiedSortVariables
                (sentenceAxiomParameters axiom)
        let context =
                PatternVerifier.Context
                    { builtinDomainValueVerifiers =
                        Builtin.domainValueVerifiers builtinVerifiers
                    , indexedModule =
                        makeIndexedModuleAttributesNull indexedModule
                    , declaredSortVariables = variables
                    , declaredVariables = emptyDeclaredVariables
                    }
        verifiedAxiomPattern <- runPatternVerifier context $ do
            verifyStandalonePattern Nothing sentenceAxiomPattern
        return axiom { sentenceAxiomPattern = verifiedAxiomPattern }
  where
    SentenceAxiom { sentenceAxiomPattern } = axiom

verifySortSentence
    :: KoreSentenceSort Object
    -> Either (Error VerifyError) (VerifiedKoreSentenceSort Object)
verifySortSentence sentenceSort = do
    _ <- buildDeclaredSortVariables (sentenceSortParameters sentenceSort)
    traverse verifyNoPatterns sentenceSort

buildDeclaredSortVariables
    :: MetaOrObject level
    => [SortVariable level]
    -> Either (Error VerifyError) (Set.Set UnifiedSortVariable)
buildDeclaredSortVariables variables =
    buildDeclaredUnifiedSortVariables
        (map asUnified variables)

buildDeclaredUnifiedSortVariables
    :: [UnifiedSortVariable]
    -> Either (Error VerifyError) (Set.Set UnifiedSortVariable)
buildDeclaredUnifiedSortVariables [] = Right Set.empty
buildDeclaredUnifiedSortVariables (unifiedVariable : list) = do
    variables <- buildDeclaredUnifiedSortVariables list
    koreFailWithLocationsWhen
        (unifiedVariable `Set.member` variables)
        [unifiedVariable]
        (  "Duplicated sort variable: '"
        ++ extractVariableName unifiedVariable
        ++ "'.")
    return (Set.insert unifiedVariable variables)
  where
    extractVariableName (UnifiedObject variable) =
        getIdForError (getSortVariable variable)
