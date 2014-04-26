module Data.Bedrock.Compile where

import           Control.Monad                     (when)
import           System.FilePath
import           Text.ParserCombinators.Parsec     (parseFromFile)
import           Text.Printf

import           Data.Bedrock.EvalApply
import           Data.Bedrock.Exceptions
import           Data.Bedrock.GlobalVariables
import           Data.Bedrock.HPT
import           Data.Bedrock.Invoke
import           Data.Bedrock.LLVM                 as LLVM
import           Data.Bedrock.Parse
import           Data.Bedrock.PrettyPrint
import           Data.Bedrock.RegisterIntroduction
import           Data.Bedrock.Rename
--import           Data.Bedrock.Simplify
import           Data.Bedrock
import           Data.Bedrock.NodeSizing
import           Data.Bedrock.Storage
import           Data.Bedrock.Storage.Fixed
import           Data.Bedrock.Storage.Pluggable

-- Compile options
type KeepIntermediateFiles = Bool
type Verbose = Bool

type Pipeline = [Step]
data Step
    = String :> (Module -> Module)
    | String :?> (HPTResult -> Module -> Module)
    | PerformHPT

infixr 9 :>
infixr 9 :?>

runPipeline :: KeepIntermediateFiles -> Verbose
            -> String -> Module -> Pipeline -> IO Module
runPipeline keepIntermediateFiles verbose title m0 =
    worker hpt0 0 m0
  where
    worker _ _ m [] = return m
    worker hpt n m (step:steps) =
        case step of
            tag :> action -> do
                m' <- runAction n m tag action
                worker hpt (n+1) m' steps
            tag :?> action -> do
                m' <- runAction n m tag (action hpt)
                worker hpt (n+1) m' steps
            PerformHPT -> do
                let hpt' = runHPT m
                when verbose $ ppHPTResult hpt'
                worker hpt' n m steps
    runAction n m tag action = do
        when verbose $
            printf "[%d] Running step %s\n" (n::Int) (show tag)
        let m' = action m
        when keepIntermediateFiles $
            writeFile (dstFile n tag) (show $ ppModule m')
        return m'
    hpt0 = runHPT m0
    dstFile n tag = title <.> show n <.> tag <.> "rock"

compileFromFile :: FilePath -> IO ()
compileFromFile = compileFromFileWithOpts True True

compileFromFileWithOpts :: KeepIntermediateFiles -> Verbose
                        -> FilePath -> IO ()
compileFromFileWithOpts keepIntermediateFiles verbose path = do
    ret <- parseFromFile parseModule path
    case ret of
        Left err -> print err
        Right m  -> do
            result <- runPipeline keepIntermediateFiles verbose base m
                [ "rename"          :> unique
                , PerformHPT
                , "no-laziness"     :?> runGen . lowerEvalApply
                , "no-exceptions"   :> unique . runGen cpsTransformation
                , PerformHPT
                , "no-invoke"       :?> runGen . lowerInvoke
                , "no-unknown-size" :?> runGen . lowerNodeSize
                , "no-nodes"        :> unique . registerIntroduction
                , "no-allocs"       :> unique . runGen lowerAlloc
                , "no-gc"           :> unique . lowerGC fixedGC
                , "no-globals"      :> unique . lowerGlobalRegisters
                ]
            LLVM.compile result (replaceExtension path "bc")
  where
    base = takeBaseName path