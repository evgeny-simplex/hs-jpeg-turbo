module Main (main) where

import Codec.Picture (DynamicImage (..), Image (..))
import Codec.Picture.WebpSandbox
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_, replicateM)
import Data.Bits (shiftL, xor)
import Data.ByteString qualified as B
import Data.List (isSuffixOf, stripPrefix)
import Data.Maybe (mapMaybe)
import Data.Vector.Storable qualified as V
import Data.Word (Word8)
import System.Directory (listDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>))
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

main :: IO ()
main = do
  testData <- getEnv "WEBP_TEST_DATA"
  fixtures <- getEnv "FIXTURES"
  conformance <- map (testData </>) . mapMaybe conformanceFile . lines <$> readFile (testData </> "libwebp_tests.md5")
  fixtureFiles <- map (fixtures </>) . filter (".webp" `isSuffixOf`) <$> listDirectory fixtures
  defaultMain $
    testGroup
      "webp-sandbox"
      [ testCase "the conformance files decode in the sandbox as natively at full size, and within 2 at sides of at most 64" do
          assertEqual "conformance files" 96 (length conformance)
          forM_ conformance sameAsNative
      , testCase "the fixtures decode in the sandbox as natively at full size, and within 2 at sides of at most 64" $
          forM_ fixtureFiles sameAsNative
      , testCase "a decode that exceeds the memory limit of the sandbox returns out of memory" do
          webp <- B.readFile (fixtures </> "tall-lossless.webp")
          small <- decodeWebp (Sandboxed 4) 16384 webp
          assertEqual "4 MiB" (Just "out of memory") (either Just (const Nothing) small)
          large <- decodeWebp (Sandboxed 128) 16384 webp
          assertBool "128 MiB" (either (const False) (const True) large)
      , testCase "a load outside the linear memory traps and returns an error" do
          inside <- loadSandboxByte 16 0
          assertEqual "address 0" (Right 0) inside
          outside <- loadSandboxByte 16 maxBound
          assertEqual "address 2^32-1" (Left "sandbox trap 1") outside
      , testCase "truncated and changed files decode in the sandbox as natively" do
          webp <- B.readFile (fixtures </> "photo-1280x720-lossless.webp")
          let n = B.length webp
              truncated = [B.take (n * k `div` 64) webp | k <- [0 .. 63]]
              changed = [flipBit (n * k `div` 64) k webp | k <- [0 .. 63]]
          forM_ (truncated <> changed) \input -> do
            native <- samples <$> decodeWebp Native 16384 input
            sandboxed <- samples <$> decodeWebp (Sandboxed 256) 16384 input
            assertEqual "outputs" native sandboxed
      , testCase "concurrent decodes in 8 sandboxes return the native outputs" do
          webps <- mapM B.readFile fixtureFiles
          expected <- forM webps \webp -> samples <$> decodeWebp Native 16384 webp
          results <- replicateM 8 do
            done <- newEmptyMVar
            _ <- forkIO $ putMVar done =<< forM webps (\webp -> samples <$> decodeWebp (Sandboxed 256) 16384 webp)
            pure done
          forM_ results \done -> takeMVar done >>= assertEqual "outputs" expected
      , testCase "concurrent traps in 8 sandboxes return errors while other sandboxes decode" do
          webp <- B.readFile (fixtures </> "photo-1280x720-lossy.webp")
          expected <- samples <$> decodeWebp Native 16384 webp
          results <- replicateM 8 do
            done <- newEmptyMVar
            _ <- forkIO $ putMVar done =<< forM [1 :: Int .. 200] \i ->
              if even i
                then (== Left "sandbox trap 1") <$> loadSandboxByte 16 maxBound
                else (== expected) . samples <$> decodeWebp (Sandboxed 256) 16384 webp
            pure done
          forM_ results \done -> takeMVar done >>= assertBool "every load trapped and every decode returned the native output" . and
      ]
  where
    conformanceFile line = case words line of
      [_, name] -> stripSuffix ".pam" name
      _ -> Nothing
    stripSuffix suffix name = reverse <$> stripPrefix (reverse suffix) (reverse name)

sameAsNative :: FilePath -> IO ()
sameAsNative path = do
  webp <- B.readFile path
  native <- samples <$> decodeWebp Native 16384 webp
  sandboxed <- samples <$> decodeWebp (Sandboxed 256) 16384 webp
  assertEqual (path <> " at full size") native sandboxed
  scaledNative <- samples <$> decodeWebp Native 64 webp
  scaledSandboxed <- samples <$> decodeWebp (Sandboxed 256) 64 webp
  assertBool (path <> " at sides of at most 64: " <> show (difference <$> scaledNative <*> scaledSandboxed)) $
    closeTo scaledNative scaledSandboxed
  where
    closeTo (Right n) (Right s) = difference n s <= 2
    closeTo n s = n == s

difference :: (Int, Int, Int, V.Vector Word8) -> (Int, Int, Int, V.Vector Word8) -> Double
difference (w, h, c, a) (w', h', c', b)
  | (w, h, c) /= (w', h', c') = 255
  | c == 4 = maximum (0 : [pixelDifference (V.slice i 4 a) (V.slice i 4 b) | i <- [0, 4 .. V.length a - 4]])
  | otherwise = maximum (0 : [abs (fromIntegral (a V.! i) - fromIntegral (b V.! i)) | i <- [0 .. V.length a - 1]])
  where
    pixelDifference p q =
      let alpha = fromIntegral (p V.! 3)
          alpha' = fromIntegral (q V.! 3)
       in maximum (abs (alpha - alpha') : [abs (fromIntegral (p V.! k) * alpha - fromIntegral (q V.! k) * alpha') / 255 | k <- [0 .. 2]])

samples :: Either String Decoded -> Either String (Int, Int, Int, V.Vector Word8)
samples = fmap \Decoded {image} -> case image of
  ImageRGB8 (Image w h v) -> (w, h, 3, v)
  ImageRGBA8 (Image w h v) -> (w, h, 4, v)
  _ -> (0, 0, 0, V.empty)

flipBit :: Int -> Int -> B.ByteString -> B.ByteString
flipBit i k webp = case B.splitAt i webp of
  (before, after) -> before <> B.map (`xor` (1 `shiftL` (k `mod` 8))) (B.take 1 after) <> B.drop 1 after
