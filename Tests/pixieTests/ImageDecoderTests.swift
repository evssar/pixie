import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import pixie

private struct PixelSize: Equatable {
    var width: Int
    var height: Int

    var longSide: Int {
        max(width, height)
    }
}

private struct RGB: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
}

private enum FixtureError: Error {
    case destination
    case finalize
    case missingImage
}

private func makeImage(
    width: Int,
    height: Int,
    paint: (inout [UInt8], Int, Int) -> Void
) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    paint(&pixels, width, height)
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func fill(
    _ pixels: inout [UInt8],
    _ width: Int,
    _ height: Int,
    red: UInt8,
    green: UInt8,
    blue: UInt8
) {
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = red
        pixels[index + 1] = green
        pixels[index + 2] = blue
        pixels[index + 3] = 255
    }
}

private func splitLeftRight(_ pixels: inout [UInt8], _ width: Int, _ height: Int) {
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            let left = x < width / 2
            pixels[index] = left ? 255 : 0
            pixels[index + 1] = 0
            pixels[index + 2] = left ? 0 : 255
            pixels[index + 3] = 255
        }
    }
}

private func encodedData(
    width: Int,
    height: Int,
    type: UTType,
    orientation: CGImagePropertyOrientation = .up,
    embedThumbnail: Bool = false,
    paint: (inout [UInt8], Int, Int) -> Void
) throws -> Data {
    let image = makeImage(width: width, height: height, paint: paint)
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        type.identifier as CFString,
        1,
        nil
    ) else {
        throw FixtureError.destination
    }

    var properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation.rawValue,
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFOrientation: orientation.rawValue
        ],
        kCGImageDestinationLossyCompressionQuality: 1.0
    ]
    if embedThumbnail {
        properties[kCGImageDestinationEmbedThumbnail] = true
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw FixtureError.finalize
    }
    return data as Data
}

private func jpegData(
    width: Int,
    height: Int,
    orientation: CGImagePropertyOrientation = .up,
    embedThumbnail: Bool = false,
    paint: @escaping (inout [UInt8], Int, Int) -> Void = { pixels, width, height in
        fill(&pixels, width, height, red: 220, green: 30, blue: 30)
    }
) throws -> Data {
    try encodedData(
        width: width,
        height: height,
        type: .jpeg,
        orientation: orientation,
        embedThumbnail: embedThumbnail,
        paint: paint
    )
}

private func pngData(width: Int, height: Int) throws -> Data {
    try encodedData(width: width, height: height, type: .png) { pixels, width, height in
        fill(&pixels, width, height, red: 20, green: 40, blue: 200)
    }
}

private func cgImage(of image: UIImage?) throws -> CGImage {
    guard let cgImage = image?.cgImage else {
        throw FixtureError.missingImage
    }
    return cgImage
}

private func pixelSize(of image: UIImage?) throws -> PixelSize {
    let image = try cgImage(of: image)
    return PixelSize(width: image.width, height: image.height)
}

private func pixel(in image: CGImage, x: Int, y: Int) -> RGB {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }
        context.interpolationQuality = .none
        let height = CGFloat(image.height)
        context.draw(
            image,
            in: CGRect(
                x: CGFloat(-x),
                y: CGFloat(-(image.height - 1 - y)),
                width: CGFloat(image.width),
                height: height
            )
        )
    }
    return RGB(red: bytes[0], green: bytes[1], blue: bytes[2])
}

private func embeddedThumbnailSize(_ data: Data, maxPixelSize: Int) -> PixelSize? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
        return nil
    }
    // Без CreateThumbnailFromImageAlways источник отдаёт встроенную
    // миниатюру, а не кадр, уменьшенный до maxPixelSize.
    let options = [
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ] as CFDictionary
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
        return nil
    }
    return PixelSize(width: thumbnail.width, height: thumbnail.height)
}

@Suite("Некорректные данные")
struct InvalidDataTests {
    @Test("Пустые байты возвращают nil")
    func emptyDataReturnsNil() async {
        let image = await ImageDecoder.downsample(Data(), maxPixelSize: 100)
        #expect(image == nil)
    }

    @Test("Посторонние байты возвращают nil")
    func nonImageBytesReturnNil() async {
        let image = await ImageDecoder.downsample(Data("not-an-image".utf8), maxPixelSize: 100)
        #expect(image == nil)
    }
}

@Suite("Размер")
struct PixelSizeTests {
    @Test("Большая сторона альбомного кадра равна maxPixelSize")
    func landscapeLongSideMatchesMaxPixelSize() async throws {
        let data = try jpegData(width: 400, height: 200)
        let image = await ImageDecoder.downsample(data, maxPixelSize: 100)
        #expect(try pixelSize(of: image) == PixelSize(width: 100, height: 50))
    }

    @Test("Большая сторона портретного кадра равна maxPixelSize")
    func portraitLongSideMatchesMaxPixelSize() async throws {
        let data = try jpegData(width: 200, height: 400)
        let image = await ImageDecoder.downsample(data, maxPixelSize: 100)
        #expect(try pixelSize(of: image) == PixelSize(width: 50, height: 100))
    }

    @Test("Квадрат уменьшается по обеим сторонам")
    func squareDownsamplesBothSides() async throws {
        let data = try jpegData(width: 300, height: 300)
        let image = await ImageDecoder.downsample(data, maxPixelSize: 80)
        #expect(try pixelSize(of: image) == PixelSize(width: 80, height: 80))
    }

    @Test("Кадр меньше maxPixelSize остаётся своего размера")
    func smallerImageKeepsItsSize() async throws {
        let data = try jpegData(width: 40, height: 20)
        let image = await ImageDecoder.downsample(data, maxPixelSize: 200)
        #expect(try pixelSize(of: image) == PixelSize(width: 40, height: 20))
    }

    @Test("maxPixelSize равный большей стороне оставляет кадр")
    func equalMaxPixelSizeKeepsTheImage() async throws {
        let data = try jpegData(width: 120, height: 80)
        let image = await ImageDecoder.downsample(data, maxPixelSize: 120)
        #expect(try pixelSize(of: image) == PixelSize(width: 120, height: 80))
    }

    @Test("PNG уменьшается до maxPixelSize")
    func pngDownsamplesToMaxPixelSize() async throws {
        let data = try pngData(width: 200, height: 100)
        let image = await ImageDecoder.downsample(data, maxPixelSize: 50)
        #expect(try pixelSize(of: image) == PixelSize(width: 50, height: 25))
    }
}

@Suite("Ориентация")
struct OrientationTests {
    @Test("EXIF right поворачивает кадр до уменьшения")
    func exifRightRotatesBeforeScaling() async throws {
        let data = try jpegData(
            width: 240,
            height: 80,
            orientation: .right,
            paint: splitLeftRight
        )
        let image = await ImageDecoder.downsample(data, maxPixelSize: 120)
        let cgImage = try cgImage(of: image)

        // Orientation.right меняет оси: 240×80 показываются как 80×240.
        // Большая сторона 240 сжимается до 120, получается 40×120.
        #expect(cgImage.width == 40)
        #expect(cgImage.height == 120)

        let top = pixel(in: cgImage, x: 20, y: 30)
        let bottom = pixel(in: cgImage, x: 20, y: 90)
        #expect(top.red > 200)
        #expect(top.blue < 40)
        #expect(bottom.blue > 200)
        #expect(bottom.red < 40)
    }
}

@Suite("Встроенная миниатюра")
struct EmbeddedThumbnailTests {
    @Test("Размер берётся из полного кадра")
    func sizeComesFromTheFullImage() async throws {
        let data = try jpegData(width: 800, height: 400, embedThumbnail: true)
        let maxPixelSize = 400
        let thumbnail = try #require(embeddedThumbnailSize(data, maxPixelSize: maxPixelSize))

        // Встроенная миниатюра меньше запрошенного размера. Если декодер
        // возьмёт её, большая сторона результата тоже будет меньше.
        #expect(thumbnail.longSide < maxPixelSize)

        let image = await ImageDecoder.downsample(data, maxPixelSize: maxPixelSize)
        #expect(try pixelSize(of: image) == PixelSize(width: 400, height: 200))
    }
}
