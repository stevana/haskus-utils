{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

-- | VariantF functor
module Haskus.Utils.VariantF
   ( VariantF (..)
   , ApplyAll
   , pattern FV
   , appendVariantF
   , toVariantFHead
   , toVariantFTail
   , popVariantFHead
   , variantFToValue
   , MapVariantF
   , mapVariantF
   , PopVariantF
   , popVariantF
   , LiftVariantF
   , liftVariantF
   , AlterVariantF
   , alterVariantF
   , AlgVariantF
   , algVariantF
   , SplitVariantF
   , splitVariantF
   , variantFToCont
   , variantFToContM
   , contToVariantF
   , contToVariantFM
   -- * Reexport
   , NoConstraint
   , module Haskus.Utils.Functor
   )
where

import Haskus.Utils.Variant
import Haskus.Utils.Functor
import Haskus.Utils.Types.List
import Haskus.Utils.ContFlow

import Unsafe.Coerce
import Data.Bifunctor
import GHC.Exts (Any,Constraint)

-- | Recursive Functor-like Variant
newtype VariantF (xs :: [* -> *]) e
   = VariantF (V (ApplyAll e xs))

-- | Apply its first argument to every element of the 2nd arg list
--
-- > ApplyAll e '[f,g,h] ==> '[f e, g e, h e]
--
type family ApplyAll e (xs :: [* -> *]) :: [*] where
   ApplyAll e '[]       = '[]
   ApplyAll e (f ': fs) = f e ': ApplyAll e fs

instance (Show (V (ApplyAll e xs))) => Show (VariantF xs e) where
   show (VariantF x) = show x
deriving instance (Eq (V (ApplyAll e xs))) => Eq (VariantF xs e)
deriving instance (Ord (V (ApplyAll e xs))) => Ord (VariantF xs e)

instance Functor (VariantF '[]) where
   fmap _ = undefined

instance (Functor (VariantF fs), Functor f) => Functor (VariantF (f ': fs)) where
   fmap f (VariantF v) = case popVariantHead v of
      Right x -> toVariantFHead (fmap f x)
      Left xs -> toVariantFTail (fmap f (VariantF xs))

-- | Pattern-match in a VariantF
pattern FV :: forall c cs e. c :< (ApplyAll e cs) => c -> VariantF cs e
pattern FV x = VariantF (V x)

-- | Retrieve a single value
variantFToValue :: VariantF '[f] e -> f e
variantFToValue (VariantF v) = variantToValue v

appendVariantF :: forall (ys :: [* -> *]) (xs :: [* -> *]) e.
   ( ApplyAll e (Concat xs ys) ~ Concat (ApplyAll e xs) (ApplyAll e ys)
   ) => VariantF xs e -> VariantF (Concat xs ys) e
appendVariantF (VariantF v) = VariantF (appendVariant @(ApplyAll e ys) v)

-- | Set the first value
toVariantFHead :: forall x xs e. x e -> VariantF (x ': xs) e
{-# INLINE toVariantFHead #-}
toVariantFHead v = VariantF (toVariantHead @(x e) @(ApplyAll e xs) v)

-- | Set the tail
toVariantFTail :: forall x xs e. VariantF xs e -> VariantF (x ': xs) e
{-# INLINE toVariantFTail #-}
toVariantFTail (VariantF v) = VariantF (toVariantTail @(x e) @(ApplyAll e xs) v)

-- | Pop VariantF head
popVariantFHead :: forall x xs e. VariantF (x ': xs) e -> Either (VariantF xs e) (x e)
{-# INLINE popVariantFHead #-}
popVariantFHead (VariantF v) = case popVariantHead v of
   Right x -> Right x
   Left xs -> Left (VariantF xs)

type PopVariantF x xs e =
   ( x e :< ApplyAll e xs
   , Remove (x e) (ApplyAll e xs) ~ ApplyAll e (Remove x xs)
   )

-- | Pop VariantF
popVariantF :: forall x xs e.
   ( PopVariantF x xs e
   ) => VariantF xs e -> Either (VariantF (Remove x xs) e) (x e)
{-# INLINE popVariantF #-}
popVariantF (VariantF v) = case popVariant v of
   Right x -> Right x
   Left xs -> Left (VariantF xs)

type MapVariantF a b cs ds e =
   ( MapVariant (a e) (b e) (ApplyAll e cs)
   , ds ~ ReplaceNS (IndexesOf a cs) b cs
   , ApplyAll e ds ~ ReplaceNS (IndexesOf (a e) (ApplyAll e cs)) (b e) (ApplyAll e cs)
   )

-- | Map the matching types of a variant
mapVariantF :: forall a b cs ds e.
   ( MapVariantF a b cs ds e
   ) => (a e -> b e) -> VariantF cs e -> VariantF ds e
mapVariantF f (VariantF v) = VariantF (mapVariant @(a e) @(b e) @(ApplyAll e cs) f v)

-- | xs is liftable in ys
type LiftVariantF xs ys e =
   ( IsSubset xs ys ~ 'True
   , LiftVariant (ApplyAll e xs) (ApplyAll e ys)
   )

-- | Lift a VariantF into another
liftVariantF :: forall as bs e.
   ( LiftVariantF as bs e
   ) => VariantF as e -> VariantF bs e
liftVariantF (VariantF v) = VariantF (liftVariant' v)

class AlterVariantF (c :: (* -> *) -> Constraint) e (xs :: [* -> *]) where
   alterVariantF' :: (forall (f :: * -> *). c f => f e -> f e) -> Word -> Any -> Any

instance AlterVariantF c e '[] where
   {-# INLINE alterVariantF' #-}
   alterVariantF' _ = undefined

instance
   ( AlterVariantF c e xs
   , c x
   ) => AlterVariantF c e (x ': xs)
   where
      {-# INLINE alterVariantF' #-}
      alterVariantF' f t v =
         case t of
            0 -> unsafeCoerce (f (unsafeCoerce v :: x e))
            n -> alterVariantF' @c @e @xs f (n-1) v

-- | Alter a variant. You need to specify the constraints required by the
-- modifying function.
--
-- Usage:
--
-- >   alterVariantF @NoConstraint id         v
-- >   alterVariantF @Resizable    (resize 4) v
-- >
-- >   -- Multiple constraints:
-- >   class (Ord a, Num a) => OrdNum a
-- >   instance (Ord a, Num a) => OrdNum a
-- >   alterVariantF @OrdNum foo v
--
alterVariantF :: forall c e (xs :: [* -> *]).
   ( AlterVariantF c e xs
   ) => (forall (f :: * -> *). c f => f e -> f e) -> VariantF xs e -> VariantF xs e
{-# INLINABLE alterVariantF #-}
alterVariantF f (VariantF (Variant t a)) =
   VariantF (Variant t (alterVariantF' @c @e @xs f t a))


class AlgVariantF (c :: (* -> *) -> Constraint) e (xs :: [* -> *]) where
   algVariantF' :: (forall (f :: * -> *). c f => f e -> e) -> Word -> Any -> e

instance AlgVariantF c e '[] where
   {-# INLINE algVariantF' #-}
   algVariantF' _ = undefined

instance
   ( AlgVariantF c e xs
   , c x
   ) => AlgVariantF c e (x ': xs)
   where
      {-# INLINE algVariantF' #-}
      algVariantF' f t v =
         case t of
            0 -> f (unsafeCoerce v :: x e)
            n -> algVariantF' @c @e @xs f (n-1) v

-- | Apply an algebra to a VariantF. You need to specify the constraints
-- required by the modifying function.
--
-- Usage:
--
-- >  algVariantF @NoConstraint id         v
-- >  algVariantF @Resizable    (resize 4) v
--
algVariantF :: forall c e (xs :: [* -> *]).
   ( AlgVariantF c e xs
   ) => (forall (f :: * -> *). c f => f e -> e) -> VariantF xs e -> e
{-# INLINABLE algVariantF #-}
algVariantF f (VariantF (Variant t a)) = algVariantF' @c @e @xs f t a

type SplitVariantF as xs e =
   ( Complement (ApplyAll e xs) (ApplyAll e as) ~ ApplyAll e (Complement xs as)
   , SplitVariant (ApplyAll e as) (ApplyAll e xs) (ApplyAll e xs)
   )

-- | Split a VariantF in two
splitVariantF :: forall as xs e.
   ( SplitVariantF as xs e
   ) => VariantF xs e
     -> Either (VariantF as e) (VariantF (Complement xs as) e)
splitVariantF (VariantF v) = bimap VariantF VariantF (splitVariant v)

-- | Convert a VariantF into a multi-continuation
variantFToCont :: ContVariant (ApplyAll e xs)
   => VariantF xs e -> ContFlow (ApplyAll e xs) r
variantFToCont (VariantF v) = variantToCont v

-- | Convert a VariantF into a multi-continuation
variantFToContM ::
   ( ContVariant (ApplyAll e xs)
   , Monad m
   ) => m (VariantF xs e) -> ContFlow (ApplyAll e xs) (m r)
variantFToContM f = variantToContM (unvariantF <$> f)
   where
      unvariantF (VariantF v) = v

-- | Convert a multi-continuation into a VariantF
contToVariantF :: forall xs e.
   ( ContVariant (ApplyAll e xs)
   ) => ContFlow (ApplyAll e xs) (V (ApplyAll e xs)) -> VariantF xs e
contToVariantF c = VariantF (contToVariant c)

-- | Convert a multi-continuation into a VariantF
contToVariantFM :: forall xs e m.
   ( ContVariant (ApplyAll e xs)
   , Monad m
   ) => ContFlow (ApplyAll e xs) (m (V (ApplyAll e xs))) -> m (VariantF xs e)
contToVariantFM f = VariantF <$> contToVariantM f

instance ContVariant (ApplyAll e xs) => MultiCont (VariantF xs e) where
   type MultiContTypes (VariantF xs e) = ApplyAll e xs
   toCont = variantFToCont
   toContM = variantFToContM