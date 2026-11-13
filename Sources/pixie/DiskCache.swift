//
//  DiskCache.swift
//  pixie
//
//  Created by Eugene Sorokin on 13.11.2026.
//

import CryptoKit
import Foundation

/// Кэш байтов изображений в каталоге на диске.
///
/// Операции с файлами выполняются по одной, отдельная блокировка
/// не нужна. Имя файла — хеш адреса. Срок жизни считается от даты
/// создания и чтением не продлевается.
actor DiskCache: ImageDiskCache {
    /// Каталог, в котором лежат файлы кэша.
    let directory: URL

    /// Предел суммарного занятого размера файлов в байтах.
    ///
    /// Пока сумма не выше предела, файлы из-за размера не удаляются.
    /// После превышения кэш удаляет те, к которым дольше всего не
    /// обращались, и останавливается, когда занято не больше 80 %
    /// `maxSize`.
    let maxSize: Int

    /// Срок жизни записи в секундах с момента создания файла.
    ///
    /// Чтение обновляет дату использования, но не продлевает этот срок.
    /// Просроченный файл удаляется, когда его читают или когда в кэш
    /// что-то записывают.
    let ttl: TimeInterval

    /// Создаёт кэш в заданном каталоге и готовит этот каталог на диске.
    ///
    /// Недостающие каталоги по пути создаются. Если каталог уже есть,
    /// инициализатор его не очищает.
    ///
    /// - Parameters:
    ///   - directory: Каталог для файлов кэша.
    ///   - maxSize: Предел суммарного занятого размера в байтах.
    ///   - ttl: Срок жизни записи в секундах с момента создания файла.
    /// - Throws: Ошибку, если каталог создать не удалось.
    init(directory: URL, maxSize: Int, ttl: TimeInterval) throws {
        self.directory = directory
        self.maxSize = maxSize
        self.ttl = ttl

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Возвращает имя файла для заданного адреса.
    ///
    /// Имя — шестнадцатеричный ``SHA256`` от байтов `absoluteString`
    /// в UTF-8. Адреса с разным строковым видом получают разные файлы.
    /// Метод не изолирован актором и не обращается к диску.
    ///
    /// - Parameter url: Адрес, для которого строится имя.
    /// - Returns: 64 шестнадцатеричных символа в нижнем регистре.
    nonisolated static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))

        return digest.map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Возвращает байты, сохранённые для заданного адреса.
    ///
    /// Срок жизни проверяется по дате создания. Файл старше `ttl`
    /// и файл без этой даты удаляются, метод возвращает `nil`.
    /// Перед чтением обновляется дата использования.
    ///
    /// - Parameter url: Адрес, идентифицирующий запись.
    /// - Returns: Сохранённые байты или `nil`, если записи нет,
    ///   срок истёк или файл не удалось прочитать.
    func data(for url: URL) -> Data? {
        let file = fileUrl(for: url)

        guard
            let values = try? file.resourceValues(forKeys: [.creationDateKey]),
            let created = values.creationDate
        else {
            try? FileManager.default.removeItem(at: file)

            return nil
        }

        if Date().timeIntervalSince(created) > ttl {
            try? FileManager.default.removeItem(at: file)

            return nil
        }

        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path())

        return try? Data(contentsOf: file)
    }

    /// Сохраняет байты изображения для заданного адреса.
    ///
    /// Запись атомарная. Ошибка записи не сообщается вызывающему;
    /// после неё кэш всё равно проверяет размер и срок жизни файлов.
    ///
    /// - Parameters:
    ///   - data: Байты, которые нужно записать на диск.
    ///   - url: Адрес, с которым связываются байты.
    func store(_ data: Data, for url: URL) {
        try? data.write(to: fileUrl(for: url), options: .atomic)

        trimIfNeeded()
    }

    /// Удаляет все записи с диска.
    ///
    /// Каталог кэша удаляется и создаётся заново. Ошибка удаления
    /// не сообщается вызывающему.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileUrl(for url: URL) -> URL {
        directory.appending(path: Self.fileName(for: url), directoryHint: .notDirectory)
    }

    /// Удаляет просроченные файлы и при превышении `maxSize`
    /// освобождает место.
    ///
    /// Срок проверяется по дате создания. Место освобождается с файлов,
    /// к которым дольше всего не обращались, пока занятый размер выше
    /// 80 % `maxSize`. Датой использования служит дата изменения файла.
    private func trimIfNeeded() {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .totalFileAllocatedSizeKey]

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else {
            return
        }

        var alive: [(url: URL, used: Date, size: Int)] = []
        var total: Int = 0

        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else {
                continue
            }

            if let created = values.creationDate, Date().timeIntervalSince(created) > ttl {
                try? FileManager.default.removeItem(at: file)

                continue
            }

            let size = values.totalFileAllocatedSize ?? 0

            alive.append((file, values.contentModificationDate ?? .distantPast, size))

            total += size
        }

        guard total > maxSize else {
            return
        }

        for entry in alive.sorted(by: { $0.used < $1.used }) where total > maxSize * 8 / 10 {
            try? FileManager.default.removeItem(at: entry.url)

            total -= entry.size
        }
    }
}
