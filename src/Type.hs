{-# LANGUAGE FlexibleInstances, FlexibleContexts #-}

module Type where

import Expr
import Eval hiding (Env, empty, extend)
import Data.List
import Data.Maybe
import Data.Either
import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe
import Control.Monad
import Data.SBV

{- Provides coeffects, and helpers for manipulating types and type
environments -}

type TyOrDisc = Either Type (Coeffect, Type)

class Semiring c where
  plus  :: c -> c -> c
  mult  :: c -> c -> c
  one   :: c
  zero  :: c

instance Semiring Coeffect where
  plus (Nat n) (Nat m) = Nat (n + m)
  plus c d = CPlus c d
  mult (Nat n) (Nat m) = Nat (n * m)
  mult c d = CTimes c d
  one = Nat 1
  zero = Nat 0

empty = []
type Env t = [(Id, t)]

-- replace an item in an environment
replace :: Env a -> Id -> a -> Env a
replace [] id v
  = [(id, v)]
replace ((id', _):env) id v | id == id'
  = (id', v) : env
replace (x : env) id v
  = x : replace env id v

-- ExtCtxt the environment
extCtxt :: Env TyOrDisc -> Id -> TyOrDisc -> Env TyOrDisc
extCtxt env id (Left t) =
  case (lookup id env) of
    Just (Left t') ->
       if t == t'
        then error $ "'" ++ id ++ "' used more than once" -- env
        else error $ "Type clash for variable " ++ id
    Just (Right (c, t')) ->
       if t == t'
         then replace env id (Right (c `plus` one, t))
         else error $ "Type clash for variable " ++ id
    Nothing -> (id, Left t) : env
extCtxt env id (Right (c, t)) =
  case (lookup id env) of
    Just (Right (c', t')) ->
        if t == t'
        then replace env id (Right (c `plus` c', t'))
        else error $ "Type clash for variable " ++ id
    Just (Left t') ->
        if t == t'
        then replace env id (Right (c `plus` one, t))
        else error $ "Type clash for variable " ++ id
    Nothing -> (id, Right (c, t)) : env

-- Given an environment, derelict and discharge all variables which are not discharged
multAll :: [Id] -> Coeffect -> Env TyOrDisc -> Env TyOrDisc

multAll _ _ []
    = []

multAll vars c ((id, Left t) : env) | id `elem` vars
    = (id, Right (c, t)) : multAll vars c env

multAll vars c ((id, Right (c', t)) : env) | id `elem` vars
    = (id, Right (c `mult` c', t)) : multAll vars c env

multAll vars c ((id, Left t) : env) = multAll vars c env
multAll vars c ((id, Right (_, t)) : env) = multAll vars c env

-- Combine two contexts
ctxPlus :: Env TyOrDisc -> Env TyOrDisc -> Env TyOrDisc
ctxPlus [] env2 = env2
ctxPlus ((i, v) : env1) env2 =
  ctxPlus env1 (extCtxt env2 i v)

instance Pretty (Type, Env TyOrDisc) where
  pretty (t, env) = pretty t


keyIntersect :: Env a -> Env a -> Env a
keyIntersect a b = sortBy (\a b -> fst a `compare` fst b) $ filter (appearsIn a) b
  where appearsIn a (id, _) = isJust $ lookup id a


vars :: Coeffect -> [String]
vars (CVar v) = [v]
vars (CPlus n m) = vars n ++ vars m
vars (CTimes n m) = vars n ++ vars m
vars _ = []

deleteVar :: Eq a => a -> [(a, b)] -> [(a, b)]
deleteVar x [] = []
deleteVar x ((y, b) : m) | x == y = deleteVar x m
                      | otherwise = (y, b) : deleteVar x m