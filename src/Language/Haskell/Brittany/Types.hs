{-# LANGUAGE DataKinds #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE BangPatterns #-}

module Language.Haskell.Brittany.Types
where



#include "prelude.inc"

import qualified Language.Haskell.GHC.ExactPrint as ExactPrint

import qualified Data.Text.Lazy.Builder as Text.Builder

import           RdrName ( RdrName(..) )
import           GHC ( runGhc, GenLocated(L), moduleNameString )
import           SrcLoc ( SrcSpan )

import           Language.Haskell.GHC.ExactPrint ( AnnKey, Comment )
import           Language.Haskell.GHC.ExactPrint.Types ( Anns, DeltaPos, mkAnnKey )

import           Language.Haskell.Brittany.Config.Types

import           Data.Generics.Uniplate.Direct as Uniplate



type PPM a = MultiRWSS.MultiRWS '[Config, ExactPrint.Anns] '[Text.Builder.Builder, [LayoutError], Seq String] '[] a

type PriorMap = Map AnnKey [(Comment, DeltaPos)]
type PostMap  = Map AnnKey [(Comment, DeltaPos)]

data LayoutState = LayoutState
  { _lstate_baseYs         :: [Int]
     -- ^ stack of number of current indentation columns
     -- (not number of indentations).
  , _lstate_curYOrAddNewline :: Either Int Int
             -- ^ Either:
             -- 1) number of chars in the current line.
             -- 2) number of newlines to be inserted before inserting any
             --    non-space elements.
  , _lstate_indLevels      :: [Int]
    -- ^ stack of current indentation levels. set for
    -- any layout-affected elements such as
    -- let/do/case/where elements.
    -- The main purpose of this member is to
    -- properly align comments, as their
    -- annotation positions are relative to the
    -- current layout indentation level.
  , _lstate_indLevelLinger :: Int -- like a "last" of indLevel. Used for
                                  -- properly treating cases where comments
                                  -- on the first indented element have an
                                  -- annotation offset relative to the last
                                  -- non-indented element, which is confusing.
  , _lstate_commentsPrior :: PriorMap -- map of "true" pre-node comments that
                                      -- really _should_ be included in the
                                      -- output.
  , _lstate_commentsPost  :: PostMap  -- similarly, for post-node comments.
  , _lstate_commentCol    :: Maybe Int -- this communicates two things:
                                       -- firstly, that cursor is currently
                                       -- at the end of a comment (so needs
                                       -- newline before any actual content).
                                       -- secondly, the column at which
                                       -- insertion of comments started.
  , _lstate_addSepSpace   :: Maybe Int -- number of spaces to insert if anyone
                                       -- writes (any non-spaces) in the
                                       -- current line.
  , _lstate_inhibitMTEL   :: Bool
      -- ^ inhibit move-to-exact-location.
      -- normally, processing a node's annotation involves moving to the exact
      -- (vertical) location of the node. this ensures that newlines in the
      -- input are retained in the output.
      -- While this flag is on, this behaviour will be disabled.
      -- The flag is automatically turned off when inserting any kind of
      -- newline.
  -- , _lstate_isNewline     :: NewLineState
  --     -- captures if the layouter currently is in a new line, i.e. if the
  --     -- current line only contains (indentation) spaces.
  }

lstate_baseY :: LayoutState -> Int
lstate_baseY = head . _lstate_baseYs

lstate_indLevel :: LayoutState -> Int
lstate_indLevel = head . _lstate_indLevels

-- evil, incomplete Show instance; only for debugging.
instance Show LayoutState where
  show state =
    "LayoutState"
    ++ "{baseYs=" ++ show (_lstate_baseYs state)
    ++ ",curYOrAddNewline=" ++ show (_lstate_curYOrAddNewline state)
    ++ ",indLevels=" ++ show (_lstate_indLevels state)
    ++ ",indLevelLinger=" ++ show (_lstate_indLevelLinger state)
    ++ ",commentCol=" ++ show (_lstate_commentCol state)
    ++ ",addSepSpace=" ++ show (_lstate_addSepSpace state)
    ++ ",inhibitMTEL=" ++ show (_lstate_inhibitMTEL state)
    ++ "}"

-- data NewLineState = NewLineStateInit -- initial state. we do not know if in a
--                                      -- newline, really. by special-casing
--                                      -- this we can appropriately handle it
--                                      -- differently at use-site.
--                   | NewLineStateYes
--                   | NewLineStateNo
--   deriving Eq

-- data LayoutSettings = LayoutSettings
--   { _lsettings_cols :: Int -- the thing that has default 80.
--   , _lsettings_indentPolicy :: IndentPolicy
--   , _lsettings_indentAmount :: Int
--   , _lsettings_indentWhereSpecial :: Bool -- indent where only 1 sometimes (TODO).
--   , _lsettings_indentListSpecial  :: Bool -- use some special indentation for ","
--                                           -- when creating zero-indentation
--                                           -- multi-line list literals.
--   , _lsettings_importColumn :: Int
--   , _lsettings_initialAnns :: ExactPrint.Anns
--   }

data LayoutError = LayoutErrorUnusedComment String
                 | LayoutWarning String
                 | forall ast . Data.Data.Data ast => LayoutErrorUnknownNode String ast

data BriSpacing = BriSpacing
  { _bs_spacePastLineIndent :: Int -- space in the current,
                                   -- potentially somewhat filled
                                   -- line.
  , _bs_spacePastIndent :: Int     -- space required in properly
                                   -- indented blocks below the
                                   -- current line.
  }

data ColSig
  = ColTyOpPrefix
    -- any prefixed operator/paren/"::"/..
    -- expected to have exactly two colums.
    -- e.g. ":: foo"
    --       111222
    --      "-> bar asd asd"
    --       11122222222222
  | ColPatternsFuncPrefix
    -- pattern-part of the lhs, e.g. "func (foo a b) c _".
    -- Has variable number of columns depending on the number of patterns.
  | ColPatternsFuncInfix
    -- pattern-part of the lhs, e.g. "Foo a <> Foo b".
    -- Has variable number of columns depending on the number of patterns.
  | ColPatterns
  | ColCasePattern
  | ColBindingLine
    -- e.g. "func pat pat = expr"
    --       1111111111111222222
    -- or   "pat | stmt -> expr"
    --       111111111112222222
    -- expected to have exactly two columns.
  | ColGuard
    -- e.g. "func pat pat | cond = ..."
    --       11111111111112222222
    -- or   "pat | cond1, cond2 -> ..."
    --       1111222222222222222
    -- expected to have exactly two columns
  | ColBindStmt
  | ColDoLet -- the non-indented variant
  | ColRecUpdate
  | ColListComp
  | ColList
  | ColApp
  | ColOpPrefix -- merge with ColList ? other stuff?

  -- TODO
  deriving (Eq, Ord, Data.Data.Data, Show)

data BrIndent = BrIndentNone
              | BrIndentRegular
              | BrIndentSpecial Int
  deriving (Eq, Ord, Typeable, Data.Data.Data, Show)

type ToBriDocM = MultiRWSS.MultiRWS '[Config, Anns] '[[LayoutError], Seq String] '[NodeAllocIndex]

type ToBriDoc (sym :: * -> *) = GenLocated SrcSpan (sym RdrName) -> ToBriDocM BriDocNumbered
type ToBriDoc' sym            = GenLocated SrcSpan sym           -> ToBriDocM BriDocNumbered
type ToBriDocC sym c          = GenLocated SrcSpan sym           -> ToBriDocM c

data DocMultiLine
  = MultiLineNo
  | MultiLinePossible
  deriving (Eq, Typeable)

-- isomorphic to BriDocF Identity. Provided for ease of use, as we do a lot
-- of transformations on `BriDocF Identity`s and it is really annoying to
-- `Identity`/`runIdentity` everywhere.
data BriDoc
  = -- BDWrapAnnKey AnnKey BriDoc
    BDEmpty
  | BDLit !Text
  | BDSeq [BriDoc] -- elements other than the last should
                   -- not contains BDPars.
  | BDCols ColSig [BriDoc] -- elements other than the last
                         -- should not contains BDPars
  | BDSeparator -- semantically, space-unless-at-end-of-line.
  | BDAddBaseY BrIndent BriDoc
  | BDBaseYPushCur BriDoc
  | BDBaseYPop BriDoc
  | BDIndentLevelPushCur BriDoc
  | BDIndentLevelPop BriDoc
  | BDPar
    { _bdpar_indent :: BrIndent
    , _bdpar_restOfLine :: BriDoc -- should not contain other BDPars
    , _bdpar_indented :: BriDoc
    }
  -- | BDAddIndent BrIndent (BriDocF f)
  -- | BDNewline
  | BDAlt [BriDoc]
  | BDForceMultiline BriDoc
  | BDForceSingleline BriDoc
  | BDForwardLineMode BriDoc
  | BDExternal AnnKey
               (Set AnnKey) -- set of annkeys contained within the node
                            -- to be printed via exactprint
               Bool -- should print extra comment ?
               Text
  | BDAnnotationPrior AnnKey BriDoc
  | BDAnnotationPost  AnnKey BriDoc
  | BDLines [BriDoc]
  | BDEnsureIndent BrIndent BriDoc
  | BDNonBottomSpacing BriDoc
  | BDProhibitMTEL BriDoc -- move to exact location
                          -- TODO: this constructor is deprecated. should
                          --       still work, but i should probably completely
                          --       remove it, as i have no proper usecase for
                          --       it anymore.
  deriving (Data.Data.Data, Eq, Ord)

data BriDocF f
  = -- BDWrapAnnKey AnnKey BriDoc
    BDFEmpty
  | BDFLit !Text
  | BDFSeq [f (BriDocF f)] -- elements other than the last should
                   -- not contains BDPars.
  | BDFCols ColSig [f (BriDocF f)] -- elements other than the last
                         -- should not contains BDPars
  | BDFSeparator -- semantically, space-unless-at-end-of-line.
  | BDFAddBaseY BrIndent (f (BriDocF f))
  | BDFBaseYPushCur (f (BriDocF f))
  | BDFBaseYPop (f (BriDocF f))
  | BDFIndentLevelPushCur (f (BriDocF f))
  | BDFIndentLevelPop (f (BriDocF f))
  | BDFPar
    { _bdfpar_indent :: BrIndent
    , _bdfpar_restOfLine :: f (BriDocF f) -- should not contain other BDPars
    , _bdfpar_indented :: f (BriDocF f)
    }
  -- | BDAddIndent BrIndent (BriDocF f)
  -- | BDNewline
  | BDFAlt [f (BriDocF f)]
  | BDFForceMultiline (f (BriDocF f))
  | BDFForceSingleline (f (BriDocF f))
  | BDFForwardLineMode (f (BriDocF f))
  | BDFExternal AnnKey
               (Set AnnKey) -- set of annkeys contained within the node
                            -- to be printed via exactprint
               Bool -- should print extra comment ?
               Text
  | BDFAnnotationPrior AnnKey (f (BriDocF f))
  | BDFAnnotationPost  AnnKey (f (BriDocF f))
  | BDFLines [(f (BriDocF f))]
  | BDFEnsureIndent BrIndent (f (BriDocF f))
  | BDFNonBottomSpacing (f (BriDocF f))
  | BDFProhibitMTEL (f (BriDocF f)) -- move to exact location
                          -- TODO: this constructor is deprecated. should
                          --       still work, but i should probably completely
                          --       remove it, as i have no proper usecase for
                          --       it anymore.

-- deriving instance Data.Data.Data (BriDocF Identity)
deriving instance Data.Data.Data (BriDocF ((,) Int))

type BriDocFInt = BriDocF ((,) Int)
type BriDocNumbered = (Int, BriDocFInt)

instance Uniplate.Uniplate BriDoc where
  uniplate x@BDEmpty{}                   = plate x
  uniplate x@BDLit{}                     = plate x
  uniplate (BDSeq list)                  = plate BDSeq ||* list
  uniplate (BDCols sig list)             = plate BDCols |- sig ||* list
  uniplate x@BDSeparator                 = plate x
  uniplate (BDAddBaseY ind bd)           = plate BDAddBaseY |- ind |* bd
  uniplate (BDBaseYPushCur bd)           = plate BDBaseYPushCur |* bd
  uniplate (BDBaseYPop bd)               = plate BDBaseYPop |* bd
  uniplate (BDIndentLevelPushCur bd)     = plate BDIndentLevelPushCur |* bd
  uniplate (BDIndentLevelPop bd)         = plate BDIndentLevelPop |* bd
  uniplate (BDPar ind line indented)     = plate BDPar |- ind |* line |* indented
  uniplate (BDAlt alts)                  = plate BDAlt ||* alts
  uniplate (BDForceMultiline  bd)        = plate BDForceMultiline |* bd
  uniplate (BDForceSingleline bd)        = plate BDForceSingleline |* bd
  uniplate (BDForwardLineMode bd)        = plate BDForwardLineMode |* bd
  uniplate x@BDExternal{}                = plate x
  uniplate (BDAnnotationPrior annKey bd) = plate BDAnnotationPrior |- annKey |* bd
  uniplate (BDAnnotationPost  annKey bd) = plate BDAnnotationPost  |- annKey |* bd
  uniplate (BDLines lines)               = plate BDLines ||* lines
  uniplate (BDEnsureIndent ind bd)       = plate BDEnsureIndent |- ind |* bd
  uniplate (BDNonBottomSpacing bd)       = plate BDNonBottomSpacing |* bd
  uniplate (BDProhibitMTEL bd)           = plate BDProhibitMTEL |* bd

newtype NodeAllocIndex = NodeAllocIndex Int

unwrapBriDocNumbered :: BriDocNumbered -> BriDoc
unwrapBriDocNumbered = snd .> \case
  BDFEmpty -> BDEmpty
  BDFLit t -> BDLit t
  BDFSeq list -> BDSeq $ rec <$> list
  BDFCols sig list -> BDCols sig $ rec <$> list
  BDFSeparator -> BDSeparator
  BDFAddBaseY ind bd -> BDAddBaseY ind $ rec bd
  BDFBaseYPushCur bd -> BDBaseYPushCur $ rec bd
  BDFBaseYPop bd -> BDBaseYPop $ rec bd
  BDFIndentLevelPushCur bd -> BDIndentLevelPushCur $ rec bd
  BDFIndentLevelPop bd -> BDIndentLevelPop $ rec bd
  BDFPar ind line indented -> BDPar ind (rec line) (rec indented)
  BDFAlt alts -> BDAlt $ rec <$> alts -- not that this will happen
  BDFForceMultiline  bd -> BDForceMultiline $ rec bd
  BDFForceSingleline bd -> BDForceSingleline $ rec bd
  BDFForwardLineMode bd -> BDForwardLineMode $ rec bd
  BDFExternal k ks c t -> BDExternal k ks c t
  BDFAnnotationPrior annKey bd -> BDAnnotationPrior annKey $ rec bd
  BDFAnnotationPost  annKey bd -> BDAnnotationPost  annKey $ rec bd
  BDFLines lines -> BDLines $ rec <$> lines
  BDFEnsureIndent ind bd -> BDEnsureIndent ind $ rec bd
  BDFNonBottomSpacing bd -> BDNonBottomSpacing $ rec bd
  BDFProhibitMTEL bd -> BDProhibitMTEL $ rec bd
 where
  rec = unwrapBriDocNumbered

briDocSeqSpine :: BriDoc -> ()
briDocSeqSpine = \case
  BDEmpty -> ()
  BDLit _t -> ()
  BDSeq list      -> foldl' ((briDocSeqSpine .) . seq) () list
  BDCols _sig list -> foldl' ((briDocSeqSpine .) . seq) () list
  BDSeparator -> ()
  BDAddBaseY _ind bd -> briDocSeqSpine bd
  BDBaseYPushCur bd     -> briDocSeqSpine bd
  BDBaseYPop bd     -> briDocSeqSpine bd
  BDIndentLevelPushCur bd -> briDocSeqSpine bd
  BDIndentLevelPop bd -> briDocSeqSpine bd
  BDPar _ind line indented -> briDocSeqSpine line `seq` briDocSeqSpine indented
  BDAlt alts -> foldl' (\(!()) -> briDocSeqSpine) () alts
  BDForceMultiline  bd -> briDocSeqSpine bd
  BDForceSingleline bd -> briDocSeqSpine bd
  BDForwardLineMode bd -> briDocSeqSpine bd
  BDExternal{} -> ()
  BDAnnotationPrior _annKey bd -> briDocSeqSpine bd
  BDAnnotationPost  _annKey bd -> briDocSeqSpine bd
  BDLines lines -> foldl' (\(!()) -> briDocSeqSpine) () lines
  BDEnsureIndent _ind bd -> briDocSeqSpine bd
  BDNonBottomSpacing bd -> briDocSeqSpine bd
  BDProhibitMTEL bd -> briDocSeqSpine bd

briDocForceSpine :: BriDoc -> BriDoc
briDocForceSpine bd = briDocSeqSpine bd `seq` bd


data VerticalSpacingPar
  = VerticalSpacingParNone -- no indented lines
  | VerticalSpacingParSome Int -- indented lines, requiring this much vertical
                               -- space at most
  | VerticalSpacingParNonBottom -- indented lines, with an unknown amount of
                                -- space required. parents should consider this
                                -- as a valid option, but provide as much space
                                -- as possible.
  deriving (Eq, Show)

data VerticalSpacing
  = VerticalSpacing
    { _vs_sameLine  :: !Int
    , _vs_paragraph :: !VerticalSpacingPar
    }
  deriving Show

newtype LineModeValidity a = LineModeValidity (Strict.Maybe a)
  deriving (Functor, Applicative, Monad, Show, Alternative)

pattern LineModeValid :: forall t. t -> LineModeValidity t
pattern LineModeValid x = LineModeValidity (Strict.Just x) :: LineModeValidity t
pattern LineModeInvalid :: forall t. LineModeValidity t
pattern LineModeInvalid = LineModeValidity Strict.Nothing :: LineModeValidity t
