module FFITest where

import Control.Exception
import Control.Monad
import Data.ByteString qualified as B
import Data.ByteString.Unsafe qualified as BU
import Foreign
import Foreign.C.String
import TurboJPEG2 qualified as TJ2

unit_TurboJPEG2 :: IO ()
unit_TurboJPEG2 = do
  inBS <- B.readFile inFile
  decoding inBS \width height jpegSubsamp jpegColorspace decoded ->
    encoding width height TJ2.TJSAMP_420 1 decoded \encoded -> do
      print ((width, height, lookup jpegSubsamp TJ2.tjsampNames, lookup jpegColorspace TJ2.tjcsNames), B.length encoded)
      B.writeFile outFile encoded
  outBS <- B.readFile outFile
  decoding outBS \_width _height _jpegSubsamp _jpegColorspace _decoded ->
    pure () :: IO () -- just read back
  where
    inFile = "../fixtures/lv.jpg"
    outFile = "../fixtures/lv-out.jpg"
    pixelFormat = TJ2.TJPF_RGB

    decoding bsIn action =
      bracket TJ2.tjInitDecompress TJ2.tjDestroy \jt ->
        BU.unsafeUseAsCStringLen bsIn \(bufPtr, bufLen) ->
          alloca \widthPtr ->
            alloca \heightPtr ->
              alloca \jpegSubsampPtr ->
                alloca \jpegColorspacePtr -> do
                  TJ2.tjDecompressHeader3 jt (castPtr bufPtr) (fromIntegral bufLen) widthPtr heightPtr jpegSubsampPtr jpegColorspacePtr >>= \rc ->
                    unless (rc == 0) $ peekCString (TJ2.tjGetErrorStr2 jt) >>= error
                  width <- peek widthPtr
                  height <- peek heightPtr
                  jpegSubsamp <- peek jpegSubsampPtr
                  jpegColorspace <- peek jpegColorspacePtr
                  pixelSize <- maybe (error "no size for pixelFormat") pure $ TJ2.tjPixelSize pixelFormat
                  let dstSize = fromIntegral $ width * height * pixelSize -- TODO: consider pitch
                  allocaBytes dstSize \dstPtr -> do
                    TJ2.tjDecompress2 jt (castPtr bufPtr) (fromIntegral bufLen) dstPtr width 0 height pixelFormat flags >>= \rc ->
                      unless (rc == 0) $ peekCString (TJ2.tjGetErrorStr2 jt) >>= error
                    BU.unsafePackCStringLen (castPtr dstPtr, dstSize) >>=
                      action width height jpegSubsamp jpegColorspace
      where
        flags = TJ2.TJFLAG_STOPONWARNING

    encoding width height jpegSubsamp jpegQual bsIn action =
      bracket TJ2.tjInitCompress TJ2.tjDestroy \jt ->
        BU.unsafeUseAsCStringLen bsIn \(bufPtr, _bufLen) ->
          with nullPtr \jpegBufPtr ->
            with 0 \jpegSizePtr -> do
              rc <- TJ2.tjCompress2 jt (castPtr bufPtr) width 0 height pixelFormat jpegBufPtr jpegSizePtr jpegSubsamp jpegQual flags
              jpegBuf <- peek jpegBufPtr
              flip finally (TJ2.tjFree jpegBuf) do
                unless (rc == 0) $ peekCString (TJ2.tjGetErrorStr2 jt) >>= error
                jpegSize <- peek jpegSizePtr
                BU.unsafePackCStringLen (castPtr jpegBuf, fromIntegral jpegSize) >>=
                  action
      where
        flags = TJ2.TJFLAG_PROGRESSIVE .|. TJ2.TJFLAG_STOPONWARNING
