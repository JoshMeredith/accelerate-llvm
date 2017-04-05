{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.Native.CodeGen.Stencil
-- Copyright   : [2014..2015] Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.Native.CodeGen.Stencil
  where

-- accelerate
import Data.Array.Accelerate.AST                                    hiding (stencilAccess)
import Data.Array.Accelerate.Analysis.Match
import Data.Array.Accelerate.Analysis.Stencil
import Data.Array.Accelerate.Array.Sugar                            ( Array, DIM2, Shape, Elt, Z(..), (:.)(..) )
import Data.Array.Accelerate.Type
import Data.Array.Accelerate.Error

import Data.Array.Accelerate.LLVM.CodeGen.Arithmetic
import Data.Array.Accelerate.LLVM.CodeGen.Array
import Data.Array.Accelerate.LLVM.CodeGen.Base
import Data.Array.Accelerate.LLVM.CodeGen.Environment
import Data.Array.Accelerate.LLVM.CodeGen.Exp
import Data.Array.Accelerate.LLVM.CodeGen.IR
import Data.Array.Accelerate.LLVM.CodeGen.Loop
import Data.Array.Accelerate.LLVM.CodeGen.Monad
import Data.Array.Accelerate.LLVM.CodeGen.Stencil -- stencilAccess
import Data.Array.Accelerate.LLVM.CodeGen.Sugar

import Data.Array.Accelerate.LLVM.Native.Target                     ( Native )
import Data.Array.Accelerate.LLVM.Native.CodeGen.Base
import Data.Array.Accelerate.LLVM.Native.CodeGen.Generate
import Data.Array.Accelerate.LLVM.Native.CodeGen.Loop

import qualified LLVM.AST.Global                                    as LLVM


mkStencil
    :: forall aenv stencil a b sh. (Stencil sh a stencil, Elt b)
    => Gamma aenv
    -> IRFun1 Native aenv (stencil -> b)
    -> Boundary (IR a)
    -> IRManifest Native aenv (Array sh a)
    -> CodeGen (IROpenAcc Native aenv (Array sh b))
mkStencil _ _ _ _
  -- | Just Refl <- matchShapeType ...
  -- = mkStencil2D undefined undefined undefined

  | otherwise
  = undefined


gangParam2D :: (IR Int, IR Int, IR Int, IR Int, [LLVM.Parameter])
gangParam2D = undefined


index2D :: IR Int -> IR Int -> IR DIM2
index2D (IR x) (IR y) = IR (OP_Pair (OP_Pair OP_Unit y) x)


mkStencil2D
    :: forall aenv stencil a b sh. (Stencil DIM2 a stencil, Elt b)
    => Gamma aenv
    -> IRFun1 Native aenv (stencil -> b)
    -> Boundary (IR a)
    -> IRManifest Native aenv (Array DIM2 a)
    -> CodeGen (IROpenAcc Native aenv (Array DIM2 b))
mkStencil2D aenv f boundary (IRManifest v) =
  let
      (x0,y0,x1,y1, paramGang)  = gangParam2D
      x0'                       = add numType x0 borderWidth
      y0'                       = add numType y0 borderHeight
      x1'                       = sub numType x1 borderWidth
      y1'                       = sub numType y1 borderHeight
      (arrOut, paramOut)        = mutableArray ("out" :: Name (Array DIM2 b))
      paramEnv                  = envParam aenv
      --
      stepx = int 1
      stepy = int 1
      shapes = offsets (undefined :: Fun aenv (stencil -> b))
                       (undefined :: OpenAcc aenv (Array DIM2 a))
      (borderWidth, borderHeight) =
        case shapes of
          (Z :. x :. y):_ -> (lift x, lift y)
          _ -> $internalError "mkStencil2D" "2D shape is not 2D"
      middleElement = stencilElement stencilAccess -- TODO: replace stencilAccess with non bounds checked version
      boundaryElement = stencilElement stencilAccess
      stencilElement access x y = do
        let ix = (undefined `index` x `index` y)
        i <- intOfIndex (irArrayShape arrOut) ix
        sten <- access boundary (irArray (aprj v aenv)) ix
        r <- app1 f sten
        writeArray arrOut i r
  in
  makeOpenAcc "stencil2D" (paramGang ++ paramOut ++ paramEnv) $ do

    startx <- x0'
    starty <- y0'
    endx   <- x1'
    endy   <- y1'

    -- Middle section of matrix.
    imapFromStepTo starty stepx endy $ \y -> do
      imapFromStepTo startx stepy endx $ \x -> do
        middleElement x y
        return_
      return_

    -- Edges section of matrix.

    -- Top and bottom (with corners).
    maxYoffset <- sub numType borderHeight (int 1)

    imapFromTo (int 0) maxYoffset $ \ytop -> do
      imapFromTo x0 x1 $ \x -> do
        ybottom <- sub numType y1 ytop
        boundaryElement x ytop
        boundaryElement x ybottom
        return_

    -- Left and right (without corners).
    maxXoffset <- sub numType borderWidth (int 1)
    y0noCorners <- add numType y0 borderWidth
    y1noCorners <- sub numType y1 borderWidth

    imapFromTo y0noCorners y1noCorners $ \y -> do
      imapFromTo (int 0) maxXoffset $ \xleft -> do
        xright <- sub numType x1 xleft
        boundaryElement xleft  y
        boundaryElement xright y
        return_



