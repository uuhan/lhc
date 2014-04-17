{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Haskell2010                #-}
module Data.Bedrock.HPT where

import           Control.Applicative ( (<$>) )
import           Data.IntMap         (IntMap)
import qualified Data.IntMap         as IntMap
import           Data.IntSet         (IntSet)
import qualified Data.IntSet         as IntSet
import           Data.Map            (Map)
import qualified Data.Map     as Map
--import           Data.Set            (Set)
--import qualified Data.Set     as Set
import           Control.Monad.RWS.Strict
import           Data.IORef
import           Data.Vector         (Vector)
import qualified Data.Vector         as Vector
import  Data.Vector.Mutable ( MVector )
import qualified Data.Vector.Mutable as MVector
import qualified Data.Vector.Unboxed.Mutable as MUVector
import           Data.Bedrock



{- Steps:
1. construct initial sharing map for variables.
2. Pass bedrock code through the run-time compiler.
3. Iterate the resulting function until no more progress can be made.
-}

{- Pathological case

long_list = [1,2,3,4,5,6,7,8,9,10,undefined]
val = sum long_list
sum [] = 0
sum (x:xs) = x + sum xs
-}

data Env = Env
    { envFnArgs              :: !FnArgs
    , envFnRets              :: !FnRets
    , envNodeScope           :: !NodeScope
    , envPtrScope            :: !PtrScope
    , envHeap                :: !Heap
    , envSharedVariables     :: !PtrSharingMap
    , envSharedHeapLocations :: !HeapSharingMap
    }
data World = World
    { worldHeapIndex           :: !HeapPtr -- Next available heap pointer
    }
newtype HPT a = HPT { unHPT :: RWST Env (Endo (HPT ())) World IO a }
    deriving
        ( Functor, Monad, MonadIO, MonadState World
        , MonadWriter (Endo (HPT ())), MonadReader Env )

type HeapPtr = Int
-- Use newtypes?
type HeapPtrSet = IntSet
type NameSet = IntSet

-- Indexes for function argument an return variables.
-- created once, used once. Not used in iterations.
type FnArgs = IntMap [Variable]
type FnRets = IntMap [Variable]

-- Variables are shared if they're used more than once.
-- Heap locations are shared if referred to by a shared variable or
-- if they are updated into a shared heap location.
type PtrSharingMap = MVector Bool
-- Set Name
type HeapSharingMap = MVector Bool
-- Set HeapPtr

-- XXX: Use HashMap?
type Objects = Map NodeName (Vector NameSet)
type PtrScope = MVector HeapPtrSet
type NodeScope = MVector Objects
type Heap = MVector Objects

--type DirtyScope = MVector Bool
--type DirtyHeap  = MVector Bool

getFunctionReturnRegisters :: Name -> HPT [Variable]
getFunctionReturnRegisters name = do
    rets <- asks envFnRets
    case IntMap.lookup (nameUnique name) rets of
        Nothing    -> error $ "Return registers not defined for: " ++
                              show name
        Just names -> return names

getFunctionArgumentRegisters :: Name -> HPT [Variable]
getFunctionArgumentRegisters name = do
    args <- asks envFnArgs
    case IntMap.lookup (nameUnique name) args of
        Nothing    -> error $ "Function arguments not defined for: " ++
                              show name
        Just names -> return names

singletonObject :: NodeName -> [Variable] -> Objects
singletonObject name vars =
    Map.singleton
        name
        (Vector.fromList $ map singletonNameSet vars )

singletonNameSet :: Variable -> NameSet
singletonNameSet var
    | variableType var == Primitive = IntSet.empty
    | otherwise                     = IntSet.singleton (variableIndex var)

variableIndex :: Variable -> Int
variableIndex = nameUnique . variableName

newHeapPtr :: HPT HeapPtr
newHeapPtr = do
    hp <- gets worldHeapIndex
    modify $ \st -> st{ worldHeapIndex = hp+1 }
    return hp

getNodeScope :: Variable -> HPT Objects
getNodeScope = getNodeScope' . variableIndex

getNodeScope' :: Int -> HPT Objects
getNodeScope' index = do
    scope <- gets worldNodeScope
    case IntMap.lookup index scope of
        Nothing      -> error $ "Missing variable: " ++ show index
        Just objects -> return objects

getPtrScope :: Variable -> HPT HeapPtrSet
getPtrScope = getPtrScope' . variableIndex

getPtrScope' :: Int -> HPT HeapPtrSet
getPtrScope' index = do
    scope <- gets worldPtrScope
    case IntMap.lookup index scope of
        Nothing   -> error $ "Missing variable: " ++ show index
        Just ptrs -> return ptrs

getHeapObjects :: HeapPtr -> HPT Objects
getHeapObjects hp = do
    heap <- gets worldHeap
    case IntMap.lookup hp heap of
        Nothing      -> error $ "Invalid heap pointer: " ++ show hp
        Just objects -> return objects

setHeapObjects :: HeapPtr -> Objects -> HPT ()
setHeapObjects hp objects = modify $ \st -> st{ worldHeap =
    IntMap.insertWith mergeObjects hp objects (worldHeap st) }

setNodeScope :: Variable -> Objects -> HPT ()
setNodeScope var objects = modify $ \st -> st{ worldNodeScope =
    IntMap.insertWith mergeObjects index objects (worldNodeScope st) }
  where
    index = variableIndex var

setPtrScope :: Variable -> HeapPtrSet -> HPT ()
setPtrScope var heapPtrs = modify $ \st -> st{ worldPtrScope =
    IntMap.insertWith IntSet.union index heapPtrs (worldPtrScope st) }
  where
    index = variableIndex var

mergeObjects :: Objects -> Objects -> Objects
mergeObjects = Map.unionWith merge
  where
    merge = Vector.zipWith IntSet.union

mergeObjectList :: [Objects] -> Objects
mergeObjectList = Map.unionsWith merge
  where
    merge = Vector.zipWith IntSet.union

eachIteration :: HPT () -> HPT ()
eachIteration action = do
    -- Run the action once and the schedule it to be part of the
    -- fix-point iteration.
    action
    tell (Endo (action >>))

-- assert (variableType src == variableType dst)
hptCopyVariables :: Variable -> Variable -> HPT ()
hptCopyVariables src dst | variableIndex src == variableIndex dst =
    return ()
hptCopyVariables src dst =
    case variableType src of
        Primitive -> return ()
        NodePtr -> do
            eachIteration $ do
                ptrs <- getPtrScope src
                setPtrScope dst ptrs
        Node -> do
            eachIteration $ do
                objects <- getNodeScope src
                setNodeScope dst objects

extract :: Objects -> NodeName -> Int -> NameSet
extract objs name nth =
    case Map.lookup name objs of
        Nothing    -> IntSet.empty
        Just names -> names Vector.! nth

hptAlternative :: Variable -> Alternative -> HPT ()
hptAlternative scrut (Alternative pattern branch) = do
    case pattern of
        LitPat{} -> return ()
        NodePat name args ->
            forM_ (zip [0..] args) $ \(nth, arg) -> eachIteration $ do
                objects <- getNodeScope scrut
                let vals = IntSet.toList (extract objects name nth)
                case variableType arg of
                    Primitive -> return ()
                    NodePtr   ->
                        forM_ vals $ \ptr -> do
                            setOfPtrs <- getPtrScope' ptr
                            setPtrScope arg setOfPtrs
                    Node      ->
                        forM_ vals $ \var -> do
                            nodes <- getNodeScope' var
                            setNodeScope arg nodes

hptExpression :: Function -> Expression -> HPT ()
hptExpression origin expr =
    case expr of
        Case scrut defaultBranch alternatives -> do
            case defaultBranch of
                Nothing -> return ()
                Just branch -> hptExpression origin branch
            mapM_ (hptAlternative scrut) alternatives
        Bind binds simple rest -> do
            hptSimpleExpression binds simple
            hptExpression origin rest
        -- Copy the values from the vars out into the return registers for
        -- our function.
        Return vars -> do
            rets <- getFunctionReturnRegisters (fnName origin)
            forM_ (zip vars rets) $ uncurry hptCopyVariables
        Throw{} ->
            error "Calls to @throw must have been lower before doing HPT\
                  \ analysis."
        -- Copy values from 'fn' return registers into ours.
        -- copy values from vars into argument registers of 'fn'
        TailCall fn vars -> do
            originRets <- getFunctionReturnRegisters (fnName origin)
            foreignRets <- getFunctionReturnRegisters fn
            foreignArgs <- getFunctionArgumentRegisters fn
            forM_ (zip foreignRets originRets) $ uncurry hptCopyVariables
            forM_ (zip vars foreignArgs) $ uncurry hptCopyVariables
        Exit -> return ()
        Panic{} -> return ()

hptSimpleExpression :: [Variable] -> SimpleExpression -> HPT ()
hptSimpleExpression binds simple =
    case simple of
        Store node vars | [ptr] <- binds -> do
            hp <- newHeapPtr
            setHeapObjects hp $ singletonObject node vars
            setPtrScope ptr (IntSet.singleton hp)
        Fetch ptrRef | [node] <- binds -> do
            eachIteration $ do
                ptrs <- IntSet.toList <$> getPtrScope ptrRef
                objects <- mapM getHeapObjects ptrs
                setNodeScope node (mergeObjectList objects)
        Unit args -> forM_ (zip binds args) $ \(bind, arg) -> do
            case arg of
                -- All such simple renamings should have been removed
                -- for performance reasons.
                RefArg var -> hptCopyVariables var bind
                LitArg{} -> return ()
                NodeArg name vars ->
                    setNodeScope bind $ singletonObject name vars
        Application fn vars -> do
            foreignRets <- getFunctionReturnRegisters fn
            foreignArgs <- getFunctionArgumentRegisters fn
            forM_ (zip vars foreignArgs) $ uncurry hptCopyVariables
            forM_ (zip foreignRets binds) $ uncurry hptCopyVariables
{-
*hp := @Store (Nothing)
ptr <- newHeapPtr
setHeap ptr (Node Nothing [])
setPtrScope *hp (IntSet.singleton ptr)

%var := @Unit( %other )
rhs <- queryScope (Variable %other)
setScope (Variable %var) rhs

@update oldObject newObject
-- 'oldObject' is a variable which may point to 'ptrs'
ptrs <- queryPtrScope oldObject
newPtrs <- queryPtrScope newObject
dependencies (ptrs, newPtrs) $
  forM_ ptrs $ \ptr ->
    setHeap ptr (nodes from newPtrs)

%node := Fetch *ptr
objects <- getHeap *ptr
dependency objects $ -- Don't run setScope if objects haven't changed.
    setScope (Variable %node) (Object objects)

case %scrut of
    0 -> prim alts are ignored.
    Object *ptr #prim %node -> ...
objects <- queryNodeScope %scrut
for each alternative:
    for each binding:
        let vals = extract nth from objects where nodename = alternative

        -- method for ptrs
        for vals $ \ptr ->
            setOfPtrs <- queryPtrScope ptr
            setPtrScope binding setOfPtrs

        -- prim is ignored.

        -- method for nodes
        for vals $ \objectRef ->
            objects <- queryNodeScope objectRef
            setNodeScope binding objects

-}
