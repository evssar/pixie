//
//  MemoryCache.swift
//  pixie
//
//  Created by Eugene Sorokin on 11.11.2026.
//

import Foundation

/// Кэш в памяти, реализованный на ``NSCache``.
///
/// ``NSCache`` потокобезопасен по своей документации. Класс не помечен
/// ``Sendable``, поэтому ``MemoryCache`` принимает `@unchecked Sendable`.
final class MemoryCache<Value: AnyObject & Sendable>: ImageMemoryCache, @unchecked Sendable {
    private let storage = NSCache<NSString, Value>()

    /// Создаёт кэш с заданными лимитами стоимости и числа объектов.
    ///
    /// Оба лимита нестрогие: объект может быть вытеснен сразу, позже
    /// или не быть вытеснен вовсе.
    ///
    /// - Parameters:
    ///   - totalCostLimit: Максимальная суммарная стоимость, которую кэш
    ///     может хранить, прежде чем начнёт вытеснять объекты. Стоимость
    ///     задаётся в байтах декодированного битмапа.
    ///   - countLimit: Максимальное число объектов, которое кэш должен
    ///     хранить. Запасной лимит рядом с `totalCostLimit`.
    init(totalCostLimit: Int, countLimit: Int) {
        storage.totalCostLimit = totalCostLimit
        storage.countLimit = countLimit
    }

    /// Возвращает значение для заданного ключа.
    ///
    /// Чтение синхронное и достаточно дешёвое, чтобы вызывать его из
    /// `cellForItemAt` на главном потоке.
    ///
    /// - Parameter key: Ключ, идентифицирующий значение.
    /// - Returns: Значение, связанное с `key`, или `nil`, если для `key`
    ///   нет значения.
    func value(for key: String) -> Value? {
        storage.object(forKey: key as NSString)
    }

    /// Сохраняет значение для заданного ключа и связывает пару со стоимостью.
    ///
    /// - Parameters:
    ///   - value: Объект, который нужно поместить в кэш.
    ///   - key: Ключ, с которым связывается значение.
    ///   - cost: Стоимость пары ключ-значение в байтах занимаемой памяти.
    ///     Для изображения это `bytesPerRow`, умноженный на высоту.
    func set(_ value: Value, for key: String, cost: Int) {
        storage.setObject(value, forKey: key as NSString, cost: cost)
    }

    /// Удаляет все объекты из кэша.
    ///
    /// Вызывайте при предупреждении о нехватке памяти. Содержимое кэша
    /// можно восстановить с диска или из сети.
    func removeAll() {
        storage.removeAllObjects()
    }
}
