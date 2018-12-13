{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Language.Granule.Checker.Checker where

import Control.Monad (unless)
import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe
import Data.List (genericLength, intercalate)
import Data.Maybe
import Data.SBV hiding (Kind, kindOf, extend)

import Language.Granule.Checker.Coeffects
import Language.Granule.Checker.Constraints
import Language.Granule.Checker.Kinds
import Language.Granule.Checker.Exhaustivity
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Patterns
import Language.Granule.Checker.Predicates
import qualified Language.Granule.Checker.Primitives as Primitives
import Language.Granule.Checker.Substitutions
import Language.Granule.Checker.Types
import Language.Granule.Context

import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Helpers (freeVars)
import Language.Granule.Syntax.Def
import Language.Granule.Syntax.Expr
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type
import Language.Granule.Utils

import Debug.Trace

data CheckerResult = Failed | Ok deriving (Eq, Show)

-- Checking (top-level)
check :: (?globals :: Globals ) => AST () () -> IO CheckerResult
check (AST dataDecls defs) = do
      let checkDataDecls = do { mapM_ checkTyCon dataDecls; mapM checkDataCons dataDecls }

      -- Get the types of all definitions (assume that they are correct for
      -- the purposes of (mutually)recursive calls).
      let checkKinds = mapM kindCheckDef defs
      -- Build a computation which checks all the defs (in order)...
      let defCtxt = map (\(Def _ name _ _ tys) -> (name, tys)) defs
      let checkedDefs = do
            status <- runMaybeT checkKinds
            case status of
              Nothing -> return [Nothing]
              Just _  -> do -- Now check the definition
                mapM (\d -> checkDef defCtxt d >>= eraseElaborated) defs

      -- ... and evaluate the computation with initial state
      let thingsToCheck = (<>) <$> checkDataDecls <*> checkedDefs
      results <- evalChecker initState thingsToCheck

      -- If all definitions type checked, then the whole file type checks
      -- let results = (results_DataDecl <> results_Def)
      if all isJust results
        then return Ok
        else return Failed

eraseElaborated (Just _) = return (Just ())
eraseElaborated Nothing = return Nothing

checkTyCon :: (?globals :: Globals ) => DataDecl -> Checker (Maybe ())
checkTyCon (DataDecl _ name tyVars kindAnn ds) = runMaybeT $
    modify' $ \st -> st { typeConstructors = (name, (tyConKind, cardin)) : typeConstructors st }
  where
    cardin = (Just . genericLength) ds -- the number of data constructors
    tyConKind = mkKind (map snd tyVars)
    mkKind [] = case kindAnn of Just k -> k; Nothing -> KType -- default to `Type`
    mkKind (v:vs) = KFun v (mkKind vs)

checkDataCons :: (?globals :: Globals ) => DataDecl -> Checker (Maybe ())
checkDataCons (DataDecl _ name tyVars _ dataConstrs) = runMaybeT $ do
    st <- get
    let Just (kind,_) = lookup name (typeConstructors st) -- can't fail, tyCon must be in checker state
    modify' $ \st -> st { tyVarContext = [(v, (k, ForallQ)) | (v, k) <- tyVars] }
    mapM_ (checkDataCon name kind tyVars) dataConstrs

checkDataCon :: (?globals :: Globals )
  => Id -- ^ The type constructor and associated type to check against
  -> Kind -- ^ The kind of the type constructor
  -> Ctxt Kind -- ^ The type variables
  -> DataConstr -- ^ The data constructor to check
  -> MaybeT Checker () -- ^ Return @Just ()@ on success, @Nothing@ on failure
checkDataCon tName kind tyVarsT (DataConstrG sp dName tySch@(Forall _ tyVarsD ty)) =
    case intersectCtxts tyVarsT tyVarsD of
      [] -> do -- no clashes
        let tyVars = tyVarsT <> tyVarsD
        tySchKind <- inferKindOfType' sp tyVars ty
        case tySchKind of
          KType -> do
            check ty
            st <- get
            case extend (dataConstructors st) dName (Forall sp tyVars ty) of
              Some ds -> put st { dataConstructors = ds }
              None _ -> halt $ NameClashError (Just sp) $ "Data constructor `" <> pretty dName <> "` already defined."
          _     -> illKindedNEq sp KType kind
      vs -> halt $ NameClashError (Just sp) $ mconcat
                    ["Type variable(s) ", intercalate ", " $ map (\(i,_) -> "`" <> pretty i <> "`") vs
                    ," in data constructor `", pretty dName
                    ,"` are already bound by the associated type constructor `", pretty tName
                    , "`. Choose different, unbound names."]
  where
    check (TyCon tC) =
        if tC == tName
          then return ()
          else halt $ GenericError (Just sp) $ "Expected type constructor `" <> pretty tName
                                             <> "`, but got `" <> pretty tC <> "` in  `"
    check (FunTy arg res) = check res
    check (TyApp fun arg) = check fun
    check x = halt $ GenericError (Just sp) $ "`" <> pretty x <> "` not valid in a datatype definition."

checkDataCon tName _ tyVars (DataConstrA sp dName params) = do
    st <- get
    case extend (dataConstructors st) dName tySch of
      Some ds -> put st { dataConstructors = ds }
      None _ -> halt $ NameClashError (Just sp) $ "Data constructor `" <> pretty dName <> "` already defined."
  where
    tySch = Forall sp tyVars ty
    ty = foldr FunTy (returnTy (TyCon tName) tyVars) params
    returnTy t [] = t
    returnTy t (v:vs) = returnTy (TyApp t ((TyVar . fst) v)) vs


checkDef :: (?globals :: Globals )
         => Ctxt TypeScheme  -- context of top-level definitions
         -> Def () ()        -- definition
         -> Checker (Maybe (Def () Type))
checkDef defCtxt (Def s defName expr pats tys@(Forall _ foralls ty)) = do

     result <- runMaybeT $ do
      -- Add explicit type variable quantifiers to the type variable context
      modify (\st -> st { tyVarContext = map (\(n, c) -> (n, (c, ForallQ))) foralls})

      (ctxt, elaboratedExpr, elaboratedPats) <- case (ty, pats) of
        (FunTy _ _, ps@(_:_)) -> do

          -- Type the pattern matching
          (patternGam, ty', elaboratedPats) <- ctxtFromTypedPatterns s ty ps

          -- Check the body in the context given by the pattern matching
          (outGam, _, elaboratedExpr) <- checkExpr defCtxt patternGam Positive True ty' expr

          st <- get
          debugM "*** pred at end of checking def" (pretty (predicateStack st))
          debugM "*** (outGam, patternGam)" (pretty (outGam, patternGam))


          -- Check that the outgoing context is a subgrading of the incoming
          ctxtEquals s outGam patternGam

          st <- get
          debugM "*** pred at end of checking def" (pretty (predicateStack st))

          -- Check linear use
          case checkLinearity patternGam outGam of
                [] -> return (outGam, elaboratedExpr, elaboratedPats)
                xs -> illLinearityMismatch s xs

        (tau, []) -> do
          -- No patterns, non function type
          (_, _, elaboratedExpr) <- checkExpr defCtxt [] Positive True tau expr
          return ([], elaboratedExpr, [])

        _         -> halt $ GenericError (Just s) "Expecting a function type"

      -- Use an SMT solver to solve the generated constraints
      checkerState <- get
      let predStack = predicateStack checkerState
      debugM "Solver predicate" $ pretty (Conj predStack)
      solveConstraints (Conj predStack) s defName

      return (elaboratedExpr, elaboratedPats)

     -- Erase the solver predicate between definitions
     modify (\st -> st { predicateStack = [], tyVarContext = [], kVarContext = [] })

     case result of
       Just (elaboratedExpr, elaboratedPats) ->
          return (Just $ Def s defName elaboratedExpr elaboratedPats tys)

       Nothing ->
          return Nothing

data Polarity = Positive | Negative deriving Show


flipPol :: Polarity -> Polarity
flipPol Positive = Negative
flipPol Negative = Positive

-- Type check an expression

--  `checkExpr defs gam t expr` computes `Just delta`
--  if the expression type checks to `t` in context `gam`:
--  where `delta` gives the post-computation context for expr
--  (which explains the exact coeffect demands)
--  or `Nothing` if the typing does not match.

checkExpr :: (?globals :: Globals )
          => Ctxt TypeScheme   -- context of top-level definitions
          -> Ctxt Assumption   -- local typing context
          -> Polarity         -- polarity of <= constraints
          -> Bool             -- whether we are top-level or not
          -> Type             -- type
          -> Expr () ()       -- expression
          -> MaybeT Checker (Ctxt Assumption, Substitution, Expr () Type)

-- Checking of constants

checkExpr _ [] _ _ ty@(TyCon c) (Val s _ (NumInt n))   | internalName c == "Int" = do
    let elaborated = Val s ty (NumInt n)
    return ([], [], elaborated)

checkExpr _ [] _ _ ty@(TyCon c) (Val s _ (NumFloat n)) | internalName c == "Float" = do
    let elaborated = Val s ty (NumFloat n)
    return ([], [], elaborated)

checkExpr defs gam pol _ ty@(FunTy sig tau) (Val s _ (Abs _ p t e)) = do
  -- If an explicit signature on the lambda was given, then check
  -- it confirms with the type being checked here

  (tau', subst1) <- case t of
    Nothing -> return (tau, [])
    Just t' -> do
      (eqT, unifiedType, subst) <- equalTypes s sig t'
      unless eqT (halt $ GenericError (Just s) $ pretty sig <> " not equal to " <> pretty t')
      return (tau, subst)

  (bindings, _, subst, elaboratedP) <- ctxtFromTypedPattern s sig p
  debugM "binding from lam" $ pretty bindings

  pIrrefutable <- isIrrefutable s sig p
  if pIrrefutable then do
    -- Check the body in the extended context
    (gam', subst2, elaboratedE) <- checkExpr defs (bindings <> gam) pol False tau' e
    -- Check linearity of locally bound variables
    case checkLinearity bindings gam' of
       [] -> do
          subst <- combineSubstitutions s subst1 subst2

          let elaborated = Val s ty (Abs tau elaboratedP t elaboratedE)
          return (gam' `subtractCtxt` bindings, subst, elaborated)

       xs -> illLinearityMismatch s xs
  else refutablePattern s p

-- Application special case for built-in 'scale'
-- TODO: needs more thought
{- checkExpr defs gam pol topLevel tau
          (App s _ (App _ _ (Val _ _ (Var _ v)) (Val _ _ (NumFloat _ x))) e) | internalName v == "scale" = do
    equalTypes s (TyCon $ mkId "Float") tau
    checkExpr defs gam pol topLevel (Box (CFloat (toRational x)) (TyCon $ mkId "Float")) e
-}

-- Application checking
checkExpr defs gam pol topLevel tau (App s _ e1 e2) = do

    (argTy, gam2, elaboratedL) <- synthExpr defs gam pol e2
    (gam1, subst, elaboratedR) <- checkExpr defs gam (flipPol pol) topLevel (FunTy argTy tau) e1
    gam <- ctxPlus s gam1 gam2

    let elaborated = App s tau elaboratedL elaboratedR
    return (gam, subst, elaborated)

{-

[G] |- e : t
 ---------------------
[G]*r |- [e] : []_r t

-}

-- Promotion
checkExpr defs gam pol _ ty@(Box demand tau) (Val s _ (Promote _ e)) = do
    let vars = freeVars e -- map fst gam
    gamF    <- discToFreshVarsIn s vars gam demand
    (gam', subst, elaboratedE) <- checkExpr defs gamF pol False tau e

    -- Causes a promotion of any typing assumptions that came from variable
    -- inside a guard from an enclosing case that have kind Level
    -- This prevents control-flow attacks and is a special case for Level
    -- (the guard contexts come from a special context in the solver)
    guardGam <- allGuardContexts
    guardGam' <- filterM isLevelKinded guardGam
    let gam'' = multAll (vars <> map fst guardGam') demand (gam' <> guardGam')

    let elaborated = Val s ty (Promote tau elaboratedE)
    return (gam'', subst, elaborated)
  where
    -- Calculate whether a type assumption is level kinded
    isLevelKinded (_, as) = do
        ty <- inferCoeffectTypeAssumption s as
        return $ case ty of
          Nothing -> False
          Just (TyCon c) | internalName c == "Level" -> True
                         | otherwise                 -> False

-- Dependent pattern-matching case (only at the top level)
checkExpr defs gam pol True tau (Case s _ guardExpr cases) = do
  -- Synthesise the type of the guardExpr
  (guardTy, guardGam, elaboratedGuard) <- synthExpr defs gam pol guardExpr
  pushGuardContext guardGam

  debugM "*** Checking case branches " ""

  -- Check each of the branches
  branchCtxtsAndSubst <-
    forM cases $ \(pat_i, e_i) -> do
      -- Build the binding context for the branch pattern
      newConjunct
      (patternGam, eVars, subst, elaborated_pat_i) <- (pretty guardTy) `trace` ctxtFromTypedPattern s guardTy pat_i

      -- Checking the case body
      newConjunct
      -- Specialise the return type and the incoming environment using the
      -- pattern-match-generated type substitution
      tau' <- substitute subst tau
      (specialisedGam, unspecialisedGam) <- substCtxt subst gam

      let checkGam = patternGam <> specialisedGam <> unspecialisedGam
      (localGam, subst', elaborated_i) <- checkExpr defs checkGam pol False tau' e_i

      -- We could do this, but it seems redundant.
      liftIO $ putStrLn $ "localGam = " ++ pretty localGam
      liftIO $ putStrLn $ "checkGam = " ++ pretty checkGam

      localGam' <- ctxPlus s localGam guardGam
      ctxtEquals s localGam' checkGam

      -- Check linear use in anything Linear
      case checkLinearity patternGam localGam of
        -- Return the resulting computed context, without any of
        -- the variable bound in the pattern of this branch
        [] -> do
           -- Conclude the implication
           concludeImplication eVars
           st <- get
           debugM "*** pred so far" (pretty (predicateStack st))

           -- The resulting context has the shared part removed
           -- 28/02/2018 - We used to have this
           --let branchCtxt = (localGam `subtractCtxt` guardGam) `subtractCtxt` specialisedGam
           -- But we want promotion to invovlve the guard to avoid leaks
           -- 29/11/2018 changed
           -- let branchCtxt = (localGam `subtractCtxt` specialisedGam) `subtractCtxt` patternGam
           -- -- Probably don't want to remove specialised things in this way- we want to
           -- -- invert the substitution and put these things into the context
           debugM "*** unsubstitute" "" 
           unsubstLocalGam <- unsubstitute subst localGam

           let branchCtxt = unsubstLocalGam `subtractCtxt` patternGam

           return (branchCtxt, subst', (elaborated_pat_i, elaborated_i))

        -- Anything that was bound in the pattern but not used correctly
        xs -> illLinearityMismatch s xs

  popGuardContext

  debugM "*** Branches and substitutions from case " (pretty branchCtxtsAndSubst)

  -- Find the upper-bound contexts
  let (branchCtxts, substs, elaboratedCases) = unzip3 branchCtxtsAndSubst
  branchesGam <- fold1M (joinCtxts s) branchCtxts

  -- Contract the outgoing context of the guard and the branches (joined)
  g <- ctxPlus s branchesGam guardGam

  debugM "--- Output context for case " (pretty g)
  let elaborated = Case s tau elaboratedGuard elaboratedCases

  st <- get
  debugM "*** pred at end of case" (pretty (predicateStack st))

  return (g, concat substs, elaborated)

-- All other expressions must be checked using synthesis
checkExpr defs gam pol topLevel tau e = do

  (tau', gam', elaboratedE) <- synthExpr defs gam pol e

  (tyEq, _, subst) <-
    case pol of
      Positive -> do
        debugM "+ Compare for equality " $ pretty tau' <> " = " <> pretty tau
        if topLevel
          -- If we are checking a top-level, then don't allow overapproximation
          then equalTypesWithPolarity (getSpan e) SndIsSpec tau' tau
          else lEqualTypesWithPolarity (getSpan e) SndIsSpec tau' tau

      -- i.e., this check is from a synth
      Negative -> do
        debugM "- Compare for equality " $ pretty tau <> " = " <> pretty tau'
        if topLevel
          -- If we are checking a top-level, then don't allow overapproximation
          then equalTypesWithPolarity (getSpan e) FstIsSpec tau' tau
          else lEqualTypesWithPolarity (getSpan e) FstIsSpec tau' tau

  if tyEq
    then return (gam', subst, elaboratedE)
    else do
      case pol of
        Positive -> do
          halt $ GenericError (Just $ getSpan e)
               $ "Expected '" <> pretty tau <> "' but got '" <> pretty tau' <> "'"

        Negative -> do
          halt $ GenericError (Just $ getSpan e)
               $ "Expected '" <> pretty tau' <> "' but got '" <> pretty tau <> "'"


-- | Synthesise the 'Type' of expressions.
-- See <https://en.wikipedia.org/w/index.php?title=Bidirectional_type_checking&redirect=no>
synthExpr :: (?globals :: Globals)
          => Ctxt TypeScheme   -- ^ Context of top-level definitions
          -> Ctxt Assumption   -- ^ Local typing context
          -> Polarity          -- ^ Polarity of subgrading
          -> Expr () ()        -- ^ Expression
          -> MaybeT Checker (Type, Ctxt Assumption, Expr () Type)

-- Literals can have their type easily synthesised
synthExpr _ _ _ (Val s _ (NumInt n))  = do
  let t = TyCon $ mkId "Int"
  return (t, [], Val s t (NumInt n))

synthExpr _ _ _ (Val s _ (NumFloat n)) = do
  let t = TyCon $ mkId "Float"
  return (t, [], Val s t (NumFloat n))

synthExpr _ _ _ (Val s _ (CharLiteral c)) = do
  let t = TyCon $ mkId "Char"
  return (t, [], Val s t (CharLiteral c))

synthExpr _ _ _ (Val s _ (StringLiteral c)) = do
  let t = TyCon $ mkId "String"
  return (t, [], Val s t (StringLiteral c))

-- Constructors
synthExpr _ gam _ (Val s _ (Constr _ c [])) = do
  -- Should be provided in the type checkers environment
  st <- get
  case lookup c (dataConstructors st) of
    Just tySch -> do
      -- Freshen the constructor
      -- (discarding any fresh type variables, info not needed here)
      (ty,_) <- freshPolymorphicInstance InstanceQ tySch

      let elaborated = Val s ty (Constr ty c [])
      return (ty, [], elaborated)

    Nothing -> halt $ UnboundVariableError (Just s) $
              "Data constructor `" <> pretty c <> "`" <?> show (dataConstructors st)

-- Case synthesis
synthExpr defs gam pol (Case s _ guardExpr cases) = do
  -- Synthesise the type of the guardExpr
  (ty, guardGam, elaboratedGuard) <- synthExpr defs gam pol guardExpr
  -- then synthesise the types of the branches
  branchTysAndCtxts <-
    forM cases $ \(pati, ei) -> do
      -- Build the binding context for the branch pattern
      newConjunct
      (patternGam, eVars, _, elaborated_pat_i) <- ctxtFromTypedPattern s ty pati
      newConjunct
      ---
      (tyCase, localGam, elaborated_i) <- synthExpr defs (patternGam <> gam) pol ei
      concludeImplication eVars
      -- Check linear use in anything Linear
      case checkLinearity patternGam localGam of
         -- Return the resulting computed context, without any of
         -- the variable bound in the pattern of this branch
         [] -> return (tyCase, localGam `subtractCtxt` patternGam,
                        (elaborated_pat_i, elaborated_i))
         xs -> illLinearityMismatch s xs

  let (branchTys, branchCtxts, elaboratedCases) = unzip3 branchTysAndCtxts
  let branchTysAndSpans = zip branchTys (map (getSpan . snd) cases)
  -- Finds the upper-bound return type between all branches
  branchType <- foldM (\ty2 (ty1, sp) -> joinTypes sp ty1 ty2)
                   (head branchTys)
                   (tail branchTysAndSpans)

  -- Find the upper-bound type on the return contexts
  branchesGam <- fold1M (joinCtxts s) branchCtxts

  -- Contract the outgoing context of the guard and the branches (joined)
  gamNew <- ctxPlus s branchesGam guardGam

  let elaborated = Case s branchType elaboratedGuard elaboratedCases
  return (branchType, gamNew, elaborated)

-- Diamond cut
synthExpr defs gam pol (LetDiamond s _ p optionalTySig e1 e2) = do
  -- TODO: refactor this once we get a proper mechanism for
  -- specifying effect over-approximations and type aliases

  (sig, gam1, elaborated1) <- synthExpr defs gam pol e1
  case sig of
    (TyApp (TyCon con) t')
      | internalName con == "FileIO" || internalName con == "Session" ->
      typeLetSubject gam1 [] t' elaborated1

    Diamond ef1 ty1 ->
      typeLetSubject gam1 ef1 ty1 elaborated1

    t -> halt $ GenericError (Just s)
              $ "Expected an effect type but inferred '"
             <> pretty t <> "' in body of let<>"

   where
      typeLetSubject gam1 ef1 ty1 elaborated1 = do
        (binders, _, _, elaboratedP)  <- ctxtFromTypedPattern s ty1 p
        pIrrefutable <- isIrrefutable s ty1 p
        if not pIrrefutable
        then refutablePattern s p
        else do
           (tau, gam2, elaborated2) <- synthExpr defs (binders <> gam) pol e2
           case tau of
            Diamond ef2 ty2 ->
                typeLetBody gam1 gam2 ef1 ef2 binders ty1 ty2 elaboratedP elaborated1 elaborated2

            (TyApp (TyCon con) t')
               | internalName con == "FileIO" || internalName con == "Session" ->
                 typeLetBody gam1 gam2 ef1 [] binders ty1 t' elaboratedP elaborated1 elaborated2

            t -> halt $ GenericError (Just s)
                      $ "Expected an effect type but got ''" <> pretty t <> "'"

      typeLetBody gam1 gam2 ef1 ef2 binders ty1 ty2 ep elt1 elt2 = do
        optionalSigEquality s optionalTySig ty1
        gamNew <- ctxPlus s (gam2 `subtractCtxt` binders) gam1
        -- Check linearity of locally bound variables
        case checkLinearity binders gam2 of
            [] ->  do
              let t = Diamond (ef1 <> ef2) ty2
              let elaborated = LetDiamond s t ep optionalTySig elt1 elt2
              return (t, gamNew, elaborated)
            xs -> illLinearityMismatch s xs

-- Variables
synthExpr defs gam _ (Val s _ (Var _ x)) =
   -- Try the local context
   case lookup x gam of
     Nothing ->
       -- Try definitions in scope
       case lookup x (defs <> Primitives.builtins) of
         Just tyScheme  -> do
           (ty',_) <- freshPolymorphicInstance InstanceQ tyScheme -- discard list of fresh type variables

           let elaborated = Val s ty' (Var ty' x)
           return (ty', [], elaborated)

         -- Couldn't find it
         Nothing  -> halt $ UnboundVariableError (Just s) $ pretty x <?> "synthExpr on variables"
                              <> if debugging ?globals then
                                  " { looking for " <> show x
                                  <> " in context " <> show gam
                                  <> "}"
                                 else ""
     -- In the local context
     Just (Linear ty)       -> do
       let elaborated = Val s ty (Var ty x)
       return (ty, [(x, Linear ty)], elaborated)

     Just (Discharged ty c) -> do
       k <- inferCoeffectType s c
       let elaborated = Val s ty (Var ty x)
       return (ty, [(x, Discharged ty (COne k))], elaborated)

-- Specialised application for scale
{-
TODO: needs thought
synthExpr defs gam pol
      (App _ _ (Val _ _ (Var _ v)) (Val _ _ (NumFloat _ r))) | internalName v == "scale" = do
  let float = TyCon $ mkId "Float"
  return (FunTy (Box (CFloat (toRational r)) float) float, [])
-}

-- Application
synthExpr defs gam pol (App s _ e e') = do
    (fTy, gam1, elaboratedL) <- synthExpr defs gam pol e
    case fTy of
      -- Got a function type for the left-hand side of application
      (FunTy sig tau) -> do
         (gam2, subst, elaboratedR) <- checkExpr defs gam (flipPol pol) False sig e'
         gamNew <- ctxPlus s gam1 gam2
         tau    <- substitute subst tau

         let elaborated = App s tau elaboratedL elaboratedR
         return (tau, gamNew, elaborated)

      -- Not a function type
      t ->
        halt $ GenericError (Just s) $ "Left-hand side of application is not a function"
                   <> " but has type '" <> pretty t <> "'"

-- Promotion
synthExpr defs gam pol (Val s _ (Promote _ e)) = do
   debugM "Synthing a promotion of " $ pretty e

   -- Create a fresh kind variable for this coeffect
   vark <- freshVar $ "kprom_" <> [head (pretty e)]

   -- TODO: note that this does not of the specil hanlding that happens with Level

   -- Create a fresh coeffect variable for the coeffect of the promoted expression
   var <- freshCoeffectVar (mkId $ "prom_" <> pretty e) (TyVar $ mkId vark)

   gamF <- discToFreshVarsIn s (freeVars e) gam (CVar var)

   (t, gam', elaboratedE) <- synthExpr defs gamF pol e

   let finalTy = Box (CVar var) t
   let elaborated = Val s finalTy (Promote t elaboratedE)
   return (finalTy, multAll (freeVars e) (CVar var) gam', elaborated)

-- BinOp
synthExpr defs gam pol (Binop s _ op e1 e2) = do
    (t1, gam1, elaboratedL) <- synthExpr defs gam pol e1
    (t2, gam2, elaboratedR) <- synthExpr defs gam pol e2
    -- Look through the list of operators (of which there might be
    -- multiple matching operators)
    case lookupMany op Primitives.binaryOperators of
      [] -> halt $ UnboundVariableError (Just s) $ "Binary operator " <> op
      ops -> do
        returnType <- selectFirstByType t1 t2 ops
        gamOut <- ctxPlus s gam1 gam2

        let elaborated = Binop s returnType op elaboratedL elaboratedR
        return (returnType, gamOut, elaborated)

  where
    -- No matching type were found (meaning there is a type error)
    selectFirstByType t1 t2 [] =
      halt $ GenericError (Just s) $ "Could not resolve operator " <> op <> " at type: "
         <> pretty (FunTy t1 (FunTy t2 (TyVar $ mkId "...")))

    selectFirstByType t1 t2 ((FunTy opt1 (FunTy opt2 resultTy)):ops) = do
      -- Attempt to use this typing
      (result, local) <- localChecking $ do
         (eq1, _, _) <- equalTypes s t1 opt1
         (eq2, _, _) <- equalTypes s t2 opt2
         return (eq1 && eq2)
      -- If successful then return this local computation
      case result of
        Just True -> local >> return resultTy
        _         -> selectFirstByType t1 t2 ops

    selectFirstByType t1 t2 (_:ops) = selectFirstByType t1 t2 ops


-- Abstraction, can only synthesise the types of
-- lambda in Church style (explicit type)
synthExpr defs gam pol (Val s _ (Abs _ p (Just sig) e)) = do
  (binding, _, subst, elaboratedP) <- ctxtFromTypedPattern s sig p

  pIrrefutable <- isIrrefutable s sig p
  if pIrrefutable then do
     (tau, gam'', elaboratedE) <- synthExpr defs (binding <> gam) pol e

     let finalTy = FunTy sig tau
     let elaborated = Val s finalTy (Abs tau elaboratedP (Just sig) elaboratedE)
     return (finalTy, gam'' `subtractCtxt` binding, elaborated)
  else refutablePattern s p

synthExpr _ _ _ e =
  halt $ GenericError (Just $ getSpan e) "Type cannot be calculated here; try adding more type signatures."

-- Check an optional type signature for equality against a type
optionalSigEquality :: (?globals :: Globals) => Span -> Maybe Type -> Type -> MaybeT Checker Bool
optionalSigEquality _ Nothing _ = return True
optionalSigEquality s (Just t) t' = do
    (eq, _, _) <- equalTypes s t' t
    return eq

solveConstraints :: (?globals :: Globals) => Pred -> Span -> Id -> MaybeT Checker ()
solveConstraints predicate s defName = do
  -- Get the coeffect kind context and constraints
  checkerState <- get
  let
    ctxtCk  = tyVarContext checkerState
    ctxtCkVar = kVarContext checkerState
    coeffectVars = justCoeffectTypesConverted checkerState ctxtCk
    coeffectKVars = justCoeffectTypesConvertedVars checkerState ctxtCkVar
    (sbvTheorem, _, unsats) = compileToSBV predicate coeffectVars coeffectKVars

  ThmResult thmRes <- liftIO . prove $ do -- proveWith defaultSMTCfg {verbose=True}
    case solverTimeoutMillis ?globals of
      Nothing -> return ()
      Just n -> setTimeOut n
    sbvTheorem

  case thmRes of
    Unsatisfiable {} -> return () -- we're good: the negation of the theorem is unsatisfiable
    ProofError _ msgs ->
      halt $ CheckerError Nothing $ "Solver error:" <> unlines msgs
    Unknown _ UnknownTimeOut ->
      halt $ CheckerError Nothing $
        "Solver timed out with limit of " <>
        show (solverTimeoutMillis ?globals) <>
        " ms. You may want to increase the timeout (see --help)."
    Unknown _ reason  ->
      halt $ CheckerError Nothing $ "Solver says unknown: " <> show reason
    _ ->
      case getModelAssignment thmRes of
        -- Main 'Falsifiable' result
        Right (False, assg :: [ Integer ] ) -> do
          -- Show any trivial inequalities
          mapM_ (\c -> halt $ GradingError (Just $ getSpan c) (pretty . Neg $ c)) unsats
          -- Show fatal error, with prover result
          {-
          negated <- liftIO . sat $ sbvSatTheorem
          print $ show $ getModelDictionary negated
          case (getModelAssignment negated) of
            Right (_, assg :: [Integer]) -> do
              print $ show assg
            Left msg -> print $ show msg
          -}
          halt $ GenericError (Just s) $ "Definition '" <> pretty defName <> "' is " <> show (ThmResult thmRes)

        Right (True, _) ->
          halt $ GenericError (Just s) $ "Definition '" <> pretty defName <> "' returned probable model."

        Left str        ->
          halt $ GenericError (Just s) $ "Definition '" <> pretty defName <> " had a solver fail: " <> str
  where

    justCoeffectTypesConverted checkerState = mapMaybe convert
      where
       convert (var, (KPromote (TyCon constr), q)) =
           case lookup constr (typeConstructors checkerState) of
             Just (KCoeffect,_) -> Just (var, (TyCon constr, q))
             _                  -> Nothing

       convert (var, (KConstr constr, q)) =
           -- TODO: look into removing this case
           case lookup (constr) (typeConstructors checkerState) of
             Just (KCoeffect,_) -> Just (var, (TyCon constr, q))
             _                  -> Nothing
       --convert (var, (KPromote (TyVar v), q)) = Just (var, (TyVar v, q))
       -- TODO: currently all poly variables are treated as kind 'Coeffect'
       -- but this need not be the case, so this can be generalised
       convert (var, (KVar v, q)) = Just (var, (TyVar v, q))
       -- Unpromote things that are already types
       convert (var, (KPromote t, q)) = Just (var, (t, q))
       convert (var, t) = Nothing

    justCoeffectTypesConvertedVars checkerState =
       stripQuantifiers . (justCoeffectTypesConverted checkerState) . map (\(var, k) -> (var, (k, ForallQ)))


ctxtApprox :: (?globals :: Globals) => Span -> Ctxt Assumption -> Ctxt Assumption
  -> MaybeT Checker ()
ctxtApprox s ctxt1 ctxt2 = do
    let ctxt  = ctxt1 `intersectCtxts` ctxt2
        ctxt' = ctxt2 `intersectCtxts` ctxt1
    zipWithM_ (relateByAssumption s ApproximatedBy) ctxt ctxt'

ctxtEquals :: (?globals :: Globals) => Span -> Ctxt Assumption -> Ctxt Assumption
  -> MaybeT Checker ()
ctxtEquals s ctxt1 ctxt2 = do
  -- intersection contains those ids from ctxt1 which appears in ctxt2
  intersection <-
    -- For everything in the right context
    -- (which should come as an input to checking)
    forM ctxt2 $ \(id, ass2) ->
      -- See if it appears in the left context...
      case lookup id ctxt1 of
        -- ... if so equate
        Just ass1 -> do
          relateByAssumption s Eq (id, ass1) (id, ass2)
          return id
        -- ... if not check to see if the missing variable is linear
        Nothing   ->
          case ass2 of
            -- Linear gets instantly reported
            Linear t -> illLinearityMismatch s [LinearNotUsed id]
            -- Else, this could be due to weakening so see if this is allowed
            Discharged t c -> do
              kind <- inferCoeffectType s c
              relateByAssumption s Eq (id, Discharged t (CZero kind)) (id, ass2)
              return id
  -- Last we sanity check, if there is anything in ctxt1 that is not in ctxt2
  -- then we have an issue!
  forM_ ctxt1 $ \(id, ass1) ->
    if (id `elem` intersection)
      then return ()
      else halt $ UnboundVariableError (Just s) $
                "Variable `" <> pretty id <> "` was used but is not bound here"

{-
    let ctxt  = ctxt1 `intersectCtxts` ctxt2
        ctxt' = ctxt2 `intersectCtxts` ctxt1
    zipWithM_ (relateByAssumption s Eq) ctxt ctxt'
-}

{- | Take the least-upper bound of two contexts.
     If one context contains a linear variable that is not present in
    the other, then the resulting context will not have this linear variable -}
joinCtxts :: (?globals :: Globals) => Span -> Ctxt Assumption -> Ctxt Assumption
  -> MaybeT Checker (Ctxt Assumption)
joinCtxts s ctxt1 ctxt2 = do
    -- All the type assumptions from ctxt1 whose variables appear in ctxt2
    -- and weaken all others
    ctxt  <- intersectCtxtsWithWeaken s ctxt1 ctxt2
    -- All the type assumptions from ctxt2 whose variables appear in ctxt1
    -- and weaken all others
    ctxt' <- intersectCtxtsWithWeaken s ctxt2 ctxt1

    -- Make an context with fresh coeffect variables for all
    -- the variables which are in both ctxt1 and ctxt2...
    varCtxt <- freshVarsIn s (map fst ctxt) ctxt

    -- ... and make these fresh coeffects the upper-bound of the coeffects
    -- in ctxt and ctxt'
    zipWithM_ (relateByAssumption s ApproximatedBy) ctxt varCtxt
    zipWithM_ (relateByAssumption s ApproximatedBy) ctxt' varCtxt
    -- Return the common upper-bound context of ctxt1 and ctxt2
    return varCtxt

{- |  intersect contexts and weaken anything not appear in both
        relative to the left context (this is not commutative) -}
intersectCtxtsWithWeaken :: (?globals :: Globals) => Span -> Ctxt Assumption -> Ctxt Assumption
  -> MaybeT Checker (Ctxt Assumption)
intersectCtxtsWithWeaken s a b = do
   let intersected = intersectCtxts a b
   -- All the things that were not shared
   let remaining   = b `subtractCtxt` intersected
   let leftRemaining = a `subtractCtxt` intersected
   weakenedRemaining <- mapM weaken remaining
   let newCtxt = intersected <> filter isNonLinearAssumption (weakenedRemaining <> leftRemaining)
   return . normaliseCtxt $ newCtxt
  where
   isNonLinearAssumption :: (Id, Assumption) -> Bool
   isNonLinearAssumption (_, Discharged _ _) = True
   isNonLinearAssumption _                   = False

   weaken :: (Id, Assumption) -> MaybeT Checker (Id, Assumption)
   weaken (var, Linear t) =
       return (var, Linear t)
   weaken (var, Discharged t c) = do
       kind <- inferCoeffectType s c
       return (var, Discharged t (CZero kind))

{- | Given an input context and output context, check the usage of
     variables in the output, returning a list of usage mismatch
     information if, e.g., a variable is bound linearly in the input but is not
     used in the output, or is discharged in the output -}
checkLinearity :: Ctxt Assumption -> Ctxt Assumption -> [LinearityMismatch]
checkLinearity [] _ = []
checkLinearity ((v, Linear _):inCtxt) outCtxt =
  case lookup v outCtxt of
    -- Good: linear variable was used
    Just Linear{} -> checkLinearity inCtxt outCtxt
    -- Bad: linear variable was discharged (boxed var but binder not unboxed)
    Just Discharged{} -> LinearUsedNonLinearly v : checkLinearity inCtxt outCtxt
    Nothing -> LinearNotUsed v : checkLinearity inCtxt outCtxt

checkLinearity ((_, Discharged{}):inCtxt) outCtxt =
  -- Discharged things can be discarded, so it doesn't matter what
  -- happens with them
  checkLinearity inCtxt outCtxt


relateByAssumption :: (?globals :: Globals)
  => Span
  -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
  -> (Id, Assumption)
  -> (Id, Assumption)
  -> MaybeT Checker ()

-- Linear assumptions ignored
relateByAssumption _ _ (_, Linear _) (_, Linear _) = return ()

-- Discharged coeffect assumptions
relateByAssumption s rel (_, Discharged _ c1) (_, Discharged _ c2) = do
  kind <- mguCoeffectTypes s c1 c2
  addConstraint (rel s c1 c2 kind)

relateByAssumption s _ x y =
  halt $ GenericError (Just s) $ "Can't unify free-variable types:\n\t"
           <> "(graded) " <> pretty x <> "\n  with\n\t(linear) " <> pretty y

relevantSubCtxt :: [Id] -> [(Id, t)] -> [(Id, t)]
relevantSubCtxt vars = filter relevant
 where relevant (var, _) = var `elem` vars

-- Replace all top-level discharged coeffects with a variable
-- and derelict anything else
-- but add a var
discToFreshVarsIn :: (?globals :: Globals) => Span -> [Id] -> Ctxt Assumption -> Coeffect
  -> MaybeT Checker (Ctxt Assumption)
discToFreshVarsIn s vars ctxt coeffect = mapM toFreshVar (relevantSubCtxt vars ctxt)
  where
    toFreshVar (var, Discharged t c) = do
      kind <- mguCoeffectTypes s c coeffect
      -- Create a fresh variable
      cvar  <- freshCoeffectVar var kind
      -- Return the freshened var-type mapping
      return (var, Discharged t (CVar cvar))

    toFreshVar (var, Linear t) = do
      kind <- inferCoeffectType s coeffect
      return (var, Discharged t (COne kind))


-- `freshVarsIn names ctxt` creates a new context with
-- all the variables names in `ctxt` that appear in the list
-- `vars` and are discharged are
-- turned into discharged coeffect assumptions annotated
-- with a fresh coeffect variable (and all variables not in
-- `vars` get deleted).
-- e.g.
--  `freshVarsIn ["x", "y"] [("x", Discharged (2, Int),
--                           ("y", Linear Int),
--                           ("z", Discharged (3, Int)]
--  -> [("x", Discharged (c5 :: Nat, Int),
--      ("y", Linear Int)]
--
freshVarsIn :: (?globals :: Globals) => Span -> [Id] -> Ctxt Assumption
  -> MaybeT Checker (Ctxt Assumption)
freshVarsIn s vars ctxt = mapM toFreshVar (relevantSubCtxt vars ctxt)
  where
    toFreshVar (var, Discharged t c) = do
      ctype <- inferCoeffectType s c
      -- Create a fresh variable
      freshName <- freshVar (internalName var)
      let cvar = mkId freshName
      -- Update the coeffect kind context
      modify (\s -> s { tyVarContext = (cvar, (promoteTypeToKind ctype, InstanceQ)) : tyVarContext s })
      -- Return the freshened var-type mapping
      return (var, Discharged t (CVar cvar))

    toFreshVar (var, Linear t) = return (var, Linear t)


-- Combine two contexts
ctxPlus :: (?globals :: Globals) => Span -> Ctxt Assumption -> Ctxt Assumption
  -> MaybeT Checker (Ctxt Assumption)
ctxPlus _ [] ctxt2 = return ctxt2
ctxPlus s ((i, v) : ctxt1) ctxt2 = do
  ctxt' <- extCtxt s ctxt2 i v
  ctxPlus s ctxt1 ctxt'

-- Erase a variable from the context
eraseVar :: Ctxt Assumption -> Id -> Ctxt Assumption
eraseVar [] _ = []
eraseVar ((var, t):ctxt) var' | var == var' = ctxt
                             | otherwise = (var, t) : eraseVar ctxt var'

-- ExtCtxt the context
extCtxt :: (?globals :: Globals) => Span -> Ctxt Assumption -> Id -> Assumption
  -> MaybeT Checker (Ctxt Assumption)
extCtxt s ctxt var (Linear t) = do

  case lookup var ctxt of
    Just (Linear t') ->
       if t == t'
        then halt $ LinearityError (Just s)
                  $ "Linear variable `" <> pretty var <> "` is used more than once.\n"
        else typeClashForVariable s var t t'
    Just (Discharged t' c) ->
       if t == t'
         then do
           k <- inferCoeffectType s c
           return $ replace ctxt var (Discharged t (c `CPlus` COne k))
         else typeClashForVariable s var t t'
    Nothing -> return $ (var, Linear t) : ctxt

extCtxt s ctxt var (Discharged t c) = do

  case lookup var ctxt of
    Just (Discharged t' c') ->
        if t == t'
        then return $ replace ctxt var (Discharged t' (c `CPlus` c'))
        else typeClashForVariable s var t t'
    Just (Linear t') ->
        if t == t'
        then do
           k <- inferCoeffectType s c
           return $ replace ctxt var (Discharged t (c `CPlus` COne k))
        else typeClashForVariable s var t t'
    Nothing -> return $ (var, Discharged t c) : ctxt

-- Helper, foldM on a list with at least one element
fold1M :: Monad m => (a -> a -> m a) -> [a] -> m a
fold1M _ []     = error "Must have at least one case"
fold1M f (x:xs) = foldM f x xs
