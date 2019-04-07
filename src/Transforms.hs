{-# LANGUAGE TemplateHaskell, StandaloneDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveGeneric #-}

module Transforms where

import Utils
import Debug.Trace
import           Data.List                          (nub, sort, findIndex, find, maximumBy)
import qualified Data.Map.Strict as M

import GHC.Generics
import Data.Aeson (FromJSON, ToJSON, toJSON)

-- a, b, c, d, e, f as here:
-- https://developer.mozilla.org/en-US/docs/Web/SVG/Attribute/transform
data HMatrix a = HMatrix {
     xScale :: a, -- a
     xSkew :: a, -- c -- What are c and b called?
     ySkew :: a, -- b
     yScale :: a, -- d
     dx     :: a, -- e
     dy     :: a  -- f
} deriving (Generic, Eq)

instance Show a => Show (HMatrix a) where
         show m = "[ " ++ show (xScale m) ++ " " ++ show (xSkew m) ++ " " ++ show (dx m) ++ " ]\n" ++
                  "  " ++ show (ySkew m) ++ " " ++ show (yScale m) ++ " " ++ show (dy m) ++ "  \n" ++
                  "  0.0 0.0 1.0 ]"

instance (FromJSON a) => FromJSON (HMatrix a)
instance (ToJSON a)   => ToJSON (HMatrix a)

idH :: (Autofloat a) => HMatrix a
idH = HMatrix {
    xScale = 1,
    xSkew = 0,
    ySkew = 0,
    yScale = 1,
    dx = 0,
    dy = 0
}

-- First row, then second row
hmToList :: (Autofloat a) => HMatrix a -> [a]
hmToList m = [ xScale m, xSkew m, dx m, ySkew m, yScale m, dy m ]

listToHm :: (Autofloat a) => [a] -> HMatrix a
listToHm l = if length l /= 6 then error "wrong length list for hmatrix"
             else HMatrix { xScale = l !! 0, xSkew = l !! 1, dx = l !! 2,
                            ySkew = l !! 3, yScale = l !! 4, dy = l !! 5 }

hmDiff :: (Autofloat a) => HMatrix a -> HMatrix a -> a
hmDiff t1 t2 = let (l1, l2) = (hmToList t1, hmToList t2) in
               norm $ l1 -. l2

applyTransform :: (Autofloat a) => HMatrix a -> Pt2 a -> Pt2 a
applyTransform m (x, y) = (x * xScale m + y * xSkew m + dx m, x * ySkew m + y * yScale m + dy m)

infixl ##
(##) :: (Autofloat a) => HMatrix a -> Pt2 a -> Pt2 a
(##) = applyTransform

-- General functions to work with transformations

-- Do t2, then t1. That is, multiply two homogeneous matrices: t1 * t2
composeTransform :: (Autofloat a) => HMatrix a -> HMatrix a -> HMatrix a
composeTransform t1 t2 = HMatrix { xScale = xScale t1 * xScale t2 + xSkew t1  * ySkew t2,
                                   xSkew  = xScale t1 * xSkew t2  + xSkew t1  * yScale t2,
                                   ySkew  =  ySkew t1 * xScale t2 + yScale t1 * ySkew t2,
                                   yScale =  ySkew t1 * xSkew t2  + yScale t1 * yScale t2,
                                   dx     = xScale t1 * dx t2 + xSkew t1 * dy t2 + dx t1,
                                   dy     = yScale t1 * dy t2 + ySkew t1 * dx t2 + dy t1 }
-- TODO: test that this gives expected results for two scalings, translations, rotations, etc.

infixl 7 #
(#) :: (Autofloat a) => HMatrix a -> HMatrix a -> HMatrix a
(#) = composeTransform

-- Compose all the transforms in RIGHT TO LEFT order:
-- [t1, t2, t3] means "do t3, then do t2, then do t1" or "t1 * t2 * t3"
composeTransforms :: (Autofloat a) => [HMatrix a] -> HMatrix a
composeTransforms ts = foldr composeTransform idH ts

-- Specific transformations

rotationM :: (Autofloat a) => a -> HMatrix a
rotationM radians = idH { xScale = cos radians, 
                          xSkew = -(sin radians),
                          ySkew = sin radians,
                          yScale = cos radians
                       }

translationM :: (Autofloat a) => Pt2 a -> HMatrix a
translationM (x, y) = idH { dx = x, dy = y }

scalingM :: (Autofloat a) => Pt2 a -> HMatrix a
scalingM (cx, cy) = idH { xScale = cx, yScale = cy }

rotationAboutM :: (Autofloat a) => a -> Pt2 a -> HMatrix a
rotationAboutM radians (x, y) = 
    -- Make the new point the new origin, do a rotation, then translate back
    composeTransforms [translationM (x, y), rotationM radians, translationM (-x, -y)]

------ Solve for final parameters

-- See PR for documentation
-- Note: returns angle in range [0, 2pi)
paramsOf :: (Autofloat a) => HMatrix a -> (a, a, a, a, a) -- There could be multiple solutions
paramsOf m = let (sx, sy) = (norm [xScale m, ySkew m], norm [xSkew m, yScale m]) in -- Ignore negative scale factors
             let theta = atan (ySkew m / (xScale m + epsd)) in -- Prevent atan(0/0) = NaN
             -- atan returns an angle in [-pi, pi]
             (sx, sy, theta, dx m, dy m)

paramsToMatrix :: (Autofloat a) => (a, a, a, a, a) -> HMatrix a
paramsToMatrix (sx, sy, theta, dx, dy) = -- scale then rotate then translate
               composeTransforms [translationM (dx, dy), rotationM theta, scalingM (sx, sy)]

unitSq :: (Autofloat a) => [Pt2 a]
unitSq = [(0.5, 0.5), (-0.5, 0.5), (-0.5, -0.5), (0.5, -0.5)]

transformPoly :: (Autofloat a) => HMatrix a -> [Pt2 a] -> [Pt2 a]
transformPoly m = map (applyTransform m)

------ Energies on polygons

-- Test energy on two polygons: optimize on the transformed shape
testEnergy :: (Autofloat a) => [Pt2 a] -> [Pt2 a] -> a
testEnergy p1 p2 = distsq (p1 !! 0) (p2 !! 0) -- Get the first two points to touch