import AppKit
import CoreImage
import Vision
// cutout <input> <output.png> <cropX> <cropY> <cropW> <cropH> <outWidth>   (crop in input pixels, top-left origin)
let a = CommandLine.arguments
let input = CIImage(contentsOf: URL(fileURLWithPath: a[1]), options: [.applyOrientationProperty: true])!.settingProperties([:])
let handler = VNImageRequestHandler(ciImage: input)
let request = VNGenerateForegroundInstanceMaskRequest()
try handler.perform([request])
guard let observation = request.results?.first else { fatalError("no subject found") }
let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
let mask = CIImage(cvPixelBuffer: maskBuffer)
    .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 24])
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.6])
    .cropped(to: input.extent)
let cut = input.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
let n = a[3...7].map { Double($0)! }
let height = input.extent.height
let crop = CGRect(x: n[0], y: height - n[1] - n[3], width: n[2], height: n[3])
let scale = n[4] / n[2]
let out = cut.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let context = CIContext()
try context.writePNGRepresentation(of: out, to: URL(fileURLWithPath: a[2]), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
print("wrote", a[2], out.extent.size)
