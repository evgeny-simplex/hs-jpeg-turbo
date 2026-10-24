{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-full-laziness #-}

module Main (main) where

import Codec.Picture (DynamicImage, Image (..), PixelRGB8, convertRGB8, readImage)
import Codec.Picture.JPEGTurbo (encodeRGB)
import Codec.Picture.Jpg (encodeJpegAtQuality)
import qualified Codec.Picture.STBIR as STBIR
import Codec.Picture.Types (convertImage, dynamicMap)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import qualified Data.ByteString.Base64.Lazy as LB64
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (intercalate, sort, unfoldr)
import qualified Data.Vector.Storable as V
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (getArgs)
import System.FilePath (takeBaseName, (</>))
import System.IO (BufferMode (..), IOMode (..), hPutBuf, hPutStr, hSetBuffering, stdout, withBinaryFile)
import Text.Printf (printf)

data Encoder = JuicyPixels | Turbo

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  getArgs >>= \case
    ["images", photo, dir] -> mapM_ (writePpm dir) . testImages =<< loadPhoto photo
    ["encode", enc, label, photo] -> mapM_ (encodeRows (encoder enc) [label, takeBaseName photo]) . testImages =<< loadPhoto photo
    ["fit", enc, label, photo] -> forM_ [1 .. 3] $ fitRows (encoder enc) [label, takeBaseName photo] photo
    _ -> fail "usage: jpeg-bench images PHOTO DIR | jpeg-bench (encode | fit) (juicypixels | turbo) LABEL PHOTO"

encoder :: String -> Encoder
encoder = \case
  "juicypixels" -> JuicyPixels
  "turbo" -> Turbo
  name -> error $ "unknown encoder: " <> name

encodeJpeg :: Encoder -> Int -> Image PixelRGB8 -> IO LB.ByteString
encodeJpeg = \case
  JuicyPixels -> \q -> pure . encodeJpegAtQuality (fromIntegral q) . convertImage
  Turbo -> \q -> fmap LB.fromStrict . encodeRGB q

loadDecoded :: FilePath -> IO DynamicImage
loadDecoded photo = do
  img <- either fail pure =<< readImage photo
  img <$ evaluate (dynamicMap (V.length . imageData) img)

loadPhoto :: FilePath -> IO (Image PixelRGB8)
loadPhoto photo = convertRGB8 <$> loadDecoded photo

testImages :: Image PixelRGB8 -> [Image PixelRGB8]
testImages photo = photo : fullHd photo : takeWhile ((>= 125) . imageWidth) halvings
  where
    halvings = unfoldr (fmap (\i -> (i, i)) . halve) photo

fullHd :: Image PixelRGB8 -> Image PixelRGB8
fullHd img = STBIR.resize STBIR.defaultOptions {STBIR.transform = Right $ STBIR.Region 0 top 1 (1 - top)} 1920 1080 img
  where
    top = (1 - fromIntegral (imageWidth img) * 9 / 16 / fromIntegral (imageHeight img)) / 2

writePpm :: FilePath -> Image PixelRGB8 -> IO ()
writePpm dir img@Image {imageWidth, imageHeight, imageData} =
  withBinaryFile (dir </> sizeName img <> ".ppm") WriteMode $ \h -> do
    hPutStr h $ "P6\n" <> show imageWidth <> " " <> show imageHeight <> "\n255\n"
    V.unsafeWith imageData $ \p -> hPutBuf h p (V.length imageData)

encodeRows :: Encoder -> [String] -> Image PixelRGB8 -> IO ()
encodeRows enc prefix img@Image {imageWidth, imageHeight} = forM_ [20, 50, 85, 95] $ \q -> do
  quality <- newIORef q
  (iterations, median, fastest, size) <- measure $ timed $ do
    q' <- readIORef quality
    evaluate . LB.length =<< encodeJpeg enc q' img
  putRow $ prefix <> [show imageWidth, show imageHeight, show q, show iterations, showMs median, showMs fastest, show size]

measure :: IO (Word64, Int64) -> IO (Int, Word64, Word64, Int64)
measure run = do
  (_, size) <- run
  times <- sort <$> go 0 0 []
  pure (length times, times !! (length times `div` 2), head times, size)
  where
    go :: Int -> Word64 -> [Word64] -> IO [Word64]
    go count total times
      | count >= 1000 || (count >= 3 && total >= 1000000000) = pure times
      | otherwise = do
          (t, _) <- run
          go (count + 1) (total + t) (t : times)

data Step = Step {stepSize :: String, stepQuality :: Int, stepBytes :: Int64, prepareNs :: Word64, encodeNs :: Word64}

fitRows :: Encoder -> [String] -> FilePath -> Int -> IO ()
fitRows enc prefix photo run = do
  fit "image" id 261120
  fit "preview" toDataUri 14000
  where
    fit target output maxSize = do
      (decodeNs, img) <- timed $ loadDecoded photo
      putRow $ prefix <> [show run, target, "decode", dynamicMap sizeName img, "", "", "", "", showMs decodeNs]
      steps <- newIORef []
      let jpeg q rgb = do
            (prepared, _) <- timed $ evaluate $ V.length $ imageData rgb
            (encoded, r) <- timed $ encodeJpeg enc q rgb >>= \bytes -> bytes <$ evaluate (LB.length bytes)
            modifyIORef' steps (Step (sizeName rgb) q (LB.length r) prepared encoded :)
            pure $ output r
      (totalNs, size) <- timed $ evaluate . either (const (-1)) LB.length =<< fitJpeg jpeg maxSize (convertRGB8 img)
      encodes <- reverse <$> readIORef steps
      forM_ encodes $ \Step {stepSize, stepQuality, stepBytes, prepareNs, encodeNs} ->
        putRow $ prefix <> [show run, target, "encode", stepSize, show stepQuality, show stepBytes, showMs prepareNs, showMs encodeNs, ""]
      putRow $ prefix <> [show run, target, "fit", "", show (length encodes), show size, showMs (sum $ map prepareNs encodes), showMs (sum $ map encodeNs encodes), showMs totalNs]

fitJpeg :: (Int -> Image PixelRGB8 -> IO LB.ByteString) -> Int64 -> Image PixelRGB8 -> IO (Either String LB.ByteString)
fitJpeg jpeg maxSize = fitHalving
  where
    fits = (<= maxSize) . LB.length
    fitHalving i = do
      r <- jpeg minJpegQuality i
      if fits r
        then Right <$> bisect maxSize qualityStep (`jpeg` i) (minJpegQuality, r) 95
        else maybe (pure $ Left "image does not fit") fitHalving $ halve i
    qualityStep good bad = if bad - good <= 1 then Nothing else Just $ (good + bad) `div` 2

bisect :: Int64 -> (p -> p -> Maybe p) -> (p -> IO LB.ByteString) -> (p, LB.ByteString) -> p -> IO LB.ByteString
bisect maxSize step encode = go
  where
    go (good, r) bad = case step good bad of
      Nothing -> pure r
      Just m -> do
        r' <- encode m
        case compare (LB.length r') maxSize of
          LT -> go (m, r') bad
          EQ -> pure r'
          GT -> go (good, r) m

minJpegQuality :: Int
minJpegQuality = 20

halve :: Image PixelRGB8 -> Maybe (Image PixelRGB8)
halve img
  | imageWidth img < 2 || imageHeight img < 2 = Nothing
  | otherwise = Just $ downscale img 2

downscale :: Image PixelRGB8 -> Float -> Image PixelRGB8
downscale img scale = STBIR.resize STBIR.defaultOptions (scaled imageWidth) (scaled imageHeight) img
  where
    scaled f = round $ fromIntegral (f img) / scale

toDataUri :: LB.ByteString -> LB.ByteString
toDataUri body = "data:image/jpg;base64," <> LB64.encode body

timed :: IO a -> IO (Word64, a)
timed action = do
  start <- getMonotonicTimeNSec
  r <- action
  end <- getMonotonicTimeNSec
  pure (end - start, r)

sizeName :: Image a -> String
sizeName Image {imageWidth, imageHeight} = show imageWidth <> "x" <> show imageHeight

showMs :: Word64 -> String
showMs ns = printf "%.3f" (fromIntegral ns / 1e6 :: Double)

putRow :: [String] -> IO ()
putRow = putStrLn . intercalate "\t"
