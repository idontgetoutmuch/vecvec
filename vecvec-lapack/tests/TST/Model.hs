{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost        #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE ViewPatterns               #-}
-- |
-- Tools for writing tests for linear algebra.
module TST.Model
  ( -- * Arbitrary extensions
    ScalarModel(..)
  , ArbitraryShape(..)
  , X(..)
  , Nonsingular(..)
    -- * Models
  , IsModel(..)
  , Model(..)
  , Pair(..)
  , ModelVec(..)
  , ModelMat(..)
    -- * Helpers
  , genSize
  , genNonsingularMatrix
  , qualTypeName
  ) where

import Control.Monad
import Data.Complex          (Complex(..))
import Data.Kind             (Type)
import Data.Function         (on)
import Data.Typeable
import Data.List             (intercalate,transpose)
import Foreign.Storable      (Storable)
import Linear.Matrix         ((!*), (!*!))
import Test.Tasty.QuickCheck

import Data.Vector.Fixed.Cont qualified as FC
import Data.Vector.Generic   qualified as VG
import Data.Vector           qualified as V
import Data.Vector.Unboxed   qualified as VU
import Data.Vector.Storable  qualified as VS

import Vecvec.Classes
import Vecvec.Classes.NDArray
import Vecvec.LAPACK                      (Strided(..))
import Vecvec.LAPACK                       qualified as VV
import Vecvec.LAPACK.Internal.Matrix.Dense (Matrix, fromRowsFF)
import Vecvec.LAPACK.Internal.Matrix.Dense qualified as Mat
import TST.Orphanage ()


----------------------------------------------------------------
-- Extending arbitrary
----------------------------------------------------------------

-- | We want to test that multiplication return correct result without
--   going into dark forest of floating point. This is achieved by
--   exploiting fact that multiplication and addition small integers
--   are exact in floating point.
class Arbitrary a => ScalarModel a where
  genScalar    :: Gen a
  shrinkScalar :: a -> [a]

instance ScalarModel Float where
  genScalar = fromIntegral <$> choose @Int (-maxGenScacar, maxGenScacar)
  shrinkScalar = \case
    0 -> []
    1 -> [0]
    _ -> [0,1]

instance ScalarModel Double where
  genScalar = fromIntegral <$> choose @Int (-maxGenScacar, maxGenScacar)
  shrinkScalar = \case
    0 -> []
    1 -> [0]
    _ -> [0,1]

instance (RealFloat a, ScalarModel a) => ScalarModel (Complex a) where
  genScalar = (:+) <$> genScalar <*> genScalar
  shrinkScalar = \case
    0      -> []
    1      -> [0, 0:+1]
    0 :+ 1 -> [0, 1]
    _      -> [0, 1, 0:+1]

maxGenScacar :: Num a => a
maxGenScacar = 10

-- | Scalar which uses @ScalarModel@ for generation
newtype X a = X a
  deriving newtype Show

instance ScalarModel a => Arbitrary (X a) where
  arbitrary = X <$> genScalar

newtype Nonsingular a = Nonsingular { getNonsingular :: Matrix a }
  deriving newtype Show

instance (ScalarModel a, VV.LAPACKy a, Typeable a, Show a, Eq a) => Arbitrary (Nonsingular a) where
  arbitrary = Nonsingular <$> (genNonsingularMatrix =<< genSize)



-- | Generate random NDarray with specified shape
class (Arbitrary a, HasShape a) => ArbitraryShape a where
  arbitraryShape :: (IsShape shape (NDim a)) => shape -> Gen a

instance (NDim a ~ 2, ArbitraryShape a) => ArbitraryShape (Tr a) where
  arbitraryShape (N2 n k) = Tr <$> arbitraryShape (k,n)

instance (NDim a ~ 2, ArbitraryShape a) => ArbitraryShape (Conj a) where
  arbitraryShape (N2 n k) = Conj <$> arbitraryShape (k,n)



----------------------------------------------------------------
-- Models
----------------------------------------------------------------

-- | Type class for models. That is data types which implements same
-- operations in simpler way.
class ( ArbitraryShape (ModelRepr v)
      , Typeable v
      , Eq v
      , Show v
      , Show (ModelRepr v)
      ) => IsModel v where
  -- | Representation of a model. It may include unobservable
  --   information such as memory layout of vector or matrix
  type ModelRepr v :: Type
  -- | Convert model to actual data type
  fromModel :: Model v -> v

-- | Newtype wrapper for model.
newtype Model v = Model { unModel :: ModelRepr v }

deriving newtype instance Show               (ModelRepr v) => Show               (Model v)
deriving newtype instance Arbitrary          (ModelRepr v) => Arbitrary          (Model v)
deriving newtype instance HasShape           (ModelRepr v) => HasShape           (Model v)
deriving newtype instance ArbitraryShape     (ModelRepr v) => ArbitraryShape     (Model v)
deriving newtype instance AdditiveSemigroup  (ModelRepr v) => AdditiveSemigroup  (Model v)
deriving newtype instance AdditiveQuasigroup (ModelRepr v) => AdditiveQuasigroup (Model v)
deriving newtype instance VectorSpace        (ModelRepr v) => VectorSpace        (Model v)
deriving newtype instance InnerSpace         (ModelRepr v) => InnerSpace         (Model v)


instance (Storable a, Num a, Show a, Eq a, Typeable a, ScalarModel a) => IsModel (VV.Vec a) where
  type ModelRepr (VV.Vec a) = (ModelVec a)
  fromModel (Model (ModelVec stride xs))
    = slice ((0,End) `Strided` stride)
    $ VG.fromList
    $ (\n -> n : replicate (stride-1) 0) =<< xs

instance (Typeable a, Show a, Eq a, ScalarModel a) => IsModel (V.Vector a) where
  type ModelRepr (V.Vector a) = ModelVec a
  fromModel = VG.fromList . unModelVec . unModel

instance (Typeable a, Show a, Eq a, VU.Unbox a, ScalarModel a) => IsModel (VU.Vector a) where
  type ModelRepr (VU.Vector a) = ModelVec a
  fromModel = VG.fromList . unModelVec . unModel

instance (Typeable a, Show a, Eq a, Storable a, ScalarModel a) => IsModel (VS.Vector a) where
  type ModelRepr (VS.Vector a) = ModelVec a
  fromModel = VG.fromList . unModelVec . unModel

instance (Typeable a, Show a, Eq a, Storable a, ScalarModel a, Num a) => IsModel (Matrix a) where
  type ModelRepr (Matrix a) = ModelMat a
  fromModel (Model m@ModelMat{unModelMat=mat, ..})
    = slice ((padRows,End), (padCols,End))
    $ fromRowsFF
    $ replicate padRows (replicate (nC + padCols) 0)
   ++ map (replicate padCols 0 ++) mat
    where
      nC = modelMatCols m

instance (NDim (ModelRepr a) ~ 2, IsModel a) => IsModel (Tr a) where
  type ModelRepr (Tr a) = Tr (ModelRepr a)
  fromModel (Model (Tr a)) = Tr $ fromModel (Model a)

instance (NDim (ModelRepr a) ~ 2, IsModel a) => IsModel (Conj a) where
  type ModelRepr (Conj a) = Conj (ModelRepr a)
  fromModel (Model (Conj a)) = Conj $ fromModel (Model a)


----------------------------------------------------------------
-- Model for vectors
----------------------------------------------------------------

-- | We use lists as model for vectors.
data ModelVec a = ModelVec { modelVecStride :: !Int
                           , unModelVec     :: [a]
                           }
  deriving stock (Show)

instance HasShape (ModelVec a) where
  type NDim (ModelVec a) = 1
  shapeAsCVec = FC.mk1 . length . unModelVec

instance ScalarModel a => Arbitrary (ModelVec a) where
  arbitrary = arbitraryShape =<< genSize @Int
  shrink (ModelVec n xs) = do
    n' <- case n of 1 -> [1]
                    _ -> [1,n]
    x  <- shrinkList (const []) xs
    return $ ModelVec n' x

instance ScalarModel a => ArbitraryShape (ModelVec a) where
  arbitraryShape (N1 n) = ModelVec <$> genStride <*> replicateM n genScalar

-- FIXME: We need to implement checks than values have same size
instance Num a => AdditiveSemigroup (ModelVec a) where
  a .+. b = ModelVec 1 $ (zipWith (+) `on` unModelVec) a b

instance Num a => AdditiveQuasigroup (ModelVec a) where
  a .-. b = ModelVec 1 $ (zipWith (-) `on` unModelVec) a b
  negateV = ModelVec 1 . map negate . unModelVec

instance Num a => VectorSpace (ModelVec a) where
  type Scalar (ModelVec a) = a
  a *. ModelVec _ xs = ModelVec 1 $ fmap (a*) xs
  ModelVec _ xs .* a = ModelVec 1 $ fmap (*a) xs

instance NormedScalar a => InnerSpace (ModelVec a) where
  ModelVec _ xs <.> ModelVec _ ys = sum $ zipWith (\x y -> conjugate x * y) xs ys
  magnitudeSq (ModelVec _ xs) = sum $ scalarNormSq <$> xs



----------------------------------------------------------------
-- Model for matrix/vector multiplication
----------------------------------------------------------------

-- | Model for general dense matrices
data ModelMat a = ModelMat
  { padRows    :: !Int  -- ^ Extra padding for rows
  , padCols    :: !Int  -- ^ Extra padding for columns
  , unModelMat :: [[a]]
  }
  deriving stock (Show,Eq)

modelMatCols :: ModelMat a -> Int
modelMatCols m = case unModelMat m of
  []  -> 0
  x:_ -> length x

instance HasShape (ModelMat a) where
  type NDim (ModelMat a) = 2
  shapeAsCVec ModelMat{unModelMat=mat} = FC.mk2 (length mat) (length (head mat))

instance (ScalarModel a, Eq a) => Arbitrary (ModelMat a) where
  arbitrary = arbitraryShape =<< genSize @(Int,Int)
  shrink mat0@ModelMat{..} = do
    p_r <- case padRows of 0 -> [0]; _ -> [0,padRows]
    p_c <- case padCols of 0 -> [0]; _ -> [0,padCols]
    p_elem <- (traverse . traverse) shrinkScalar unModelMat
    let mat = ModelMat p_r p_c p_elem
    guard (mat /= mat0)
    return mat

instance (Eq a, ScalarModel a) => ArbitraryShape (ModelMat a) where
  arbitraryShape (N2 m n)
     = ModelMat
    <$> genOffset
    <*> genOffset
    <*> replicateM m (replicateM n genScalar)

instance Num a => AdditiveSemigroup (ModelMat a) where
  a .+. b = ModelMat 0 0 $ ((zipWith . zipWith) (+) `on` unModelMat) a b

instance Num a => AdditiveQuasigroup (ModelMat a) where
  a .-. b = ModelMat 0 0 $ ((zipWith . zipWith) (-) `on` unModelMat) a b
  negateV = ModelMat 0 0 . ((map . map) negate) . unModelMat

instance Num a => VectorSpace (ModelMat a) where
  type Scalar (ModelMat a) = a
  a *. ModelMat _ _ xs = ModelMat 0 0 $ (fmap . fmap) (a*) xs
  ModelMat _ _ xs .* a = ModelMat 0 0 $ (fmap . fmap) (*a) xs



-- | Data types which could be converted to matrix model
class IsModelMat m a where
  toModelMat :: m -> ModelMat a

instance a ~ a' => IsModelMat (ModelMat a) a' where
  toModelMat = id
instance a ~ a' => IsModelMat (Tr (ModelMat a)) a' where
  toModelMat (Tr m) = (ModelMat 0 0 . transpose . unModelMat) m
instance (NormedScalar a, a ~ a') => IsModelMat (Conj (ModelMat a)) a' where
  toModelMat (Conj m) = (ModelMat 0 0 . (fmap . fmap) conjugate . transpose . unModelMat) m


instance (Num a) => MatMul (ModelMat a) (ModelVec a) (ModelVec a) where
  m @@ v = ModelVec 1 $ unModelMat m !* unModelVec v

instance (Num a) => MatMul (Tr (ModelMat a)) (ModelVec a) (ModelVec a) where
  m @@ v = ModelVec 1 $ (unModelMat . toModelMat) m !* unModelVec v

instance (NormedScalar a) => MatMul (Conj (ModelMat a)) (ModelVec a) (ModelVec a) where
  m @@ v = ModelVec 1 $ (unModelMat . toModelMat) m !* unModelVec v


instance (NormedScalar a) => MatMul       (ModelMat a)        (ModelMat a)  (ModelMat a) where (@@) = defaultMulMM
instance (NormedScalar a) => MatMul (Tr   (ModelMat a))       (ModelMat a)  (ModelMat a) where (@@) = defaultMulMM
instance (NormedScalar a) => MatMul (Conj (ModelMat a))       (ModelMat a)  (ModelMat a) where (@@) = defaultMulMM
instance (NormedScalar a) => MatMul       (ModelMat a)  (Tr   (ModelMat a)) (ModelMat a) where (@@) = defaultMulMM
instance (NormedScalar a) => MatMul (Tr   (ModelMat a)) (Tr   (ModelMat a)) (ModelMat a) where (@@) = defaultMulMM
instance (NormedScalar a) => MatMul (Conj (ModelMat a)) (Tr   (ModelMat a)) (ModelMat a) where (@@) = defaultMulMM
instance (NormedScalar a) => MatMul       (ModelMat a)  (Conj (ModelMat a)) (ModelMat a) where (@@) = defaultMulMM
instance (NormedScalar a) => MatMul (Tr   (ModelMat a)) (Conj (ModelMat a)) (ModelMat a) where (@@) = defaultMulMM
instance (NormedScalar a) => MatMul (Conj (ModelMat a)) (Conj (ModelMat a)) (ModelMat a) where (@@) = defaultMulMM

-- | Default model implementation of matrix-matrix multiplication
defaultMulMM :: (Num a, IsModelMat m1 a, IsModelMat m2 a) => m1 -> m2 -> ModelMat a
defaultMulMM m1 m2 = ModelMat 0 0 $ unModelMat (toModelMat m1) !*! unModelMat (toModelMat m2)



----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

-- | Pair of models with same size
data Pair v = Pair (Model v) (Model v)

deriving stock instance Show (Model v) => Show (Pair v)

instance (IsModel v) => Arbitrary (Pair v) where
  arbitrary = do
    sz <- genSize @(FC.ContVec _ _)
    Pair <$> arbitraryShape sz <*> arbitraryShape sz

-- | Pretty print name of type
qualTypeName :: forall v. (Typeable v) => String
qualTypeName = intercalate " "
             $ tyConModule con <> "." <> tyConName con
             : map showParam par
  where
    tyV = typeRep (Proxy @v)
    (con,par) = splitTyConApp tyV
    showParam p = case show p of
      s | ' ' `elem` s -> "("++s++")"
        | otherwise    -> s

-- | Generate size for N-dimensional array
genSize :: forall shape n. (FC.Arity n, IsShape shape n) => Gen shape
genSize = shapeFromCVec <$> FC.replicateM @n (choose (1,10))

-- | Generate stride for vectors
genStride :: Gen Int
genStride = choose (1,3)

-- | Generate offset for matrices
genOffset :: Gen Int
genOffset = choose (0,3)

-- | Generate nonsingular square matrix. In order to ensure
--   nonsingularity we generate matrix with diagonal dominance
genNonsingularMatrix
  :: (ScalarModel a, VV.LAPACKy a, Typeable a, Show a, Eq a)
  => Int -> Gen (Matrix a)
genNonsingularMatrix sz = do
  mdl <- arbitraryShape (sz,sz)
  pure $  (2 * maxGenScacar * fromIntegral sz) *. Mat.eye sz
      .+. fromModel mdl
