---------------------------------------------------------------------------
-- | An implementation of our automata using existentially-quantified maps

-- Header material                                                      {{{
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wall #-}

module Dyna.XXX.Automata.NamedAut(NA(NA), naUnfold, naFromMap) where

import           Control.Applicative
import           Control.Lens
import           Control.Monad.Identity
import           Control.Monad.Trans.Either
import           Control.Monad.State
import qualified Data.Foldable                     as F
import qualified Data.Map                          as M
import qualified Data.Maybe                        as MA
import qualified Data.Set                          as S
import qualified Data.Traversable                  as T
import           Dyna.XXX.Automata.Class
import           Dyna.XXX.DataUtils (mapInOrCons)
import           Dyna.XXX.MonadUtils (incState, tryMapCache, trySetCache)
import qualified Prelude.Extras                    as PE

------------------------------------------------------------------------}}}
-- Definition                                                           {{{

-- | A single-accepting-state automaton representation, using an existential
-- for state labels.
data NA f = forall a . (Ord a) => NA a (M.Map a (f a))

------------------------------------------------------------------------}}}
-- Internal utilities                                                   {{{

naImport :: (T.Traversable f, Ord k, Functor m, Monad m)
         => m a
         -> (a -> f a -> m ())
         -> (k -> f k)
         -> k
         -> a
         -> m ()
naImport nxt ins look r ir = do
  _ <- flip runStateT M.empty $ go r ir
  return ()
 where
  go k a = T.traverse rec (look k) >>= lift . ins a
  rec = tryMapCache id (\_ -> lift nxt) go

naPrune :: forall f . (F.Foldable f) => NA f -> NA f
naPrune (NA a0 m0) = (NA a0 m')
 where
  m' = execState (go a0) M.empty
  go a = tryMapCache id (\_ -> return af) (\_ _ -> F.mapM_ go af) a
   where af = MA.fromJust $ m0 ^. at a

naRelabel_ :: (Ord a, Enum o)
           => M.Map a x
           -> M.Map a o
naRelabel_ m = flip evalState (toEnum 0) $ T.traverse (\_ -> incState id) m

-- | Convert from whatever internal representation we're using for states
-- to Int.
naExposeAll :: (Functor f, Enum o, Ord o) => NA f -> (o, M.Map o (f o))
naExposeAll (NA a0 m0) = let labels = naRelabel_ m0
                             relabel a = MA.fromJust $ labels ^. at a
                         in  ( relabel a0
                             , fmap (fmap relabel)
                               $ M.mapKeysWith (error "NA relabel collision")
                                               relabel m0)

newtype DC f = DC (f ())
instance (PE.Eq1 f) => Eq (DC f) where
  (DC l) == (DC r) = l PE.==# r
instance (PE.Ord1 f) => Ord (DC f) where
  (DC l) `compare` (DC r) = l `PE.compare1` r

-- | Downcast away a forall.  The instances above convert our 'PE.Ord1'
-- requirements into the traditional 'Ord' and 'Eq' for 'f ()'.  This serves
-- to hide the use of '()' from the consumer code.
dc :: NonRec f -> DC f
dc i = DC i

------------------------------------------------------------------------}}}
-- Unfolder                                                             {{{

-- | Build an automata over the functor @f@ by unfolding.  @r@ carries
-- top-down information flow, while the user-specified 'Monad' @m@ may carry
-- sideways state (that is, information dependent upon the unfolding order).
-- @ix@ provides the internal label for the state being unfolded so that it
-- may be referenced later (/e.g./ by first being stored in @m@ or @r@).
--
-- As a convenience, the unfolder is allowed to supply an entire (isolated)
-- automata in liu of recursively descending.
naUnfold :: forall f ix m r .
            (Enum ix, Ord ix, Functor m, Monad m, Traversable f)
         => (forall t . (MonadTrans t, Monad (t m))
              => r -> ix -> t m (Either (NA f) (f (Either ix r))))
         -> r -> m (NA f)
naUnfold uf = liftM (\(r,(_,m)) -> NA r m)
            . flip runStateT (toEnum 0,M.empty) . visit
 where
  visit r = do
   i <- nxt
   f <- uf r i
   case f of
     Right f' -> do
                 f'' <- T.mapM (either return visit) f'
                 ins i f''
     Left (NA r' m') -> naImport nxt ins (MA.fromJust . (m' ^.) . at) r' i
   return i

  nxt = incState _1
  ins k v = _2 . at k .= Just v
{-# INLINABLE naUnfold #-}

{-
-- | Build an automata over the functor @f@ by unfolding.  @t@ carries
-- top-down information flow while @s@ carries sideways state (that is,
-- information dependent upon the unfolding order).  @ix@ provides the
-- internal label for the state being unfolded.
--
-- One might use @s@ to carry a (partial) map from @t@ to @ix@ values,
-- either for tying cyclic knots or to avoid re-unfolding structure.  It may
-- also be safe to ignore (just pass '()').
naUnfold :: forall f ix m s t .
            (Enum ix, Ord ix, Traversable f) =>
            (t -> ix -> s -> (f (Either ix t), s))  -- ^ Unfolder step
            -> t                                    -- ^ Initial root
            -> s                                    -- ^ Initial flow state
            -> NA f
naUnfold uf t0 s0 = (\(r,(_,m,_)) -> NA r m)
                  $ flip runState (toEnum 0, M.empty, s0)
                  $ visit t0
 where
  visit t = do
    i <- incState _1
    (f,s') <- uses _3 (uf t i)
    _3 .= s'
    f' <- T.mapM (either return visit) f
    _2 . at i .= Just f'
    return i
-}

naFromMap :: forall f oix .
             (T.Traversable f, Ord oix)
          => M.Map oix (f oix) -> oix -> NA f
naFromMap m0 a0 = flip evalState (M.empty :: M.Map oix Int) (naUnfold u a0)
 where
  u :: forall t m . (MonadTrans t, Monad (t m), MonadState (M.Map oix Int) m)
    => oix -> Int -> t m (Either (NA f) (f (Either Int oix)))
  u oix iix = do
    lift (at oix .= Just iix)
    liftM Right $ T.mapM relabel $ MA.fromJust (m0 ^. at oix)

  relabel oix = lift (use (at oix)) >>= return . maybe (Right oix) (Left)
{-# INLINABLE naFromMap #-}

{-
naFromAut :: forall a f x .
             (Automata a, T.Traversable f, Enum x, Ord x)
          => a f -> (x, M.Map x (f x))
naFromAut = autReduceIx cyc rec
 where
  cyc x = (x,M.empty)
  rec x fr = (x, M.insert x frx $ M.unions frms)
   where
   frx = fmap fst fr
   frms = F.toList $ fmap snd fr
{-# INLINABLE naFromAut #-}
-}

------------------------------------------------------------------------}}}
-- Internal data types                                                  {{{

data NBinState f c a b = NBS { _nbs_next  :: Int
                             , _nbs_ctx   :: M.Map Int (f Int)
                             , _nbs_cache_symm :: M.Map (c,a   ,b   ) Int
                             , _nbs_cache_lsml :: M.Map (c,a   ,DC f) Int
                             , _nbs_cache_lsmr :: M.Map (c,DC f,b   ) Int
                             }
$(makeLenses ''NBinState)
type NBSC m f c a b = (Monad m, MonadState (NBinState f c a b) m)

iNBS :: forall (f :: * -> *) c a b. NBinState f c a b
iNBS = NBS 0 M.empty M.empty M.empty M.empty

data MinState a c = MS
  { _ms_classes :: M.Map c [a]
  , _ms_clinv   :: M.Map a c
  }
 deriving (Show)
$(makeLenses ''MinState)

data MinSplitState f a c = MSS
  { _mss_newcl  :: M.Map (f c) [a] }
 deriving (Show)
$(makeLenses ''MinSplitState)

------------------------------------------------------------------------}}}
-- Automata instance                                                    {{{

instance AutomataRepr NA where
  autHide i0 = flip evalState (0::Int, M.empty) $ do
    i0' <- T.traverse go i0
    ra  <- nxt
    ins ra i0'
    rm  <- use _2
    return (NA ra rm)
   where
    nxt = incState _1
    ins k v = _2 . at k .= Just v

    go (NA i' m') = do
      i <- nxt
      naImport nxt ins (MA.fromJust . (m' ^.) . at) i' i
      return i

  autShallow f = do
    f' <- T.mapM (const mzero) f
    return (NA () (M.fromList [((),f')]))
  {-# INLINABLE autShallow #-}

  autExpose (NA a0 m) = fmap (\a -> NA a m) $ MA.fromJust $ m ^. at a0
  {-# INLINABLE autExpose #-}

  autAtEachState q (NA a0 m0) = NA a0 (M.map q' m0)
   where
    q' = q (MA.fromJust . (m0 ^.) . at)
  {-# INLINABLE autAtEachState #-}

  autReduce cyc red (NA a0 m0) = evalState (q a0) M.empty
   where
    q a = do
      _ <- tryMapCache id (\_ -> return cyc) miss a
      liftM MA.fromJust $ use (at a)

    miss a _ = do
     fr <- T.mapM q (MA.fromJust $ m0 ^. at a)
     let r = red fr
     at a .= Just r
  {-# INLINABLE autReduce #-}

  autReduceIx cyc red (naExposeAll -> (a0,m0)) = evalState (q a0) M.empty
   where
    q a = do
      _ <- tryMapCache id (return . cyc) miss a
      liftM MA.fromJust $ use (at a)

    miss a _ = do
     fr <- T.mapM q (MA.fromJust $ m0 ^. at a)
     let r = red a fr
     at a .= Just r
  {-# INLINABLE autReduceIx #-}

  autBiReduce c q (NA la0 lm) (NA ra0 rm) =
    evalState (qip la0 ra0) (S.empty, S.empty, S.empty)
   where
    qip l r = flip (trySetCache _1 c) (l,r) $ \_ -> do
               let lf = MA.fromJust $ lm ^. at l
               let rf = MA.fromJust $ rm ^. at r
               q qopl qopr qip lf rf

    qopl l r = flip (trySetCache _2 c) (l, dc r) $ \_ -> do
                let lf = MA.fromJust $ lm ^. at l
                q qopl qopr qip lf r

    qopr l r = flip (trySetCache _3 c) (dc l, r) $ \_ -> do
                let rf = MA.fromJust $ rm ^. at r
                q qopl qopr qip l rf
  {-# INLINABLE autBiReduce #-}

  -- While unusual, we need this instance type declaration to introduce
  -- scoped type variables for us to hold on to down below.  Oy!
  autMerge :: forall c f .
              (Ord c, PE.Ord1 f)
           => (forall x y . f x -> f y -> c)
           -> (forall x y z m .
                  (Monad m)
               => (c -> x        -> NonRec f -> m z)
               -> (c -> NonRec f -> y        -> m z)
               -> (c -> x        -> y        -> m z)
               ->  c -> f x      -> f y      -> m (f z))
           -> NA f -> NA f -> NA f
  autMerge ci f (NA (la0 :: la) lm) (NA (ra0 :: ra) rm) = evalState tlq iNBS
   where
    f' :: NBSC m f c la ra => c -> f la -> f ra -> m (f Int)
    f' = f lsml lsmr merge

    tlq = do
      let lf :: f la = MA.fromJust $ lm ^. at la0
      let rf :: f ra = MA.fromJust $ rm ^. at ra0
      let ic = ci lf rf
      ma <- merge ic la0 ra0
      mm <- use nbs_ctx
      return (NA ma mm)

    -- These two are here so that the skolems remain local to this
    -- defintion.  It's a bit of a shame that the type system is
    -- not willing to let these exist at higher scope.
    nxt :: NBSC m f c la ra => m Int
    nxt = incState nbs_next
    ins k v = nbs_ctx . at k .= Just v

    merge :: NBSC m f c la ra => c -> la -> ra -> m Int
    merge c l r =
      flip (tryMapCache nbs_cache_symm (\_ -> nxt)) (c,l,r) $ \_ a -> do
        let lf = MA.fromJust $ lm ^. at l
        let rf = MA.fromJust $ rm ^. at r
        v <- f' c lf rf
        ins a v

    lsml :: NBSC m f c la ra => c -> la -> NonRec f -> m Int
    lsml c l r =
      flip (tryMapCache nbs_cache_lsml (\_ -> nxt)) (c,l,dc r) $ \_ a -> do
        let lf = MA.fromJust $ lm ^. at l
        v <- f' c lf r
        ins a v

    lsmr :: NBSC m f c la ra => c -> NonRec f -> ra -> m Int
    lsmr c l r =
      flip (tryMapCache nbs_cache_lsmr (\_ -> nxt)) (c,dc l,r) $ \_ a -> do
        let rf = MA.fromJust $ rm ^. at r
        v <- f' c l rf
        ins a v
  {-# INLINABLE autMerge #-}

  autPMerge :: forall c e f .
               (Ord c, PE.Ord1 f)
            => (forall x y . f x -> f y -> c)
            -> (forall x y z m .
                   (Monad m)
                => (c -> x        -> NonRec f -> m z)
                -> (c -> NonRec f -> y        -> m z)
                -> (c -> x        -> y        -> m z)
                ->  c -> f x      -> f y      -> m (Either e (f z)))
            -> NA f -> NA f -> Either e (NA f)
  autPMerge ci f (NA (la0 :: la) lm) (NA (ra0 :: ra) rm) =
    evalState (runEitherT tlq) iNBS
   where
    f' :: NBSC m f c la ra
       => c -> f la -> f ra -> EitherT e m (Either e (f Int))
    f' = f lsml lsmr merge

    tlq = do
      let lf :: f la = MA.fromJust $ lm ^. at la0
      let rf :: f ra = MA.fromJust $ rm ^. at ra0
      let ic = ci lf rf
      ma <- merge ic la0 ra0
      mm <- use nbs_ctx
      return (NA ma mm)

    -- These two are here so that the skolems remain local to this
    -- defintion.  It's a bit of a shame that the type system is
    -- not willing to let these exist at higher scope.
    nxt :: NBSC m f c la ra => m Int
    nxt = incState nbs_next
    ins k v = nbs_ctx . at k .= Just v

    merge :: NBSC m f c la ra => c -> la -> ra -> EitherT e m Int
    merge c l r =
      flip (tryMapCache nbs_cache_symm (\_ -> nxt)) (c,l,r) $ \_ a -> do
        let lf = MA.fromJust $ lm ^. at l
        let rf = MA.fromJust $ rm ^. at r
        m <- f' c lf rf
        v <- hoistEither m
        ins a v

    lsml :: NBSC m f c la ra => c -> la -> NonRec f -> EitherT e m Int
    lsml c l r =
      flip (tryMapCache nbs_cache_lsml (\_ -> nxt)) (c,l,dc r) $ \_ a -> do
        let lf = MA.fromJust $ lm ^. at l
        m <- f' c lf r
        v <- hoistEither m
        ins a v

    lsmr :: NBSC m f c la ra => c -> NonRec f -> ra -> EitherT e m Int
    lsmr c l r =
      flip (tryMapCache nbs_cache_lsmr (\_ -> nxt)) (c,dc l,r) $ \_ a -> do
        let rf = MA.fromJust $ rm ^. at r
        m <- f' c l rf
        v <- hoistEither m
        ins a v
  {-# INLINABLE autPMerge #-}

------------------------------------------------------------------------}}}
-- AutMinimize instance                                                 {{{

instance AutMinimize NA where

  autMinimize (naPrune -> NA a0 m0) =
    let ms = classifyUntil m0 (MS M.empty M.empty)
                              (mkClasses [M.keys m0])

        msci = ms ^. ms_clinv

        defn = \(a:_) -> fmap (\a' -> MA.fromJust $ msci ^. at a')
                            $ MA.fromJust $ m0 ^. at a
    in NA ((MA.fromJust $ msci ^. at a0) :: Int)
          (fmap defn $ ms ^. ms_classes)

   where

    -- Attempt to partition a class in the equivalence relationship.  Evaluate
    -- each contained state to see if they have become distinguished.
    splitClasses :: forall f a c . (Ord c, Ord a, Traversable f, Ord (f c))
                 => M.Map a (f a)
                 -> MinState a c
                 -> [[a]]
    splitClasses im ms =
        concat $ flip map (M.keys $ ms ^. ms_classes)
      $ \c -> (M.elems . _mss_newcl) $ flip execState (MSS M.empty)
      $ forM_ (MA.fromJust $ (ms ^. ms_classes) ^. at c)
      $ \a -> do
        -- Look up the definition of this state in the original automata
        -- so that we can sort it into mss_newcl appropriately
        let ia :: f c
               = runIdentity
                 $ traverse (pure . MA.fromJust . ((ms ^. ms_clinv) ^.) . at)
                 $ (MA.fromJust $ im ^. at a :: f a)
        mss_newcl %= mapInOrCons ia a

    mkClasses :: (Ord a, Enum c, Ord c) => [[a]] -> MinState a c
    mkClasses = uncurry MS . go (toEnum 0) M.empty M.empty
     where
      go _ mc mi []          = (mc,mi)
      go c mc mi ([]:xs)     = c `seq` go (succ c) mc mi xs
      go c mc mi ((a:as):xs) = go c (mapInOrCons c a mc) (M.insert a c mi) (as:xs)

    classifyUntil :: forall a c f . (Ord a, Enum c, Ord c, Traversable f, Ord (f c))
                  => M.Map a (f a) -> MinState a c -> MinState a c -> MinState a c
    classifyUntil im p p' =
      if M.size (p ^. ms_classes) == M.size (p' ^. ms_classes)
       then p'
       else classifyUntil im p' (mkClasses $ splitClasses im p')

------------------------------------------------------------------------}}}
