module SimpleFormulaChecker where

import Language.Java.Syntax
import Language.Java.Parser
import Language.Java.Pretty

import Z3.Monad
import Z3.Opts

import Javawlp.Engine.Types
import Javawlp.Engine.HelperFunctions

import LogicIR.Expr
import LogicIR.Eval
import LogicIR.Frontend.Java
import LogicIR.Backend.Z3
import LogicIR.Backend.QuickCheck
import LogicIR.Backend.Pretty
import LogicIR.Backend.Null

import ModelParser.Parser
import ModelParser.Model

import Control.Monad (when)
import Control.Monad.Trans (liftIO)
import Data.Maybe
import Data.List
import Debug.Trace
import Data.Int
import qualified Data.Map as M

-- See README.md for a high-level description of this project.

type MethodDef = ([TypeDecl], Stmt, TypeEnv)

-- Takes a java source file and a method name and returns the class declarations,
-- the method body and the method's formal parameters.
parseMethod :: (FilePath, String) -> IO MethodDef
parseMethod (src, name) = do
    -- parse the Java source file:
    compilationnUnit <- parseJava src
    -- get all the class declarations in the Java source file; usually a single file defines only
    -- one class, but it could theoretically have more:
    let decls = getDecls compilationnUnit
    -- get the method's body ; to make it simple, the method's name is assumed to uniquely identify its body
    let mbody = fromJust $ getMethod decls (Ident name)
    -- get the method's formal parameters:
    let env = getMethodTypeEnv decls (Ident name)
    -- return the relevant data
    return (decls, mbody, env)
    where
    -- parse a Java source file, and extracts the necessary information from the compilation unit
    parseJava :: FilePath -> IO CompilationUnit
    parseJava s = do
        -- Get the source code
        source <- readFile s
        -- Parse the source code
        case parser compilationUnit source of
            Left parseError -> error (show parseError)
            Right compUnit  -> return compUnit

-- Get a list of all calls to a method of a specific name from a method definition.
getMethodCalls :: MethodDef -> String -> [MethodInvocation]
getMethodCalls (_, StmtBlock (Block bs), _) name = mapMaybe extractMethodInv bs
    where
        extractMethodInv :: BlockStmt -> Maybe MethodInvocation
        extractMethodInv (BlockStmt (ExpStmt (MethodInv i@(MethodCall (Name [Ident n]) _)))) = if n == name then Just i else Nothing
        extractMethodInv _ = Nothing

-- [pre(a), pre(b), pre(c)] -> (a AND b AND c)
extractExpr :: [MethodInvocation] -> Exp
extractExpr call = combineExprs $ map (\(MethodCall (Name [Ident _]) [a]) -> a) call
    where combineExprs :: [Exp] -> Exp
          combineExprs [e] = e
          combineExprs (e:es) = BinOp e CAnd (combineExprs es)

-- Check if two Z3 AST's are equivalent
isEquivalent :: Z3 AST -> Z3 AST -> IO (Result, Maybe Model)
isEquivalent ast1' ast2' = evalZ3 z3
    where
    z3 = do
         ast1 <- ast1'
         ast2 <- ast2'
         astEq <- mkEq ast1 ast2
         astNeq <- mkNot astEq -- negate the question to get a model
         assert astNeq
         r <- solverCheckAndGetModel -- check in documentatie
         solverReset
         return r

-- Function that shows a human-readable model and also highlights potential inconsistencies.
-- Sorry for the code, it is quite awful...
showRelevantModel :: Z3Model -> IO ()
showRelevantModel model = do
  putStrLn "Pretty model:"
  mapM_ (putStrLn . prettyModelVal) $ fromKeys (consts ++ arrays)
  where modelMap :: M.Map String ModelVal
        modelMap = M.fromList model
        modelClean :: M.Map String ModelVal
        modelClean = M.filterWithKey (\k _ -> '!' `notElem` k) $ M.map modelCleanFunc modelMap
        fromKeys :: [String] -> [(String, ModelVal)]
        fromKeys = map (\k -> let v = M.findWithDefault defaultArray k modelClean in (k, v))
        defaultArray :: ModelVal
        defaultArray = ArrayFunc [InstElse (-1000000000000000)] -- nullTest2
        -- Pretty print the model value
        prettyModelVal :: (String, ModelVal) -> String
        prettyModelVal (k, BoolVal b) = k ++ " = " ++ if b then "true" else "false"
        prettyModelVal (k, IntVal n) = k ++ " = " ++ show n
        prettyModelVal (k, ArrayFunc a) = k ++ " = " ++ final ++ "       " -- ++ show (aNull, aLength, a, arrKv, elseVal, length (buildArray 0))
            where (BoolVal aNull) = M.findWithDefault (BoolVal False) (k ++ "?null") modelClean
                  (IntVal aLength) = M.findWithDefault (IntVal (-1)) (k ++ "?length") modelClean
                  [InstElse elseVal] = filter (not . isInst) a
                  arrKv :: [(Int, Int)]
                  arrKv = filter (\(k, v) -> v /= elseVal) (sort (map (\(InstInt k v) -> (k, v)) (filter isInst a)))
                  isInst :: FuncInst -> Bool
                  isInst (InstInt _ v) = True
                  isInst _ = False
                  isValidArray :: Bool
                  isValidArray = null arrKv || (minIndex >= 0 && maxIndex < aLength)
                      where minIndex = minimum indices
                            maxIndex = maximum indices
                            indices  = map fst arrKv
                  arrMap :: M.Map Int Int
                  arrMap = M.fromList arrKv
                  buildArray :: Int -> [Int]
                  buildArray i = if aLength == 0 then [] else M.findWithDefault elseVal i arrMap : if i + 1 == aLength || i + 1 > 100 then [] else buildArray (i + 1)
                  final :: String
                  final | aNull = "null"
                        | isValidArray = show (buildArray 0) ++ if aLength > 100 then " (TRUNCATED, length: " ++ show aLength ++ ")" else "" --let xs = buildArray 0 in if length xs > 100 then show (take 100 xs) ++ " (TRUNCATED)" else show xs
                        | otherwise = "inconsistent array representation" -- blub2
        -- Remove all occurrences of ArrayRef and ArrayAsConst for easier processing later, also does type casting
        modelCleanFunc :: ModelVal -> ModelVal
        modelCleanFunc (BoolVal b) = BoolVal b
        modelCleanFunc (IntVal n) = IntVal (cropInt32 n)
        modelCleanFunc (ArrayRef s) = let Just v = M.lookup s modelMap in v
        modelCleanFunc (ArrayAsConst n) = ArrayFunc [InstElse (cropInt32 n)]
        modelCleanFunc (ArrayFunc v) = ArrayFunc (map funcInstClean v)
            where funcInstClean :: FuncInst -> FuncInst
                  funcInstClean (InstInt k v) = InstInt (cropInt32 k) (cropInt32 v)
                  funcInstClean (InstElse v) = InstElse (cropInt32 v)
        -- Crop an Integer to an Int32
        cropInt32 :: Int -> Int
        cropInt32 n = fromIntegral (fromIntegral n :: Int32) :: Int
        -- Names of the array variables
        arrays :: [String]
        arrays = nub $ M.keys (M.filter isArray modelClean) ++ mapMaybe arrayName (M.keys modelClean)
        -- Names of the constant variables
        consts :: [String]
        consts = filter (\v -> not (isSuffixOf "?length" v || isSuffixOf "?null" v)) $ M.keys (M.filter isConst modelClean)
        -- Returns Just "a" for "a?length" and "a?null"
        arrayName :: String -> Maybe String
        arrayName s
            | "?length" `isSuffixOf` s = Just $ take (length s - 7) s
            | "?null" `isSuffixOf` s = Just $ take (length s - 5) s
            | otherwise = Nothing
        -- Whether a ModelVal is an array
        isArray :: ModelVal -> Bool
        isArray (ArrayFunc _) = True
        isArray _ = False
        -- Whether a ModelVal is a constant
        isConst :: ModelVal -> Bool
        isConst v = case v of
                         BoolVal _ -> True
                         IntVal _ -> True
                         _ -> False

-- Determine the equality of two method's pre/post conditions.
determineFormulaEq :: MethodDef -> MethodDef -> String -> IO Bool
determineFormulaEq m1@(decls1, mbody1, env1) m2@(decls2, mbody2, env2) name = do
    -- get pre/post condition
    let (e1, e2) = (extractCond m1 name, extractCond m2 name)
    let (lexpr1', lexpr2') = (javaExpToLExpr e1 env1 decls1, javaExpToLExpr e2 env2 decls2)
    -- preprocess "a == null" to "isNull(a)"
    let (lexpr1, lexpr2) = (lExprPreprocessNull lexpr1', lExprPreprocessNull lexpr2')
    let (ast1, ast2) = (lExprToZ3Ast lexpr1, lExprToZ3Ast lexpr2)
    putStrLn $ "e1:\n" ++ prettyPrint e1 ++ "\n\ne2:\n" ++ prettyPrint e2 ++ "\n"
    putStrLn $ "LogicIR.Expr 1:\n" ++ show lexpr1 ++ "\n\nLogicIR.Expr 2:\n" ++ show lexpr2 ++ "\n"
    putStrLn $ "LogicIR.Pretty 1:\n" ++ prettyLExpr lexpr1 ++ "\n\nLogicIR.Pretty 2:\n" ++ prettyLExpr lexpr2 ++ "\n"
    ast1s <- showZ3AST ast1
    putStrLn $ "Z3 AST 1:\n" ++ ast1s ++ "\n"
    ast2s <- showZ3AST ast2
    putStrLn $ "Z3 AST 2:\n" ++ ast2s ++ "\n"
    putStrLn "Z3 Result:"
    -- Check if the formula is satisfiable. If it is, print the instantiation of its free
    -- variables that would make it true:
    (result, model) <- isEquivalent ast1 ast2
    case result of
       Unsat -> do
         putStrLn "formulas are equivalent!"
         return True
       Undef -> do
         putStrLn "unable to decide the satisfiablity (TODO: use QuickCheck)" -- this should happen on timeout, but the Z3 library does not function properly...
         return False
       Sat   -> do
                putStrLn "formulas are NOT equivalent, model:"
                case model of
                  Just m -> do s <- evalZ3With Nothing (Z3.Opts.opt "timeout" (1000 :: Int)) (modelToString m) -- TODO: the option is set, but does not actually work :(
                               putStrLn s
                               showRelevantModel $ parseModel s
                               return False
                  _      -> return False
    where
        extractCond :: MethodDef -> String -> Exp
        extractCond m n = extractExpr (getMethodCalls m n)
        showZ3AST :: Z3 AST -> IO String
        showZ3AST ast' = evalZ3 $ ast' >>= astToString

-- Function that compares both the pre and the post condition for two methods.
-- It is assumed that both methods have the same environment (parameter names, class member names, etc).
compareSpec :: (FilePath, String) -> (FilePath, String) -> IO Bool
compareSpec method1@(_, name1) method2@(_, name2) = do
    -- load the methods
    m1@(decls1, mbody1, env1) <- parseMethod method1
    m2@(decls2, mbody2, env2) <- parseMethod method2
    when (env1 /= env2) $ fail "inconsistent method parameters"
    when (decls1 /= decls2) $ fail "inconsistent class declarations (TODO)"
    putStrLn $ "----PRE---- (" ++ name1 ++ " vs " ++ name2 ++ ")"
    preAns <- determineFormulaEq m1 m2 "pre"
    putStrLn "\n----POST---"
    postAns <- determineFormulaEq m1 m2 "post"
    return $ preAns && postAns

quickCheckTest = do
    (result, model) <- LogicIR.Backend.QuickCheck.check e e
    putStrLn $ "Expressions are equal: " ++ (show result)
    putStrLn $ "Model used: " ++ (show model)
    return ()
        where e = LBinop (LBinop (LUnop NNot (LBinop (LUnop NNeg (LVar (Var (TPrim PInt32) "a"))) NMul (LVar (Var (TPrim PInt32) "c")))) CEqual (LBinop (LConst (CInt 79)) NAnd (LConst (CInt 41)))) LAnd (LBinop (LBinop (LBinop (LVar (Var (TPrim PInt32) "a")) NMul (LVar (Var (TPrim PInt32) "c"))) CGreater (LConst (CInt 0))) LAnd (LQuant QAny (Var (TPrim PInt32) "i") (LBinop (LBinop (LVar (Var (TPrim PInt32) "i")) CGreater (LConst (CInt 0))) LAnd (LBinop (LVar (Var (TPrim PInt32) "i")) CLess (LLen (Var (TArray (TPrim PInt32)) "b")))) (LBinop (LArray (Var (TArray (TPrim PInt32)) "b") (LVar (Var (TPrim PInt32) "i"))) CEqual (LVar (Var (TPrim PInt32) "retval")))))

evaluate :: String -> IO (Bool, Maybe Bool)
evaluate method = do
      m@(decls, mbody, env) <- parseMethod ("examples/javawlp_edsl/src/nl/uu/javawlp_edsl/Main.java", method)
      let e = extractExpr (getMethodCalls m "pre")
      let lexpr = javaExpToLExpr e env decls
      putStrLn (show lexpr)
      putStrLn (prettyLExpr lexpr)
      let t = CBool True
      let possible = LogicIR.Eval.evalPossible lexpr
      let res = if possible then Just (LogicIR.Eval.eval lexpr == t) else Nothing
      return (possible, res)

