{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Codec.Picture (DynamicImage (..), Image (..), decodeImage, dynamicMap)
import Control.Exception (evaluate)
import Data.Bits (xor)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64.Lazy as LB64
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.List (intercalate)
import qualified Data.Vector.Storable as VS
import Data.Word (Word64, Word8)
import GHC.Clock (getMonotonicTimeNSec)
import Simplex.Chat.Image (ColourProfile, decodeResizable, imageFormat, resizeImage, resizeImageDataUri)
import System.Environment (getArgs)

main :: IO ()
main =
  getArgs >>= \case
    ["decode", file] -> do
      (r, ms) <- timed . decodeForced =<< B.readFile file
      putStrLn $ json $ [("mode", str "decode"), ("file", str file), ("decode_ms", show ms)] <> decoded r
    ["resize", file, out] -> do
      (r, ms) <- timed . decodeForced =<< B.readFile file
      resized <- either (const $ pure []) (uncurry $ resize out) r
      putStrLn $ json $ [("mode", str "resize"), ("file", str file), ("decode_ms", show ms)] <> decoded r <> resized
    _ -> fail "usage: resize decode FILE | resize resize FILE OUTDIR"

decodeForced :: B.ByteString -> IO (Either String (DynamicImage, ColourProfile))
decodeForced bytes =
  decodeResizable bytes >>= \case
    Right (img, profile) -> Right (img, profile) <$ evaluate (dynamicMap (VS.length . imageData) img)
    Left e -> pure $ Left e

resize :: FilePath -> DynamicImage -> ColourProfile -> IO [(String, String)]
resize out img profile = do
  (image, imageMs) <- timed $ resizeImage (imageFormat img) 261120 img profile >>= forced
  (uri, previewMs) <- timed $ resizeImageDataUri 14000 img profile >>= forced
  imageFields <- output "image" image
  previewFields <- output "preview" $ (LB64.decode . LB.drop 1 . LB.dropWhile (/= ',')) =<< uri
  pure $ [("image_ms", show imageMs), ("preview_ms", show previewMs), ("preview_chars", either (const "null") (show . LB.length) uri)] <> imageFields <> previewFields
  where
    forced = either (pure . Left) (\b -> Right b <$ evaluate (LB.length b))
    output name = \case
      Left e -> pure [(name <> "_error", str e)]
      Right bytes -> do
        let ext = if "\x89PNG" `LB.isPrefixOf` bytes then "png" else "jpg"
            path = out <> "/" <> name <> "." <> ext
        LB.writeFile path bytes
        pure $
          [(name <> "_file", str path), (name <> "_bytes", show $ LB.length bytes)]
            <> either (const []) (\i -> [(name <> "_width", show $ fst $ size i), (name <> "_height", show $ snd $ size i)]) (decodeImage $ LB.toStrict bytes)

decoded :: Either String (DynamicImage, ColourProfile) -> [(String, String)]
decoded = \case
  Left e -> [("error", str e)]
  Right (img, profile) ->
    [ ("width", show $ fst $ size img),
      ("height", show $ snd $ size img),
      ("constructor", str $ constructor img),
      ("profile", str $ show profile),
      ("samples_fnv1a", maybe "null" (str . show . VS.foldl' fnv1a 14695981039346656037) $ samples img)
    ]

size :: DynamicImage -> (Int, Int)
size = dynamicMap (\i -> (imageWidth i, imageHeight i))

constructor :: DynamicImage -> String
constructor = \case
  ImageY8 _ -> "Y8"
  ImageRGB8 _ -> "RGB8"
  ImageRGBA8 _ -> "RGBA8"
  ImageCMYK8 _ -> "CMYK8"
  _ -> "other"

samples :: DynamicImage -> Maybe (VS.Vector Word8)
samples = \case
  ImageY8 i -> Just $ imageData i
  ImageRGB8 i -> Just $ imageData i
  ImageRGBA8 i -> Just $ imageData i
  ImageCMYK8 i -> Just $ imageData i
  _ -> Nothing

fnv1a :: Word64 -> Word8 -> Word64
fnv1a h b = (h `xor` fromIntegral b) * 1099511628211

timed :: IO a -> IO (a, Double)
timed action = do
  start <- getMonotonicTimeNSec
  r <- action
  end <- getMonotonicTimeNSec
  pure (r, fromIntegral (end - start) / 1e6)

str :: String -> String
str = show

json :: [(String, String)] -> String
json fields = "{" <> intercalate ", " [show k <> ": " <> v | (k, v) <- fields] <> "}"
