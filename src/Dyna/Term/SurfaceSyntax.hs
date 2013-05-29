---------------------------------------------------------------------------
-- | Things common to surface syntax representation of terms that are used
-- by several stages of the pipeline.

-- Header material                                                      {{{
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}

module Dyna.Term.SurfaceSyntax where

import qualified Data.ByteString.UTF8       as BU
import qualified Data.Char                  as C
import qualified Data.Map                   as M
import           Dyna.Term.TTerm

------------------------------------------------------------------------}}}
-- Keywords                                                             {{{

-- These are defined here rather than being implicit in Dyna.Analysis.ANF.
--
-- If we ever revisit the structure of rules, cross-ref XREF:ANFRESERVED and
-- maybe move all of this into the parser proper.

dynaEvalOper  = "*"
dynaQuoteOper = "&"
dynaEvalAssignOper = "is"
dynaConjOper = ","
dynaRevConjOpers = ["whenever","for"]
dynaUnitTerm = "true"

------------------------------------------------------------------------}}}
-- Evaluation Disposition                                               {{{
-- Definition                                                           {{{

data SelfDispos = SDInherit
                | SDEval
                | SDQuote
 deriving (Eq,Show)

data ArgDispos = ADEval
               | ADQuote
 deriving (Eq,Show)

type DisposTabOver = M.Map DFunctAr (SelfDispos,[ArgDispos])

data DisposTab = DisposTab
               { dt_selfEvalDispos :: DFunctAr -> SelfDispos
               , dt_argEvalDispos  :: DFunctAr -> [ArgDispos]
               }

------------------------------------------------------------------------}}}
-- Functions                                                            {{{

dtoMerge :: DFunctAr
         -> (SelfDispos,[ArgDispos])
         -> DisposTabOver
         -> DisposTabOver
dtoMerge = M.insert
{-# INLINE dtoMerge #-}

------------------------------------------------------------------------}}}
-- Defaults                                                             {{{

-- | Make the default surface syntax look like a kind of prolog with funny
-- operators.  In particular all initial-alphanumeric functors inherit and
-- prefer to /quote/ their arguments, while initial-symbolic functors
-- request their own evaluation and the evaluation of their arguments.
--
-- Notably, TimV seems to prefer this syntax.
disposTab_prologish :: DisposTabOver -> DisposTab
disposTab_prologish t = DisposTab s a
 where
  s :: (DFunct, Int) -> SelfDispos
  s fa = maybe (maybe def fst $ M.lookup fa dt) fst $ M.lookup fa t
   where
    def = let (name,_) = fa
          in maybe SDEval id $ fmap test $ BU.uncons name
    test (x,_) = if C.isAlphaNum x then SDInherit else SDEval

  a :: (DFunct, Int) -> [ArgDispos]
  a fa = maybe (maybe def snd $ M.lookup fa dt) snd $ M.lookup fa t
   where
    def = let (name,arity) = fa
          in take arity $ repeat
           $ maybe ADEval id $ fmap test $ BU.uncons name
    test (x,_) = if C.isAlphaNum x then ADQuote else ADEval

  -- A built-in set of defaults, used if we miss the user-provided table
  -- but before we fall-back to the default rules.
  dt = M.fromList [
       -- math
         (("abs"  ,1),(SDEval,[ADEval]))
       , (("exp"  ,1),(SDEval,[ADEval]))
       , (("log"  ,1),(SDEval,[ADEval]))
       , (("mod"  ,2),(SDEval,[ADEval,ADEval]))
       -- logic
       , (("="    ,2),(SDEval,[ADQuote,ADQuote]))
       , (("and"  ,2),(SDEval,[ADEval, ADEval]))
       , (("or"   ,2),(SDEval,[ADEval, ADEval]))
       , (("not"  ,1),(SDEval,[ADEval]))
       -- structure
       , (("eval" ,1),(SDEval,[ADEval]))
       , (("pair" ,2),(SDQuote,[ADEval,ADEval]))
       , (("true" ,0),(SDQuote,[]))
       , (("false",0),(SDQuote,[]))
       ]

-- | Make the default surface syntax more functional.  Here, all functors
-- inherit their self disposition from context and always prefer to evaluate
-- their arguments.
disposTab_dyna :: DisposTabOver -> DisposTab
disposTab_dyna t = DisposTab s a
 where
  s :: (DFunct, Int) -> SelfDispos
  s fa = maybe (maybe SDInherit fst $ M.lookup fa dt) fst $ M.lookup fa t

  a :: (DFunct, Int) -> [ArgDispos]
  a fa@(_,arity) = maybe (maybe def snd $ M.lookup fa dt) snd $ M.lookup fa t
   where
    def = take arity $ repeat ADEval

  -- There are, however, even in this case a few terms we would prefer to
  -- behave structurally by default.
  dt = M.fromList [
         (("pair" ,2),(SDQuote,[ADEval,ADEval]))
       , (("true" ,0),(SDQuote,[]))
       , (("false",0),(SDQuote,[]))
       ]

------------------------------------------------------------------------}}}
------------------------------------------------------------------------}}}