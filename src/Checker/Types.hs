{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Checker.Types where

import Syntax.Expr
import Syntax.Pretty
import Context
import Data.List

import Control.Monad.Trans.Maybe
import Control.Monad.State.Strict

import Checker.Coeffects
import Checker.Constraints
import Checker.Environment

-- Given a pattern and its type, construct the binding environment
-- for that pattern
ctxtFromTypedPattern
   :: Bool -> Span -> Type -> Pattern -> MaybeT Checker (Maybe [(Id, Assumption)])
ctxtFromTypedPattern _ _ _              (PWild _)      = return $ Just []
ctxtFromTypedPattern _ _ t              (PVar _ v)     = return $ Just [(v, Linear t)]
ctxtFromTypedPattern _ _ (ConT "Int")   (PInt _ _)     = return $ Just []
ctxtFromTypedPattern _ _ (ConT "Float") (PFloat _ _)   = return $ Just []
ctxtFromTypedPattern _ _ (Box c t)      (PBox _ (PVar _ v))  = return $  Just [(v, Discharged t c)]
ctxtFromTypedPattern _ _ (ConT "Bool")  (PConstr _ "True")  = return $ Just []
ctxtFromTypedPattern _ _ (ConT "Bool")  (PConstr _ "False") = return $ Just []
ctxtFromTypedPattern _ _ (ConT "List")  (PConstr _ "Cons")  = return $ Just []
ctxtFromTypedPattern _ s (TyApp (TyApp (ConT "List") n) _) (PConstr _ "Nil") = do
  let kind       = CConstr "Nat="
  case n of
    TyVar v -> addConstraint $ Eq s (CVar v) (CNat Discrete 0) kind
    TyInt n -> addConstraint $ Eq s (CNat Discrete n) (CNat Discrete 0) kind
  return $ Just []
ctxtFromTypedPattern dbg s (TyApp (TyApp (ConT "List") n) t) (PApp _ (PApp _ (PConstr _ "Cons") p1) p2) = do
  bs1 <- ctxtFromTypedPattern dbg s t p1
  sizeVar <- freshVar "in"
  let sizeVarInc = CPlus (CVar sizeVar) (CNat Discrete 1)
  let kind       = CConstr "Nat="
  -- Update coeffect-kind environment
  checkerState <- get
  put $ checkerState { ckenv = (sizeVar, (kind, ExistsQ)) : ckenv checkerState }
  -- Generate equality constraint
  case n of
    TyVar v -> addConstraint $ Eq s (CVar v) sizeVarInc kind
    TyInt n -> addConstraint $ Eq s (CNat Discrete n) sizeVarInc kind
  bs2 <- ctxtFromTypedPattern dbg s (TyApp (TyApp (ConT "List") (TyVar sizeVar)) t) p2
  return $ bs1 >>= (\bs1' -> bs2 >>= (\bs2' -> Just (bs1' ++ bs2')))
ctxtFromTypedPattern _ _ t p = return Nothing

-- Check whether two types are equal, and at the same time
-- generate coeffect equality constraints
--
-- The first argument is taken to be possibly approximated by the second
-- e.g., the first argument is inferred, the second is a specification
-- being checked against
equalTypes :: Bool -> Span -> Type -> Type -> MaybeT Checker Bool
equalTypes dbg s (FunTy t1 t2) (FunTy t1' t2') = do
  eq1 <- equalTypes dbg s t1' t1 -- contravariance
  eq2 <- equalTypes dbg s t2 t2' -- covariance
  return (eq1 && eq2)

equalTypes _ _ (ConT con) (ConT con') = return (con == con')

equalTypes dbg s (Diamond ef t) (Diamond ef' t') = do
  eq <- equalTypes dbg s t t'
  if ef == ef'
    then return eq
    else do
      illGraded s $ "Effect mismatch: " ++ pretty ef
                  ++ " not equal to " ++ pretty ef'
      halt

equalTypes dbg s (Box c t) (Box c' t') = do
  -- Debugging
  dbgMsg dbg $ pretty c ++ " == " ++ pretty c'
  dbgMsg dbg $ "[ " ++ show c ++ " , " ++ show c' ++ "]"
  -- Unify the coeffect kinds of the two coeffects
  kind <- mguCoeffectKinds s c c'
  addConstraint (Leq s c c' kind)
  equalTypes dbg s t t'

equalTypes dbg s (TyApp t1 t2) (TyApp t1' t2') = do
  one <- equalTypes dbg s t1 t1'
  two <- equalTypes dbg s t2 t2'
  return (one && two)

equalTypes dbg s (TyInt n) (TyVar m) = do
  addConstraint (Eq s (CNat Discrete n) (CVar m) (CConstr "Nat="))
  return True

equalTypes dbg s (TyVar n) (TyInt m) = do
  addConstraint (Eq s (CVar n) (CNat Discrete m) (CConstr "Nat="))
  return True

equalTypes dbg s (TyVar n) (TyVar m) = do
  addConstraint (Eq s (CVar n) (CVar m) (CConstr "Nat="))
  return True

equalTypes dbg s (TyInt n) (TyInt m) = do
  return (n == m)

equalTypes _ s t1 t2 =
  illTyped s $ "Expected '" ++ pretty t2 ++ "' but got '" ++ pretty t1 ++ "'"

-- Essentially equality on types but join on any coeffects
joinTypes :: Bool -> Span -> Type -> Type -> MaybeT Checker Type
joinTypes dbg s (FunTy t1 t2) (FunTy t1' t2') = do
  t1j <- joinTypes dbg s t1' t1 -- contravariance
  t2j <- joinTypes dbg s t2 t2'
  return (FunTy t1j t2j)

joinTypes _ _ (ConT t) (ConT t') | t == t' = return (ConT t)

joinTypes dbg s (Diamond ef t) (Diamond ef' t') = do
  tj <- joinTypes dbg s t t'
  if ef == ef'
    then return (Diamond ef tj)
    else do
      illGraded s $ "Effect mismatch: " ++ pretty ef ++ " not equal to " ++ pretty ef'
      halt

joinTypes dbg s (Box c t) (Box c' t') = do
  kind <- mguCoeffectKinds s c c'
  -- Create a fresh coeffect variable
  topVar <- freshCoeffectVar "" kind
  -- Unify the two coeffects into one
  addConstraint (Leq s c  (CVar topVar) kind)
  addConstraint (Leq s c' (CVar topVar) kind)
  tu <- joinTypes dbg s t t'
  return $ Box (CVar topVar) tu


joinTypes dbg s (TyInt n) (TyInt m) | n == m = do
  return $ TyInt n

joinTypes dbg s (TyInt n) (TyVar m) = do
  -- Create a fresh coeffect variable
  let kind = CConstr "Nat="
  var <- freshCoeffectVar m kind
  -- Unify the two coeffects into one
  addConstraint (Eq s (CNat Discrete n) (CVar var) kind)
  return $ TyInt n

joinTypes dbg s (TyVar n) (TyInt m) = do
  joinTypes dbg s (TyInt m) (TyVar n)

joinTypes dbg s (TyVar n) (TyVar m) = do
  -- Create fresh variables for the two tyint variables
  let kind = CConstr "Nat="
  nvar <- freshCoeffectVar n kind
  mvar <- freshCoeffectVar m kind
  -- Unify the two variables into one
  addConstraint (Leq s (CVar nvar) (CVar mvar) kind)
  return $ TyVar n

joinTypes dbg s (TyApp t1 t2) (TyApp t1' t2') = do
  t1'' <- joinTypes dbg s t1 t1'
  t2'' <- joinTypes dbg s t2 t2'
  return (TyApp t1'' t2'')

joinTypes _ s t1 t2 =
  illTyped s
    $ "Type '" ++ pretty t1 ++ "' and '"
               ++ pretty t2 ++ "' have no upper bound"



instance Pretty (Type, Env Assumption) where
    pretty (t, _) = pretty t

instance Pretty (Id, Assumption) where
    pretty (v, ty) = v ++ " : " ++ pretty ty

instance Pretty Assumption where
    pretty (Linear ty) = pretty ty
    pretty (Discharged ty c) = "|" ++ pretty ty ++ "|." ++ pretty c

instance Pretty (Env TypeScheme) where
   pretty xs = "{" ++ intercalate "," (map pp xs) ++ "}"
     where pp (var, t) = var ++ " : " ++ pretty t

instance Pretty (Env Assumption) where
   pretty xs = "{" ++ intercalate "," (map pp xs) ++ "}"
     where pp (var, Linear t) = var ++ " : " ++ pretty t
           pp (var, Discharged t c) = var ++ " : .[" ++ pretty t ++ "]. " ++ pretty c
