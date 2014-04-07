{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeSynonymInstances #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.PTX.Execute.Marshal
-- Copyright   : [2014] Trevor L. McDonell, Sean Lee, Vinod Grover, NVIDIA Corporation
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@nvidia.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.PTX.Execute.Marshal (

  Marshalable, marshal

) where

-- accelerate
import Data.Array.Accelerate.Array.Sugar
import qualified Data.Array.Accelerate.Array.Representation     as R

import Data.Array.Accelerate.LLVM.CodeGen.Environment           ( Gamma, Idx'(..) )
import Data.Array.Accelerate.LLVM.State

import Data.Array.Accelerate.LLVM.PTX.Target
import Data.Array.Accelerate.LLVM.PTX.Array.Data
import Data.Array.Accelerate.LLVM.PTX.Execute.Async
import Data.Array.Accelerate.LLVM.PTX.Execute.Environment
import qualified Data.Array.Accelerate.LLVM.PTX.Array.Prim      as Prim

-- cuda
import qualified Foreign.CUDA.Driver                            as CUDA

-- libraries
import Control.Monad.State
import Control.Monad.Reader
import Data.Int
import Data.DList                                               ( DList )
import Data.Typeable
import Foreign.Ptr
import qualified Data.DList                                     as DL
import qualified Data.IntMap                                    as IM


-- Marshalling arguments
-- ---------------------

-- | Convert function arguments into stream a form suitable for CUDA function calls
--
marshal :: Marshalable args => PTX -> Stream -> args -> IO [CUDA.FunParam]
marshal ptx stream args = DL.toList `fmap` marshal' ptx stream args


-- Data which can be marshalled as function arguments to kernels
--
class Marshalable a where
  marshal' :: PTX -> Stream -> a -> IO (DList CUDA.FunParam)

instance Marshalable () where
  marshal' _ _ () = return DL.empty

instance ArrayElt e => Marshalable (ArrayData e) where
  marshal' PTX{..} _ adata = do
    let marshalP :: forall e' a. (ArrayElt e', ArrayPtrs e' ~ Ptr a, Typeable a)
                 => ArrayData e'
                 -> IO (DList CUDA.FunParam)
        marshalP ad =
          fmap (DL.singleton . CUDA.VArg)
               (Prim.devicePtr ptxMemoryTable ad :: IO (CUDA.DevicePtr a))

        marshalR :: ArrayEltR e' -> ArrayData e' -> IO (DList CUDA.FunParam)
        marshalR ArrayEltRunit             _  = return DL.empty
        marshalR (ArrayEltRpair aeR1 aeR2) ad =
          return DL.append `ap` marshalR aeR1 (fstArrayData ad)
                           `ap` marshalR aeR2 (sndArrayData ad)
        marshalR ArrayEltRint     ad = marshalP ad
        marshalR ArrayEltRint8    ad = marshalP ad
        marshalR ArrayEltRint16   ad = marshalP ad
        marshalR ArrayEltRint32   ad = marshalP ad
        marshalR ArrayEltRint64   ad = marshalP ad
        marshalR ArrayEltRword    ad = marshalP ad
        marshalR ArrayEltRword8   ad = marshalP ad
        marshalR ArrayEltRword16  ad = marshalP ad
        marshalR ArrayEltRword32  ad = marshalP ad
        marshalR ArrayEltRword64  ad = marshalP ad
        marshalR ArrayEltRfloat   ad = marshalP ad
        marshalR ArrayEltRdouble  ad = marshalP ad
        marshalR ArrayEltRchar    ad = marshalP ad
        marshalR ArrayEltRcshort  ad = marshalP ad
        marshalR ArrayEltRcushort ad = marshalP ad
        marshalR ArrayEltRcint    ad = marshalP ad
        marshalR ArrayEltRcuint   ad = marshalP ad
        marshalR ArrayEltRclong   ad = marshalP ad
        marshalR ArrayEltRculong  ad = marshalP ad
        marshalR ArrayEltRcllong  ad = marshalP ad
        marshalR ArrayEltRcullong ad = marshalP ad
        marshalR ArrayEltRcchar   ad = marshalP ad
        marshalR ArrayEltRcschar  ad = marshalP ad
        marshalR ArrayEltRcuchar  ad = marshalP ad
        marshalR ArrayEltRcfloat  ad = marshalP ad
        marshalR ArrayEltRcdouble ad = marshalP ad
        marshalR ArrayEltRbool    ad = marshalP ad

    marshalR arrayElt adata

instance Marshalable (Gamma aenv, Aval aenv) where              -- overlaps with instance (a,b)
  marshal' ptx stream (gamma, aenv)
    = fmap DL.concat
    $ mapM (\(_, Idx' idx) -> marshal' ptx stream =<< sync (aprj idx aenv)) (IM.elems gamma)
    where
      sync :: Async a -> IO a
      sync arr = evalStateT (runReaderT (runLLVM (after stream arr)) undefined) ptx     -- HAXORZ!! D:

instance (Shape sh, Elt e) => Marshalable (Array sh e) where
  marshal' ptx stream (Array sh adata) =
    marshal' ptx stream (adata, reverse (R.shapeToList sh))

instance (Marshalable a, Marshalable b) => Marshalable (a, b) where
  marshal' ptx s (a, b) =
    DL.concat `fmap` sequence [marshal' ptx s a, marshal' ptx s b]

instance (Marshalable a, Marshalable b, Marshalable c) => Marshalable (a, b, c) where
  marshal' ptx s (a, b, c) =
    DL.concat `fmap` sequence [marshal' ptx s a, marshal' ptx s b, marshal' ptx s c]

instance (Marshalable a, Marshalable b, Marshalable c, Marshalable d) => Marshalable (a, b, c, d) where
  marshal' ptx s (a, b, c, d) =
    DL.concat `fmap` sequence [marshal' ptx s a, marshal' ptx s b, marshal' ptx s c, marshal' ptx s d]

instance (Marshalable a, Marshalable b, Marshalable c, Marshalable d, Marshalable e)
    => Marshalable (a, b, c, d, e) where
  marshal' ptx s (a, b, c, d, e) =
    DL.concat `fmap` sequence [marshal' ptx s a, marshal' ptx s b, marshal' ptx s c, marshal' ptx s d, marshal' ptx s e]

instance (Marshalable a, Marshalable b, Marshalable c, Marshalable d, Marshalable e, Marshalable f)
    => Marshalable (a, b, c, d, e, f) where
  marshal' ptx s (a, b, c, d, e, f) =
    DL.concat `fmap` sequence [marshal' ptx s a, marshal' ptx s b, marshal' ptx s c, marshal' ptx s d, marshal' ptx s e, marshal' ptx s f]

instance Marshalable Int where
  marshal' _ _ x = return $ DL.singleton (CUDA.VArg x)

instance Marshalable Int32 where
  marshal' _ _ x = return $ DL.singleton (CUDA.VArg x)

instance Marshalable a => Marshalable [a] where
  marshal' ptx s = fmap DL.concat . mapM (marshal' ptx s)

