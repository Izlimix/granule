{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

module Language.Granule.Checker.Types where

import Control.Monad.State.Strict
import Data.List (sortBy)

import Language.Granule.Checker.Constraints.Compile

import Language.Granule.Checker.Effects
import Language.Granule.Checker.Kinds
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates
import Language.Granule.Checker.SubstitutionContexts
import Language.Granule.Checker.Substitution
import Language.Granule.Checker.Variables
import Language.Granule.Checker.Normalise

import Language.Granule.Syntax.Helpers
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type

import Language.Granule.Utils

import Data.Functor.Const

lEqualTypesWithPolarity :: (?globals :: Globals)
  => Span -> SpecIndicator -> Type Zero -> Type Zero -> Checker (Bool, Type Zero, Substitution)
lEqualTypesWithPolarity s pol = equalTypesRelatedCoeffectsAndUnify s ApproximatedBy pol

equalTypesWithPolarity :: (?globals :: Globals)
  => Span -> SpecIndicator -> Type Zero -> Type Zero -> Checker (Bool, Type Zero, Substitution)
equalTypesWithPolarity s pol = equalTypesRelatedCoeffectsAndUnify s Eq pol

lEqualTypes :: (?globals :: Globals)
  => Span -> Type Zero -> Type Zero -> Checker (Bool, Type Zero, Substitution)
lEqualTypes s = equalTypesRelatedCoeffectsAndUnify s ApproximatedBy SndIsSpec

equalTypes :: (?globals :: Globals)
  => Span -> Type Zero -> Type Zero -> Checker (Bool, Type Zero, Substitution)
equalTypes s = equalTypesRelatedCoeffectsAndUnify s Eq SndIsSpec

equalTypesWithUniversalSpecialisation :: (?globals :: Globals)
  => Span -> Type Zero -> Type Zero -> Checker (Bool, Type Zero, Substitution)
equalTypesWithUniversalSpecialisation s = equalTypesRelatedCoeffectsAndUnify s Eq SndIsSpec

{- | Check whether two types are equal, and at the same time
     generate coeffect equality constraints and unify the
     two types

     The first argument is taken to be possibly approximated by the second
     e.g., the first argument is inferred, the second is a specification
     being checked against
-}
equalTypesRelatedCoeffectsAndUnify :: (?globals :: Globals)
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> Type One -> Constraint)
  -- Starting spec indication
  -> SpecIndicator
  -- Left type (usually the inferred)
  -> Type Zero
  -- Right type (usually the specified)
  -> Type Zero
  -- Result is a effectful, producing:
  --    * a boolean of the equality
  --    * the most specialised type (after the unifier is applied)
  --    * the unifier
  -> Checker (Bool, Type Zero, Substitution)
equalTypesRelatedCoeffectsAndUnify s rel spec t1 t2 = do

   (eq, unif) <- equalTypesRelatedCoeffects s rel t1 t2 spec
   if eq
     then do
        t2 <- substitute unif t2
        return (eq, t2, unif)
     else let t1 = normaliseType t1 in
       return (eq, t1, [])

data SpecIndicator = FstIsSpec | SndIsSpec | PatternCtxt
  deriving (Eq, Show)

flipIndicator :: SpecIndicator -> SpecIndicator
flipIndicator FstIsSpec = SndIsSpec
flipIndicator SndIsSpec = FstIsSpec
flipIndicator PatternCtxt = PatternCtxt

{- | Check whether two types are equal, and at the same time
     generate coeffect equality constraints and a unifier
      Polarity indicates which -}
equalTypesRelatedCoeffects :: (?globals :: Globals)
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> Type One -> Constraint)
  -> Type Zero
  -> Type Zero
  -- Indicates whether the first type or second type is a specification
  -> SpecIndicator
  -> Checker (Bool, Substitution)
equalTypesRelatedCoeffects s rel t1 t2 sp = do
  -- Infer kinds
  k1 <- inferKindOfType s t1
  k2 <- inferKindOfType s t2
  -- Check the kinds are equal
  (eq, kind, unif) <- equalKinds s k1 k2
  -- If so, proceed with equality on types of this kind
  if eq
    then equalTypesRelatedCoeffectsInner s rel t1 t2 kind sp
    else
      -- Otherwise throw a kind error
      case sp of
        FstIsSpec -> throw $ KindMismatch { errLoc = s, tyActualK = Just t1, kExpected = k1, kActual = k2}
        _         -> throw $ KindMismatch { errLoc = s, tyActualK = Just t1, kExpected = k2, kActual = k1}

equalTypesRelatedCoeffectsInner :: (?globals :: Globals)
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> Type One -> Constraint)
  -> Type Zero
  -> Type Zero
  -> Kind
  -- Indicates whether the first type or second type is a specification
  -> SpecIndicator
  -> Checker (Bool, Substitution)

equalTypesRelatedCoeffectsInner s rel fTy1@(FunTy t1 t2) fTy2@(FunTy t1' t2') _ sp = do
  -- contravariant position (always approximate)
  (eq1, u1) <-
    case sp of
      FstIsSpec -> equalTypesRelatedCoeffects s ApproximatedBy t1 t1' (flipIndicator sp)
      _         -> equalTypesRelatedCoeffects s ApproximatedBy t1' t1 (flipIndicator sp)
   -- covariant position (depends: is not always over approximated)
  t2 <- substitute u1 t2
  t2' <- substitute u1 t2'
  (eq2, u2) <- equalTypesRelatedCoeffects s rel t2 t2' sp
  unifiers <- combineSubstitutions s u1 u2
  return (eq1 && eq2, unifiers)

equalTypesRelatedCoeffectsInner _ _ (TyCon con1) (TyCon con2) _ _
  | internalName con1 /= "Pure" && internalName con2 /= "Pure" =
  return (con1 == con2, [])

equalTypesRelatedCoeffectsInner s rel (Diamond ef1 t1) (Diamond ef2 t2) _ sp = do
  (eq, unif) <- equalTypesRelatedCoeffects s rel t1 t2 sp
  (eq', unif') <- equalTypesRelatedCoeffects s rel ef1 ef2 sp
  u <- combineSubstitutions s unif unif'
  return (eq && eq', u)

equalTypesRelatedCoeffectsInner s rel x@(Box c t) y@(Box c' t') k sp = do
  -- Debugging messages
  debugM "equalTypesRelatedCoeffectsInner (pretty)" $ pretty c <> " == " <> pretty c'
  debugM "equalTypesRelatedCoeffectsInner (show)" $ "[ " <> show c <> " , " <> show c' <> "]"
  -- Unify the coeffect kinds of the two coeffects
  (kind, (inj1, inj2)) <- mguCoeffectTypesFromCoeffects s c c'
  -- subst <- unify c c'

  -- Add constraint for the coeffect (using ^op for the ordering compared with the order of equality)
  addConstraint (rel s (inj2 c') (inj1 c) kind)

  equalTypesRelatedCoeffects s rel t t' sp
  --(eq, subst') <- equalTypesRelatedCoeffectsInner s rel uS t t' sp
  --case subst of
  --  Just subst -> do
--      substFinal <- combineSubstitutions s subst subst'
--      return (eq, substFinal)
  --  Nothing -> return (False, [])

equalTypesRelatedCoeffectsInner s _ (TyVar n) (TyVar m) _ _ | n == m = do
  checkerState <- get
  case lookup n (tyVarContext checkerState) of
    Just _ -> return (True, [])
    Nothing -> throw UnboundTypeVariable { errLoc = s, errId = n }

equalTypesRelatedCoeffectsInner s _ (TyVar n) (TyVar m) sp _ = do
  checkerState <- get
  debugM "variable equality" $ pretty n <> " ~ " <> pretty m <> " where "
                            <> pretty (lookup n (tyVarContext checkerState)) <> " and "
                            <> pretty (lookup m (tyVarContext checkerState))

  case (lookup n (tyVarContext checkerState), lookup m (tyVarContext checkerState)) of

    -- Two universally quantified variables are unequal
    (Just (_, ForallQ), Just (_, ForallQ)) ->
        return (False, [])

    -- We can unify a universal a dependently bound universal
    (Just (TypeWithLevel (LSucc LZero) k1, ForallQ), Just (TypeWithLevel (LSucc LZero) k2, BoundQ)) ->
      tyVarConstraint (k1, n) (k2, m)

    (Just (TypeWithLevel (LSucc LZero) k1, BoundQ), Just (TypeWithLevel (LSucc LZero) k2, ForallQ)) ->
      tyVarConstraint (k1, n) (k2, m)


    -- We can unify two instance type variables
    (Just (TypeWithLevel (LSucc LZero) k1, InstanceQ), Just (TypeWithLevel (LSucc LZero) k2, BoundQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (TypeWithLevel (LSucc LZero) k1, BoundQ), Just (TypeWithLevel (LSucc LZero) k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (TypeWithLevel (LSucc LZero) k1, InstanceQ), Just (TypeWithLevel (LSucc LZero) k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (TypeWithLevel (LSucc LZero) k1, BoundQ), Just (TypeWithLevel (LSucc LZero) k2, BoundQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- But we can unify a forall and an instance
    (Just (TypeWithLevel (LSucc LZero) k1, InstanceQ), Just (TypeWithLevel (LSucc LZero) k2, ForallQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- But we can unify a forall and an instance
    (Just (TypeWithLevel (LSucc LZero) k1, ForallQ), Just (TypeWithLevel (LSucc LZero) k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    (t1, t2) -> error $ pretty s <> "-" <> show sp <> "\n"
              <> pretty n <> " : " <> show t1
              <> "\n" <> pretty m <> " : " <> show t2
  where
    tyVarConstraint (k1, n) (k2, m) = do
      jK <- k1 `joinKind` k2
      case jK of
        Just (TyCon kc, unif) -> do

          k <- inferKindOfType s (TyCon kc)
          -- Create solver vars for coeffects
          if isCoeffectKind k
            then addConstraint (Eq s (CVar n) (CVar m) (TyCon kc))
            else return ()
          return (True, unif ++ [(n, SubstT $ TyVar m)])
        Just (_, unif) ->
          return (True, unif ++ [(m, SubstT $ TyVar n)])
        Nothing ->
          return (False, [])

-- Duality is idempotent (left)
equalTypesRelatedCoeffectsInner s rel (TyApp (TyCon d') (TyApp (TyCon d) t)) t' k sp
  | internalName d == "Dual" && internalName d' == "Dual" =
  equalTypesRelatedCoeffectsInner s rel t t' k sp

-- Duality is idempotent (right)
equalTypesRelatedCoeffectsInner s rel t (TyApp (TyCon d') (TyApp (TyCon d) t')) k sp
  | internalName d == "Dual" && internalName d' == "Dual" =
  equalTypesRelatedCoeffectsInner s rel t t' k sp

equalTypesRelatedCoeffectsInner s rel (TyVar n) t kind sp = do
  checkerState <- get
  debugM "Types.equalTypesRelatedCoeffectsInner on TyVar"
          $ "span: " <> show s
          <> "\nTyVar: " <> show n <> " with " <> show (lookup n (tyVarContext checkerState))
          <> "\ntype: " <> show t <> "\nspec indicator: " <> show sp

  -- Do an occurs check for types
  case kind of
    Type LZero ->
       if n `elem` freeVars t
         then throw OccursCheckFail { errLoc = s, errVar = n, errTy = t }
         else return ()
    _ -> return ()

  case lookup n (tyVarContext checkerState) of
    -- We can unify an instance with a concrete type
    (Just (TypeWithLevel (LSucc LZero) k1, q)) | (q == BoundQ) || (q == InstanceQ) -> do --  && sp /= PatternCtxt

      jK <-  k1 `joinKind` kind
      case jK of
        Nothing -> throw UnificationKindError
          { errLoc = s, errTy1 = (TyVar n), errK1 = k1, errTy2 = t, errK2 = kind }

        -- If the kind is Nat, then create a solver constraint
        Just (TyCon (internalName -> "Nat"), unif) -> do
          nat <- compileNatKindedTypeToCoeffect s t
          addConstraint (Eq s (CVar n) nat (TyCon $ mkId "Nat"))
          return (True, unif ++ [(n, SubstT t)])

        Just (_, unif) -> return (True, unif ++ [(n, SubstT t)])

    (Just (TypeWithLevel (LSucc LZero) k1, ForallQ)) -> do

       -- If the kind if nat then set up and equation as there might be a
       -- pausible equation involving the quantified variable
       jK <- k1 `joinKind` kind
       case jK of
         Just (TyCon (Id "Nat" "Nat"), unif) -> do
           c1 <- compileNatKindedTypeToCoeffect s (TyVar n)
           c2 <- compileNatKindedTypeToCoeffect s t
           addConstraint $ Eq s c1 c2 (TyCon $ mkId "Nat")
           return (True, unif ++ [(n, SubstT t)])

         _ -> throw UnificationFail{ errLoc = s, errVar = n, errKind = k1, errTy = t }

    (Just _) -> error "Please open an issue at https://github.com/dorchard/granule/issues"
    Nothing -> throw UnboundTypeVariable { errLoc = s, errId = n }


equalTypesRelatedCoeffectsInner s rel t (TyVar n) k sp =
  equalTypesRelatedCoeffectsInner s rel (TyVar n) t k (flipIndicator sp)

-- Do duality check (left) [special case of TyApp rule]
equalTypesRelatedCoeffectsInner s rel (TyApp (TyCon d) t) t' _ sp
  | internalName d == "Dual" = isDualSession s rel t t' sp

equalTypesRelatedCoeffectsInner s rel t (TyApp (TyCon d) t') _ sp
  | internalName d == "Dual" = isDualSession s rel t t' sp

-- Equality on type application
equalTypesRelatedCoeffectsInner s rel (TyApp t1 t2) (TyApp t1' t2') _ sp = do
  (one, u1) <- equalTypesRelatedCoeffects s rel t1 t1' sp
  t2  <- substitute u1 t2
  t2' <- substitute u1 t2'
  (two, u2) <- equalTypesRelatedCoeffects s rel t2 t2' sp
  unifiers <- combineSubstitutions s u1 u2
  return (one && two, unifiers)

equalTypesRelatedCoeffectsInner s rel (TyCase t1 b1) (TyCase t1' b1') k sp = do
  -- Check guards are equal
  (r1, u1) <- equalTypesRelatedCoeffects s rel t1 t1' sp
  b1  <- mapM (pairMapM (substitute u1)) b1
  b1' <- mapM (pairMapM (substitute u1)) b1'
  -- Check whether there are the same number of branches
  let r2 = (length b1) == (length b1')
  -- Sort both branches by their patterns
  let bs = zip (sortBranch b1) (sortBranch b1')
  -- For each pair of branches, check whether the patterns are equal and the results are equal
  checkBs bs (r1 && r2) u1
    where
      sortBranch :: Ord a => [(a, b)] -> [(a, b)]
      sortBranch = sortBy (\(x, _) (y, _) -> compare x y)

      pairMapM :: Monad m => (a -> m b) -> (a, a) -> m (b, b)
      pairMapM f (x, y) = do
        x' <- f x
        y' <- f y
        return (x', y')

      checkBs [] r u = return (r, u)
      checkBs (((p1, t1), (p2, t2)) : bs) r u= do
        (r1, u1) <- equalTypesRelatedCoeffects s rel p1 p2 sp
        t1 <- substitute u1 t1
        t2 <- substitute u1 t2
        unifiers <- combineSubstitutions s u u1
        (r2, u2) <- equalTypesRelatedCoeffects s rel t1 t2 sp
        unifiers <- combineSubstitutions s unifiers u2
        checkBs bs (r && r1 && r2) unifiers

equalTypesRelatedCoeffectsInner s rel t1 t2 k sp =
--TODO: fix isEffect case
  -- Look to see if we are doing equality on sets that are not effects
  case (t1, t2) of
    -- If so do set equality (no approximation)
    (TySet ts1, TySet ts2) ->
      return (all (`elem` ts2) ts1 && all (`elem` ts1) ts2, [])

    -- Otherwise look at other equalities
    _ -> equalOtherKindedTypesGeneric s t1 t2 k

{-
equalTypesRelatedCoeffectsInner s rel t1 t2 k sp = do
  if isEffectType k
    then do
      -- If the kind of this equality is Effect
      -- then use effect equality (and possible approximation)
      eq <- effApproximates s effTy t1 t2
      return (eq, [])
    else
      -- Look to see if we are doing equality on sets that are not effects
      case (t1, t2) of
        -- If so do set equality (no approximation)
        (TySet ts1, TySet ts2) ->
          return (all (`elem` ts2) ts1 && all (`elem` ts1) ts2, [])

        -- Otherwise look at other equalities
        _ -> equalOtherKindedTypesGeneric s t1 t2 k


TODO: Fix above base case definition. effTy isn't defined, and effApproximates expects Type Zeroes when it's working with Coeffect constraints (????)
equalTypesRelatedCoeffectsInner s rel t1 t2 k sp = do
  effTyM <- isEffectTypeFromKind s k
  case effTyM of
    Right effTy -> do
      -- If the kind of this equality is Effect
      -- then use effect equality (and possible approximation)
      eq <- effApproximates s effTy t1 t2
      return (eq, [])
    Left k ->
      -- Look to see if we are doing equality on sets that are not effects
      case (t1, t2) of
        -- If so do set equality (no approximation)
        (TySet ts1, TySet ts2) ->
          return (all (`elem` ts2) ts1 && all (`elem` ts1) ts2, [])

        -- Otherwise look at other equalities
        _ -> equalOtherKindedTypesGeneric s t1 t2 k
-}

{- | Equality on other types (e.g. Nat and Session members) -}
equalOtherKindedTypesGeneric :: (?globals :: Globals)
    => Span
    -> Type Zero
    -> Type Zero
    -> Kind
    -> Checker (Bool, Substitution)
equalOtherKindedTypesGeneric s t1 t2 k = do
  case k of
    TyCon (internalName -> "Nat") -> do
      c1 <- compileNatKindedTypeToCoeffect s t1
      c2 <- compileNatKindedTypeToCoeffect s t2
      addConstraint $ Eq s c1 c2 (TyCon $ mkId "Nat")
      return (True, [])

    TyCon (internalName -> "Protocol") ->
      sessionInequality s t1 t2

    Type LZero -> throw UnificationError{ errLoc = s, errTy1 = t1, errTy2 = t2}

    _ ->
      throw UndefinedEqualityKindError
        { errLoc = s, errTy1 = t1, errK1 = k, errTy2 = t2, errK2 = k }

-- Essentially use to report better error messages when two session type
-- are not equality
sessionInequality :: (?globals :: Globals)
    => Span -> Type Zero -> Type Zero -> Checker (Bool, Substitution)
sessionInequality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Send" && internalName c' == "Send" = do
  (g, _, u) <- equalTypes s t t'
  return (g, u)

sessionInequality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Recv" && internalName c' == "Recv" = do
  (g, _, u) <- equalTypes s t t'
  return (g, u)

sessionInequality s (TyCon c) (TyCon c')
  | internalName c == "End" && internalName c' == "End" =
  return (True, [])

sessionInequality s t1 t2 = throw TypeError{ errLoc = s, tyExpected = t1, tyActual = t2 }

isDualSession :: (?globals :: Globals)
    => Span
       -- Explain how coeffects should be related by a solver constraint
    -> (Span -> Coeffect -> Coeffect -> Type One -> Constraint)
    -> Type Zero
    -> Type Zero
    -- Indicates whether the first type or second type is a specification
    -> SpecIndicator
    -> Checker (Bool, Substitution)
isDualSession sp rel (TyApp (TyApp (TyCon c) t) s) (TyApp (TyApp (TyCon c') t') s') ind
  |  (internalName c == "Send" && internalName c' == "Recv")
  || (internalName c == "Recv" && internalName c' == "Send") = do
  (eq1, u1) <- equalTypesRelatedCoeffects sp rel t t' ind
  s <- substitute u1 s
  s' <- substitute u1 s'
  (eq2, u2) <- isDualSession sp rel s s' ind
  u <- combineSubstitutions sp u1 u2
  return (eq1 && eq2, u)

isDualSession _ _ (TyCon c) (TyCon c') _
  | internalName c == "End" && internalName c' == "End" =
  return (True, [])

isDualSession sp rel t (TyVar v) ind =
  equalTypesRelatedCoeffects sp rel (TyApp (TyCon $ mkId "Dual") t) (TyVar v) ind

isDualSession sp rel (TyVar v) t ind =
  equalTypesRelatedCoeffects sp rel (TyVar v) (TyApp (TyCon $ mkId "Dual") t) ind

isDualSession sp _ t1 t2 _ = throw
  SessionDualityError{ errLoc = sp, errTy1 = t1, errTy2 = t2 }


-- Essentially equality on types but join on any coeffects
joinTypes :: (?globals :: Globals) => Span -> Type Zero -> Type Zero -> Checker (Type Zero)
joinTypes s t t' | t == t' = return t

joinTypes s (FunTy t1 t2) (FunTy t1' t2') = do
  t1j <- joinTypes s t1' t1 -- contravariance
  t2j <- joinTypes s t2 t2'
  return (FunTy t1j t2j)

joinTypes _ (TyCon t) (TyCon t') | t == t' = return (TyCon t)

joinTypes s (Diamond ef t) (Diamond ef' t') = do
  tj <- joinTypes s t t'
  ej <- joinTypes s ef ef'
  return (Diamond ej tj)

joinTypes s (Box c t) (Box c' t') = do
  (coeffTy, (inj1, inj2)) <- mguCoeffectTypesFromCoeffects s c c'
  -- Create a fresh coeffect variable
  topVar <- freshTyVarInContext (mkId "") coeffTy
  -- Unify the two coeffects into one
  addConstraint (ApproximatedBy s (inj1 c)  (CVar topVar) coeffTy)
  addConstraint (ApproximatedBy s (inj2 c') (CVar topVar) coeffTy)
  tUpper <- joinTypes s t t'
  return $ Box (CVar topVar) tUpper

-- TODO: Replace how this Nat is constructed?
joinTypes s (TyInt n) (TyVar m) = do
  -- Create a fresh coeffect variable
  let ty = TyCon $ mkId "Nat"
  ty' <- tryTyPromote s ty
  var <- freshTyVarInContext m ty'
  -- Unify the two coeffects into one
  addConstraint (Eq s (CNat n) (CVar var) ty)
  return $ TyInt n

joinTypes s (TyVar n) (TyInt m) = joinTypes s (TyInt m) (TyVar n)

joinTypes s (TyVar n) (TyVar m) = {- do

  kind <- inferKindOfType s (TyVar n)
  case kind of
    TyPromote t -> do

      nvar <- freshTyVarInContextWithBinding n kind BoundQ
      -- Unify the two variables into one
      addConstraint (ApproximatedBy s (CVar n) (CVar nvar) t)
      addConstraint (ApproximatedBy s (CVar m) (CVar nvar) t)
      return $ TyVar nvar

    _ -> error $ "Trying to join two type variables: " ++ pretty n ++ " and " ++ pretty m -}
  error $ "Trying to join two type variables: " ++ pretty n ++ " and " ++ pretty m

joinTypes s (TyApp t1 t2) (TyApp t1' t2') = do
  t1'' <- joinTypes s t1 t1'
  t2'' <- joinTypes s t2 t2'
  return (TyApp t1'' t2'')

-- TODO: Create proper substitutions
joinTypes s (TyVar _) t = return t
joinTypes s t (TyVar _) = return t

joinTypes s t1 t2 = do
    --TODO: Remove type promotion?
    t1' <- tryTyPromote s t1
    t2' <- tryTyPromote s t2

    -- See if the two types are actually effects and if so do the join
    ef1 <- isEffectType s t1'
    ef2 <- isEffectType s t2'
    if ef1 && ef2
      then do
        -- Check that the types of the effect terms match
        (eq, _, u) <- equalTypes s t1 t2
        -- If equal, do the upper bound
        if eq
          then do effectUpperBound s t1 t1 t2
          else do
            efTy1 <- tryTyPromote s t1
            efTy2 <- tryTyPromote s t2
            throw $ KindMismatch { errLoc = s, tyActualK = Just t1, kExpected = efTy1, kActual = efTy2 }
      else throw $ NoUpperBoundError{ errLoc = s, errTy1 = t1, errTy2 = t2 }

-- TODO: eventually merge this with joinKind
equalKinds :: (?globals :: Globals) => Span -> Kind -> Kind -> Checker (Bool, Kind, Substitution)
equalKinds sp k1 k2 | k1 == k2 = return (True, k1, [])
equalKinds sp (FunTy k1 k1') (FunTy k2 k2') = do
    (eq, k, u) <- equalKinds sp k1 k2
    (eq', k', u') <- equalKinds sp k1' k2'
    u2 <- combineSubstitutions sp u u'
    return $ (eq && eq', FunTy k k', u2)
equalKinds sp (TyVar v) k = do
    return (True, k, [(v, SubstK k)])
equalKinds sp k (TyVar v) = do
    return (True, k, [(v, SubstK k)])
equalKinds sp k1 k2 = do
    jK <- joinKind k1 k2
    case jK of
      Just (k, u) -> return (True, k, u)
      Nothing -> throw $ KindsNotEqual { errLoc = sp, errK1 = k1, errK2 = k2 }

twoEqualEffectTypes :: (?globals :: Globals) => Span -> Type Zero -> Type Zero -> Checker (Type Zero, Substitution)
twoEqualEffectTypes s ef1 ef2 = do
    --TODO: See if this function makes more sense as Span -> Type One -> Type One -> ... instead of promoting the types
    ef1' <- tryTyPromote s ef1
    ef2' <- tryTyPromote s ef2

    mef1 <- isEffectType s ef1'
    mef2 <- isEffectType s ef2'
    if mef1
      then do
        if mef2
          then do
            -- Check that the types of the effect terms match
            (eq, _, u) <- equalTypes s ef1 ef2
            if eq then do
              return (ef1, u)
            else do
              efTy1' <- tryTyPromote s ef1
              efTy2' <- tryTyPromote s ef2
              throw $ KindMismatch { errLoc = s, tyActualK = Just ef1, kExpected = efTy1', kActual = efTy2' }
          else do
            k <- inferKindOfType s ef2
            throw $ UnknownResourceAlgebra { errLoc = s, errTy = ef2 , errK = k }
      else do
        k <- inferKindOfType s ef1
        throw $ UnknownResourceAlgebra { errLoc = s, errTy = ef1 , errK = k }

-- | Find out if a type is indexed
isIndexedType :: Type Zero -> Checker Bool
isIndexedType t = do
  b <- typeFoldM0 TypeFoldZero
      { tfFunTy0 = \(Const x) (Const y) -> return $ Const (x || y)
      , tfTyCon0 = \c -> do {
          st <- get;
          return $ Const $ case lookup c (typeConstructors st) of Just (_,_,ixed) -> ixed; Nothing -> False }
      , tfBox0 = \_ (Const x) -> return $ Const x
      , tfDiamond0 = \_ (Const x) -> return $ Const x
      , tfTyVar0 = \_ -> return $ Const False
      , tfTyApp0 = \(Const x) (Const y) -> return $ Const (x || y)
      , tfTyInt0 = \_ -> return $ Const False
      , tfTyInfix0 = \_ (Const x) (Const y) -> return $ Const (x || y)
      , tfSet0 = \_ -> return $ Const False
      , tfTyCase0 = \_ _ -> return $ Const False } t
  return $ getConst b