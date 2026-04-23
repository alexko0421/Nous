import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

let inputURL = URL(fileURLWithPath: "/Users/kochunlong/.gemini/antigravity/brain/393b83a2-2e1b-440b-a066-20065947863e/media__1776904920799.png")
let outputURL = URL(fileURLWithPath: "/Users/kochunlong/conductor/workspaces/Nous/new-york/Sources/Nous/Resources/nous_logo_transparent.png")

guard let image = NSImage(contentsOf: inputURL) else { 
    print("Could not load image")
    exit(1) 
}
guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { 
    print("Could not get cgImage")
    exit(1) 
}
let ciImage = CIImage(cgImage: cgImage)

// 1. Convert to Alpha Mask using Luminance, increasing contrast
let filter = CIFilter.colorMatrix()
filter.inputImage = ciImage
filter.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
filter.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
filter.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
// Multiply luminance by a factor to make text pure white, background pure black
// (R*0.3 + G*0.6 + B*0.1) * 2 - 0.1
filter.aVector = CIVector(x: 0.6, y: 1.2, z: 0.2, w: 0)
filter.biasVector = CIVector(x: 1, y: 1, z: 1, w: -0.1)

guard let outputCI = filter.outputImage else { 
    print("Filter failed")
    exit(1) 
}

let context = CIContext()
guard let alphaCGImage = context.createCGImage(outputCI, from: ciImage.extent) else { 
    print("Could not create cgImage from filter")
    exit(1) 
}

// 2. Find bounding box of non-transparent pixels
// We'll read the bitmap data
let width = alphaCGImage.width
let height = alphaCGImage.height
var rawData = [UInt8](repeating: 0, count: width * height * 4)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

guard let cgContext = CGContext(data: &rawData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { 
    print("Could not create cgContext")
    exit(1) 
}

cgContext.draw(alphaCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

var minX = width
var maxX = 0
var minY = height
var maxY = 0

for y in 0..<height {
    for x in 0..<width {
        let alpha = rawData[(y * width + x) * 4 + 3]
        if alpha > 10 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}

if minX > maxX { minX = 0; maxX = width; minY = 0; maxY = height }

// Add a small padding
minX = max(0, minX - 5)
maxX = min(width, maxX + 5)
minY = max(0, minY - 5)
maxY = min(height, maxY + 5)

let cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

// Crop image
guard let croppedCGImage = alphaCGImage.cropping(to: cropRect) else { 
    print("Could not crop")
    exit(1) 
}

// 3. Save as PNG
let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, croppedCGImage, nil)
CGImageDestinationFinalize(dest)
print("Saved cropped transparent logo.")
