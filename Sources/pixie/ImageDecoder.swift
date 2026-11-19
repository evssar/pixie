//
//  ImageDecoder.swift
//  pixie
//
//  Created by Eugene Sorokin on 14.11.2026.
//

import UIKit
import ImageIO

/// Декодер изображений, реализованный на ``ImageIO``.
///
/// Уменьшает кадр до заданного размера и держит в памяти только
/// уменьшенный битмап.
enum ImageDecoder {
    /// Возвращает уменьшенную копию изображения из сжатых байтов.
    ///
    /// Большая сторона результата не превышает `maxPixelSize`. ``ImageIO``
    /// декодирует кадр с прореживанием и держит в памяти только уменьшенный
    /// битмап. Изображение меньше `maxPixelSize` остаётся своего размера.
    /// Метод помечен `@concurrent` и не занимает вызывающий актор.
    ///
    /// - Parameters:
    ///   - data: Сжатые байты изображения, например JPEG, PNG или HEIC.
    ///   - maxPixelSize: Предел ширины и высоты результата в пикселях.
    /// - Returns: Уменьшенное изображение или `nil`, если `data`
    ///   прочитать не удалось.
    @concurrent
    static func downsample(_ data: Data, maxPixelSize: Int) async -> UIImage? {
        // Источник только читает байты и пиксели не создаёт. false
        // оставляет его без кэша декодированного кадра: на 64-битных
        // системах значение по умолчанию true.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        // Always игнорирует встроенную EXIF-миниатюру и строит кадр
        // из полного изображения. ShouldCacheImmediately декодирует
        // пиксели здесь, а не при первой отрисовке. WithTransform
        // применяет поворот из EXIF: у CGImage своего тега ориентации нет.
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
