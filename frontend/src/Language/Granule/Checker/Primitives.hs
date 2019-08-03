-- Provides all the type information for built-ins
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE QuasiQuotes #-}

module Language.Granule.Checker.Primitives where

import Data.List (genericLength)
import Data.List.NonEmpty (NonEmpty(..))
import Text.RawString.QQ (r)

import Language.Granule.Checker.SubstitutionContexts

import Language.Granule.Syntax.Def
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Parser (parseDefs)
import Language.Granule.Syntax.Type
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Expr (Operator(..))

nullSpanBuiltin :: Span
nullSpanBuiltin = Span (0, 0) (0, 0) "Builtin"

-- Given a name to the powerset of a set of particular elements,
-- where (Y, PY) in setElements means that PY is an alias for the powerset of Y.
setElements :: [(Kind, Type)]
setElements = [(KPromote $ TyCon $ mkId "IOElem", TyCon $ mkId "IO")]

typeConstructors :: [(Id, (Kind, Cardinality))] -- TODO Cardinality is not a good term
typeConstructors =
    [ (mkId "ArrayStack", (KFun kNat (KFun kNat (KFun KType KType)), Nothing))
    , (mkId ",", (KFun KType (KFun KType KType), Just 1))
    , (mkId "×", (KFun KCoeffect (KFun KCoeffect KCoeffect), Just 1))
    , (mkId "Int",  (KType, Nothing))
    , (mkId "Float", (KType, Nothing))
    , (mkId "Char", (KType, Nothing))
    , (mkId "String", (KType, Nothing))
    , (mkId "Protocol", (KType, Nothing))
    , (mkId "Nat",  (KUnion KCoeffect KEffect, Nothing))
    , (mkId "Q",    (KCoeffect, Nothing)) -- Rationals
    , (mkId "Level", (KCoeffect, Nothing)) -- Security level
    , (mkId "Interval", (KFun KCoeffect KCoeffect, Nothing))
    , (mkId "Set", (KFun (KVar $ mkId "k") (KFun (kConstr $ mkId "k") KCoeffect), Nothing))
    -- File stuff
    -- Channels and protocol types
    , (mkId "Send", (KFun KType (KFun protocol protocol), Nothing))
    , (mkId "Recv", (KFun KType (KFun protocol protocol), Nothing))
    , (mkId "End" , (protocol, Nothing))
    , (mkId "Chan", (KFun protocol KType, Nothing))
    , (mkId "Dual", (KFun protocol protocol, Nothing))
    , (mkId "->", (KFun KType (KFun KType KType), Nothing))
    -- Top completion on a coeffect, e.g., Ext Nat is extended naturals (with ∞)
    , (mkId "Ext", (KFun KCoeffect KCoeffect, Nothing))
    -- Effect grade types - Sessions
    , (mkId "Session", (KPromote (TyCon $ mkId "Com"), Nothing))
    , (mkId "Com", (KEffect, Nothing))
    -- Effect grade types - IO
    , (mkId "IO", (KEffect, Nothing))
    , (mkId "Stdout", (KPromote (TyCon $ mkId "IOElem"), Nothing))
    , (mkId "Stdin", (KPromote (TyCon $ mkId "IOElem"), Nothing))
    , (mkId "Stderr", (KPromote (TyCon $ mkId "IOElem"), Nothing))
    , (mkId "Open", (KPromote (TyCon $ mkId "IOElem"), Nothing))
    , (mkId "Read", (KPromote (TyCon $ mkId "IOElem"), Nothing))
    , (mkId "Write", (KPromote (TyCon $ mkId "IOElem"), Nothing))
    , (mkId "IOExcept", (KPromote (TyCon $ mkId "IOElem"), Nothing))
    , (mkId "Close", (KPromote (TyCon $ mkId "IOElem"), Nothing))
    ] ++ builtinTypeConstructors

tyOps :: TypeOperator -> (Kind, Kind, Kind)
tyOps = \case
    TyOpLesser -> (kNat, kNat, (KConstraint Predicate))
    TyOpLesserEq -> (kNat, kNat, (KConstraint Predicate))
    TyOpGreater -> (kNat, kNat, (KConstraint Predicate))
    TyOpGreaterEq -> (kNat, kNat, (KConstraint Predicate))
    TyOpEq -> (kNat, kNat, (KConstraint Predicate))
    TyOpNotEq -> (kNat, kNat, (KConstraint Predicate))
    TyOpPlus -> (kNat, kNat, kNat)
    TyOpTimes -> (kNat, kNat, kNat)
    TyOpMinus -> (kNat, kNat, kNat)
    TyOpExpon -> (kNat, kNat, kNat)
    TyOpMeet -> (kNat, kNat, kNat)
    TyOpJoin -> (kNat, kNat, kNat)

dataConstructors :: [(Id, (TypeScheme, Substitution))]
dataConstructors =
    [ ( mkId ",", (Forall nullSpanBuiltin [((mkId "a"),KType),((mkId "b"),KType)] []
        (FunTy (TyVar (mkId "a"))
          (FunTy (TyVar (mkId "b"))
                 (TyApp (TyApp (TyCon (mkId ",")) (TyVar (mkId "a"))) (TyVar (mkId "b"))))), [])
      )
    ] ++ builtinDataConstructors

binaryOperators :: Operator -> NonEmpty Type
binaryOperators = \case
    OpPlus ->
      FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Int"))
      :| [FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Float"))]
    OpMinus ->
      FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Int"))
      :| [FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Float"))]
    OpTimes ->
      FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Int"))
      :| [FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Float"))]
    OpEq ->
      FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool"))
      :| [FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool"))]
    OpNotEq ->
      FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool"))
      :| [FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool"))]
    OpLesserEq ->
      FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool"))
      :| [FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool"))]
    OpLesser ->
      FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool"))
      :| [FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool"))]
    OpGreater ->
      FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool"))
      :| [FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool"))]
    OpGreaterEq ->
      FunTy (TyCon $ mkId "Int") (FunTy (TyCon $ mkId "Int") (TyCon $ mkId "Bool"))
      :| [FunTy (TyCon $ mkId "Float") (FunTy (TyCon $ mkId "Float") (TyCon $ mkId "Bool"))]

-- TODO make a proper quasi quoter that parses this at compile time
builtinSrc :: String
builtinSrc = [r|

import Prelude

data () = ()

--------------------------------------------------------------------------------
-- Arithmetic
--------------------------------------------------------------------------------

div : Int -> Int -> Int
div = BUILTIN

--------------------------------------------------------------------------------
-- Graded Possiblity
--------------------------------------------------------------------------------

pure
  : forall {a : Type}
  . a -> a <>
pure = BUILTIN

--------------------------------------------------------------------------------
-- I/O
--------------------------------------------------------------------------------

fromStdin : String <{Stdin}>
fromStdin = BUILTIN

toStdout : String -> () <{Stdout}>
toStdout = BUILTIN

toStderr : String -> () <{Stderr}>
toStderr = BUILTIN

readInt : Int <{Stdin}>
readInt = BUILTIN

--------------------------------------------------------------------------------
-- Conversions
--------------------------------------------------------------------------------

showChar : Char -> String
showChar = BUILTIN

intToFloat : Int -> Float
intToFloat = BUILTIN

showInt : Int -> String
showInt = BUILTIN

--------------------------------------------------------------------------------
-- Thread / Sessions
--------------------------------------------------------------------------------

fork
  : forall {s : Protocol, k : Coeffect, c : k}
  . ((Chan s) [c] -> () <Session>) -> ((Chan (Dual s)) [c]) <Session>
fork = BUILTIN

forkLinear
  : forall {s : Protocol}
  . (Chan s -> () <Session>) -> (Chan (Dual s)) <Session>
forkLinear = BUILTIN

send
  : forall {a : Type, s : Protocol}
  . Chan (Send a s) -> a -> (Chan s) <Session>
send = BUILTIN

recv
  : forall {a : Type, s : Protocol}
  . Chan (Recv a s) -> (a, Chan s) <Session>
recv = BUILTIN

close : Chan End -> () <Session>
close = BUILTIN

unpackChan
  : forall {s : Protocol}
  . Chan s -> s
unpackChan = BUILTIN

--------------------------------------------------------------------------------
-- File Handles
--------------------------------------------------------------------------------

data Handle : HandleType -> Type
  = BUILTIN

-- TODO: with type level sets we could index a handle by a set of capabilities
-- then we wouldn't need readChar and readChar' etc.
data IOMode : HandleType -> Type where
  ReadMode : IOMode R;
  WriteMode : IOMode W;
  AppendMode : IOMode A;
  ReadWriteMode : IOMode RW

data HandleType = R | W | A | RW

openHandle
  : forall {m : HandleType}
  . IOMode m
  -> String
  -> (Handle m) <{Open,IOExcept}>
openHandle = BUILTIN

readChar : Handle R -> (Handle R, Char) <{Read,IOExcept}>
readChar = BUILTIN

readChar' : Handle RW -> (Handle RW, Char) <{Read,IOExcept}>
readChar' = BUILTIN

appendChar : Handle A -> Char -> (Handle A) <{Write,IOExcept}>
appendChar = BUILTIN

writeChar : Handle W -> Char -> (Handle W) <{Write,IOExcept}>
writeChar = BUILTIN

writeChar' : Handle RW -> Char -> (Handle RW) <{Write,IOExcept}>
writeChar' = BUILTIN

closeHandle : forall {m : HandleType} . Handle m -> () <{Close,IOExcept}>
closeHandle = BUILTIN

isEOF : Handle R -> (Handle R, Bool) <{Read,IOExcept}>
isEOF = BUILTIN

isEOF' : Handle RW -> (Handle RW, Bool) <{Read,IOExcept}>
isEOF' = BUILTIN

-- ???
-- evalIO : forall {a : Type, e : Effect} . (a [0..1]) <IOExcept, e> -> (Maybe a) <e>
-- catch = BUILTIN
--------------------------------------------------------------------------------
-- Char
--------------------------------------------------------------------------------

-- module Char

charToInt : Char -> Int
charToInt = BUILTIN

charFromInt : Int -> Char
charFromInt = BUILTIN



--------------------------------------------------------------------------------
-- String manipulation
--------------------------------------------------------------------------------

stringAppend : String → String → String
stringAppend = BUILTIN

stringUncons : String → Maybe (Char, String)
stringUncons = BUILTIN

stringCons : Char → String → String
stringCons = BUILTIN

stringUnsnoc : String → Maybe (String, Char)
stringUnsnoc = BUILTIN

stringSnoc : String → Char → String
stringSnoc = BUILTIN

--------------------------------------------------------------------------------
-- Arrays
--------------------------------------------------------------------------------

data
  ArrayStack
    (capacity : Nat)
    (maxIndex : Nat)
    (a : Type)
  where

push
  : ∀ {a : Type, cap : Nat, maxIndex : Nat}
  . {maxIndex < cap}
  ⇒ ArrayStack cap maxIndex a
  → a
  → ArrayStack cap (maxIndex + 1) a
push = BUILTIN

pop
  : ∀ {a : Type, cap : Nat, maxIndex : Nat}
  . {maxIndex > 0}
  ⇒ ArrayStack cap maxIndex a
  → a × ArrayStack cap (maxIndex - 1) a
pop = BUILTIN

-- Boxed array, so we allocate cap words
allocate
  : ∀ {a : Type, cap : Nat}
  . N cap
  → ArrayStack cap 0 a
allocate = BUILTIN

swap
  : ∀ {a : Type, cap : Nat, maxIndex : Nat}
  . ArrayStack cap (maxIndex + 1) a
  → Fin (maxIndex + 1)
  → a
  → a × ArrayStack cap (maxIndex + 1) a
swap = BUILTIN

copy
  : ∀ {a : Type, cap : Nat, maxIndex : Nat}
  . ArrayStack cap maxIndex (a [2])
  → ArrayStack cap maxIndex a × ArrayStack cap maxIndex a
copy = BUILTIN

--------------------------------------------------------------------------------
-- Cost
--------------------------------------------------------------------------------

tick : () <1>
tick = BUILTIN

|]


builtinTypeConstructors :: [(Id, (Kind, Cardinality))]
builtinDataConstructors :: [(Id, (TypeScheme, Substitution))]
builtins :: [(Id, TypeScheme)]
(builtinTypeConstructors, builtinDataConstructors, builtins) =
  (map fst datas, concatMap snd datas, map unDef defs)
    where
      AST types defs _ _ _ = case parseDefs "builtins" builtinSrc of
        Right ast -> ast
        Left err -> error err
      datas = map unData types

      unDef :: Def () () -> (Id, TypeScheme)
      unDef (Def _ name _ (Forall _ bs cs t)) = (name, Forall nullSpanBuiltin bs cs t)

      unData :: DataDecl -> ((Id, (Kind, Cardinality)), [(Id, (TypeScheme, Substitution))])
      unData (DataDecl _ tyConName tyVars kind dataConstrs)
        = (( tyConName, (maybe KType id kind, (Just $ genericLength dataConstrs)))
          , map unDataConstr dataConstrs
          )
        where
          unDataConstr :: DataConstr -> (Id, (TypeScheme, Substitution))
          unDataConstr (DataConstrIndexed _ name tysch) = (name, (tysch, []))
          unDataConstr d = unDataConstr (nonIndexedToIndexedDataConstr tyConName tyVars d)
