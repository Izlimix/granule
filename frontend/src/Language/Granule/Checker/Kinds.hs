-- Mainly provides a kind checker on types
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ViewPatterns #-}

module Language.Granule.Checker.Kinds (kindCheckDef
                    , inferKindOfType
                    , inferKindOfType'
                    , joinCoeffectTypes
                    , hasLub
                    , joinKind
                    , inferCoeffectType
                    , inferCoeffectTypeAssumption
                    , mguCoeffectTypes
                    , promoteTypeToKind) where

import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe

import Language.Granule.Checker.Monad

import Language.Granule.Checker.Predicates

import Language.Granule.Syntax.Def
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type
import Language.Granule.Context
import Language.Granule.Utils

promoteTypeToKind :: Type -> Kind
promoteTypeToKind (TyCon c) = kConstr c
promoteTypeToKind (TyVar v) = KVar v
promoteTypeToKind t = KPromote t

-- Currently we expect that a type scheme has kind KType
kindCheckDef :: (?globals :: Globals) => Def v t -> MaybeT Checker ()
kindCheckDef (Def s _ _ _ (Forall _ quantifiedVariables ty)) = do
  -- Set up the quantified variables in the type variable context
  modify (\st -> st { tyVarContext = map (\(n, c) -> (n, (c, ForallQ))) quantifiedVariables})

  kind <- inferKindOfType' s quantifiedVariables ty
  case kind of
    KType -> modify (\st -> st { tyVarContext = [] })
    _     -> illKindedNEq s KType kind

inferKindOfType :: (?globals :: Globals) => Span -> Type -> MaybeT Checker Kind
inferKindOfType s t = do
    checkerState <- get
    inferKindOfType' s (stripQuantifiers $ tyVarContext checkerState) t

inferKindOfType' :: (?globals :: Globals) => Span -> Ctxt Kind -> Type -> MaybeT Checker Kind
inferKindOfType' s quantifiedVariables t =
    typeFoldM (TypeFold kFun kCon kBox kDiamond kVar kApp kInt kInfix) t
  where
    kFun (KPromote (TyCon c)) (KPromote (TyCon c'))
     | internalName c == internalName c' = return $ kConstr c

    kFun KType KType = return KType
    kFun KType y = illKindedNEq s KType y
    kFun x _     = illKindedNEq s KType x
    kCon conId = do
        st <- get
        case lookup conId (typeConstructors st) of
          Just (kind,_) -> return kind
          Nothing   -> halt $ UnboundVariableError (Just s) (pretty conId <> " constructor.")

    kBox c KType = do
       -- Infer the coeffect (fails if that is ill typed)
       _ <- inferCoeffectType s c
       return KType
    kBox _ x = illKindedNEq s KType x

    kDiamond _ KType = return KType
    kDiamond _ x     = illKindedNEq s KType x

    kVar tyVar =
      case lookup tyVar quantifiedVariables of
        Just kind -> return kind
        Nothing   -> do
          st <- get
          case lookup tyVar (kVarContext st) of
            Just kind -> return kind
            Nothing ->
              halt $ UnboundVariableError (Just s) $
                       "Type variable `" <> pretty tyVar <> "` is unbound (not quantified)." <?> show quantifiedVariables

    kApp (KFun k1 k2) kArg | k1 `hasLub` kArg = return k2
    kApp k kArg = illKindedNEq s (KFun kArg (KVar $ mkId "...")) k

    kInt _ = return $ kConstr $ mkId "Nat"

    kInfix op k1 k2 = do
      st <- get
      case lookup (mkId op) (typeConstructors st) of
       Just (KFun k1' (KFun k2' kr), _) ->
         if k1 `hasLub` k1'
          then if k2 `hasLub` k2'
               then return kr
               else illKindedNEq s k2' k2
          else illKindedNEq s k1' k1
       Nothing   -> halt $ UnboundVariableError (Just s) (pretty op <> " operator.")

-- | Compute the join of two kinds, if it exists
joinKind :: Kind -> Kind -> Maybe Kind
joinKind k1 k2 | k1 == k2 = Just k1
joinKind (KPromote t1) (KPromote t2) =
   fmap KPromote (joinCoeffectTypes t1 t2)
joinKind _ _ = Nothing

-- | Some coeffect types can be joined (have a least-upper bound). This
-- | function computes the join if it exists.
joinCoeffectTypes :: Type -> Type -> Maybe Type
joinCoeffectTypes t1 t2 =
 case (t1, t2) of
  -- `Nat` can unify with `Q` to `Q`
  (TyCon (internalName -> "Q"), TyCon (internalName -> "Nat")) ->
        Just $ TyCon $ mkId "Q"

  (TyCon (internalName -> "Nat"), TyCon (internalName -> "Q")) ->
        Just $ TyCon $ mkId "Q"

  -- `Nat` can unify with `Ext Nat` to `Ext Nat`
  (t, TyCon (internalName -> "Nat")) | t == extendedNat ->
        Just extendedNat
  (TyCon (internalName -> "Nat"), t) | t == extendedNat ->
        Just extendedNat

  -- Equal things unify to the same thing
  (t, t') | t == t' -> Just t

  _ -> Nothing

-- | Predicate on whether two kinds have a leasy upper bound
hasLub :: Kind -> Kind -> Bool
hasLub k1 k2 =
  case joinKind k1 k2 of
    Nothing -> False
    Just _  -> True


-- | Infer the type of ta coeffect term (giving its span as well)
inferCoeffectType :: (?globals :: Globals) => Span -> Coeffect -> MaybeT Checker Type

-- Coeffect constants have an obvious kind
inferCoeffectType _ (Level _)         = return $ TyCon $ mkId "Level"
inferCoeffectType _ (CNat _)          = return $ TyCon $ mkId "Nat"
inferCoeffectType _ (CFloat _)        = return $ TyCon $ mkId "Q"
inferCoeffectType _ (CSet _)          = return $ TyCon $ mkId "Set"
inferCoeffectType s (CInterval c1 c2)    = do
  k1 <- inferCoeffectType s c1
  k2 <- inferCoeffectType s c2

  case joinCoeffectTypes k1 k2 of
    Just k -> return $ TyApp (TyCon $ mkId "Interval") k

    Nothing ->
      halt $ KindError (Just s) $ "Interval grades do not match: `" <> pretty k1
          <> "` does not match with `" <> pretty k2 <> "`"

-- Take the join for compound coeffect epxressions
inferCoeffectType s (CPlus c c')  = mguCoeffectTypes s c c'
inferCoeffectType s (CTimes c c') = mguCoeffectTypes s c c'
inferCoeffectType s (CMeet c c')  = mguCoeffectTypes s c c'
inferCoeffectType s (CJoin c c')  = mguCoeffectTypes s c c'
inferCoeffectType s (CExpon c c') = mguCoeffectTypes s c c'

-- Coeffect variables should have a type in the cvar->kind context
inferCoeffectType s (CVar cvar) = do
  st <- get
  case lookup cvar (tyVarContext st) of
     Nothing -> do
       halt $ UnboundVariableError (Just s) $ "Tried to look up kind of `" <> pretty cvar <> "`"
                                              <?> show (cvar,(tyVarContext st))
--       state <- get
--       let newType = TyVar $ "ck" <> show (uniqueVarId state)
       -- We don't know what it is yet though, so don't update the coeffect kind ctxt
--       put (state { uniqueVarId = uniqueVarId state + 1 })
--       return newType


     Just (KVar   name, _) -> return $ TyVar name
     Just (KPromote t, _)  -> checkKindIsCoeffect s t
     Just (k, _)           -> illKindedNEq s KCoeffect k

inferCoeffectType s (CZero t) = checkKindIsCoeffect s t
inferCoeffectType s (COne t)  = checkKindIsCoeffect s t
inferCoeffectType s (CInfinity (Just t)) = checkKindIsCoeffect s t
-- Unknown infinity defaults to the interval of extended nats version
inferCoeffectType s (CInfinity Nothing) = return (TyApp (TyCon $ mkId "Interval") extendedNat)
inferCoeffectType s (CSig _ t) = checkKindIsCoeffect s t

inferCoeffectTypeAssumption :: (?globals :: Globals)
                            => Span -> Assumption -> MaybeT Checker (Maybe Type)
inferCoeffectTypeAssumption _ (Linear _) = return Nothing
inferCoeffectTypeAssumption s (Discharged _ c) = do
    t <- inferCoeffectType s c
    return $ Just t

checkKindIsCoeffect :: (?globals :: Globals) => Span -> Type -> MaybeT Checker Type
checkKindIsCoeffect s t = do
  k <- inferKindOfType s t
  case k of
    KCoeffect -> return t
    k         -> illKindedNEq s KCoeffect k

-- Find the most general unifier of two coeffects
-- This is an effectful operation which can update the coeffect-kind
-- contexts if a unification resolves a variable
mguCoeffectTypes :: (?globals :: Globals) => Span -> Coeffect -> Coeffect -> MaybeT Checker Type
mguCoeffectTypes s c1 c2 = do
  ck1 <- inferCoeffectType s c1
  ck2 <- inferCoeffectType s c2
  case (ck1, ck2) of
    -- Both are poly
    (TyVar kv1, TyVar kv2) -> do
      updateCoeffectType kv1 (TyVar kv2)
      return (TyVar kv2)

   -- Linear-hand side is a poly variable, but right is concrete
    (TyVar kv1, ck2') -> do
      updateCoeffectType kv1 ck2'
      return ck2'

    -- Right-hand side is a poly variable, but Linear is concrete
    (ck1', TyVar kv2) -> do
      updateCoeffectType kv2 ck1'
      return ck1'

    (TyCon k1, TyCon k2) | k1 == k2 -> return $ TyCon k1

    (t, t') | t == t' -> return t

    -- Try to unify coeffect types
    (t, t') | Just tj <- joinCoeffectTypes t t' -> return tj

    (k1, k2) -> halt $ KindError (Just s) $ "Cannot unify coeffect types '"
               <> pretty k1 <> "' and '" <> pretty k2
               <> "' for coeffects " <> pretty c1 <> " and " <> pretty c2

-- Given a coeffect type variable and a coeffect kind,
-- replace any occurence of that variable in an context
-- and update the current solver predicate as well
updateCoeffectType :: Id -> Type -> MaybeT Checker ()
updateCoeffectType tyVar ty = do
   modify (\checkerState ->
    checkerState
     { tyVarContext = rewriteCtxt (tyVarContext checkerState),
       kVarContext = replace (kVarContext checkerState) tyVar (KPromote ty) })
 where
   rewriteCtxt :: Ctxt (Kind, Quantifier) -> Ctxt (Kind, Quantifier)
   rewriteCtxt [] = []
   rewriteCtxt ((name, (KVar kindVar, q)) : ctxt)
    | tyVar == kindVar = (name, (KPromote ty, q)) : rewriteCtxt ctxt
   rewriteCtxt (x : ctxt) = x : rewriteCtxt ctxt
