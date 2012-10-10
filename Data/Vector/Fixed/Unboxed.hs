{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ImpredicativeTypes #-}
-- |
-- Unboxed vectors with fixed length
module Data.Vector.Fixed.Unboxed (
    Vec
  ) where

import Control.Monad
import Control.Monad.ST
import Data.Primitive.ByteArray
import Data.Primitive
import Prelude hiding (length)

import Data.Vector.Fixed



----------------------------------------------------------------
-- Data type
----------------------------------------------------------------

-- | Unboxed vector with fixed length
data Vec n a = Vec {-# UNPACK #-} !Int       -- Offset from start
                   {-# UNPACK #-} !ByteArray -- Data array

type instance Dim (Vec n) = n

instance (Arity n, Prim a) => Vector (Vec n) a where
  construct = fmap makeVec construct
  inspect   = inspectVec
  {-# INLINE construct #-}
  {-# INLINE inspect   #-}


newtype T_idx n = T_idx Int

inspectVec :: forall n a b. (Arity n, Prim a) => Vec n a -> Fun n a b -> b
{-# INLINE inspectVec #-}
inspectVec v (Fun f)
  = apply (\(T_idx i) -> (index i v, T_idx (i+1)))
          (T_idx 0 :: T_idx n)
          f

-- It's downright impossible to write construct for Vec using
-- accum. runST require existential quantification and mess everything
-- up!
makeVec :: forall n a. (Arity n, Prim a) => VecList n a -> Vec n a
{-# INLINE makeVec #-}
makeVec v@(VecList xs) = runST $ do
  arr <- newByteArray $! n * sizeOf (undefined :: a)
  forM_ (zip [0..] xs) $ \(i,x) -> do
    writeByteArray arr i x
  vec <- unsafeFreezeByteArray arr
  return $ Vec 0 vec
  where
    n = length v



----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

-- Low level indexing operation
index :: Prim a => Int -> Vec n a -> a
index n (Vec off arr) = indexByteArray arr (off + n)
