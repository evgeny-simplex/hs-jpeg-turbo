{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Codec.Picture (DynamicImage (..), Image (..), Pixel, convertRGB8, convertRGBA8, decodeImage, dynamicMap)
import Codec.Picture.JPEGTurbo (encodeRGB)
import qualified Codec.Picture.Spng as Spng
import Control.Exception (evaluate)
import Data.Bits (xor)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64.Lazy as LB64
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.List (intercalate, isPrefixOf)
import qualified Data.Vector.Storable as VS
import Data.Word (Word64, Word8)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Simplex.Chat.Image (ColourProfile, ImageFormat (..), decodeResizable, imageFormat, resizeImage, resizeImageDataUri, scaleRGB8, scaleRGBA8)
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
    ["stages", file] -> stages file
    _ -> fail "usage: resize decode FILE | resize resize FILE OUTDIR | resize stages FILE"

stages :: FilePath -> IO ()
stages file = do
  bytes <- stage "read the file" $ B.readFile file >>= \b -> b <$ evaluate (B.length b)
  stage "decodeResizable" (decodeForced bytes) >>= \case
    Left e -> putStrLn $ json [("stage", str "decodeResizable"), ("error", str e)]
    Right (img, profile) -> do
      let (w, h) = size img
          largest = halved (w, h)
      case imageFormat img of
        IFPng -> do
          let scale = scaleRGBA8 (convertRGBA8 img)
          _ <- stage "premultiply, as the first trial of scaleRGBA8 (1x1 output)" $ forcedImage $ scale (1, 1)
          trial <- stage ("trial at the largest size " <> show largest <> ": Catmull-Rom, sharpen, unpremultiply") $ forcedImage $ scale largest
          _ <- stage "encode the trial twice, libspng level 9 with and without filters" $ mapM (\f -> Spng.encodePng (Spng.EncodeOptions 9 f Nothing) trial) [False, True]
          pure ()
        IFJpeg -> do
          trial <- stage ("trial at the largest size " <> show largest <> ": Catmull-Rom, sharpen") $ forcedImage $ scaleRGB8 (convertRGB8 img) largest
          _ <- stage "encode the trial, mozjpeg quality 65" $ encodeRGB 65 Nothing trial >>= \b -> b <$ evaluate (B.length b)
          pure ()
      _ <- stage "resizeImage, 261120 bytes" $ resizeImage (imageFormat img) 261120 img profile >>= either (pure . Left) (\b -> Right b <$ evaluate (LB.length b))
      _ <- stage "resizeImageDataUri, 14000 characters" $ resizeImageDataUri 14000 img profile >>= either (pure . Left) (\b -> Right b <$ evaluate (LB.length b))
      pure ()
  where
    halved (w, h)
      | w <= 4320 && h <= 4320 = (w, h)
      | otherwise = halved (half w, half h)
    half :: Int -> Int
    half side = round (fromIntegral side / 2 :: Float)

forcedImage :: Pixel a => Image a -> IO (Image a)
forcedImage i = i <$ evaluate (VS.length $ imageData i)

stage :: String -> IO a -> IO a
stage name action = do
  (r, ms) <- timed action
  rss <- procStatus "VmRSS:"
  hwm <- procStatus "VmHWM:"
  heap <- getRTSStatsEnabled >>= \enabled -> if enabled then Just . max_mem_in_use_bytes <$> getRTSStats else pure Nothing
  putStrLn $ json [("stage", str name), ("ms", show ms), ("rss_mib", show rss), ("hwm_mib", show hwm), ("rts_max_mem_in_use_mib", maybe "null" (\b -> show (fromIntegral b / 1048576 :: Double)) heap)]
  pure r

procStatus :: String -> IO Double
procStatus key = do
  status <- readFile "/proc/self/status"
  _ <- evaluate (length status)
  pure $ case [read (head (words (drop (length key) line))) :: Double | line <- lines status, key `isPrefixOf` line] of
    kb : _ -> kb / 1024
    [] -> -1

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
