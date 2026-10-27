import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Original Remote Lab artwork, drawn locally. The iOS mask is applied by the system.
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [color(0x133C58), color(0x071B31)] as CFArray,
                            locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: 1024),
                           end: CGPoint(x: 1024, y: 0), options: [])
context.setStrokeColor(color(0x66F0D1, alpha: 0.24))
context.setLineWidth(18)
context.strokeEllipse(in: CGRect(x: 182, y: 182, width: 660, height: 660))
context.setFillColor(color(0x66F0D1, alpha: 0.14))
context.fillEllipse(in: CGRect(x: 230, y: 230, width: 564, height: 564))

// Four cardinal detents surround a raised thumb pad.
context.setStrokeColor(color(0x8FFFE3))
context.setLineWidth(28)
context.setLineCap(.round)
for angle in [CGFloat(0), .pi / 2, .pi, 3 * .pi / 2] {
    context.move(to: CGPoint(x: 512 + 228 * cos(angle), y: 512 + 228 * sin(angle)))
    context.addLine(to: CGPoint(x: 512 + 264 * cos(angle), y: 512 + 264 * sin(angle)))
}
context.strokePath()
context.setShadow(offset: CGSize(width: 0, height: -16), blur: 32, color: color(0x000000, alpha: 0.35))
context.setFillColor(color(0x66F0D1))
context.fillEllipse(in: CGRect(x: 348, y: 348, width: 328, height: 328))
context.setShadow(offset: .zero, blur: 0)
context.setStrokeColor(color(0xD4FFF4, alpha: 0.65))
context.setLineWidth(10)
context.strokeEllipse(in: CGRect(x: 371, y: 371, width: 282, height: 282))
context.setFillColor(color(0x103B4F))
context.fillEllipse(in: CGRect(x: 484, y: 484, width: 56, height: 56))

let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
