module Verifier where

import Language.Java.Syntax
import Language.Java.Pretty
import Z3.Monad
import System.IO.Unsafe

import Folds
import HelperFunctions
import Settings


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
                                                                                                                                            symbol <- mkStringSymbol ("*length(" ++ prettyPrint name ++ ", " ++ show n ++ ")")
                                                                                                                                            mkIntVar symbol
                                                                                                        Cond g a1 a2                    -> foldExp expAssertAlgebra (Cond g (MethodInv (MethodCall (Name [Ident "*length"]) [a1, (Lit (Int n))])) (MethodInv (MethodCall (Name [Ident "*length"]) [a2, (Lit (Int n))]))) env decls
                                                                                                        Lit Null                        -> mkInteger (-1)
                                                                                                        _                               -> error ("length of non-array: " ++ prettyPrint a)
                                        _ -> error (prettyPrint invocation)
    fArrayAccess arrayIndex env decls = case arrayIndex of
                                            ArrayIndex (ArrayCreate t _ _) _ -> foldExp expAssertAlgebra (getInitValue t) env decls
                                            ArrayIndex (ArrayCreateInit t _ _) _ -> foldExp expAssertAlgebra (getInitValue t) env decls
                                            ArrayIndex (ExpName name) i -> do
                                                                            symbol <- mkStringSymbol (prettyPrint name ++ "[" ++ show i ++ "]")
                                                                            case arrayContentType (lookupType decls env name) of
                                                                                PrimType BooleanT    -> mkBoolVar symbol
                                                                                PrimType FloatT      -> mkRealVar symbol
                                                                                PrimType DoubleT     -> mkRealVar symbol
                                                                                _                    -> mkIntVar symbol
                                            ArrayIndex (Cond g a1 a2) i -> foldExp expAssertAlgebra (Cond g (ArrayAccess (ArrayIndex a1 i)) (ArrayAccess (ArrayIndex a2 i))) env decls
                                            ArrayIndex e _ -> foldExp expAssertAlgebra e env decls
    fExpName name env decls      = do
                                    symbol <- mkStringSymbol (prettyPrint name)
                                    case prettyPrint name of
                                        -- For now, we assume library methods return ints. Fixing this would require type information of library methods.
                                        '$':_   -> if ignoreLibMethods then mkStringSymbol "libMethodCall" >>= mkIntVar else error "introduced variable in WLP expression"
                                        -- If we're not dealing with library methods, we should be able to get the type from the type environment
                                        _       -> case lookupType decls env name of
                                                        PrimType BooleanT    -> mkBoolVar symbol
                                                        PrimType FloatT      -> mkRealVar symbol
                                                        PrimType DoubleT     -> mkRealVar symbol
                                                        PrimType IntT        -> mkIntVar symbol
                                                        RefType _            -> mkIntVar symbol
                                                        t                           -> error ("Verifier: Type of " ++ prettyPrint name ++ " unknown or not implemented: " ++ show t)
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
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkBvshl ast1 ast2
                                    RShift -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkBvashr ast1 ast2
                                    RRShift -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkBvlshr ast1 ast2
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
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkAnd [ast1, ast2]
                                    Or -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkOr [ast1, ast2]
                                    Xor -> do
                                              ast1 <- e1 env decls
                                              ast2 <- e2 env decls
                                              mkXor ast1 ast2
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
    fLambda = undefined
    fMethodRef = undefined