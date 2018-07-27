{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE CPP #-}

{-|
Module      : Std.Data.Vector.Sort
Description : Sorting vectors
Copyright   : (c) 2008-2011 Dan Doel, (c) Winterland, 2017-2018
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : non-portable

This module provide three stable sorting algorithms, which are:

  * 'mergeSort', a /O(log(n))/ general-purpose sorting algorithms for all different size vectors.

  * 'insertSort' a /O(n^2)/ sorting algorithms suitable for very small vectors.

  * 'radixSort' a /O(n)/ sorting algorithms based on 'Radix' instance, which is prefered on large vectors.

Sorting is always performed in ascending order. To reverse the order, either use @XXSortBy@ or use 'Down', 'PrimDown', 'RadixDown' newtypes. In general changing comparing functions can be done by creating auxiliary newtypes and 'Ord' instances (make sure you inline instance's method for performence!). Or 'Radix' instances in 'radixSort' case, for example:

@
data Foo = Foo { key :: Int16, ... }

instance Radix Foo where
    -- You should add INLINE pragmas to following methods
    bucketSize = bucketSize . key
    passes = passes . key
    radix0 = radix0 . key
    radix i = radix i . key
@

-}

module Std.Data.Vector.Sort (
  -- * Sort
    mergeSort
  , mergeSortBy
  , mergeTileSize
  , insertSort
  , insertSortBy
  , Down(..)
  , PrimDown(..)
  , radixSort
  , Radix(..)
  , RadixDown(..)
  ) where

import           Control.Monad.ST
import           Data.Bits
import           Data.Int
import           Data.Ord               (Down (..))
import           Data.Primitive         (sizeOf)
import           Data.Primitive.Types   (Prim (..))
import           Data.Word
import           Prelude                hiding (splitAt)
import           Std.Data.Array
import           Std.Data.Vector.Base
import           Std.Data.Vector.Extra

--------------------------------------------------------------------------------
-- Comparison Sort

-- | /O(n*log(n))/ Sort vector based on element's 'Ord' instance with classic
-- <https://en.wikipedia.org/wiki/Merge_sort mergesort> algorithm.
--
-- This is a stable sort, During sorting two O(n) worker arrays are needed, one of
-- them will be freezed into the result vector. The merge sort only begin at tile
-- size larger than 'mergeTileSize', each tile will be sorted with 'insertSort', then
-- iteratively merged into larger array, until all elements are sorted.
mergeSort :: forall v a. (Vec v a, Ord a) => v a -> v a
{-# INLINABLE mergeSort #-}
mergeSort = mergeSortBy compare

mergeSortBy :: forall v a. Vec v a => (a -> a -> Ordering) -> v a -> v a
{-# INLINE mergeSortBy #-}
mergeSortBy cmp v@(Vec _ _ l)
    | l <= mergeTileSize = insertSortBy cmp v
    | otherwise = runST (do
        -- create two worker array
        w1 <- newArr l
        w2 <- newArr l
        firstPass v 0 w1
        w <- mergePass w1 w2 mergeTileSize
        return $! fromArr w 0 l)
  where
    firstPass !v !i !marr
        | i >= l     = return ()
        | otherwise = do
            let (v',rest) = splitAt mergeTileSize v
            insertSortToMArr cmp v' i marr
            firstPass rest (i+mergeTileSize) marr

    mergePass !w1 !w2 !blockSiz
        | blockSiz >= l = unsafeFreezeArr w1
        | otherwise     = do
            mergeLoop w1 w2 blockSiz 0
            mergePass w2 w1 (blockSiz*2) -- swap worker array and continue merging

    mergeLoop !src !target !blockSiz !i
        | i >= l-blockSiz =                 -- remaining elements less than a block
            if i >= l
            then return ()
            else copyMutableArr target i src i (l-i)
        | otherwise = do
            let !mergeEnd = min (i+blockSiz+blockSiz) l
            mergeBlock src target (i+blockSiz) mergeEnd i (i+blockSiz) i
            mergeLoop src target blockSiz mergeEnd

    mergeBlock !src !target !leftEnd !rightEnd !i !j !k = do
        l <- readArr src i
        r <- readArr src j
        case r `cmp` l of
            LT -> do
                writeArr target k r
                let !j' = j + 1
                    !k' = k + 1
                if j' >= rightEnd
                then copyMutableArr target k' src i (leftEnd - i)
                else mergeBlock src target leftEnd rightEnd i j' k'
            _ -> do
                writeArr target k l
                let !i' = i + 1
                    !k' = k + 1
                if i' >= leftEnd
                then copyMutableArr target k' src j (rightEnd - j)
                else mergeBlock src target leftEnd rightEnd i' j k'

-- | The mergesort tile size, @mergeTileSize = 16@.
mergeTileSize :: Int
{-# INLINE mergeTileSize #-}
mergeTileSize = 16

-- | /O(n^2)/ Sort vector based on element's 'Ord' instance with simple
-- <https://en.wikipedia.org/wiki/Insertion_sort insertion-sort> algorithm.
--
-- This is a stable sort. O(n) extra space are needed,
-- which will be freezed into result vector.
insertSort :: (Vec v a, Ord a) => v a -> v a
{-# INLINE insertSort #-}
insertSort = insertSortBy compare

insertSortBy :: Vec v a => (a -> a -> Ordering) -> v a -> v a
{-# INLINE insertSortBy #-}
insertSortBy _ v@(Vec _ _ 0) = empty
insertSortBy _ v@(Vec arr s 1) = case indexArr' arr s of (# x #) -> singleton x
insertSortBy cmp v@(Vec arr s l) = create l (insertSortToMArr cmp v 0)

insertSortToMArr  :: Vec v a
                  => (a -> a -> Ordering)
                  -> v a            -- the original vector
                  -> Int            -- writing offset in the mutable array
                  -> MArray v s a   -- writing mutable array, must have enough space!
                  -> ST s ()
{-# INLINE insertSortToMArr #-}
insertSortToMArr cmp (Vec arr s l) moff marr = go s
  where
    !end = s + l
    !doff = moff-s
    go !i | i >= end  = return ()
          | otherwise = case indexArr' arr i of
               (# x #) -> do insert x (i+doff)
                             go (i+1)
    insert !temp !i
        | i <= moff = do
            writeArr marr moff temp
        | otherwise = do
            x <- readArr marr (i-1)
            case temp `cmp` x of
                LT -> do
                    writeArr marr i x
                    insert temp (i-1)
                _ -> writeArr marr i temp

-- | 'Down' newtype with 'Prim' support, this newtype can inverse the order of a 'Ord' 'Prim'.
newtype PrimDown a = PrimDown a deriving (Show, Eq, Prim)

instance Ord a => Ord (PrimDown a) where
    {-# INLINE compare #-}
    compare (PrimDown x) (PrimDown y) = y `compare` x
    {-# INLINE (<) #-}
    (PrimDown x) < (PrimDown y) = x >= y
    {-# INLINE (>) #-}
    (PrimDown x) > (PrimDown y) = x <= y
    {-# INLINE (<=) #-}
    (PrimDown x) <= (PrimDown y) = x > y
    {-# INLINE (>=) #-}
    (PrimDown x) >= (PrimDown y) = x < y

--------------------------------------------------------------------------------
-- Radix Sort

-- | Types contain radixs, which can be inspected with 'radix' during different 'passes'.
--
-- The default instances share a same 'bucketSize' 256, which seems to be a good default.
class Radix a where
    -- | The size of an auxiliary array, i.e. the counting bucket
    bucketSize :: a -> Int
    -- | The number of passes necessary to sort an array of es,
    --   it equals to the key's byte number.
    passes :: a -> Int
    -- | The radix function used in the first pass.
    radix0  :: a -> Int
    -- | The radix function parameterized by the current pass (0 < pass < passes e).
    radix  :: Int -> a -> Int

instance Radix Int8 where
    {-# INLINE bucketSize #-};
    bucketSize _ = 256
    {-# INLINE passes #-}
    passes _ = 1
    {-# INLINE radix0 #-}
    radix0 a =  255 .&. fromIntegral a `xor` 128
    {-# INLINE radix #-}
    radix _ _ = 0

#define MULTI_BYTES_INT_RADIX(T) \
    {-# INLINE bucketSize #-}; \
    bucketSize _ = 256; \
    {-# INLINE passes #-}; \
    passes _ = sizeOf (undefined :: T); \
    {-# INLINE radix0 #-}; \
    radix0 a = fromIntegral (255 .&. a); \
    {-# INLINE radix #-}; \
    radix i a = \
        if fromIntegral i == passes a - 1 then radix' (a `xor` minBound) else radix' a \
      where radix' a = fromIntegral (a `unsafeShiftR` (i `unsafeShiftL` 3)) .&. 255

instance Radix Int where MULTI_BYTES_INT_RADIX(Int)
instance Radix Int16 where MULTI_BYTES_INT_RADIX(Int16)
instance Radix Int32 where MULTI_BYTES_INT_RADIX(Int32)
instance Radix Int64 where MULTI_BYTES_INT_RADIX(Int64)

instance Radix Word8 where
    {-# INLINE bucketSize #-};
    bucketSize _ = 256
    {-# INLINE passes #-}
    passes _ = 1
    {-# INLINE radix0 #-}
    radix0 = fromIntegral
    {-# INLINE radix #-}
    radix _ _ = 0

#define MULTI_BYTES_WORD_RADIX(T) \
    {-# INLINE bucketSize #-}; \
    bucketSize _ = 256; \
    {-# INLINE passes #-}; \
    passes _ = sizeOf (undefined :: T); \
    {-# INLINE radix0 #-}; \
    radix0 a = fromIntegral (255 .&. a); \
    {-# INLINE radix #-}; \
    radix i a = fromIntegral (a `unsafeShiftR` (i `unsafeShiftL` 3)) .&. 255

instance Radix Word where MULTI_BYTES_INT_RADIX(Word)
instance Radix Word16 where MULTI_BYTES_INT_RADIX(Word16)
instance Radix Word32 where MULTI_BYTES_INT_RADIX(Word32)
instance Radix Word64 where MULTI_BYTES_INT_RADIX(Word64)

-- | Similar to 'Down' newtype for 'Ord', this newtype can inverse the order of a 'Radix'
-- instance when used in 'radixSort'.
newtype RadixDown a = RadixDown a deriving (Show, Eq, Prim)

instance Radix a => Radix (RadixDown a) where
    {-# INLINE bucketSize #-}
    bucketSize (RadixDown a) = bucketSize a
    {-# INLINE passes #-}
    passes (RadixDown a)  = passes a
    {-# INLINE radix0 #-}
    radix0 (RadixDown a) = bucketSize a - radix0 a -1
    {-# INLINE radix #-}
    radix i (RadixDown a) = bucketSize a - radix i a -1

-- | /O(n)/ Sort vector based on element's 'Radix' instance with
-- <https://en.wikipedia.org/wiki/Radix_sort radix-sort>,
-- (Least significant digit radix sorts variation).
--
-- This is a stable sort, one or two extra O(n) worker array are need
-- depend on how many 'passes' shall be performed, and a 'bucketSize'
-- counting bucket are also needed. This sort algorithms performed extremly
-- well on small byte size types such as 'Int8' or 'Word8', while on larger
-- type, constant passes may render this algorithm not suitable for small
-- vectors (turning point around 2^(2*passes)).
radixSort :: forall v a. (Vec v a, Radix a) => v a -> v a
{-# INLINABLE radixSort #-}
radixSort v@(Vec _ _ 0) = empty
radixSort v@(Vec arr s 1) = case indexArr' arr s of (# x #) -> singleton x
radixSort (Vec arr s l) = runST (do
        bucket <- newArrWith buktSiz 0 :: ST s (MutablePrimArray s Int)
        w1 <- newArr l
        firstCountPass arr bucket s
        accumBucket bucket buktSiz 0 0
        firstMovePass arr s bucket w1
        w <- if (passSiz == 1)
            then unsafeFreezeArr w1
            else do
                w2 <- newArr l
                radixLoop w1 w2 bucket buktSiz 1
        return $! fromArr w 0 l)
  where
    passSiz = passes (undefined :: a)
    buktSiz = bucketSize (undefined :: a)
    !end = s + l

    {-# INLINABLE firstCountPass #-}
    firstCountPass !arr !bucket !i
        | i >= end  = return ()
        | otherwise = case indexArr' arr i of
            (# x #) -> do
                let !r = radix0 x
                c <- readArr bucket r
                writeArr bucket r (c+1)
                firstCountPass arr bucket (i+1)

    {-# INLINABLE accumBucket #-}
    accumBucket !bucket !buktSiz !i !acc
        | i >= buktSiz = return ()
        | otherwise = do
            c <- readArr bucket i
            writeArr bucket i acc
            accumBucket bucket buktSiz (i+1) (acc+c)

    {-# INLINABLE firstMovePass #-}
    firstMovePass !arr !i !bucket !w
        | i >= end  = return ()
        | otherwise = case indexArr' arr i of
            (# x #) -> do
                let !r = radix0 x
                c <- readArr bucket r
                writeArr bucket r (c+1)
                writeArr w c x
                firstMovePass arr (i+1) bucket w

    {-# INLINABLE radixLoop #-}
    radixLoop !w1 !w2 !bucket !buktSiz !pass
        | pass >= passSiz = unsafeFreezeArr w1
        | otherwise = do
            setArr bucket 0 buktSiz 0   -- clear the counting bucket
            countPass w1 bucket pass 0
            accumBucket bucket buktSiz 0 0
            movePass w1 bucket pass w2 0
            radixLoop w2 w1 bucket buktSiz (pass+1)

    {-# INLINABLE countPass #-}
    countPass !marr !bucket !pass !i
        | i >= l  = return ()
        | otherwise = do
                x <- readArr marr i
                let !r = radix pass x
                c <- readArr bucket r
                writeArr bucket r (c+1)
                countPass marr bucket pass (i+1)

    {-# INLINABLE movePass #-}
    movePass !src !bucket !pass !target !i
        | i >= l  = return ()
        | otherwise = do
                x <- readArr src i
                let !r = radix pass x
                c <- readArr bucket r
                writeArr bucket r (c+1)
                writeArr target c x
                movePass src bucket pass target (i+1)
