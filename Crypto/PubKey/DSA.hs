-- |
-- Module      : Crypto.PubKey.DSA
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : Good
--
-- An implementation of the Digital Signature Algorithm (DSA)
{-# LANGUAGE DeriveDataTypeable #-}
module Crypto.PubKey.DSA
    ( Params(..)
    , Signature(..)
    , PublicKey(..)
    , PrivateKey(..)
    , PublicNumber
    , PrivateNumber
    -- * Generation
    , generatePrivate
    , calculatePublic
    -- * Signature primitive
    , sign
    , signWith
    -- * Verification primitive
    , verify
    -- * Key pair
    , KeyPair(..)
    , toPublicKey
    , toPrivateKey
    ) where

import           Crypto.Random.Types
import qualified Data.Bits as Bits (shiftL, (.|.), shiftR)
import           Data.Data
import           Data.Maybe
import           Crypto.Number.Basic (numBits)
import           Crypto.Number.ModArithmetic (expFast, expSafe, inverse)
import           Crypto.Number.Serialize
import           Crypto.Number.Generate
import           Crypto.Internal.ByteArray (ByteArrayAccess, ByteArray, ScrubbedBytes, convert, index, dropView, takeView, pack, unpack)
import           Crypto.Internal.Imports
import           Crypto.Hash
import           Prelude

-- | DSA Public Number, usually embedded in DSA Public Key
type PublicNumber = Integer

-- | DSA Private Number, usually embedded in DSA Private Key
type PrivateNumber = Integer

-- | Represent DSA parameters namely P, G, and Q.
data Params = Params
    { params_p :: Integer -- ^ DSA p
    , params_g :: Integer -- ^ DSA g
    , params_q :: Integer -- ^ DSA q
    } deriving (Show,Read,Eq,Data,Typeable)

instance NFData Params where
    rnf (Params p g q) = p `seq` g `seq` q `seq` ()

-- | Represent a DSA signature namely R and S.
data Signature = Signature
    { sign_r :: Integer -- ^ DSA r
    , sign_s :: Integer -- ^ DSA s
    } deriving (Show,Read,Eq,Data,Typeable)

instance NFData Signature where
    rnf (Signature r s) = r `seq` s `seq` ()

-- | Represent a DSA public key.
data PublicKey = PublicKey
    { public_params :: Params       -- ^ DSA parameters
    , public_y      :: PublicNumber -- ^ DSA public Y
    } deriving (Show,Read,Eq,Data,Typeable)

instance NFData PublicKey where
    rnf (PublicKey params y) = y `seq` params `seq` ()

-- | Represent a DSA private key.
--
-- Only x need to be secret.
-- the DSA parameters are publicly shared with the other side.
data PrivateKey = PrivateKey
    { private_params :: Params        -- ^ DSA parameters
    , private_x      :: PrivateNumber -- ^ DSA private X
    } deriving (Show,Read,Eq,Data,Typeable)

instance NFData PrivateKey where
    rnf (PrivateKey params x) = x `seq` params `seq` ()

-- | Represent a DSA key pair
data KeyPair = KeyPair Params PublicNumber PrivateNumber
    deriving (Show,Read,Eq,Data,Typeable)

instance NFData KeyPair where
    rnf (KeyPair params y x) = x `seq` y `seq` params `seq` ()

-- | Public key of a DSA Key pair
toPublicKey :: KeyPair -> PublicKey
toPublicKey (KeyPair params pub _) = PublicKey params pub

-- | Private key of a DSA Key pair
toPrivateKey :: KeyPair -> PrivateKey
toPrivateKey (KeyPair params _ priv) = PrivateKey params priv

-- | generate a private number with no specific property
-- this number is usually called X in DSA text.
generatePrivate :: MonadRandom m => Params -> m PrivateNumber
generatePrivate (Params _ _ q) = generateMax q

-- | Calculate the public number from the parameters and the private key
calculatePublic :: Params -> PrivateNumber -> PublicNumber
calculatePublic (Params p g _) x = expSafe g x p

-- | sign message using the private key and an explicit k number.
signWith :: (ByteArrayAccess msg, HashAlgorithm hash)
         => Integer         -- ^ k random number
         -> PrivateKey      -- ^ private key
         -> hash            -- ^ hash function
         -> msg             -- ^ message to sign
         -> Maybe Signature
signWith k pk hashAlg msg
    | r == 0 || s == 0  = Nothing
    | otherwise         = Just $ Signature r s
    where -- parameters
          (Params p g q) = private_params pk
          x              = private_x pk
          -- compute r,s
          kInv      = fromJust $ inverse k q
          hm        = dsaHash q hashAlg msg
          r         = expSafe g k p `mod` q
          s         = (kInv * (hm + x * r)) `mod` q

-- | sign message using the private key.
sign :: (ByteArrayAccess msg, HashAlgorithm hash, MonadRandom m) => PrivateKey -> hash -> msg -> m Signature
sign pk hashAlg msg = do
    k <- generateMax q
    case signWith k pk hashAlg msg of
        Nothing  -> sign pk hashAlg msg
        Just sig -> return sig
  where
    (Params _ _ q) = private_params pk

-- | verify a bytestring using the public key.
verify :: (ByteArrayAccess msg, HashAlgorithm hash) => hash -> PublicKey -> Signature -> msg -> Bool
verify hashAlg pk (Signature r s) m
    -- Reject the signature if either 0 < r < q or 0 < s < q is not satisfied.
    | r <= 0 || r >= q || s <= 0 || s >= q = False
    | otherwise                            = v == r
    where (Params p g q) = public_params pk
          y       = public_y pk
          hm      = dsaHash q hashAlg m

          w       = fromJust $ inverse s q
          u1      = (hm*w) `mod` q
          u2      = (r*w) `mod` q
          v       = ((expFast g u1 p) * (expFast y u2 p)) `mod` p `mod` q

dsaHash :: (ByteArrayAccess msg, HashAlgorithm hash) => Integer -> hash -> msg -> Integer
dsaHash q hashAlg msg =
  -- if the hash is larger than the size of q, truncate it; FIXME: deal with the case of a q not evenly divisible by 8
  let numDropBits = (hashDigestSize hashAlg)*8 - numBits q
      rawHash = hashWith hashAlg msg
  in case compare numDropBits 0 of 
       GT -> -- hash output is larger than modulus
          let (nq,nr) = numDropBits `divMod` 8
          in if nr == 0 -- difference is 0 mod 8 => numBits is 0 `mod` 8
             then os2ip $ takeView rawHash $ (numBits q) `div` 8
             else os2ip $ shiftR rawHash numDropBits
       _ -> os2ip rawHash

-- shift right by a given number of bits, dropping full bytes of leading zeros
-- based on code from the `bits-bytestring` package 
shiftR :: (ByteArrayAccess m) => m -> Int -> ScrubbedBytes
shiftR bs i =
    let ws = unpack bs
    in pack $ go 0 $ take (length ws - q) ws
  where
    (q,r) = i `divMod` 8
    go _ [] = []
    go w1 (w2:wst) = (maskR w1 w2) : go w2 wst
    -- given [w1,w2], constructs w2', which is  left by j bits to get the
    -- bottom j bits of w1 || top (8-j) bits of w2
    maskR w1 w2 = (Bits.shiftL w1 (8-r)) Bits..|. (Bits.shiftR w2 r)