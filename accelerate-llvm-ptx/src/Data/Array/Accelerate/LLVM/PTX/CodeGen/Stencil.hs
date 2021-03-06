{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.PTX.CodeGen.Stencil
-- Copyright   : [2018] Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.PTX.CodeGen.Stencil (

  mkStencil1,
  mkStencil2,

) where

import Data.Array.Accelerate.AST                                    ( Stencil, StencilR(..), stencil )
import Data.Array.Accelerate.Analysis.Match
import Data.Array.Accelerate.Array.Sugar
import Data.Array.Accelerate.Error
import Data.Array.Accelerate.Type

import Data.Array.Accelerate.LLVM.CodeGen.Arithmetic
import Data.Array.Accelerate.LLVM.CodeGen.Array
import Data.Array.Accelerate.LLVM.CodeGen.Base
import Data.Array.Accelerate.LLVM.CodeGen.Environment
import Data.Array.Accelerate.LLVM.CodeGen.Exp
import Data.Array.Accelerate.LLVM.CodeGen.IR
import Data.Array.Accelerate.LLVM.CodeGen.Monad
import Data.Array.Accelerate.LLVM.CodeGen.Stencil
import Data.Array.Accelerate.LLVM.CodeGen.Sugar

import Data.Array.Accelerate.LLVM.PTX.CodeGen.Base
import Data.Array.Accelerate.LLVM.PTX.CodeGen.Loop
import Data.Array.Accelerate.LLVM.PTX.Target                        ( PTX )

import Control.Monad


-- The stencil function is similar to a map, but has access to surrounding
-- elements as specified by the stencil pattern.
--
-- This generates two functions:
--
--  * stencil_inside: does not apply boundary conditions, assumes all element
--                    accesses are valid
--
--  * stencil_border: applies boundary condition check to each array access
--
mkStencil1
    :: forall aenv stencil sh a b. (Stencil sh a stencil, Elt b)
    => Gamma aenv
    -> IRFun1     PTX aenv (stencil -> b)
    -> IRBoundary PTX aenv (Array sh a)
    -> IRDelayed  PTX aenv (Array sh a)
    -> CodeGen    PTX      (IROpenAcc PTX aenv (Array sh b))
mkStencil1 aenv fun bnd arr =
  let halo = stencilBorder (stencil :: StencilR sh a stencil)
  in
  (+++) <$> mkInside aenv halo (IRFun1 $ app1 fun <=< stencilAccess Nothing    arr)
        <*> mkBorder aenv      (IRFun1 $ app1 fun <=< stencilAccess (Just bnd) arr)


mkStencil2
    :: forall aenv stencil1 stencil2 sh a b c. (Stencil sh a stencil1, Stencil sh b stencil2, Elt c)
    => Gamma aenv
    -> IRFun2     PTX aenv (stencil1 -> stencil2 -> c)
    -> IRBoundary PTX aenv (Array sh a)
    -> IRDelayed  PTX aenv (Array sh a)
    -> IRBoundary PTX aenv (Array sh b)
    -> IRDelayed  PTX aenv (Array sh b)
    -> CodeGen    PTX      (IROpenAcc PTX aenv (Array sh c))
mkStencil2 aenv f bnd1 arr1 bnd2 arr2 =
  let
      inside  = IRFun1 $ \ix -> do
        stencil1 <- stencilAccess Nothing arr1 ix
        stencil2 <- stencilAccess Nothing arr2 ix
        app2 f stencil1 stencil2
      --
      border  = IRFun1 $ \ix -> do
        stencil1 <- stencilAccess (Just bnd1) arr1 ix
        stencil2 <- stencilAccess (Just bnd2) arr2 ix
        app2 f stencil1 stencil2

      halo1   = stencilBorder (stencil :: StencilR sh a stencil1)
      halo2   = stencilBorder (stencil :: StencilR sh b stencil2)
      halo    = halo1 `union` halo2
  in
  (+++) <$> mkInside aenv halo inside
        <*> mkBorder aenv      border


mkInside
    :: forall aenv sh e. (Shape sh, Elt e)
    => Gamma aenv
    -> sh
    -> IRFun1  PTX aenv (sh -> e)
    -> CodeGen PTX      (IROpenAcc PTX aenv (Array sh e))
mkInside aenv halo apply =
  let
      (arrOut, paramOut)  = mutableArray ("out"  :: Name (Array sh e))
      paramIn             = parameter    ("shIn" :: Name sh)
      shIn                = local        ("shIn" :: Name sh)
      shOut               = irArrayShape arrOut
      paramEnv            = envParam aenv
      --
  in
  makeOpenAcc "stencil_inside" (paramIn ++ paramOut ++ paramEnv) $ do

    start <- return (lift 0)
    end   <- shapeSize shIn

    -- iterate over the inside region as a linear index space
    --
    imapFromTo start end $ \i -> do

      ixIn  <- indexOfInt shIn i        -- convert to multidimensional index of inside region
      ixOut <- offset ixIn (lift halo)  -- shift to multidimensional index of outside region
      r     <- app1 apply ixOut         -- apply generator function
      j     <- intOfIndex shOut ixOut
      writeArray arrOut j r

    return_


mkBorder
    :: forall aenv sh e. (Shape sh, Elt e)
    => Gamma aenv
    -> IRFun1  PTX aenv (sh -> e)
    -> CodeGen PTX      (IROpenAcc PTX aenv (Array sh e))
mkBorder aenv apply =
  let
      (arrOut, paramOut)  = mutableArray ("out"    :: Name (Array sh e))
      paramFrom           = parameter    ("shFrom" :: Name sh)
      shFrom              = local        ("shFrom" :: Name sh)
      paramIn             = parameter    ("shIn"   :: Name sh)
      shIn                = local        ("shIn"   :: Name sh)
      shOut               = irArrayShape arrOut
      paramEnv            = envParam aenv
      --
  in
  makeOpenAcc "stencil_border" (paramFrom ++ paramIn ++ paramOut ++ paramEnv) $ do

    start <- return (lift 0)
    end   <- shapeSize shIn

    imapFromTo start end $ \i -> do

      ixIn  <- indexOfInt shIn i        -- convert to multidimensional index of inside region
      ixOut <- offset ixIn shFrom       -- shift to multidimensional index of outside region
      r     <- app1 apply ixOut         -- apply generator function
      j     <- intOfIndex shOut ixOut
      writeArray arrOut j r

    return_


offset :: forall sh. Shape sh => IR sh -> IR sh -> CodeGen PTX (IR sh)
offset (IR sh1) (IR sh2) = IR <$> go (eltType @sh) sh1 sh2
  where
    go :: TupleType t -> Operands t -> Operands t -> CodeGen PTX (Operands t)
    go TypeRunit OP_Unit OP_Unit
      = return OP_Unit

    go (TypeRpair ta tb) (OP_Pair sa1 sb1) (OP_Pair sa2 sb2)
      = OP_Pair <$> go ta sa1 sa2 <*> go tb sb1 sb2

    go (TypeRscalar t) sa sb
      | Just Refl <- matchScalarType t (scalarType :: ScalarType Int)
      = do IR x <- add (numType :: NumType Int) (IR sa) (IR sb)
           return x

    go _ _ _
      = $internalError "offset" "expected shape with Int components"


stencilBorder :: StencilR sh a stencil -> sh
stencilBorder = go
  where
    go :: StencilR sh' e stencil' -> sh'
    go StencilRunit3 = Z :. 1
    go StencilRunit5 = Z :. 2
    go StencilRunit7 = Z :. 3
    go StencilRunit9 = Z :. 4
    --
    go (StencilRtup3 a b c            ) = foldl1 union [go a, go b, go c]                                     :. 1
    go (StencilRtup5 a b c d e        ) = foldl1 union [go a, go b, go c, go d, go e]                         :. 2
    go (StencilRtup7 a b c d e f g    ) = foldl1 union [go a, go b, go c, go d, go e, go f, go g]             :. 3
    go (StencilRtup9 a b c d e f g h i) = foldl1 union [go a, go b, go c, go d, go e, go f, go g, go h, go i] :. 4

