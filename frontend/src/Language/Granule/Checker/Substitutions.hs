{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Language.Granule.Checker.Substitutions where

import Control.Monad
import Control.Monad.State.Strict
import Data.Maybe (mapMaybe, catMaybes)

import Language.Granule.Context
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type

import Language.Granule.Checker.Kinds
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates
import Language.Granule.Checker.Variables (freshCoeffectVarWithBinding, freshVar)

import Control.Monad.Trans.Maybe
import Language.Granule.Utils

-- For doctest:
-- $setup
-- >>> import Language.Granule.Syntax.Identifiers (mkId)
-- >>> import Language.Granule.Syntax.Pattern
-- >>> import Language.Granule.TestUtils
-- >>> :set -XImplicitParams

{-| Substitutions map from variables to type-level things as defined by
    substitutors -}
type Substitution = Ctxt Substitutor

{-| Substitutor are things we want to substitute in... they may be one
     of several things... -}
data Substitutor =
    SubstT  Type
  | SubstC  Coeffect
  | SubstK  Kind
  | SubstE  Effect
  deriving (Eq, Show)

instance Pretty Substitutor where
  prettyL l (SubstT t) = "->" <> prettyL l t
  prettyL l (SubstC c) = "->" <> prettyL l c
  prettyL l (SubstK k) = "->" <> prettyL l k
  prettyL l (SubstE e) = "->" <> prettyL l e

invertedLookup :: (Eq t, Substitutable t) => Substitution -> t -> Maybe Id
invertedLookup subst x =
  lookup x invertedSubst
   where
     invertedSubst =
      mapMaybe (\(v, s) -> invertSubstitutor s >>= \y -> return (y, v)) subst

class Substitutable t where
  -- | Rewrite a 't' using a substitution
  substitute :: (?globals :: Globals)
             => Substitution -> t -> MaybeT Checker t

  unsubstitute :: (?globals :: Globals)
             => Substitution -> t -> MaybeT Checker t

  invertSubstitutor :: Substitutor -> Maybe t

  unify :: (?globals :: Globals)
        => t -> t -> MaybeT Checker (Maybe Substitution)

-- Instances for the main representation of things in the types

instance Substitutable Substitutor where

  substitute subst s =
    case s of
      SubstT t -> do
        t <- substitute subst t
        return $ SubstT t

      SubstC c -> do
        c <- substitute subst c
        return $ SubstC c

      SubstK k -> do
        k <- substitute subst k
        return $ SubstK k

      SubstE e -> do
        e <- substitute subst e
        return $ SubstE e

  unsubstitute subst s =
   case s of
     SubstT t -> do
       t <- unsubstitute subst t
       return $ SubstT t

     SubstC c -> do
       c <- unsubstitute subst c
       return $ SubstC c

     SubstK k -> do
       k <- unsubstitute subst k
       return $ SubstK k

     SubstE e -> do
       e <- unsubstitute subst e
       return $ SubstE e

  -- There is no substitutor of a substitutor, so always false
  invertSubstitutor _ = Nothing

  unify (SubstT t) (SubstT t') = unify t t'
  unify (SubstT t) (SubstC c') = do
    -- We can unify a type with a coeffect, if the type is actually a Nat
    k <- inferKindOfType nullSpan t
    k' <- inferCoeffectType nullSpan c'
    case joinKind k (KPromote k') of
      Just (KPromote (TyCon k)) | internalName k == "Nat" -> do
             c <- compileNatKindedTypeToCoeffect nullSpan t
             unify c c'
      _ -> return Nothing
  unify (SubstC c') (SubstT t) = unify (SubstT t) (SubstC c')
  unify (SubstC c) (SubstC c') = unify c c'
  unify (SubstK k) (SubstK k') = unify k k'
  unify (SubstE e) (SubstE e') = unify e e'
  unify _ _ = return Nothing

instance Substitutable Type where
  substitute subst = typeFoldM (baseTypeFold
                              { tfFunTy = funSubst
                              , tfTyApp = appSubst
                              , tfTyVar = varSubst
                              , tfBox = box
                              , tfDiamond = dia
                              , tfTyInfix = infixSubst })
    where
      funSubst t1 t2 = do
        t1 <- substitute subst t1
        t2 <- substitute subst t2
        mFunTy t1 t2

      appSubst t1 t2 = do
          t1 <- substitute subst t1
          t2 <- substitute subst t2
          mTyApp t1 t2

      infixSubst o t1 t2 = do
          t1 <- substitute subst t1
          t2 <- substitute subst t2
          mTyInfix o t1 t2

      box c t = do
        c <- substitute subst c
        t <- substitute subst t
        mBox c t

      dia e t = do
        e <- substitute subst e
        t <- substitute subst t
        mDiamond e t

      varSubst v =
         case lookup v subst of
           Just (SubstT t) -> return t
           _               -> mTyVar v

  invertSubstitutor (SubstT t) = Just t
  invertSubstitutor _ = Nothing

  unsubstitute subst t =
      case invertedLookup subst t of
        Nothing -> unsubstituteRecurse t
        Just v  -> return $ TyVar v
    where
      unsubstituteRecurse (FunTy t1 t2) = do
        t1 <- unsubstitute subst t1
        t2 <- unsubstitute subst t2
        mFunTy t1 t2

      unsubstituteRecurse (TyApp t1 t2) = do
          t1 <- unsubstitute subst t1
          t2 <- unsubstitute subst t2
          mTyApp t1 t2

      unsubstituteRecurse (TyInfix o t1 t2) = do
          t1 <- unsubstitute subst t1
          t2 <- unsubstitute subst t2
          mTyInfix o t1 t2

      unsubstituteRecurse (Box c t) = do
        c <- unsubstitute subst c
        t <- unsubstitute subst t
        mBox c t

      unsubstituteRecurse (Diamond e t) = do
        e <- unsubstitute subst e
        t <- unsubstitute subst t
        mDiamond e t

      unsubstituteRecurse t = return t


  unify (TyVar v) t = return $ Just [(v, SubstT t)]
  unify t (TyVar v) = return $ Just [(v, SubstT t)]
  unify (FunTy t1 t2) (FunTy t1' t2') = do
    u1 <- unify t1 t1'
    u2 <- unify t2 t2'
    u1 <<>> u2
  unify (TyCon c) (TyCon c') | c == c' = return $ Just []
  unify (Box c t) (Box c' t') = do
    u1 <- unify c c'
    u2 <- unify t t'
    u1 <<>> u2
  unify (Diamond e t) (Diamond e' t') = do
    u1 <- unify e e'
    u2 <- unify t t'
    u1 <<>> u2
  unify (TyApp t1 t2) (TyApp t1' t2') = do
    u1 <- unify t1 t1'
    u2 <- unify t2 t2'
    u1 <<>> u2
  unify (TyInt i) (TyInt j) | i == j = return $ Just []
  unify t@(TyInfix o t1 t2) t'@(TyInfix o' t1' t2') = do
    k <- inferKindOfType nullSpan t
    k' <- inferKindOfType nullSpan t
    case joinKind k k' of
      Just (KPromote (TyCon (internalName -> "Nat"))) -> do
        c  <- compileNatKindedTypeToCoeffect nullSpan t
        c' <- compileNatKindedTypeToCoeffect nullSpan t'
        addConstraint $ Eq nullSpan c c' (TyCon $ mkId "Nat")
        return $ Just []

      _ | o == o' -> do
        u1 <- unify t1 t1'
        u2 <- unify t2 t2'
        u1 <<>> u2
      -- No unification
      _ -> return $ Nothing
  -- No unification
  unify _ _ = return $ Nothing

instance Substitutable Coeffect where

  substitute subst (CPlus c1 c2) = do
      c1' <- substitute subst c1
      c2' <- substitute subst c2
      return $ CPlus c1' c2'

  substitute subst (CJoin c1 c2) = do
      c1' <- substitute subst c1
      c2' <- substitute subst c2
      return $ CJoin c1' c2'

  substitute subst (CMeet c1 c2) = do
      c1' <- substitute subst c1
      c2' <- substitute subst c2
      return $ CMeet c1' c2'

  substitute subst (CTimes c1 c2) = do
      c1' <- substitute subst c1
      c2' <- substitute subst c2
      return $ CTimes c1' c2'

  substitute subst (CExpon c1 c2) = do
      c1' <- substitute subst c1
      c2' <- substitute subst c2
      return $ CExpon c1' c2'

  substitute subst (CInterval c1 c2) = do
      c1' <- substitute subst c1
      c2' <- substitute subst c2
      return $ CInterval c1' c2'

  substitute subst (CVar v) =
      case lookup v subst of
        Just (SubstC c) -> do
           checkerState <- get
           case lookup v (tyVarContext checkerState) of
             -- If the coeffect variable has a poly kind then update it with the
             -- kind of c
             Just ((KVar kv), q) -> do
                k' <- inferCoeffectType nullSpan c
                put $ checkerState { tyVarContext = replace (tyVarContext checkerState)
                                                           v (promoteTypeToKind k', q) }
             _ -> return ()
           return c
        -- Convert a single type substitution (type variable, type pair) into a
        -- coeffect substituion
        Just (SubstT t) -> do
          k <- inferKindOfType nullSpan t
          k' <- inferCoeffectType nullSpan (CVar v)
          case joinKind k (promoteTypeToKind k') of
            Just (KPromote (TyCon (internalName -> "Nat"))) ->
              compileNatKindedTypeToCoeffect nullSpan t
            _ -> return (CVar v)

        _               -> return $ CVar v

  substitute subst (CInfinity k) = do
    k <- substitute subst k
    return $ CInfinity k

  substitute subst (COne k) = do
    k <- substitute subst k
    return $ COne k

  substitute subst (CZero k) = do
    k <- substitute subst k
    return $ CZero k

  substitute subst (CSet tys) = do
    tys <- mapM (\(v, t) -> substitute subst t >>= (\t' -> return (v, t'))) tys
    return $ CSet tys

  substitute subst (CSig c k) = do
    c <- substitute subst c
    k <- substitute subst k
    return $ CSig c k

  substitute _ c@CNat{}      = return c
  substitute _ c@CFloat{}    = return c
  substitute _ c@Level{}     = return c

  invertSubstitutor (SubstC c) = Just c
  invertSubstitutor _ = Nothing

  unsubstitute subst c = do
     subst' <- mapM invertTypeToCoeffect subst
     unsubstituteC (catMaybes subst') c
    where
      unsubstituteC substC c =
        -- See if we can convert a coeffect back to a var
        case invertedLookup subst c of
          Just v -> return $ CVar v
          Nothing ->
            -- See if there is a coeffet which has come from a translated type
            case lookup c substC of
              Just v -> return $ CVar v
              Nothing -> unsubstituteRecurse substC c


      invertTypeToCoeffect (v, SubstT t) = do
            c <- compileNatKindedTypeToCoeffect nullSpan t
            return (Just (c, v))
      invertTypeToCoeffect _ =
            return Nothing

      unsubstituteRecurse substC (CInterval c1 c2)  = do
        c1 <- unsubstituteC substC c1
        c2 <- unsubstituteC substC c2
        return $ CInterval c1 c2

      unsubstituteRecurse substC (CPlus c1 c2) = do
        c1 <- unsubstituteC substC c1
        c2 <- unsubstituteC substC c2
        return $ CPlus c1 c2

      unsubstituteRecurse substC (CTimes c1 c2) = do
          c1 <- unsubstituteC substC c1
          c2 <- unsubstituteC substC c2
          return $ CTimes c1 c2

      unsubstituteRecurse substC (CMeet c1 c2) = do
          c1 <- unsubstituteC substC c1
          c2 <- unsubstituteC substC c2
          return $ CMeet c1 c2

      unsubstituteRecurse substC (CZero t) = do
          t <- unsubstitute subst t
          return $ CZero t

      unsubstituteRecurse substC (COne t) = do
          t <- unsubstitute subst t
          return $ COne t

      unsubstituteRecurse substC (CSet tys) = do
          tys <- mapM (\(v, t) -> do
                          t <- unsubstitute subst t
                          return (v, t)) tys
          return $ CSet tys

      unsubstituteRecurse substC (CSig c t) = do
          c <- unsubstituteC substC c
          t <- unsubstitute subst t
          return $ CSig c t

      unsubstituteRecurse substC (CExpon c1 c2) = do
          c1 <- unsubstituteC substC c1
          c2 <- unsubstituteC substC c2
          return $ CExpon c1 c2

      unsubstituteRecurse _ c = return c


  unify (CVar v) c = do
    checkerState <- get
    case lookup v (tyVarContext checkerState) of
      -- If the coeffect variable has a poly kind then update it with the
      -- kind of c
      Just ((KVar kv), q) -> do
        k' <- inferCoeffectType nullSpan c
        put $ checkerState { tyVarContext = replace (tyVarContext checkerState)
                                                    v (promoteTypeToKind k', q) }
      Just (k, q) ->
        case c of
          CVar v' -> do
            case lookup v' (tyVarContext checkerState) of
              Just (KVar _, q) ->
                -- The type of v is known and c is a variable with a poly kind
                put $ checkerState { tyVarContext =
                                       replace (tyVarContext checkerState)
                                               v' (k, q) }
              _ -> return ()
          _ -> return ()
      Nothing -> return ()
    -- Standard result of unifying with a variable
    return $ Just [(v, SubstC c)]

  unify c (CVar v) = unify (CVar v) c
  unify (CPlus c1 c2) (CPlus c1' c2') = do
    u1 <- unify c1 c1'
    u2 <- unify c2 c2'
    u1 <<>> u2

  unify (CTimes c1 c2) (CTimes c1' c2') = do
    u1 <- unify c1 c1'
    u2 <- unify c2 c2'
    u1 <<>> u2

  unify (CMeet c1 c2) (CMeet c1' c2') = do
    u1 <- unify c1 c1'
    u2 <- unify c2 c2'
    u1 <<>> u2

  unify (CJoin c1 c2) (CJoin c1' c2') = do
    u1 <- unify c1 c1'
    u2 <- unify c2 c2'
    u1 <<>> u2

  unify (CInfinity k) (CInfinity k') = do
    unify k k'

  unify (CZero k) (CZero k') = do
    unify k k'

  unify (COne k) (COne k') = do
    unify k k'

  unify (CSet tys) (CSet tys') = do
    ums <- zipWithM (\x y -> unify (snd x) (snd y)) tys tys'
    foldM (<<>>) (Just []) ums


  unify (CSig c ck) (CSig c' ck') = do
    u1 <- unify c c'
    u2 <- unify ck ck'
    u1 <<>> u2

  unify c c' =
    if c == c' then return $ Just [] else return Nothing

instance Substitutable Effect where
  -- {TODO: Make effects richer}
  substitute subst e = return e
  unify e e' =
    if e == e' then return $ Just []
               else return $ Nothing

  invertSubstitutor (SubstE e) = Just e
  invertSubstitutor _ = Nothing

  unsubstitute _ t = return t

instance Substitutable Kind where

  substitute subst (KPromote t) = do
      t <- substitute subst t
      return $ KPromote t

  substitute subst KType = return KType
  substitute subst KCoeffect = return KCoeffect
  substitute subst (KFun c1 c2) = do
    c1 <- substitute subst c1
    c2 <- substitute subst c2
    return $ KFun c1 c2
  substitute subst (KVar v) =
    case lookup v subst of
      Just (SubstK k) -> return k
      _               -> return $ KVar v

  invertSubstitutor (SubstK k) = Just k
  invertSubstitutor _ = Nothing

  unsubstitute subst k =
      case invertedLookup subst k of
        Nothing -> unsubstituteRecurse k
        Just v -> return $ KVar v
    where
       unsubstituteRecurse (KFun k1 k2) = do
         k1 <- unsubstitute subst k1
         k2 <- unsubstitute subst k2
         return $ KFun k1 k2
       unsubstituteRecurse k = return k

  unify (KVar v) k =
    return $ Just [(v, SubstK k)]
  unify k (KVar v) =
    return $ Just [(v, SubstK k)]
  unify (KFun k1 k2) (KFun k1' k2') = do
    u1 <- unify k1 k1'
    u2 <- unify k2 k2'
    u1 <<>> u2
  unify k k' = return $ if k == k' then Just [] else Nothing

instance Substitutable t => Substitutable (Maybe t) where
  substitute s Nothing = return Nothing
  substitute s (Just t) = substitute s t >>= return . Just
  unify Nothing _ = return (Just [])
  unify _ Nothing = return (Just [])
  unify (Just x) (Just y) = unify x y

  unsubstitute s (Just t) = unsubstitute s t >>= return . Just
  unsubstitute s Nothing = return Nothing

  invertSubstitutor _ = Nothing


-- | Combine substitutions wrapped in Maybe
(<<>>) :: (?globals :: Globals)
  => Maybe Substitution -> Maybe Substitution -> MaybeT Checker (Maybe Substitution)
xs <<>> ys =
  case (xs, ys) of
    (Just xs', Just ys') ->
         combineSubstitutions nullSpan xs' ys' >>= (return . Just)
    _ -> return Nothing

-- | Combines substitutions which may fail if there are conflicting
-- | substitutions
combineSubstitutions ::
    (?globals :: Globals)
    => Span -> Substitution -> Substitution -> MaybeT Checker Substitution
combineSubstitutions sp u1 u2 = do
      -- For all things in the (possibly empty) intersection of contexts `u1` and `u2`,
      -- check whether things can be unified, i.e. exactly
      uss1 <- forM u1 $ \(v, s) ->
        case lookupMany v u2 of
          -- Unifier in u1 but not in u2
          [] -> return [(v, s)]
          -- Possible unificaitons in each part
          alts -> do
              unifs <-
                forM alts $ \s' -> do
                   --(us, t) <- unifiable v t t' t t'
                   us <- unify s s'
                   case us of
                     Nothing -> error "Cannot unify"
                     Just us -> do
                       sUnified <- substitute us s
                       combineSubstitutions sp [(v, sUnified)] us

              return $ concat unifs
      -- Any remaining unifiers that are in u2 but not u1
      uss2 <- forM u2 $ \(v, s) ->
         case lookup v u1 of
           Nothing -> return [(v, s)]
           _       -> return []
      return $ concat uss1 <> concat uss2

{-| Take a context of 'a' and a subhstitution for 'a's (also a context)
  apply the substitution returning a pair of contexts, one for parts
  of the context where a substitution occurred, and one where substitution
  did not occur
>>> let ?globals = defaultGlobals in evalChecker initState (runMaybeT $ substCtxt [(mkId "y", SubstT $ TyInt 0)] [(mkId "x", Linear (TyVar $ mkId "x")), (mkId "y", Linear (TyVar $ mkId "y")), (mkId "z", Discharged (TyVar $ mkId "z") (CVar $ mkId "b"))])
Just ([((Id "y" "y"),Linear (TyInt 0))],[((Id "x" "x"),Linear (TyVar (Id "x" "x"))),((Id "z" "z"),Discharged (TyVar (Id "z" "z")) (CVar (Id "b" "b")))])
-}

instance Substitutable (Ctxt Assumption) where

  substitute subst ctxt = do
    (ctxt0, ctxt1) <- substCtxt subst ctxt
    return (ctxt0 <> ctxt1)

  unify = error "Unify not implemented for contexts"

  invertSubstitutor _ = Nothing

  unsubstitute subst ctxt = do
    mapM (unsubst subst) ctxt
    where
      unsubst subst (v, Linear t) = do
        t <- unsubstitute subst t
        return (v, Linear t)
      unsubst subst (v, Discharged t c) = do
        t <- unsubstitute subst t
        c <- unsubstitute subst c
        return (v, Discharged t c)

substCtxt :: (?globals :: Globals) => Substitution -> Ctxt Assumption
  -> MaybeT Checker (Ctxt Assumption, Ctxt Assumption)
substCtxt _ [] = return ([], [])
substCtxt subst ((v, x):ctxt) = do
  (substituteds, unsubstituteds) <- substCtxt subst ctxt
  (v', x') <- substAssumption subst (v, x)

  if (v', x') == (v, x)
    then return (substituteds, (v, x) : unsubstituteds)
    else return ((v, x') : substituteds, unsubstituteds)

substAssumption :: (?globals :: Globals) => Substitution -> (Id, Assumption)
  -> MaybeT Checker (Id, Assumption)
substAssumption subst (v, Linear t) = do
    t <- substitute subst t
    return (v, Linear t)
substAssumption subst (v, Discharged t c) = do
    t <- substitute subst t
    c <- substitute subst c
    return (v, Discharged t c)

compileNatKindedTypeToCoeffect :: (?globals :: Globals) => Span -> Type -> MaybeT Checker Coeffect
compileNatKindedTypeToCoeffect s (TyInfix op t1 t2) = do
  t1' <- compileNatKindedTypeToCoeffect s t1
  t2' <- compileNatKindedTypeToCoeffect s t2
  case op of
    "+"   -> return $ CPlus t1' t2'
    "*"   -> return $ CTimes t1' t2'
    "^"   -> return $ CExpon t1' t2'
    "\\/" -> return $ CJoin t1' t2'
    "/\\" -> return $ CMeet t1' t2'
    _     -> halt $ UnboundVariableError (Just s) $ "Type-level operator " <> op
compileNatKindedTypeToCoeffect _ (TyInt n) =
  return $ CNat n
compileNatKindedTypeToCoeffect _ (TyVar v) =
  return $ CVar v
compileNatKindedTypeToCoeffect s t =
  halt $ KindError (Just s) $ "Type `" <> pretty t <> "` does not have kind `Nat`"


-- | Apply a name map to a type to rename the type variables
renameType :: (?globals :: Globals) => [(Id, Id)] -> Type -> MaybeT Checker Type
renameType subst t =
      typeFoldM (baseTypeFold { tfBox   = renameBox subst
                              , tfTyVar = renameTyVar subst }) t
  where
    renameBox renameMap c t = do
      c' <- substitute (map (\(v, var) -> (v, SubstC $ CVar var)) renameMap) c
      t' <- renameType renameMap t
      return $ Box c' t'
    renameTyVar renameMap v =
      case lookup v renameMap of
        Just v' -> return $ TyVar v'
        -- Shouldn't happen
        Nothing -> return $ TyVar v

-- | Get a fresh polymorphic instance of a type scheme and list of instantiated type variables
-- and their new names.
freshPolymorphicInstance :: (?globals :: Globals)
  => Quantifier -> TypeScheme -> MaybeT Checker (Type, [Id])
freshPolymorphicInstance quantifier (Forall s kinds ty) = do
    -- Universal becomes an existential (via freshCoeffeVar)
    -- since we are instantiating a polymorphic type
    renameMap <- mapM instantiateVariable kinds
    ty <- renameType renameMap ty
    return (ty, map snd renameMap)

  where
    -- Freshen variables, create existential instantiation
    instantiateVariable (var, k) = do
      -- Freshen the variable depending on its kind
      var' <- case k of
               k | typeBased k -> do
                 freshName <- freshVar (internalName var)
                 let var'  = mkId freshName
                 -- Label fresh variable as an existential
                 modify (\st -> st { tyVarContext = (var', (k, quantifier)) : tyVarContext st })
                 return var'
               KPromote (TyCon c) -> freshCoeffectVarWithBinding var (TyCon c) quantifier
               KPromote _ -> error "Arbirary promoted types not yet supported"
               KCoeffect -> error "Coeffect kind variables not yet supported"
               KVar _ -> error "Tried to instantiate a polymorphic kind. This is not supported yet.\
               \ Please open an issue with a snippet of your code at https://github.com/dorchard/granule/issues"
               KType    -> error "Impossible" -- covered by typeBased
               KFun _ _ -> error "Tried to instantiate a non instantiatable kind"
      -- Return pair of old variable name and instantiated name (for
      -- name map)
      return (var, var')
    typeBased KType = True
    typeBased (KFun k1 k2) = typeBased k1 && typeBased k2
    typeBased _     = False
