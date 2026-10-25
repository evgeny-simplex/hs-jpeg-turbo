import CoreGraphics
import Foundation
import ImageIO

#if canImport(UIKit)
import OSLog
import UIKit

let logger = Logger()

public func resizeImageToStrSizeSync(_ image: UIImage, maxDataSize: Int64) -> String? {
    var img = image
    let hasAlpha = imageHasAlpha(image)
    var str = compressImageStr(img, hasAlpha: hasAlpha)
    var dataSize = str?.count ?? 0
    while dataSize != 0 && dataSize > maxDataSize {
        let ratio = sqrt(Double(dataSize) / Double(maxDataSize))
        let clippedRatio = min(ratio, 2.0)
        img = reduceSize(img, ratio: clippedRatio, hasAlpha: hasAlpha)
        str = compressImageStr(img, hasAlpha: hasAlpha)
        dataSize = str?.count ?? 0
    }
    logger.debug("resizeImageToStrSize final \(dataSize)")
    return str
}

public func compressImageStr(_ image: UIImage, _ compressionQuality: CGFloat = 0.85, hasAlpha: Bool) -> String? {
    let ext = hasAlpha ? "png" : "jpg"
    if let data = hasAlpha ? image.pngData() : image.jpegData(compressionQuality: compressionQuality) {
        return "data:image/\(ext);base64,\(data.base64EncodedString())"
    }
    return nil
}

private func reduceSize(_ image: UIImage, ratio: CGFloat, hasAlpha: Bool) -> UIImage {
    let newSize = CGSize(width: floor(image.size.width / ratio), height: floor(image.size.height / ratio))
    let bounds = CGRect(origin: .zero, size: newSize)
    return resizeImage(image, newBounds: bounds, drawIn: bounds, hasAlpha: hasAlpha)
}

public func resizeImage(_ image: UIImage, newBounds: CGRect, drawIn: CGRect, hasAlpha: Bool) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.opaque = !hasAlpha
    return UIGraphicsImageRenderer(bounds: newBounds, format: format).image { _ in
        image.draw(in: drawIn)
    }
}

public func imageHasAlpha(_ img: UIImage) -> Bool {
    if let cgImage = img.cgImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        if let context = CGContext(data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            if let data = context.data {
                let data = data.assumingMemoryBound(to: UInt8.self)
                let size = cgImage.width * cgImage.height * 4
                var i = 0
                while i < size {
                    if data[i] < 255 { return true }
                    i += 4
                }
            }
        }
    }
    return false
}

func previewStr(_ data: Data) -> String? {
    let image = UIImage(data: data)!
    let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let probe = resizeImage(image, newBounds: bounds, drawIn: bounds, hasAlpha: false).cgImage!
    print("renderer", probe.colorSpace!, probe.bitsPerComponent, probe.bitsPerPixel)
    return resizeImageToStrSizeSync(image, maxDataSize: 14000)
}
#else
func resizeImageToStrSizeSync(_ image: CGImage, maxDataSize: Int64) -> String? {
    var img = image
    var str = compressImageStr(img)
    var dataSize = str?.count ?? 0
    while dataSize != 0 && dataSize > maxDataSize {
        let ratio = sqrt(Double(dataSize) / Double(maxDataSize))
        let clippedRatio = min(ratio, 2.0)
        img = reduceSize(img, ratio: clippedRatio)
        str = compressImageStr(img)
        dataSize = str?.count ?? 0
    }
    return str
}

func compressImageStr(_ image: CGImage) -> String? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? "data:image/jpg;base64,\((data as Data).base64EncodedString())" : nil
}

func reduceSize(_ image: CGImage, ratio: CGFloat) -> CGImage {
    let width = Int(floor(CGFloat(image.width) / ratio))
    let height = Int(floor(CGFloat(image.height) / ratio))
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func previewStr(_ data: Data) -> String? {
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
    return resizeImageToStrSizeSync(image, maxDataSize: 14000)
}
#endif

public func dropImagePrefix(_ s: String) -> String {
    dropPrefix(dropPrefix(s, "data:image/png;base64,"), "data:image/jpg;base64,")
}

private func dropPrefix(_ s: String, _ prefix: String) -> String {
    s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
}

let args = CommandLine.arguments
let str = try previewStr(Data(contentsOf: URL(fileURLWithPath: args[1])))!
let jpeg = Data(base64Encoded: dropImagePrefix(str))!
try jpeg.write(to: URL(fileURLWithPath: args[2]))
let preview = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
print(args[1], preview.width, preview.height, jpeg.count, str.count)
