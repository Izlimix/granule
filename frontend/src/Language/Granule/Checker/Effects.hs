{- Deals with effect algebras -}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

module Language.Granule.Checker.Effects where

import Language.Granule.Checker.Constraints.Compile
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates
import qualified Language.Granule.Checker.Primitives as P (setElements, typeConstructors)
import Language.Granule.Checker.Variables

import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Type
import Language.Granule.Syntax.Span

import Language.Granule.Utils

import Data.List (nub)
import Data.Maybe (mapMaybe)

-- Describe all effect types that are based on a union-emptyset monoid
unionSetLike :: Id -> Bool
unionSetLike (internalName -> "IO") = True
unionSetLike _ = False

-- `isEffUnit sp effTy eff` checks whether `eff` of effect type `effTy`
-- is equal to the unit element of the algebra.
isEffUnit :: (?globals :: Globals) => Span -> Type Zero -> Type Zero -> Checker Bool
isEffUnit s effTy eff =
    case effTy of
        -- Nat case
        TyCon (internalName -> "Nat") -> do
            nat <- compileNatKindedTypeToCoeffect s eff
            addConstraint (Eq s (CNat 0) nat (TyCon $ mkId "Nat"))
            return True
        -- Session singleton case
        TyCon (internalName -> "Com") -> do
            return True
        -- IO set case
        -- Any union-set effects, like IO
        TyCon c | unionSetLike c ->
            case eff of
                (TySet []) -> return True
                _          -> return False
        -- Unknown
        _ -> do
            effTy' <- tryTyPromote s effTy
            throw $ UnknownResourceAlgebra { errLoc = s, errTy = eff, errK = effTy' }

-- `effApproximates s effTy eff1 eff2` checks whether `eff1 <= eff2` for the `effTy`
-- resource algebra
effApproximates :: (?globals :: Globals) => Span -> Type Zero -> Type Zero -> Type Zero -> Checker Bool
effApproximates s effTy eff1 eff2 =
    -- as 1 <= e for all e
    if isPure eff1 then return True
    else
        case effTy of
            -- Nat case
            TyCon (internalName -> "Nat") -> do
                nat1 <- compileNatKindedTypeToCoeffect s eff1
                nat2 <- compileNatKindedTypeToCoeffect s eff2
                addConstraint (LtEq s nat1 nat2)
                return True
            -- Session singleton case
            TyCon (internalName -> "Com") -> do
                return True
            -- IO set case
            -- Any union-set effects, like IO
            TyCon c | unionSetLike c ->
                case eff1 of
                    (TyCon (internalName -> "Pure")) -> return True
                    (TySet efs1) ->
                        case eff2 of
                            (TySet efs2) ->
                                -- eff1 is a subset of eff2
                                return $ all (\ef1 -> ef1 `elem` efs2) efs1
                            _ -> return False
                    _ -> return False
            -- Unknown effect resource algebra
            _ -> do
              effTy <- tryTyPromote s effTy
              throw $ UnknownResourceAlgebra { errLoc = s, errTy = eff1, errK = effTy }

effectMult :: Span -> Type Zero -> Type Zero -> Type Zero -> Checker (Type Zero)
effectMult sp effTy t1 t2 = do
  if isPure t1 then return t2
  else if isPure t2 then return t1
    else
      case effTy of
        -- Nat effects
        TyCon (internalName -> "Nat") ->
          return $ TyInfix TyOpPlus t1 t2

        -- Com (Session), so far just a singleton
        TyCon (internalName -> "Com") ->
          return $ TyCon $ mkId "Session"

        -- Any union-set effects, like IO
        TyCon c | unionSetLike c ->
          case (t1, t2) of
            -- Actual sets, take the union
            (TySet ts1, TySet ts2) ->
              return $ TySet $ nub (ts1 <> ts2)
            _ -> throw $
                  TypeError { errLoc = sp, tyExpected = TySet [TyVar $ mkId "?"], tyActual = t1 }
        _ -> do
          effTy <- tryTyPromote sp effTy
          throw $ UnknownResourceAlgebra { errLoc = sp, errTy = t1, errK = effTy }

effectUpperBound :: (?globals :: Globals) => Span -> Type Zero -> Type Zero -> Type Zero -> Checker (Type Zero)
effectUpperBound s t@(TyCon (internalName -> "Nat")) t1 t2 = do
    t <- tryTyPromote s t
    nvar <- freshTyVarInContextWithBinding (mkId "n") t BoundQ
    -- Unify the two variables into one
    nat1 <- compileNatKindedTypeToCoeffect s t1
    nat2 <- compileNatKindedTypeToCoeffect s t2
    addConstraint (ApproximatedBy s nat1 (CVar nvar) t)
    addConstraint (ApproximatedBy s nat2 (CVar nvar) t)
    return $ TyVar nvar

effectUpperBound _ t@(TyCon (internalName -> "Com")) t1 t2 = do
    return $ TyCon $ mkId "Session"

effectUpperBound s t@(TyCon c) t1 t2 | unionSetLike c = do
    case t1 of
        TySet efs1 ->
            case t2 of
                TySet efs2 ->
                    -- Both sets, take the union
                    return $ TySet (nub (efs1 ++ efs2))
                -- Unit right
                TyCon (internalName -> "Pure") ->
                    return t1
                _ -> throw NoUpperBoundError{ errLoc = s, errTy1 = t1, errTy2 = t2 }
        -- Unift left
        TyCon (internalName -> "Pure") ->
            return t2
        _ ->  throw NoUpperBoundError{ errLoc = s, errTy1 = t1, errTy2 = t2 }

effectUpperBound s effTy t1 t2 = do
    effTy <- tryTyPromote s effTy
    throw UnknownResourceAlgebra{ errLoc = s, errTy = t1, errK = effTy }

-- "Top" element of the effect
effectTop :: Type Zero -> Maybe (Type Zero)
effectTop (TyCon (internalName -> "Nat")) = Nothing
effectTop (TyCon (internalName -> "Com")) = Just $ TyCon $ mkId "Session"
-- Otherwise
-- Based on an effect type, provide its top-element, which for set-like effects
-- like IO can later be aliased to the name of effect type,
-- i.e., a <IO> is an alias for a <{Read, Write, ... }>
effectTop t = do
    -- Compute the full-set of elements based on the the kinds of elements
    -- in the primitives
    elemKind <- lookup t (map swap P.setElements)
    return (TySet (map TyCon (allConstructorsMatchingElemKind elemKind)))
  where
    swap (a, b) = (b, a)
    -- find all elements of the matching element type
    allConstructorsMatchingElemKind :: Kind -> [Id]
    allConstructorsMatchingElemKind elemKind = mapMaybe (go elemKind) P.typeConstructors
    go :: Kind -> (Id, (TypeWithLevel, a, Bool)) -> Maybe Id
    go elemKind (con, (TypeWithLevel (LSucc LZero) k, _, _)) =
        if k == elemKind then Just con else Nothing
    -- Level doesn't match
    go elemKind _ = Nothing

isPure :: Type Zero -> Bool
isPure (TyCon c) = internalName c == "Pure"
isPure _ = False