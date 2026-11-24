module Main (main) where

import Codec.Picture.WebpSandbox
import Control.Monad (forM, forM_)
import Data.ByteString qualified as B
import Data.List (sort)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (getArgs)
import System.FilePath (takeFileName)
import Text.Printf (printf)

main :: IO ()
main = do
  files <- getArgs
  putStrLn "| Image | Native ms | Sandboxed ms | Ratio |"
  putStrLn "|---|---|---|---|"
  forM_ files \path -> do
    webp <- B.readFile path
    native <- median <$> timeDecodes Native webp
    sandboxed <- median <$> timeDecodes (Sandboxed 256) webp
    printf "| %s | %.2f | %.2f | %.2fx |\n" (takeFileName path) (native / 1e6) (sandboxed / 1e6) (sandboxed / native)
  where
    median times = sort times !! (length times `div` 2)

timeDecodes :: Decoder -> B.ByteString -> IO [Double]
timeDecodes decoder webp = forM [1 :: Int .. 9] \_ -> do
  start <- getMonotonicTimeNSec
  decodeWebp decoder 16384 webp >>= either fail (const $ pure ())
  end <- getMonotonicTimeNSec
  pure $ fromIntegral (end - start)
