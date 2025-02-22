
-- Initially authored by Andreas, 2013-10-22.

-- | A bidirectional type checker for internal syntax.
--
--   Performs checking on unreduced terms.
--   With the exception that projection-like function applications
--   have to be reduced since they break bidirectionality.

module Agda.TypeChecking.CheckInternal
  ( MonadCheckInternal
  , checkType
  , checkType'
  , checkSort
  , checkInternal
  , checkInternal'
  , checkInternalType'
  , Action(..), defaultAction, eraseUnusedAction
  , infer
  , inferSpine'
  , shouldBeSort
  ) where

import Control.Arrow (first)
import Control.Monad

import Agda.Syntax.Common
import Agda.Syntax.Internal

import Agda.TypeChecking.Conversion
import Agda.TypeChecking.Datatypes -- (getConType, getFullyAppliedConType)
import Agda.TypeChecking.Level
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.ProjectionLike (elimView, ProjEliminator(..))
import Agda.TypeChecking.Records (getDefType)
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Sort
import Agda.TypeChecking.Telescope


import Agda.Utils.Functor (($>))
import Agda.Utils.Pretty  (prettyShow)
import Agda.Utils.Size

import Agda.Utils.Impossible

-- * Bidirectional rechecker

type MonadCheckInternal m = MonadConversion m

-- -- | Entry point for e.g. checking WithFunctionType.
-- checkType :: Type -> TCM ()
-- checkType t = -- dontAssignMetas $ ignoreSorts $
--   checkInternal (unEl t) (sort Inf)

-- | Entry point for e.g. checking WithFunctionType.
checkType :: (MonadCheckInternal m) => Type -> m ()
checkType t = catchConstraint (CheckType t) $ do
  inferred <- checkType' t
  equalSort (getSort t) inferred

-- | Check a type and infer its sort.
--
--   Necessary because of PTS rule @(SizeUniv, Set i, Set i)@
--   but @SizeUniv@ is not included in any @Set i@.
--
--   This algorithm follows
--     Abel, Coquand, Dybjer, MPC 08,
--     Verifying a Semantic βη-Conversion Test for Martin-Löf Type Theory
--
checkType' :: (MonadCheckInternal m) => Type -> m Sort
checkType' t = do
  reportSDoc "tc.check.internal" 20 $ sep
    [ "checking internal type "
    , prettyTCM t
    ]
  v <- elimView EvenLone $ unEl t -- bring projection-like funs in post-fix form
  case v of
    Pi a b -> do
      s1 <- checkType' $ unDom a
      s2 <- (b $>) <$> do
        let goInside = case b of Abs{}   -> addContext (absName b, a)
                                 NoAbs{} -> id
        goInside $ checkType' $ unAbs b
      inferPiSort a s2
    Sort s -> do
      _ <- checkSort defaultAction s
      inferUnivSort s
    Var i es   -> do
      a <- typeOfBV i
      checkTypeSpine a (Var i   []) es
    Def f es   -> do  -- not a projection-like fun
      a <- defType <$> getConstInfo f
      checkTypeSpine a (Def f   []) es
    MetaV x es -> do -- we assume meta instantiations to be well-typed
      a <- metaType x
      checkTypeSpine a (MetaV x []) es
    v@Lam{}    -> typeError $ InvalidType v
    v@Con{}    -> typeError $ InvalidType v
    v@Lit{}    -> typeError $ InvalidType v
    v@Level{}  -> typeError $ InvalidType v
    DontCare v -> checkType' $ t $> v
    Dummy s _  -> __IMPOSSIBLE_VERBOSE__ s

checkTypeSpine :: (MonadCheckInternal m) => Type -> Term -> Elims -> m Sort
checkTypeSpine a self es = shouldBeSort =<< do snd <$> inferSpine a self es

checkInternalType' :: (MonadCheckInternal m) => Action m -> Type -> m Type
checkInternalType' act El{_getSort=s, unEl=t} = do
  tAfterAct <- checkInternal' act t CmpLeq (sort s)
  return El{_getSort=s, unEl=tAfterAct}

-- | 'checkInternal' traverses the whole 'Term', and we can use this
--   traversal to modify the term.
data Action m = Action
  { preAction  :: Type -> Term -> m Term
    -- ^ Called on each subterm before the checker runs.
  , postAction :: Type -> Term -> m Term
    -- ^ Called on each subterm after the type checking.
  , modalityAction :: Modality -> Modality -> Modality
    -- ^ Called for each @ArgInfo@.
    --   The first 'Modality' is from the type,
    --   the second from the term.
  , elimViewAction :: Term -> m Term
    -- ^ Called for bringing projection-like funs in post-fix form
  }

-- | The default action is to not change the 'Term' at all.
defaultAction :: PureTCM m => Action m
--(MonadReduce m, MonadTCEnv m, HasConstInfo m) => Action m
defaultAction = Action
  { preAction       = \ _ -> return
  , postAction      = \ _ -> return
  , modalityAction  = \ _ -> id
  , elimViewAction  = elimView EvenLone
  }

eraseUnusedAction :: Action TCM
eraseUnusedAction = defaultAction { postAction = eraseUnused }
  where
    eraseUnused :: Type -> Term -> TCM Term
    eraseUnused t = \case
      Def f es -> do
        pols <- getPolarity f
        return $ Def f $ eraseIfNonvariant pols es
      v        -> return v

    eraseIfNonvariant :: [Polarity] -> Elims -> Elims
    eraseIfNonvariant []                  es             = es
    eraseIfNonvariant pols                []             = []
    eraseIfNonvariant (Nonvariant : pols) (e : es) = (fmap dontCare e) : eraseIfNonvariant pols es
    eraseIfNonvariant (_          : pols) (e : es) = e : eraseIfNonvariant pols es

-- | Entry point for term checking.
checkInternal :: (MonadCheckInternal m) => Term -> Comparison -> Type -> m ()
checkInternal v cmp t = void $ checkInternal' defaultAction v cmp t

checkInternal' :: (MonadCheckInternal m) => Action m -> Term -> Comparison -> Type -> m Term
checkInternal' action v cmp t = verboseBracket "tc.check.internal" 20 "" $ do
  reportSDoc "tc.check.internal" 20 $ sep
    [ "checking internal "
    , nest 2 $ sep [ prettyTCM v <+> ":"
                   , nest 2 $ prettyTCM t ] ]
  reportSDoc "tc.check.internal" 60 $ sep
    [ "checking internal with DB indices"
    , nest 2 $ sep [ pretty v <+> ":"
                   , nest 2 $ pretty t ] ]
  ctx <- getContextTelescope
  unless (null ctx) $ reportSDoc "tc.check.internal" 30 $ sep
    [ "In context"
    , nest 2 $ sep [ prettyTCM ctx ] ]
  -- Bring projection-like funs in post-fix form,
  -- (even lone ones by default).
  v <- elimViewAction action =<< preAction action t v
  postAction action t =<< case v of
    Var i es   -> do
      a <- typeOfBV i
      reportSDoc "tc.check.internal" 30 $ fsep
        [ "variable" , prettyTCM (var i) , "has type" , prettyTCM a ]
      checkSpine action a (Var i []) es cmp t
    Def f es   -> do  -- f is not projection(-like)!
      a <- defType <$> getConstInfo f
      checkSpine action a (Def f []) es cmp t
    MetaV x es -> do -- we assume meta instantiations to be well-typed
      a <- metaType x
      reportSDoc "tc.check.internal" 30 $ "metavariable" <+> prettyTCM x <+> "has type" <+> prettyTCM a
      checkSpine action a (MetaV x []) es cmp t
    Con c ci vs -> do
      -- We need to fully apply the constructor to make getConType work!
      fullyApplyCon c vs t $ \ _d _dt _pars a vs' tel t -> do
        Con c ci vs2 <- checkSpine action a (Con c ci []) vs' cmp t
        -- Strip away the extra arguments
        return $ applySubst (strengthenS impossible (size tel))
          $ Con c ci $ take (length vs) vs2
    Lit l      -> do
      lt <- litType l
      compareType cmp lt t
      return $ Lit l
    Lam ai vb  -> do
      (a, b) <- maybe (shouldBePi t) return =<< isPath t
      ai <- checkArgInfo action ai $ domInfo a
      let name = suggests [ Suggestion vb , Suggestion b ]
      addContext (name, a) $ do
        Lam ai . Abs (absName vb) <$> checkInternal' action (absBody vb) cmp (absBody b)
    Pi a b     -> do
      s <- shouldBeSort t
      when (s == SizeUniv) $ typeError $ FunctionTypeInSizeUniv v
      let sa  = getSort a
          sb  = getSort (unAbs b)
          mkDom v = El sa v <$ a
          mkRng v = fmap (v <$) b
          -- Preserve NoAbs
          goInside = case b of Abs{}   -> addContext (absName b, a)
                               NoAbs{} -> id
      a <- mkDom <$> checkInternal' action (unEl $ unDom a) CmpLeq (sort sa)
      v' <- goInside $ Pi a . mkRng <$> checkInternal' action (unEl $ unAbs b) CmpLeq (sort sb)
      s' <- sortOf v'
      compareSort cmp s' s
      return v'
    Sort s     -> do
      reportSDoc "tc.check.internal" 30 $ "checking sort" <+> prettyTCM s
      s <- checkSort action s
      s' <- inferUnivSort s
      s'' <- shouldBeSort t
      compareSort cmp s' s''
      return $ Sort s
    Level l    -> do
      l <- checkLevel action l
      lt <- levelType
      compareType cmp lt t
      return $ Level l
    DontCare v -> DontCare <$> checkInternal' action v cmp t
    Dummy s _ -> __IMPOSSIBLE_VERBOSE__ s

-- | Make sure a constructor is fully applied
--   and infer the type of the constructor.
--   Raises a type error if the constructor does not belong to the given type.
fullyApplyCon
  :: (MonadCheckInternal m)
  => ConHead -- ^ Constructor.
  -> Elims    -- ^ Constructor arguments.
  -> Type    -- ^ Type of the constructor application.
  -> (QName -> Type -> Args -> Type -> Elims -> Telescope -> Type -> m a)
       -- ^ Name of the data/record type,
       --   type of the data/record type,
       --   reconstructed parameters,
       --   type of the constructor (applied to parameters),
       --   full application arguments,
       --   types of missing arguments (already added to context),
       --   type of the full application.
  -> m a
fullyApplyCon c vs t0 ret = do
  (TelV tel t, boundary) <- telViewPathBoundaryP t0
  -- The type of the constructor application may still be a function
  -- type.  In this case, we introduce the domains @tel@ into the context
  -- and apply the constructor to these fresh variables.
  addContext tel $ do
    t <- abortIfBlocked t
    getFullyAppliedConType c t >>= \case
      Nothing ->
        typeError $ DoesNotConstructAnElementOf (conName c) t
      Just ((d, dt, pars), a) ->
        ret d dt pars a (raise (size tel) vs ++ teleElims tel boundary) tel t

checkSpine
  :: (MonadCheckInternal m)
  => Action m
  -> Type       -- ^ Type of the head @self@.
  -> Term       -- ^ The head @self@.
  -> Elims      -- ^ The eliminations @es@.
  -> Comparison -- ^ Check (@CmpLeq@) or infer (@CmpEq@) the final type.
  -> Type       -- ^ Expected type of the application @self es@.
  -> m Term     -- ^ The application after modification by the @Action@.
checkSpine action a self es cmp t = do
  reportSDoc "tc.check.internal" 20 $ sep
    [ "checking spine "
    , nest 2 $ sep [ parens (sep [ prettyTCM self <+> ":"
                                 , nest 2 $ prettyTCM a ])
                   , nest 4 $ prettyTCM es <+> ":"
                   , nest 2 $ prettyTCM t ] ]
  ((v, v'), t') <- inferSpine' action a self self es
  t' <- reduce t'
  v' <$ coerceSize (compareType cmp) v t' t
--UNUSED Liang-Ting Chen 2019-07-16
--checkArgs
--  :: (MonadCheckInternal m)
--  => Action m
--  -> Type      -- ^ Type of the head.
--  -> Term      -- ^ The head.
--  -> Args      -- ^ The arguments.
--  -> Type      -- ^ Expected type of the application.
--  -> m Term    -- ^ The application after modification by the @Action@.
--checkArgs action a self vs t = checkSpine action a self (map Apply vs) t

-- | @checkArgInfo actual expected@.
--
--   The @expected@ 'ArgInfo' comes from the type.
--   The @actual@ 'ArgInfo' comes from the term and can be updated
--   by an action.
checkArgInfo :: (MonadCheckInternal m) => Action m -> ArgInfo -> ArgInfo -> m ArgInfo
checkArgInfo action ai ai' = do
  checkHiding    (getHiding ai)     (getHiding ai')
  mod <- checkModality action (getModality ai)  (getModality ai')
  return $ setModality mod ai

checkHiding    :: (MonadCheckInternal m) => Hiding -> Hiding -> m ()
checkHiding    h h' = unless (sameHiding h h') $ typeError $ HidingMismatch h h'

-- | @checkRelevance action term type@.
--
--   The @term@ 'Relevance' can be updated by the @action@.
checkModality :: (MonadCheckInternal m) => Action m -> Modality -> Modality -> m Modality
checkModality action mod mod' = do
  let (r,r') = (getRelevance mod, getRelevance mod')
      (q,q') = (getQuantity  mod, getQuantity  mod')
  unless (sameModality mod mod') $ typeError $ if
    | not (sameRelevance r r') -> RelevanceMismatch r r'
    | not (sameQuantity q q')  -> QuantityMismatch  q q'
    | otherwise -> __IMPOSSIBLE__ -- add more cases when adding new modalities
  return $ modalityAction action mod' mod  -- Argument order for actions: @type@ @term@

-- | Infer type of a neutral term.
infer :: (MonadCheckInternal m) => Term -> m Type
infer = \case
    Var i es   -> do
      a <- typeOfBV i
      snd <$> inferSpine a (Var i   []) es
    Def f (Apply a : es) -> inferDef' f a es -- possibly proj.like
    Def f es             -> inferDef  f   es -- not a projection-like fun
    MetaV x es -> do -- we assume meta instantiations to be well-typed
      a <- metaType x
      snd <$> inferSpine a (MetaV x []) es
    v -> __IMPOSSIBLE_VERBOSE__ $ unlines
      [ "CheckInternal.infer: non-inferable term:"
      , "  " ++ prettyShow v
      ]

-- | Infer ordinary function application.
inferDef :: (MonadCheckInternal m) => QName -> Elims -> m Type
inferDef f es = do
  a <- defType <$> getConstInfo f
  snd <$> inferSpine a (Def f []) es

-- | Infer possibly projection-like function application
inferDef' :: (MonadCheckInternal m) => QName -> Arg Term -> Elims -> m Type
inferDef' f a es = do
  -- Andreas, 2022-03-07, issue #5809: don't drop parameters of irrelevant projections.
  isRelevantProjection f >>= \case
    Just Projection{ projIndex = n } | n > 0 -> do
      let self = unArg a
      b <- infer self
      snd <$> inferSpine b self (Proj ProjSystem f : es)
    _ -> inferDef f (Apply a : es)


-- | @inferSpine t self es@ checks that spine @es@ eliminates
--   value @self@ of type @t@ and returns the remaining type
--   (target of elimination) and the final self (has that type).
inferSpine :: (MonadCheckInternal m) => Type -> Term -> Elims -> m (Term, Type)
inferSpine a v es = first fst <$> inferSpine' defaultAction a v v es

-- | Returns both the real term (first) and the transformed term (second). The
--   transformed term is not necessarily a valid term, so it must not be used
--   in types.
inferSpine' :: (MonadCheckInternal m)
            => Action m -> Type -> Term -> Term -> Elims -> m ((Term, Term), Type)
inferSpine' action t self self' [] = return ((self, self'), t)
inferSpine' action t self self' (e : es) = do
  reportSDoc "tc.infer.internal" 30 $ sep
    [ "inferSpine': "
    , "type t = " <+> pretty t
    , "self  = " <+> pretty self
    , "self' = " <+> pretty self'
    , "eliminated by e = " <+> pretty e
    ]
  case e of
    IApply x y r -> do
      (a, b) <- shouldBePath t
      r' <- checkInternal' action r CmpLeq (unDom a)
      izero <- primIZero
      ione  <- primIOne
      x' <- checkInternal' action x CmpLeq (b `absApp` izero)
      y' <- checkInternal' action y CmpLeq (b `absApp` ione)
      inferSpine' action (b `absApp` r) (self `applyE` [e]) (self' `applyE` [IApply x' y' r']) es
    Apply (Arg ai v) -> do
      (a, b) <- shouldBePi t
      ai <- checkArgInfo action ai $ domInfo a
      v' <- checkInternal' action v CmpLeq $ unDom a
      inferSpine' action (b `absApp` v) (self `applyE` [e]) (self' `applyE` [Apply (Arg ai v')]) es
    -- case: projection or projection-like
    Proj o f -> do
      (a, b) <- shouldBePi =<< shouldBeProjectible t f
      u  <- applyDef o f (argFromDom a $> self)
      u' <- applyDef o f (argFromDom a $> self')
      inferSpine' action (b `absApp` self) u u' es

-- | Type should either be a record type of a type eligible for
--   the principal argument of projection-like functions.
shouldBeProjectible :: (MonadCheckInternal m) => Type -> QName -> m Type
-- shouldBeProjectible t f = maybe failure return =<< projectionType t f
shouldBeProjectible t f = do
    t <- abortIfBlocked t
    maybe failure return =<< getDefType f t
  where failure = typeError $ ShouldBeRecordType t
    -- TODO: more accurate error that makes sense also for proj.-like funs.

shouldBePath :: (MonadCheckInternal m) => Type -> m (Dom Type, Abs Type)
shouldBePath t = do
  t <- abortIfBlocked t
  m <- isPath t
  case m of
    Just p  -> return p
    Nothing -> typeError $ ShouldBePath t

shouldBePi :: (MonadCheckInternal m) => Type -> m (Dom Type, Abs Type)
shouldBePi t = abortIfBlocked t >>= \ case
  El _ (Pi a b) -> return (a, b)
  _             -> typeError $ ShouldBePi t

-- | Check if sort is well-formed.
checkSort :: (MonadCheckInternal m) => Action m -> Sort -> m Sort
checkSort action s =
  case s of
    Type l   -> Type <$> checkLevel action l
    Prop l   -> Prop <$> checkLevel action l
    Inf f n  -> return $ Inf f n
    SSet l   -> SSet <$> checkLevel action l
    SizeUniv -> return SizeUniv
    LockUniv -> return LockUniv
    IntervalUniv -> return IntervalUniv
    PiSort dom s1 s2 -> do
      let a = unDom dom
      s1' <- checkSort action s1
      a' <- checkInternal' action a CmpLeq $ sort s1'
      let dom' = dom $> a'
      s2' <- mapAbstraction (El s1' <$> dom') (checkSort action) s2
      return $ PiSort dom' s1' s2'
    FunSort s1 s2 -> do
      s1' <- checkSort action s1
      s2' <- checkSort action s2
      return $ FunSort s1' s2'
    UnivSort s -> UnivSort <$> checkSort action s
    MetaS x es -> do -- we assume sort meta instantiations to be well-formed
      a <- metaType x
      let self = Sort $ MetaS x []
      ((_,v),_) <- inferSpine' action a self self es
      case v of
        Sort s     -> return s
        MetaV x es -> return $ MetaS x es
        Def d es   -> return $ DefS d es
        _          -> __IMPOSSIBLE__
    DefS d es -> do
      a <- defType <$> getConstInfo d
      let self = Sort $ DefS d []
      ((_,v),_) <- inferSpine' action a self self es
      case v of
        Sort s     -> return s
        MetaV x es -> return $ MetaS x es
        Def d es   -> return $ DefS d es
        _          -> __IMPOSSIBLE__
    DummyS s -> __IMPOSSIBLE_VERBOSE__ s

-- | Check if level is well-formed.
checkLevel :: (MonadCheckInternal m) => Action m -> Level -> m Level
checkLevel action (Max n ls) = Max n <$> mapM checkPlusLevel ls
  where
    checkPlusLevel (Plus k l)      = Plus k <$> checkLevelAtom l

    checkLevelAtom l = do
      lvl <- levelType
      checkInternal' action l CmpLeq lvl

-- | Universe subsumption and type equality (subtyping for sizes, resp.).
cmptype :: (MonadCheckInternal m) => Comparison -> Type -> Type -> m ()
cmptype cmp t1 t2 = do
    -- Andreas, 2017-03-09, issue #2493
    -- Only check subtyping, do not solve any metas!
    dontAssignMetas $ compareType cmp t1 t2
