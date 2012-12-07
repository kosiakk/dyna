---------------------------------------------------------------------------
-- | Some simple analysis to move to ANF.
--
-- In Dyna's surface syntax, there exists both \"in-place evaluation\" and
-- \"in-place construction\".  How do we deal with this?  Well, it's a
-- little messy.
--
--   1. There are explicit \"eval\" (@*@) and \"quote\" (@&@) operators
--   which may be used to manually specify which is intended.
--
--   2. Functors specify \"argument dispositions\", indicating whether they
--   prefer to evaluate or build structure in each argument position.
--
--   3. Functors further specify \"self disposition\", indicating whether
--   they 1) leave the decision to the parent, 2) prefer to build structure
--   unless explicitly evaluated, or 3) prefer to be evaluated unless
--   explicitly quoted.
--
-- In short, explicit marks are always obeyed; absent one, the functor's
-- self disposition is obeyed; if the functor has no preference, the outer
-- functor's argument disposition is used as a last resort.  There is,
-- however, one important caveat: /variables/ and /primitive terms/ (e.g.
-- numerics, strings, literal dynabases, foreign terms, ...) have self
-- dispositions of preferring structural interpretation.  Variables may be
-- meaningfully explicitly evaluated, with the effect of evaluating their
-- bindings.  Attempting to evaluate a primitive is an error.
--
-- Note that in rules, the head is by default not evaluated (regardless of
-- the disposition of their outer functor), while the body is interpreted as
-- a term expression (or list of term expressions) to be evaluated.
--
-- XXX This is really quite simplistic and is probably a far cry from where
-- we need to end up.  Especially of note is that we do not yet parse any
-- sort of pragmas for augmenting our disposition list.
--
-- XXX The handling for "is/2" is probably wrong.  Right now it's not
-- special at all, but every Dyna program is defined to include
-- @is(X,Y) :- X = *Y.@.  Is that something we should be normalizing out
-- here or should be waiting for some further unfolding optimization phase?

-- FIXME: "str" is the same a constant str.

-- TODO: ANF Normalizer should return *flat terms* so that we have type-safety
-- can a lint checker can verify we have exhaustive pattern matching... etc.

--     timv: should there ever be more than one side condition? shouldn't it be
--     a single result variable after normalization? I see that if I use comma
--     to combine my conditions I get mutliple variables but should side
--     condtions be combined with comma? I was under the impression that we
--     always want strong Boolean values (i.e. none of that three-values null
--     stuff).
--
--     it might be nice if terms came in with a type that verified that they are
--     "flat term" -- they've been normalized.
--
--     It would also be nice if spans were killed... maybe there is an argument
--     against this.
--
--     ANF Rule, `result` always the name of a variable -- it would be nice for
--     its type were string in that case. Similarly, side conditions are always
--     variables.
--


-- Header material                                                      {{{
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}

module Dyna.Analysis.ANF (
    ANFState(..), NT, FDT, ENT, EVF, FDR, 
    normTerm, normRule, runNormalize, printANF
) where

import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Unification
import qualified Data.ByteString.UTF8       as BU
import qualified Data.ByteString            as B
import qualified Data.Map                   as M
import           Text.PrettyPrint.Free
import qualified Text.Trifecta              as T

import qualified Dyna.ParserHS.Parser       as P
import           Dyna.Term.TTerm
import           Dyna.XXX.PPrint (valign)
-- import           Dyna.Test.Trifecta         -- XXX

import qualified Data.Char as C

------------------------------------------------------------------------}}}
-- Preliminaries                                                        {{{

data SelfDispos = SDInherit
                | SDEval
                | SDQuote

data ArgDispos = ADEval
               | ADQuote

data ECSrc = ECFunctor
           | ECExplicit

type EvalCtx = (ECSrc,ArgDispos)

data ANFDict = AD
  { -- | A map from (functor,arity) to a list of bits indicating whether to
    -- (True) or not to (False) evaluate that positional argument.
    --
    -- XXX This isn't going to work when we get more complicated terms.
    --
    -- XXX Stronger type desired: we'd like static assurance that the
    -- length of the list matches the arity in the key!
    ad_arg_dispos  :: (DFunct,Int) -> [ArgDispos]

    -- | A map from (functor,arity) to self disposition.
  , ad_self_dispos :: (DFunct,Int) -> SelfDispos
  }

mergeDispositions :: SelfDispos -> (ECSrc, ArgDispos) -> ArgDispos
mergeDispositions = md
 where
  md SDInherit (_,d)                = d
  md SDEval    (ECExplicit,ADQuote) = ADQuote
  md SDEval    (_,_)                = ADEval
  md SDQuote   (ECExplicit,ADEval)  = ADEval
  md SDQuote   (_,_)                = ADQuote

data NT = NTNumeric (Either Integer Double)
        | NTString  B.ByteString
        | NTVar     DVar
 deriving (Show)
type FDT = TermF DVar NT
type EVF = Either DVar FDT
type ENT = Either NT FDT

{- This stage of ANF does not actually link evaluations to
 - their semantic interpretation.  That is, we have not yet
 - resolved foreign function calls.
 -}
data ANFState = AS
              { as_next  :: !Int
              , as_evals :: M.Map DVar EVF
              , as_unifs :: M.Map DVar ENT
              , as_annot :: M.Map DVar [T.Spanned (Annotation DTerm)]
              , as_warns :: [(B.ByteString, [T.Span])]
              }
 deriving (Show)

nextVar :: (MonadState ANFState m) => String -> m DVar
nextVar pfx = do
    vn  <- gets as_next
    modify (\s -> s { as_next = vn + 1 })
    return $ BU.fromString $ pfx ++ show vn

newEval :: (MonadState ANFState m) => String -> EVF -> m DVar
newEval pfx t = do
    n   <- nextVar pfx
    evs <- gets as_evals
    modify (\s -> s { as_evals = M.insert n t evs })
    return n

newUnif :: (MonadState ANFState m) => String -> ENT -> m DVar
newUnif pfx (Left (NTVar x)) = return x
newUnif pfx t = do
    n   <- nextVar pfx
    uns <- gets as_unifs
    modify (\s -> s { as_unifs = M.insert n t uns })
    return n

newWarn :: (MonadState ANFState m) => B.ByteString -> [T.Span] -> m ()
newWarn msg loc = modify (\s -> s { as_warns = (msg,loc):(as_warns s) })

------------------------------------------------------------------------}}}
-- Disposition computations                                             {{{

-- XXX These should be read from declarations
dynaFunctorArgDispositions :: (DFunct, Int) -> [ArgDispos]
dynaFunctorArgDispositions x = case x of
    ("is", 2)  -> [ADQuote,ADEval]
    -- evaluate arithmetic / math
    ("exp", 1) -> [ADEval]
    ("log", 1) -> [ADEval]
    -- logic
    ("and", 2) -> [ADEval, ADEval]
    ("or", 2)  -> [ADEval, ADEval]
    ("not", 1) -> [ADEval]
    (name, arity) ->
       -- If it starts with a nonalpha, it prefers to evaluate arguments
       let d = if C.isAlphaNum $ head $ BU.toString name
                then ADQuote
                else ADEval
       in take arity $ repeat $ d

-- XXX These should be read from declarations
dynaFunctorSelfDispositions :: (DFunct,Int) -> SelfDispos
dynaFunctorSelfDispositions x = case x of
    ("true",0)   -> SDQuote
    ("false",0)  -> SDQuote
    ("pair",2)   -> SDQuote
    (name, _) ->
       -- If it starts with a nonalpha, it prefers to evaluate
       let d = if C.isAlphaNum $ head $ BU.toString name
                then SDInherit
                else SDEval
       in d

------------------------------------------------------------------------}}}
-- Normalize a Term                                                     {{{

-- | Convert a syntactic term into ANF; while here, move to a
-- Control.Unification term representation.
--
-- The ANFState ensures that variables are unique; we additionally give them
-- \"semi-meaningful\" prefixes, but these should not be relied upon.
--
-- XXX On second thought, we should just move to a @TermF B.ByteString
-- Var@ representation, since we want everything flattened.
--
-- XXX This sheds span information entirely, which is probably not what we
-- actually want.  Note that we're careful to keep a stack of contexts
-- around, so we should probably do something clever like attach them to
-- operations we extract?
normTerm_ :: (Functor m, MonadState ANFState m, MonadReader ANFDict m)
               => EvalCtx       -- ^ In an evaluation context?
               -> [T.Span]      -- ^ List of spans traversed
               -> P.Term        -- ^ Term being digested
               -> m NT

-- Variables only evaluate in explicit context
--
-- While here, replace bare underscores with unique names.
-- XXX is this the right place for that?
normTerm_ c _ (P.TVar v) = do
    v' <- if v == "_" then nextVar "_$w" else return v
    case c of
       (ECExplicit,ADEval) -> NTVar `fmap` newEval "_$v" (Left v')
       _                   -> return $ NTVar v'

-- Numerics get returned in-place and raise a warning if they are evaluated.
normTerm_ c   ss  (P.TNumeric n)    = do
    case c of
      (ECExplicit,ADEval) -> newWarn "Ignoring request to evaluate numeric" ss
      _                   -> return ()
    return $ NTNumeric n

-- Strings too
normTerm_ c   ss  (P.TString s)    = do
    case c of
      (ECExplicit,ADEval) -> newWarn "Ignoring request to evaluate string" ss
      _                   -> return ()
    return $ NTString s

-- Quote makes the context explicitly a quoting one
normTerm_ _   ss (P.TFunctor "&" [t T.:~ st]) = do
    normTerm_ (ECExplicit,ADQuote) (st:ss) t

-- Evaluation is a little different: in addition to forcing the context to
-- evaluate, it must also evaluate if the context from on high is one of
-- evaluation!
normTerm_ c   ss (P.TFunctor "*" [t T.:~ st]) =
    normTerm_ (ECExplicit,ADEval) (st:ss) t
    >>= \nt -> case c of
                (_,ADEval) -> case nt of
                                NTVar v -> NTVar `fmap` newEval "_$s" (Left v)
                                _       -> do
                                            newWarn "Ignoring * of literal" ss
                                            return nt
                _          -> return nt

-- Annotations are stripped of their span information
--
-- XXX this is probably the wrong thing to do
normTerm_ c   ss (P.TAnnot a (t T.:~ st)) = do
    nt <- normTerm_ c (st:ss) t
    -- return $ UTerm $ TAnnot (fmap unspan a) nt
    undefined -- XXX!!!

-- Functors have both top-down and bottom-up dispositions on
-- their handling.
normTerm_ c   ss (P.TFunctor f as) = do

    argdispos <- asks $ flip ($) (f,length as) . ad_arg_dispos
    normas <- mapM (\(a T.:~ s,d) -> normTerm_ (ECFunctor,d) (s:ss) a)
                   (zip as argdispos)

    selfdispos <- asks $ flip ($) (f,length as) . ad_self_dispos

    let dispos = mergeDispositions selfdispos c
    
    fmap NTVar $
     case dispos of
       ADEval  -> newEval "_$f" . Right
       ADQuote -> newUnif "_$u" . Right
      $ TFunctor f normas

normTerm :: (Functor m, MonadState ANFState m, MonadReader ANFDict m)
         => Bool               -- ^ In an evaluation context?
         -> T.Spanned P.Term   -- ^ Term to digest
         -> m NT
normTerm c (t T.:~ s) = normTerm_ (ECFunctor,if c then ADEval else ADQuote)
                                  [s] t

------------------------------------------------------------------------}}}
-- Normalize a Rule                                                     {{{

data FDR = FRule DVar B.ByteString [DVar] DVar

-- XXX
normRule :: (Functor m, MonadState ANFState m, MonadReader ANFDict m)
         => T.Spanned P.Rule   -- ^ Term to digest
         -> m FDR
normRule (P.Rule h a es r T.:~ _) = do
    nh  <- normTerm False h >>= newUnif "_$h" . Left
    nr  <- normTerm True  r >>= newUnif "_$r" . Left
    nes <- mapM (\e -> normTerm True e >>= newUnif "_$c" . Left) es
    return $ FRule nh a nes nr

------------------------------------------------------------------------}}}
-- Run the normalizer                                                   {{{

-- | Run the normalization routine.
--
-- Use as @runNormalize nRule
runNormalize :: ReaderT ANFDict (State ANFState) a -> (a, ANFState)
runNormalize =
  flip runState   (AS 0 M.empty M.empty M.empty []) .
  flip runReaderT (AD dynaFunctorArgDispositions dynaFunctorSelfDispositions)

------------------------------------------------------------------------}}}
-- Pretty Printer                                                       {{{

printANF :: (FDR, ANFState) -> Doc e
printANF ((FRule h a e result), AS {as_evals = evals, as_unifs = unifs}) =
  parens $ (pretty a)
           <+> valign [ (pretty h)
                      , parens $ text "side"   <+> (valign $ map pretty e)
                      , parens $ text "evals"  <+> (pev evals)
                      , parens $ text "unifs"  <+> (pun unifs)
                      , parens $ text "result" <+> (pretty result)
                      ]
  where
    pnt (NTNumeric (Left x))        = pretty x
    pnt (NTNumeric (Right x))       = pretty x
    pnt (NTString s)                = pretty s
    pnt (NTVar v)                   = pretty v

    pft (TFunctor fn args)   = parens $ hcat $ punctuate (text " ")
                                             $ (pretty fn : (map pnt args))
    pft (TNumeric (Left x))  = pretty x
    pft (TNumeric (Right x)) = pretty x
    pft (TString s)          = pretty s

    pef (Left v)   = pretty v
    pef (Right t)  = pft t

    pet (Left n)   = pnt n
    pet (Right t)  = pft t

    pev x = valign $ map (\(y,z)-> parens $ pretty y <+> pef z) $ M.toList x
    pun x = valign $ map (\(y,z)-> parens $ pretty y <+> pet z) $ M.toList x

------------------------------------------------------------------------}}}