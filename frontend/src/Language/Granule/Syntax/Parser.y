{
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}

module Language.Granule.Syntax.Parser where

import Control.Monad (forM, when, unless)
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Class (lift)
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.List (intercalate, nub, stripPrefix)
import Data.Maybe (mapMaybe)
import Data.Set (Set, (\\), fromList, insert, empty, singleton)
import qualified Data.Map as M
import Numeric
import System.FilePath ((</>), takeBaseName)
import System.Exit

import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Lexer
import Language.Granule.Syntax.Def
import Language.Granule.Syntax.Expr
import Language.Granule.Syntax.Pattern
import Language.Granule.Syntax.Preprocessor.Markdown
import Language.Granule.Syntax.Preprocessor.Latex
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type
import Language.Granule.Utils hiding (mkSpan)

}

%name topLevel TopLevel
%name expr Expr
%name tscheme TypeScheme
%tokentype { Token }
%error { parseError }
%monad { ReaderT String (Either String) }

%token
    nl    { TokenNL _ }
    data  { TokenData _ }
    where { TokenWhere _ }
    module { TokenModule _ }
    hiding { TokenHiding _ }
    let   { TokenLet _ }
    in    { TokenIn  _  }
    if    { TokenIf _ }
    then  { TokenThen _ }
    else  { TokenElse _ }
    case  { TokenCase _ }
    of    { TokenOf _ }
    import { TokenImport _ _ }
    INT   { TokenInt _ _ }
    FLOAT  { TokenFloat _ _}
    VAR    { TokenSym _ _ }
    CONSTR { TokenConstr _ _ }
    CHAR   { TokenCharLiteral _ _ }
    STRING { TokenStringLiteral _ _ }
    forall { TokenForall _ }
    '∞'   { TokenInfinity _ }
    '\\'  { TokenLambda _ }
    '/'  { TokenForwardSlash _ }
    '->'  { TokenArrow _ }
    '<-'  { TokenBind _ }
    '=>'  { TokenConstrain _ }
    ','   { TokenComma _ }
    '×'   { TokenCross _ }
    '='   { TokenEq _ }
    '=='  { TokenEquiv _ }
    '/='  { TokenNeq _ }
    '+'   { TokenAdd _ }
    '-'   { TokenSub _ }
    '*'   { TokenMul _ }
    '('   { TokenLParen _ }
    ')'   { TokenRParen _ }
    ':'   { TokenSig _ }
    '['   { TokenBoxLeft _ }
    '{'   { TokenLBrace _ }
    '}'   { TokenRBrace _ }
    ']'   { TokenBoxRight _ }
    '<'   { TokenLangle _ }
    '>'   { TokenRangle _ }
    '<='  { TokenLesserEq _ }
    '>='  { TokenGreaterEq _ }
    '|'   { TokenPipe _ }
    '_'   { TokenUnderscore _ }
    ';'   { TokenSemicolon _ }
    '.'   { TokenPeriod _ }
    '`'   { TokenBackTick _ }
    '^'   { TokenCaret _ }
    '..'  { TokenDotDot _ }
    "\\/" { TokenJoin _ }
    "/\\" { TokenMeet _ }
    '∘'   { TokenRing _ }
    '?'   { TokenHole _ }

%right '∘'
%right in
%right '->'
%left ':'
%right '×'
%left '..'
%left '+' '-'
%left '*'
%left '^'
%left '|'
%left '.'
%%

TopLevel :: { AST () () }
  : module CONSTR where NL Defs
            { $5 { moduleName = Just $ mkId $ constrString $2 } }

  | module CONSTR hiding '(' Ids ')' where  NL Defs
            { let modName = mkId $ constrString $2
              in $9 { moduleName = Just modName, hiddenNames = $5 modName } }

  | Defs                                        { $1 }

Ids :: { Id -> M.Map Id Id }
 : CONSTR          { \modName -> M.insert (mkId $ constrString $1) modName M.empty }
 | CONSTR ',' Ids  { \modName -> M.insert (mkId $ constrString $1) modName ($3 modName) }

Defs :: { AST () () }
  : Def                       { AST [] [$1] mempty mempty Nothing }
  | DataDecl                  { AST [$1] [] mempty mempty Nothing }
  | Import                    { AST [] [] (singleton $1) mempty Nothing }
  | DataDecl NL Defs          { $3 { dataTypes = $1 : dataTypes $3 } }
  | Def NL Defs               { $3 { definitions = $1 : definitions $3 } }
  | Import NL Defs            { $3 { imports = insert $1 (imports $3) } }

NL :: { () }
  : nl NL                     { }
  | nl                        { }

Import :: { Import }
  : import                    { let TokenImport _ ('i':'m':'p':'o':'r':'t':path) = $1
                                in dropWhile isSpace path <> ".gr"
                              }

Def :: { Def () () }
  : Sig NL Bindings
    {% let name = fst3 $1
       in case $3 of
          (Just nameB, _) | not (nameB == name) ->
            error $ "Name for equation `" <> nameB <> "` does not match the signature head `" <> name <> "`"

          (_, bindings) -> do
            span <- mkSpan (thd3 $1, endPos $ getSpan $ last bindings)
            return $ Def span (mkId name) bindings (snd3 $1)
    }

DataDecl :: { DataDecl }
  : data CONSTR TyVars KindAnn where DataConstrs
      {% do
          span <- mkSpan (getPos $1, lastSpan' $6)
          return $ DataDecl span (mkId $ constrString $2) $3 $4 $6 }
  | data CONSTR TyVars KindAnn '=' DataConstrs
      {% do
          span <- mkSpan (getPos $1, lastSpan' $6)
          return $ DataDecl span (mkId $ constrString $2) $3 $4 $6 }

Sig :: { (String, TypeScheme, Pos) }
  : VAR ':' TypeScheme        { (symString $1, $3, getPos $1) }

Bindings :: { (Maybe String, [Equation () ()]) }
  : Binding ';' NL Bindings   { let (v, bind) = $1
                                in case $4 of
                                    (v', binds)
                                      | v' == v || v' == Nothing ->
                                          (v, (bind : binds))
                                      | otherwise ->
                                          error $ "Identifier " <> show v' <> " in group of equations does not match " <> show v
                              }
  | Binding                   { case $1 of (v, bind) -> (v, [bind]) }

Binding :: { (Maybe String, Equation () ()) }
  : VAR '=' Expr
      {% do
          span <- mkSpan (getPos $1, getEnd $3)
          return (Just $ symString $1, Equation span () [] $3) }

  | VAR Pats '=' Expr
      {% do
          span <- mkSpan (getPos $1, getEnd $4)
          return (Just $ symString $1, Equation span () $2 $4) }

-- this was probably a silly idea @buggymcbugfix
  -- | '|' Pats '=' Expr
  --     {% do
  --         span <- mkSpan (getPos $1, getEnd $4)
  --         return (Nothing, Equation span () $2 $4) }

DataConstrs :: { [DataConstr] }
  : DataConstr DataConstrNext { $1 : $2 }
  | {- empty -}               { [] }

DataConstr :: { DataConstr }
  : CONSTR ':' TypeScheme
       {% do span <- mkSpan (getPos $1, getEnd $3)
             return $ DataConstrIndexed span (mkId $ constrString $1) $3 }

  | CONSTR TyParams
       {% do span <- mkSpan (getPosToSpan $1)
             return $ DataConstrNonIndexed span (mkId $ constrString $1) $2 }

DataConstrNext :: { [DataConstr] }
  : '|' DataConstrs           { $2 }
  | ';' DataConstrs           { $2 }
  | {- empty -}               { [] }

TyVars :: { [(Id, Kind)] }
  : '(' VAR ':' Kind ')' TyVars { (mkId $ symString $2, $4) : $6 }
  | VAR TyVars                  { (mkId $ symString $1, Type LZero) : $2 }
  | {- empty -}                 { [] }

KindAnn :: { Maybe Kind }
  : ':' Kind                  { Just $2 }
  | {- empty -}               { Nothing }

Pats :: { [Pattern ()] }
  : PAtom                     { [$1] }
  | PAtom Pats                { $1 : $2 }

PAtom :: { Pattern () }
  : VAR
       {% (mkSpan $ getPosToSpan $1) >>= \sp -> return $ PVar sp () (mkId $ symString $1) }

  | '_'
       {% (mkSpan $ getPosToSpan $1) >>= \sp -> return $ PWild sp () }

  | INT
       {% (mkSpan $ getPosToSpan $1) >>= \sp -> return $ let TokenInt _ x = $1 in PInt sp () x }

  | FLOAT
       {% (mkSpan $ getPosToSpan $1) >>= \sp -> return $ let TokenFloat _ x = $1 in PFloat sp () $ read x }

  | CONSTR
       {% (mkSpan $ getPosToSpan $1) >>= \sp -> return $ let TokenConstr _ x = $1 in PConstr sp () (mkId x) [] }

  | '(' NAryConstr ')'        { $2 }

  | '[' PAtom ']'
       {% (mkSpan (getPos $1, getPos $3)) >>= \sp -> return $ PBox sp () $2 }

  | '[' NAryConstr ']'
       {% (mkSpan (getPos $1, getPos $3)) >>= \sp -> return $ PBox sp () $2 }

  | '(' PMolecule ',' PMolecule ')'
       {% (mkSpan (getPos $1, getPos $5)) >>= \sp -> return $ PConstr sp () (mkId ",") [$2, $4] }

PMolecule :: { Pattern () }
  : NAryConstr                { $1 }
  | PAtom                     { $1 }

NAryConstr :: { Pattern () }
  : CONSTR Pats               {% let TokenConstr _ x = $1
                                in (mkSpan (getPos $1, getEnd $ last $2)) >>=
                                       \sp -> return $ PConstr sp  () (mkId x) $2 }

ForallSig :: { [(Id, Kind)] }
 : '{' VarSigs '}' { $2 }
 | VarSigs         { $1 }

Forall :: { (((Pos, Pos), [(Id, Kind)]), [Type Zero]) }
 : forall ForallSig '.'                          { (((getPos $1, getPos $3), $2), []) }
 | forall ForallSig '.' '{' Constraints '}' '=>' { (((getPos $1, getPos $7), $2), $5) }

Constraints :: { [Type Zero] }
Constraints
 : Constraint ',' Constraints { $1 : $3 }
 | Constraint                 { [$1] }

TypeScheme :: { TypeScheme }
 : Type
       {% return $ Forall nullSpanNoFile [] [] $1 }

 | Forall Type
       {% (mkSpan (fst $ fst $1)) >>= \sp -> return $ Forall sp (snd $ fst $1) (snd $1) $2 }

VarSigs :: { [(Id, Kind)] }
  : VarSig ',' VarSigs        { $1 <> $3 }
  | VarSig                    { $1 }

VarSig :: { [(Id, Kind)] }
  : Vars1 ':' Kind            { map (\id -> (mkId id, $3)) $1 }
  | Vars1                     { flip concatMap $1 (\id -> let k = mkId ("_k" <> id)
                                                          in [(mkId id, TyVar k)]) }

-- A non-empty list of variables
Vars1 :: { [String] }
  : VAR                       { [symString $1] }
  | VAR Vars1                 { symString $1 : $2 }

Kind :: { Kind }
  : Kind '->' Kind            { FunTy $1 $3 }
  | VAR                       { TyVar (mkId $ symString $1) }
  | CONSTR                    { case constrString $1 of
                                  "Type"      -> Type LZero
                                  "Coeffect"  -> (TyCon (mkId "Coeffect"))
                                  "Predicate" -> (TyCon (mkId "Predicate"))
                                  s          -> tyCon s }
  | '(' TyJuxt TyAtom ')'     { case tyPromote (TyApp $2 $3) of
                                  Just ty -> ty
                                  Nothing -> error $ "Type at " ++ (show (getPos $1)) ++ " cannot be used as a kind" }

  | TyJuxt TyAtom             { case tyPromote (TyApp $1 $2) of
                                  Just ty -> ty
                                  Nothing -> error $ "Type " ++ (show (TyApp $1 $2)) ++ " cannot be used as a kind" }


Type :: { Type Zero }
  : TyJuxt                    { $1 }
  | Type '->' Type            { FunTy $1 $3 }
  | Type '×' Type             { TyApp (TyApp (TyCon $ mkId ",") $1) $3 }
  | TyAtom '[' Coeffect ']'   { Box $3 $1 }
  | TyAtom '[' ']'            { Box (CInterval (CZero extendedNat) infinity) $1 }

  | TyAtom '<' Effect '>'     { Diamond $3 $1 }
  | case Type of TyCases { TyCase $2 $4 }

TyApp :: { Type Zero }
 : TyJuxt TyAtom              { TyApp $1 $2 }
 | TyAtom                     { $1 }

TyJuxt :: { Type Zero }
  : TyJuxt '`' TyAtom '`'     { TyApp $3 $1 }
  | TyJuxt TyAtom             { TyApp $1 $2 }
  | TyAtom                    { $1 }
  | TyAtom '+' TyAtom         { TyInfix TyOpPlus $1 $3 }
  | TyAtom '-' TyAtom         { TyInfix TyOpMinus $1 $3 }
  | TyAtom '*' TyAtom         { TyInfix TyOpTimes $1 $3 }
  | TyAtom '^' TyAtom         { TyInfix TyOpExpon $1 $3 }
  | TyAtom "/\\" TyAtom       { TyInfix TyOpMeet $1 $3 }
  | TyAtom "\\/" TyAtom       { TyInfix TyOpJoin $1 $3 }

TyCases :: { [(Type Zero, Type Zero)] }
 : TyCase TyCasesNext             { $1 : $2 }

TyCasesNext :: { [(Type Zero, Type Zero)] }
  : ';' TyCases                 { $2 }
  | {- empty -}               { [] }

TyCase :: { (Type Zero, Type Zero) }
  : Type '->' Type           { ($1, $3) }

Constraint :: { Type Zero }
  : TyAtom '>' TyAtom         { TyInfix TyOpGreater $1 $3 }
  | TyAtom '<' TyAtom         { TyInfix TyOpLesser $1 $3 }
  | TyAtom '<=' TyAtom        { TyInfix TyOpLesserEq $1 $3 }
  | TyAtom '>=' TyAtom        { TyInfix TyOpGreaterEq $1 $3 }
  | TyAtom '==' TyAtom        { TyInfix TyOpEq $1 $3 }
  | TyAtom '/=' TyAtom        { TyInfix TyOpNotEq $1 $3 }

TyAtom :: { Type Zero }
  : CONSTR                    { TyCon $ mkId $ constrString $1 }
  | VAR                       { TyVar (mkId $ symString $1) }
  | INT                       { let TokenInt _ x = $1 in TyInt x }
  | '(' Type ')'              { $2 }
  | '(' Type ',' Type ')'     { TyApp (TyApp (TyCon $ mkId ",") $2) $4 }

TyParams :: { [Type Zero] }
  : TyAtom TyParams           { $1 : $2 } -- use right recursion for simplicity -- VBL
  |                           { [] }

Coeffect :: { Coeffect }
  : INT                         { let TokenInt _ x = $1 in CNat x }
  | '∞'                         { infinity }
  | FLOAT                       { let TokenFloat _ x = $1 in CFloat $ myReadFloat x }
  | CONSTR                      { case (constrString $1) of
                                    "Public" -> Level publicRepresentation
                                    "Private" -> Level privateRepresentation
                                    "Unused" -> Level unusedRepresentation
                                    "Inf" -> infinity
                                    x -> error $ "Unknown coeffect constructor `" <> x <> "`" }
  | VAR                         { CVar (mkId $ symString $1) }
  | Coeffect '..' Coeffect      { CInterval $1 $3 }
  | Coeffect '+' Coeffect       { CPlus $1 $3 }
  | Coeffect '*' Coeffect       { CTimes $1 $3 }
  | Coeffect '-' Coeffect       { CMinus $1 $3 }
  | Coeffect '^' Coeffect       { CExpon $1 $3 }
  | Coeffect "/\\" Coeffect       { CMeet $1 $3 }
  | Coeffect "\\/" Coeffect       { CJoin $1 $3 }
  | '(' Coeffect ')'            { $2 }
  | '{' Set '}'                 { CSet $2 }
  | Coeffect ':' Type           { case tyPromote $3 of
                                    Just ty -> normalise (CSig $1 ty)
                                    Nothing -> error $ "Type " ++ (show $3) ++ " cannot be used as a kind" }
  | '(' Coeffect ',' Coeffect ')' { CProduct $2 $4 }

Set :: { [(String, Type Zero)] }
  : VAR ':' Type ',' Set      { (symString $1, $3) : $5 }
  | VAR ':' Type              { [(symString $1, $3)] }

Effect :: { Type Zero }
  : '{' EffSet '}'            { TySet $2 }
  | {- EMPTY -}               { TyCon $ mkId "Pure" }
  | TyJuxt                    { $1 }

EffSet :: { [Type Zero] }
  : Eff ',' EffSet         { $1 : $3 }
  | Eff                    { [$1] }

Eff :: { Type Zero }
  : CONSTR                  { TyCon $ mkId $ constrString $1 }

Expr :: { Expr () () }
  : let LetBind MultiLet
      {% let (_, pat, mt, expr) = $2
      	in (mkSpan (getPos $1, getEnd $3)) >>=
           \sp -> return $ App sp ()
                   (Val (getSpan $3) () (Abs () pat mt $3)) expr
      }

  | '\\' '(' PAtom ':' Type ')' '->' Expr
      {% (mkSpan (getPos $1, getEnd $8)) >>=
             \sp -> return $ Val sp () (Abs () $3 (Just $5) $8) }

  | '\\' PAtom '->' Expr
      {% (mkSpan (getPos $1, getEnd $4)) >>=
             \sp -> return $ Val sp () (Abs () $2 Nothing $4) }

  | let LetBindEff MultiLetEff
      {% let (_, pat, mt, expr) = $2
        in (mkSpan (getPos $1, getEnd $3)) >>=
              \sp -> return $ LetDiamond sp () pat mt expr $3 }

  | case Expr of Cases
    {% (mkSpan (getPos $1, lastSpan $4)) >>=
             \sp -> return $ Case sp () $2 $4 }

  | if Expr then Expr else Expr
    {% do
        span1 <- mkSpan (getPos $1, getEnd $6)
        span2 <- mkSpan $ getPosToSpan $3
        span3 <- mkSpan $ getPosToSpan $3
        return $ Case span1 () $2
                  [(PConstr span2 () (mkId "True") [], $4),
                     (PConstr span3 () (mkId "False") [], $6)] }

  | Form
    { $1 }

LetBind :: { (Pos, Pattern (), Maybe (Type Zero), Expr () ()) }
  : PAtom ':' Type '=' Expr
      { (getStart $1, $1, Just $3, $5) }
  | PAtom '=' Expr
      { (getStart $1, $1, Nothing, $3) }
  | NAryConstr ':' Type '=' Expr
      { (getStart $1, $1, Just $3, $5) }
  | NAryConstr '=' Expr
      { (getStart $1, $1, Nothing, $3) }

MultiLet :: { Expr () () }
MultiLet
  : ';' LetBind MultiLet
    {% let (_, pat, mt, expr) = $2

     	in (mkSpan (getPos $1, getEnd $3)) >>=
           \sp -> return $ App sp ()
     	               (Val (getSpan $3) () (Abs () pat mt $3)) expr }
  | in Expr
    { $2 }

LetBindEff :: { (Pos, Pattern (), Maybe (Type Zero), Expr () ()) }
  : PAtom '<-' Expr            { (getStart $1, $1, Nothing, $3) }
  | PAtom ':' Type '<-' Expr   { (getStart $1, $1, Just $3, $5) }

MultiLetEff :: { Expr () () }
MultiLetEff
  : ';' LetBindEff MultiLetEff
      {% let (_, pat, mt, expr) = $2
	      in (mkSpan (getPos $1, getEnd $3)) >>=
             \sp -> return $ LetDiamond sp () pat mt expr $3
      }
  | in Expr                   { $2 }

Cases :: { [(Pattern (), Expr () () )] }
 : Case CasesNext             { $1 : $2 }

CasesNext :: { [(Pattern (), Expr () ())] }
  : ';' Cases                 { $2 }
  | {- empty -}               { [] }

Case :: { (Pattern (), Expr () ()) }
  : PAtom '->' Expr           { ($1, $3) }
  | NAryConstr '->' Expr      { ($1, $3) }

Form :: { Expr () () }
  : Form '+' Form  {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ Binop sp () OpPlus $1 $3 }
  | Form '-' Form  {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ Binop sp () OpMinus $1 $3 }
  | Form '*' Form  {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ Binop sp () OpTimes $1 $3 }
  | Form '<' Form  {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ Binop sp () OpLesser $1 $3 }
  | Form '>' Form  {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ Binop sp () OpGreater $1 $3 }
  | Form '<=' Form {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ Binop sp () OpLesserEq $1 $3 }
  | Form '>=' Form {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ Binop sp () OpGreaterEq $1 $3 }
  | Form '==' Form {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ Binop sp () OpEq $1 $3 }
  | Form '/=' Form {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ Binop sp () OpNotEq $1 $3 }
  | Form '∘'  Form {% (mkSpan $ getPosToSpan $2) >>= \sp -> return $ App sp () (App sp () (Val sp () (Var () (mkId "compose"))) $1) $3 }
  | Juxt           { $1 }

Juxt :: { Expr () () }
  : Juxt '`' Atom '`'         {% (mkSpan (getStart $1, getEnd $3)) >>= \sp -> return $ App sp () $3 $1 }
  | Juxt Atom                 {% (mkSpan (getStart $1, getEnd $2)) >>= \sp -> return $ App sp () $1 $2 }
  | Atom                      { $1 }

Atom :: { Expr () () }
  : '(' Expr ')'              { $2 }
  | INT                       {% let (TokenInt _ x) = $1
                                 in (mkSpan $ getPosToSpan $1)
                                    >>= \sp -> return $ Val sp () $ NumInt x }
  -- | '<' Expr '>'              {% (mkSpan (getPos $1, getPos $3)) >>= \sp -> return $ App sp () (Val sp () (Var () (mkId "pure"))) $2 }
  | FLOAT                     {% let (TokenFloat _ x) = $1
                                 in (mkSpan $ getPosToSpan $1)
                                     >>= \sp -> return $ Val sp () $ NumFloat $ read x }

  | VAR                       {% (mkSpan $ getPosToSpan $1)  >>= \sp -> return $ Val sp () $ Var () (mkId $ symString $1) }

  | '[' Expr ']'              {% (mkSpan (getPos $1, getPos $3)) >>= \sp -> return $ Val sp () $ Promote () $2 }
  | CONSTR                    {% (mkSpan $ getPosToSpan $1)  >>= \sp -> return $ Val sp () $ Constr () (mkId $ constrString $1) [] }
  | '(' Expr ',' Expr ')'     {% do
                                    span1 <- (mkSpan (getPos $1, getPos $5))
                                    span2 <- (mkSpan (getPos $1, getPos $3))
                                    span3 <- (mkSpan $ getPosToSpan $3)
                                    return $ App span1 () (App span2 ()
                                              (Val span3 () (Constr () (mkId ",") []))
                                                $2)
                                              $4 }
  | CHAR                      {% (mkSpan $ getPosToSpan $1) >>= \sp ->
                                  return $ Val sp () $
                                     case $1 of (TokenCharLiteral _ c) -> CharLiteral c }
  | STRING                    {% (mkSpan $ getPosToSpan $1) >>= \sp ->
                                  return $ Val sp () $
                                      case $1 of (TokenStringLiteral _ c) -> StringLiteral c }
  | '?'
    {% (mkSpan $ getPosToSpan $1) >>= \sp -> return $ Hole sp () }

{

mkSpan :: (Pos, Pos) -> ReaderT String (Either String) Span
mkSpan (start, end) = do
  filename <- ask
  return $ Span start end filename

parseError :: [Token] -> ReaderT String (Either String) a
parseError [] = lift $ Left "Premature end of file"
parseError t  =  do
    file <- ask
    lift . Left $ file <> ":" <> show l <> ":" <> show c <> ": parse error"
  where (l, c) = getPos (head t)

parseDefs :: FilePath -> String -> Either String (AST () ())
parseDefs file input = runReaderT (topLevel $ scanTokens input) file

parseAndDoImportsAndFreshenDefs :: (?globals :: Globals) => String -> IO (AST () ())
parseAndDoImportsAndFreshenDefs input = do
    ast <- parseDefsAndDoImports input
    return $ freshenAST ast

parseDefsAndDoImports :: (?globals :: Globals) => String -> IO (AST () ())
parseDefsAndDoImports input = do
    ast <- either failWithMsg return $ parseDefs sourceFilePath input
    case moduleName ast of
      Nothing -> doImportsRecursively (imports ast) (ast { imports = empty })
      Just (Id name _) ->
        if name == takeBaseName sourceFilePath
          then doImportsRecursively (imports ast) (ast { imports = empty })
          else do
            failWithMsg $ "Module name `" <> name <> "` does not match filename `" <> takeBaseName sourceFilePath <> "`"

  where
    -- Get all (transitive) dependencies. TODO: blows up when the file imports itself
    doImportsRecursively :: Set Import -> AST () () -> IO (AST () ())
    doImportsRecursively todo ast@(AST dds defs done hidden name) = do
      case toList (todo \\ done) of
        [] -> return ast
        (i:todo) ->
          let path = includePath </> i in
          let ?globals = ?globals { globalsSourceFilePath = Just path } in do
            src <- readFile path
            AST dds' defs' imports' hidden' _ <- either failWithMsg return $ parseDefs path src
            doImportsRecursively
              (fromList todo <> imports')
              (AST (dds' <> dds) (defs' <> defs) (insert i done) (hidden `M.union` hidden') name)

failWithMsg :: String -> IO a
failWithMsg msg = putStrLn msg >> exitFailure

lastSpan [] = fst $ nullSpanLocs
lastSpan xs = getEnd . snd . last $ xs

lastSpan' [] = fst $ nullSpanLocs
lastSpan' xs = endPos $ getSpan (last xs)

myReadFloat :: String -> Rational
myReadFloat str =
    case readFloat str of
      ((n, []):_) -> n
      _ -> error "Invalid number"

fst3 (a, b, c) = a
snd3 (a, b, c) = b
thd3 (a, b, c) = c
}
