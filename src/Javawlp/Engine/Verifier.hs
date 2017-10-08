-- Copyright (c) 2017 Utrecht University
-- Author: Koen Wermer

-- Providing a converter from Java expression to Z3 expression
module Javawlp.Engine.Verifier where

import Language.Java.Syntax
import Language.Java.Pretty
import Z3.Monad
import System.IO.Unsafe

import Javawlp.Engine.Folds
import Javawlp.Engine.HelperFunctions

import Control.Monad.Trans (liftIO)


-- | Checks wether the negation is unsatisfiable
isTrue :: TypeEnv -> [TypeDecl] -> Exp -> Z3 Bool
isTrue env decls e = isFalse env decls (PreNot e)


-- | Checks wether the expression is unsatisfiable
isFalse :: TypeEnv -> [TypeDecl] -> Exp -> Z3 Bool
isFalse env decls e =
    do
        ast <- foldExp expAssertAlgebra e env decls
        assert ast
        result <- check
        solverReset
        case result of
            Unsat -> return True
            _     -> return False

zprint :: MonadZ3 z3 => (a -> z3 String) -> a -> z3 ()
zprint mshowx x = mshowx x >>= liftIO . putStrLn

-- Equivalent to "z3_tests/forall.py"
testForall :: IO ()
testForall = evalZ3 $
    do
    sInt <- mkIntSort
    fSym <- mkStringSymbol "f"
    fDecl <- mkFuncDecl fSym [sInt, sInt] sInt
    printFunc fDecl

    x <- int "x"
    call1 <- mkApp fDecl [x, x]
    zero <- mkInteger 0
    body <- mkEq call1 zero
    xApp <- toApp x
    ast1 <- mkForallConst [] [xApp] body
    printAst ast1
    assert ast1

    a <- int "a"
    b <- int "b"
    call2 <- mkApp fDecl [a, b]
    one <- mkInteger 1
    ast2 <- mkEq call2 one
    printAst ast2
    assert ast2

    r <- solverCheckAndGetModel
    solverReset

    let (result, model) = r
    liftIO $ putStrLn $ "result: " ++ show result
    case model of Nothing -> liftIO $ putStrLn $ "model: " ++ "Nothing"
                  Just m -> do s <- showModel m; liftIO $ putStrLn $ "model: " ++ s

    where int x = mkStringSymbol x >>= mkIntVar
          printFunc x = zprint funcDeclToString x
          printAst x = zprint astToString x


-- | Check if a formula is satisfiable, and if so, return the model for it as well.
-- The result is a pair (r,m) where r is either Sat, Unsat, or Undef. If r is Sat,
-- then m is Just v where v a model witnessing the satisfiability of the input
-- formula. Else m is Nothing.
--
unsafeIsSatisfiable :: TypeEnv -> [TypeDecl] -> Exp -> (Result, Maybe Model)
unsafeIsSatisfiable env decls e = unsafePerformIO $ evalZ3 z3
    where
    z3 = do
         ast <- foldExp expAssertAlgebra e env decls
         assert ast
         r <- solverCheckAndGetModel
         solverReset
         return r


-- | Unsafe version of isTrue
unsafeIsTrue :: TypeEnv -> [TypeDecl] -> Exp -> Bool
unsafeIsTrue env decls = unsafePerformIO . evalZ3 . isTrue env decls

-- | Unsafe version of isFalse
unsafeIsFalse :: TypeEnv -> [TypeDecl] -> Exp -> Bool
unsafeIsFalse env decls = unsafePerformIO . evalZ3 . isFalse env decls

stringToBv :: String -> Z3 AST
stringToBv [] = mkIntNum 0 >>= mkInt2bv 8
stringToBv (c:cs) = do
                        c' <- mkIntNum (fromEnum c) >>= mkInt2bv 8
                        cs' <- stringToBv cs
                        mkConcat c' cs'

-- Creates a string to represent a name as a z3 variable
getVarName :: Name -> String
getVarName name = case prettyPrint name of
                    -- The wlp may contain variables introduced by method call (since methods may loop indefinitely we can't always get the return value)
                    -- We must ignore the exact number of the call, as it would introduce false positives
                    '$':s   -> '$' : takeWhile (/= '$') s
                    s       -> s

-- | Defines the convertion from an expression to AST so that Z3 can assert satisfiability
--   This is used to fold expressions generated by the WLP transformer, so not all valid Java expressions need to be handled
expAssertAlgebra :: ExpAlgebra (TypeEnv -> [TypeDecl] -> Z3 AST)
expAssertAlgebra = (fLit, fClassLit, fThis, fThisClass, fInstanceCreation, fQualInstanceCreation, fArrayCreate, fArrayCreateInit, fFieldAccess, fMethodInv, fArrayAccess, fExpName, fPostIncrement, fPostDecrement, fPreIncrement, fPreDecrement, fPrePlus, fPreMinus, fPreBitCompl, fPreNot, fCast, fBinOp, fInstanceOf, fCond, fAssign, fLambda, fMethodRef) where
    fLit lit _ _   = case lit of
                        Int n -> mkInteger n
                        Word n -> mkInteger n
                        Float d -> mkRealNum d
                        Double d -> mkRealNum d
                        Boolean b -> mkBool b
                        Char c -> do sort <- mkIntSort
                                     mkInt (fromEnum c) sort
                        String s -> stringToBv s
                        Null -> do sort <- mkIntSort
                                   mkInt 0 sort
    fClassLit = undefined
    fThis = undefined
    fThisClass = undefined
    fInstanceCreation = undefined
    fQualInstanceCreation = undefined
    fArrayCreate = error "ArrayCreate"
    fArrayCreateInit = undefined
    fFieldAccess fieldAccess _ _ = case fieldAccess of
                                    PrimaryFieldAccess e id         -> case e of
                                                                        InstanceCreation _ t args _ -> undefined
                                                                        _ -> undefined
                                    SuperFieldAccess id             -> mkStringSymbol (prettyPrint (Name [id])) >>= mkIntVar
                                    ClassFieldAccess (Name name) id -> mkStringSymbol (prettyPrint (Name (name ++ [id]))) >>= mkIntVar
    fMethodInv invocation env decls = case invocation of
                                        MethodCall (Name [Ident "*length"]) [a, (Lit (Int n))] -> case a of
                                                                                                        ArrayCreate t exps dim          -> foldExp expAssertAlgebra (if fromEnum n < length exps then (exps !! fromEnum n) else Lit (Int 0)) env decls
                                                                                                        ArrayCreateInit t dim arrayInit -> mkInteger 0
                                                                                                        ExpName name                    -> do
                                                                                                                                            symbol <- mkStringSymbol ("*length(" ++ getVarName name ++ ", " ++ show n ++ ")")
                                                                                                                                            mkIntVar symbol
                                                                                                        Cond g a1 a2                    -> foldExp expAssertAlgebra (Cond g (MethodInv (MethodCall (Name [Ident "*length"]) [a1, (Lit (Int n))])) (MethodInv (MethodCall (Name [Ident "*length"]) [a2, (Lit (Int n))]))) env decls
                                                                                                        Lit Null                        -> mkInteger (-1)
                                                                                                        _                               -> error ("length of non-array: " ++ prettyPrint a)
                                        _ -> error (prettyPrint invocation)
    fArrayAccess arrayIndex env decls = case arrayIndex of
                                            ArrayIndex (ArrayCreate t _ _) _ -> foldExp expAssertAlgebra (getInitValue t) env decls
                                            ArrayIndex (ArrayCreateInit t _ _) _ -> foldExp expAssertAlgebra (getInitValue t) env decls
                                            ArrayIndex (ExpName name) i -> do
                                                                            symbol <- mkStringSymbol (getVarName name ++ "[" ++ show i ++ "]")
                                                                            case arrayContentType (lookupType decls env name) of
                                                                                PrimType BooleanT    -> mkBoolVar symbol
                                                                                PrimType FloatT      -> mkRealVar symbol
                                                                                PrimType DoubleT     -> mkRealVar symbol
                                                                                _                    -> mkIntVar symbol
                                            ArrayIndex (Cond g a1 a2) i -> foldExp expAssertAlgebra (Cond g (ArrayAccess (ArrayIndex a1 i)) (ArrayAccess (ArrayIndex a2 i))) env decls
                                            ArrayIndex e _ -> foldExp expAssertAlgebra e env decls
    fExpName name env decls      = do
                                    symbol <- mkStringSymbol (getVarName name)

                                    -- If we're not dealing with library methods, we should be able to get the type from the type environment
                                    case lookupType decls env name of
                                        PrimType BooleanT    -> mkBoolVar symbol
                                        PrimType FloatT      -> mkRealVar symbol
                                        PrimType DoubleT     -> mkRealVar symbol
                                        PrimType IntT        -> mkIntVar symbol
                                        PrimType ByteT       -> mkIntVar symbol
                                        RefType _            -> mkIntVar symbol
                                        t                    -> error ("Verifier: Type of " ++ prettyPrint name ++ " unknown or not implemented: " ++ show t)
    fPostIncrement = undefined
    fPostDecrement = undefined
    fPreIncrement = undefined
    fPreDecrement = undefined
    fPrePlus e env decls = e env decls
    fPreMinus e env decls = do
                                ast <- e env decls
                                zero <- mkInteger 0
                                mkSub [zero, ast]
    fPreBitCompl = undefined
    fPreNot e env decls = e env decls >>= mkNot
    fCast = undefined
    fBinOp e1 op e2 env decls = case op of
                                    Mult -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkMul [ast1, ast2]
                                    Div -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkDiv ast1 ast2
                                    Rem -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkRem ast1 ast2
                                    Add -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkAdd [ast1, ast2]
                                    Sub -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkSub [ast1, ast2]
                                    LShift -> do
                                              ast1 <- e1 env decls >>= mkInt2bv 8
                                              ast2 <- e2 env decls >>= mkInt2bv 8
                                              astr <- mkBvshl ast1 ast2
                                              mkBv2int astr True
                                    RShift -> do
                                              ast1 <- e1 env decls >>= mkInt2bv 8
                                              ast2 <- e2 env decls >>= mkInt2bv 8
                                              astr <- mkBvashr ast1 ast2
                                              mkBv2int astr True
                                    RRShift -> do
                                              ast1 <- e1 env decls >>= mkInt2bv 8
                                              ast2 <- e2 env decls >>= mkInt2bv 8
                                              astr <- mkBvlshr ast1 ast2
                                              mkBv2int astr True
                                    LThan -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkLt ast1 ast2
                                    GThan -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkGt ast1 ast2
                                    LThanE -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkLe ast1 ast2
                                    GThanE -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkGe ast1 ast2
                                    Equal -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkEq ast1 ast2
                                    NotEq -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              eq <- mkEq ast1 ast2
                                              mkNot eq
                                    And-> do
                                              ast1 <- e1 env decls >>= mkInt2bv 8
                                              ast2 <- e2 env decls >>= mkInt2bv 8
                                              astr <- mkBvand ast1 ast2
                                              mkBv2int astr True
                                    Or -> do
                                              ast1 <- e1 env decls >>= mkInt2bv 8
                                              ast2 <- e2 env decls >>= mkInt2bv 8
                                              astr <- mkBvor ast1 ast2
                                              mkBv2int astr True
                                    Xor -> do
                                              ast1 <- e1 env decls >>= mkInt2bv 8
                                              ast2 <- e2 env decls >>= mkInt2bv 8
                                              astr <- mkBvxor ast1 ast2
                                              mkBv2int astr True
                                    CAnd -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkAnd [ast1, ast2]
                                    COr -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkOr [ast1, ast2]
    fInstanceOf = undefined
    fCond g e1 e2 env decls = do
                                astg <- g env decls
                                ast1 <- e1 env decls
                                ast2 <- e2 env decls
                                mkIte astg ast1 ast2
    fAssign = undefined
    fLambda params expr = error $ ('\n': show params) ++ "\n" ++ show expr
    fMethodRef = undefined
