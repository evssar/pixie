import Foundation
import Testing
@testable import pixie

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "pixie-disk-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func withCache<T>(
    maxSize: Int = 50_000_000,
    ttl: TimeInterval = 86_400,
    prepare: ((URL) throws -> Void)? = nil,
    _ body: (DiskCache) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "pixie-disk-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    if prepare != nil {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try prepare?(root)
    }
    let cache = try DiskCache(directory: root, maxSize: maxSize, ttl: ttl)
    return try await body(cache)
}

private func cacheFile(in directory: URL, for url: URL) -> URL {
    directory.appending(path: DiskCache.fileName(for: url), directoryHint: .notDirectory)
}

private func allocatedSize(of file: URL) throws -> Int {
    let values = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
    guard let size = values.totalFileAllocatedSize else {
        throw CocoaError(.fileReadUnknown)
    }
    return size
}

private func setFileDates(_ file: URL, created: Date? = nil, modified: Date? = nil) throws {
    var attributes: [FileAttributeKey: Any] = [:]
    if let created {
        attributes[.creationDate] = created
    }
    if let modified {
        attributes[.modificationDate] = modified
    }
    try FileManager.default.setAttributes(attributes, ofItemAtPath: file.path(percentEncoded: false))
}

private func samplePayload(marker: UInt8) -> Data {
    var data = Data(repeating: 0xCD, count: 32 * 1024)
    data[0] = marker
    return data
}

@Suite("Имя файла")
struct FileNameTests {
    @Test("Имя — SHA256 от absoluteString в нижнем регистре")
    func fileNameIsLowercaseSHA256OfAbsoluteString() {
        let url = URL(string: "https://example.com/a")!
        let name = DiskCache.fileName(for: url)
        let hex = Set("0123456789abcdef")
        #expect(url.absoluteString == "https://example.com/a")
        #expect(name.count == 64)
        #expect(name.allSatisfy { hex.contains($0) })
        // Дайджест SHA256 от UTF-8 байтов "https://example.com/a".
        #expect(name == "2dce0a4c50441bfccfa9caf4b58c3cba6e06c420505dd829f0436de1aa44baac")
    }

    @Test("Одинаковый absoluteString даёт одно имя")
    func sameAbsoluteStringSharesAName() {
        let left = URL(string: "https://example.com/a")!
        let right = URL(string: "https://example.com/" + "a")!
        #expect(left.absoluteString == right.absoluteString)
        #expect(DiskCache.fileName(for: left) == DiskCache.fileName(for: right))
    }

    @Test("Регистр пути, query и fragment дают разные имена")
    func pathCaseQueryAndFragmentChangeTheName() {
        let base = URL(string: "https://example.com/a")!
        let variants = [
            "https://example.com/A",
            "https://example.com/a?x=1",
            "https://example.com/a#part",
            "https://example.com/a/",
        ].map { URL(string: $0)! }
        let baseName = DiskCache.fileName(for: base)
        for variant in variants {
            #expect(variant.absoluteString != base.absoluteString)
            #expect(DiskCache.fileName(for: variant) != baseName)
        }
    }

    @Test("Регистр хоста остаётся в absoluteString и меняет имя")
    func hostCaseChangesTheFileName() {
        let upper = URL(string: "https://EXAMPLE.com/a")!
        let lower = URL(string: "https://example.com/a")!
        // URL не приводит хост к нижнему регистру, имя считается от строки как есть.
        #expect(upper.absoluteString != lower.absoluteString)
        #expect(DiskCache.fileName(for: upper) != DiskCache.fileName(for: lower))
    }
}

@Suite("Создание каталога")
struct DirectorySetupTests {
    @Test("Инициализатор создаёт промежуточные каталоги")
    func initCreatesIntermediateDirectories() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appending(path: "nested/cache", directoryHint: .isDirectory)
        let cache = try DiskCache(directory: deep, maxSize: 10, ttl: 10)
        #expect(FileManager.default.fileExists(atPath: deep.path(percentEncoded: false)))
        #expect(await cache.directory == deep)
    }

    @Test("Инициализатор сохраняет лимиты и не очищает каталог")
    func initKeepsExistingFilesAndStoresLimits() async throws {
        let marker = Data("keep".utf8)
        try await withCache(maxSize: 99, ttl: 42, prepare: { root in
            try marker.write(to: root.appending(path: "note.txt"), options: .atomic)
        }) { cache in
            let directory = await cache.directory
            #expect(await cache.maxSize == 99)
            #expect(await cache.ttl == 42)
            let note = directory.appending(path: "note.txt")
            let stored = try Data(contentsOf: note)
            #expect(stored == marker)
        }
    }

    @Test("Инициализатор бросает ошибку, если по пути лежит файл")
    func initThrowsWhenDirectoryPathIsAFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "not-a-directory")
        try Data([1]).write(to: file)
        #expect(throws: (any Error).self) {
            try DiskCache(directory: file, maxSize: 10, ttl: 10)
        }
    }
}

@Suite("Чтение и запись")
struct ReadAndWriteTests {
    @Test("Неизвестный адрес возвращает nil и не создаёт файл")
    func missingURLReturnsNilAndCreatesNoFile() async throws {
        let url = URL(string: "https://example.com/missing")!
        try await withCache { cache in
            #expect(await cache.data(for: url) == nil)
            let directory = await cache.directory
            let names = try FileManager.default.contentsOfDirectory(
                atPath: directory.path(percentEncoded: false)
            )
            #expect(names.isEmpty)
        }
    }

    @Test("Запись читается теми же байтами")
    func roundTripPreservesRawBytes() async throws {
        let url = URL(string: "https://example.com/a.png")!
        let payload = Data([0x00, 0xff, 0x89, 0x50, 0x4e, 0x47])
        try await withCache { cache in
            await cache.store(payload, for: url)
            #expect(await cache.data(for: url) == payload)
            #expect(await cache.data(for: url) == payload)
        }
    }

    @Test("Пустые байты сохраняются и читаются")
    func emptyDataRoundTrips() async throws {
        let url = URL(string: "https://example.com/empty")!
        try await withCache { cache in
            await cache.store(Data(), for: url)
            #expect(await cache.data(for: url) == Data())
        }
    }

    @Test("Повторная запись по тому же адресу подменяет байты")
    func repeatedStoreReplacesBytes() async throws {
        let url = URL(string: "https://example.com/a")!
        try await withCache { cache in
            await cache.store(Data("one".utf8), for: url)
            await cache.store(Data("two".utf8), for: url)
            let directory = await cache.directory
            let names = try FileManager.default.contentsOfDirectory(
                atPath: directory.path(percentEncoded: false)
            )
            #expect(names == [DiskCache.fileName(for: url)])
            #expect(await cache.data(for: url) == Data("two".utf8))
        }
    }

    @Test("Разные адреса не затирают друг друга")
    func distinctURLsStayIndependent() async throws {
        let image = URL(string: "https://cdn.example/a.jpg")!
        let preview = URL(string: "https://cdn.example/a.jpg?w=10")!
        let imageBytes = Data("image".utf8)
        let previewBytes = Data("preview".utf8)
        try await withCache { cache in
            await cache.store(imageBytes, for: image)
            await cache.store(previewBytes, for: preview)
            #expect(await cache.data(for: image) == imageBytes)
            #expect(await cache.data(for: preview) == previewBytes)
        }
    }

    @Test("На диске лежит файл с именем хеша и исходными байтами")
    func storedFileUsesTheHashNameAndRawBytes() async throws {
        let url = URL(string: "https://example.com/a")!
        let payload = Data([0x00, 0xff, 0x10])
        try await withCache { cache in
            await cache.store(payload, for: url)
            let file = cacheFile(in: await cache.directory, for: url)
            let stored = try Data(contentsOf: file)
            #expect(stored == payload)
        }
    }

    @Test("Файл, уже лежащий по хешу адреса, читается")
    func preexistingHashedFileIsReadable() async throws {
        let url = URL(string: "https://example.com/cover")!
        let payload = Data("seed".utf8)
        try await withCache(prepare: { root in
            try payload.write(to: cacheFile(in: root, for: url), options: .atomic)
        }) { cache in
            #expect(await cache.data(for: url) == payload)
        }
    }

    @Test("Нечитаемый файл возвращает nil и остаётся на диске")
    func unreadableFileReturnsNilAndStaysOnDisk() async throws {
        let url = URL(string: "https://example.com/a")!
        try await withCache { cache in
            await cache.store(Data("secret".utf8), for: url)
            let file = cacheFile(in: await cache.directory, for: url)
            let path = file.path(percentEncoded: false)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            }
            #expect(await cache.data(for: url) == nil)
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test("Ошибка записи не бросает исключение и не создаёт запись")
    func failedWriteDoesNotThrowOrInsert() async throws {
        let url = URL(string: "https://example.com/a")!
        try await withCache { cache in
            let directory = await cache.directory
            let path = directory.path(percentEncoded: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
            await cache.store(Data("bytes".utf8), for: url)
            #expect(await cache.data(for: url) == nil)
        }
    }

    @Test("Кэш доступен через ImageDiskCache")
    func cacheIsUsableThroughTheProtocol() async throws {
        let url = URL(string: "https://example.com/a")!
        let payload = Data("via-protocol".utf8)
        try await withCache { concrete in
            let cache: any ImageDiskCache = concrete
            await cache.store(payload, for: url)
            #expect(await cache.data(for: url) == payload)
        }
    }
}

@Suite("Срок жизни")
struct LifetimeTests {
    @Test("Файл внутри срока жизни читается")
    func fileInsideTTLIsReadable() async throws {
        let ttl: TimeInterval = 60
        let url = URL(string: "https://example.com/a")!
        let payload = Data("fresh".utf8)
        try await withCache(ttl: ttl) { cache in
            await cache.store(payload, for: url)
            let file = cacheFile(in: await cache.directory, for: url)
            try setFileDates(file, created: Date().addingTimeInterval(-(ttl - 5)))
            #expect(await cache.data(for: url) == payload)
        }
    }

    @Test("Просроченный файл удаляется при чтении и не задевает соседний")
    func expiredFileIsDeletedOnRead() async throws {
        let ttl: TimeInterval = 60
        let expiredURL = URL(string: "https://example.com/old")!
        let liveURL = URL(string: "https://example.com/new")!
        let live = Data("live".utf8)
        try await withCache(ttl: ttl) { cache in
            await cache.store(Data("old".utf8), for: expiredURL)
            await cache.store(live, for: liveURL)
            let directory = await cache.directory
            try setFileDates(
                cacheFile(in: directory, for: expiredURL),
                created: Date().addingTimeInterval(-(ttl + 5))
            )
            #expect(await cache.data(for: expiredURL) == nil)
            let expiredPath = cacheFile(in: directory, for: expiredURL).path(percentEncoded: false)
            #expect(!FileManager.default.fileExists(atPath: expiredPath))
            #expect(await cache.data(for: liveURL) == live)
        }
    }

    @Test("Чтение обновляет дату использования и не продлевает срок")
    func readRefreshesUseDateWithoutExtendingLifetime() async throws {
        let ttl: TimeInterval = 60
        let url = URL(string: "https://example.com/a")!
        let payload = Data("image".utf8)
        try await withCache(ttl: ttl) { cache in
            await cache.store(payload, for: url)
            let file = cacheFile(in: await cache.directory, for: url)
            let created = Date().addingTimeInterval(-30)
            // Дата изменения позже даты создания, иначе система состарит создание.
            try setFileDates(file, created: created, modified: created.addingTimeInterval(10))
            #expect(await cache.data(for: url) == payload)
            let values = try file.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
            ])
            let creation = try #require(values.creationDate)
            let modified = try #require(values.contentModificationDate)
            #expect(abs(creation.timeIntervalSince(created)) < 2)
            #expect(abs(modified.timeIntervalSinceNow) < 5)
        }
    }

    @Test("Запись удаляет просроченных соседей")
    func storeDeletesExpiredSiblings() async throws {
        let ttl: TimeInterval = 60
        let expiredURL = URL(string: "https://example.com/old")!
        let freshURL = URL(string: "https://example.com/new")!
        let fresh = Data("fresh".utf8)
        try await withCache(ttl: ttl) { cache in
            await cache.store(Data("old".utf8), for: expiredURL)
            let directory = await cache.directory
            try setFileDates(
                cacheFile(in: directory, for: expiredURL),
                created: Date().addingTimeInterval(-(ttl + 5))
            )
            await cache.store(fresh, for: freshURL)
            let expiredPath = cacheFile(in: directory, for: expiredURL).path(percentEncoded: false)
            #expect(!FileManager.default.fileExists(atPath: expiredPath))
            #expect(await cache.data(for: expiredURL) == nil)
            #expect(await cache.data(for: freshURL) == fresh)
        }
    }
}

@Suite("Размер")
struct SizeLimitTests {
    @Test("Файлы внутри maxSize остаются")
    func filesUnderTheLimitRemain() async throws {
        let urls = (0..<3).map { URL(string: "https://example.com/fit/\($0)")! }
        let payloads = (0..<3).map { samplePayload(marker: UInt8($0)) }
        let allocated = try await allocatedSize(of: payloads[0], for: urls[0])
        try await withCache(maxSize: allocated * 10) { cache in
            for (url, payload) in zip(urls, payloads) {
                await cache.store(payload, for: url)
            }
            for (url, payload) in zip(urls, payloads) {
                #expect(await cache.data(for: url) == payload)
            }
        }
    }

    @Test("Файл, занимающий ровно maxSize, остаётся")
    func fileAtTheExactLimitRemains() async throws {
        let url = URL(string: "https://example.com/exact")!
        let payload = samplePayload(marker: 1)
        let allocated = try await allocatedSize(of: payload, for: url)
        try await withCache(maxSize: allocated) { cache in
            await cache.store(payload, for: url)
            #expect(await cache.data(for: url) == payload)
        }
    }

    @Test("Файл больше maxSize удаляется при записи")
    func fileOverTheLimitIsRemovedOnStore() async throws {
        let url = URL(string: "https://example.com/huge")!
        let payload = samplePayload(marker: 2)
        let allocated = try await allocatedSize(of: payload, for: url)
        let maxSize = allocated > 1 ? allocated / 2 : 0
        try await withCache(maxSize: maxSize) { cache in
            await cache.store(payload, for: url)
            let path = cacheFile(in: await cache.directory, for: url).path(percentEncoded: false)
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(await cache.data(for: url) == nil)
        }
    }

    @Test("Превышение maxSize удаляет самые старые записи до 80 % лимита")
    func overflowTrimsOldestEntriesDownToEightyPercent() async throws {
        let urls = (0..<4).map { URL(string: "https://example.com/img/\($0)")! }
        let payloads = (0..<4).map { samplePayload(marker: UInt8($0)) }
        let allocated = try await allocatedSize(of: payloads[0], for: urls[0])
        #expect(allocated > 0)

        try await withCache(maxSize: allocated * 3) { cache in
            let directory = await cache.directory
            for index in 0..<3 {
                await cache.store(payloads[index], for: urls[index])
            }
            let sizes = try (0..<3).map { index in
                try allocatedSize(of: cacheFile(in: directory, for: urls[index]))
            }
            #expect(sizes.allSatisfy { $0 == allocated })

            let created = Date().addingTimeInterval(-40)
            for index in 0..<3 {
                try setFileDates(
                    cacheFile(in: directory, for: urls[index]),
                    created: created,
                    modified: created.addingTimeInterval(TimeInterval(index + 1) * 10)
                )
            }
            await cache.store(payloads[3], for: urls[3])

            // maxSize равен трём файлам. Четвёртый запускает очистку.
            // Порог — 80 % лимита, поэтому остаются два самых новых, а не три.
            #expect(await cache.data(for: urls[0]) == nil)
            #expect(await cache.data(for: urls[1]) == nil)
            #expect(await cache.data(for: urls[2]) == payloads[2])
            #expect(await cache.data(for: urls[3]) == payloads[3])
        }
    }
}

@Suite("removeAll")
struct DiskRemoveAllTests {
    @Test("Очистка удаляет записи и создаёт каталог заново")
    func removeAllDropsEntriesAndRecreatesDirectory() async throws {
        let first = URL(string: "https://example.com/a")!
        let second = URL(string: "https://example.com/b")!
        try await withCache { cache in
            await cache.store(Data("a".utf8), for: first)
            await cache.store(Data("b".utf8), for: second)
            await cache.removeAll()
            let directory = await cache.directory
            var isDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(
                atPath: directory.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            let names = try FileManager.default.contentsOfDirectory(
                atPath: directory.path(percentEncoded: false)
            )
            #expect(exists)
            #expect(isDirectory.boolValue)
            #expect(names.isEmpty)
            #expect(await cache.data(for: first) == nil)
            #expect(await cache.data(for: second) == nil)
        }
    }

    @Test("Очистка пустого кэша безопасна")
    func removeAllOnEmptyCacheIsSafe() async throws {
        let url = URL(string: "https://example.com/missing")!
        try await withCache { cache in
            await cache.removeAll()
            #expect(await cache.data(for: url) == nil)
        }
    }

    @Test("Повторная очистка безопасна")
    func secondRemoveAllIsSafe() async throws {
        let url = URL(string: "https://example.com/a")!
        try await withCache { cache in
            await cache.store(Data("a".utf8), for: url)
            await cache.removeAll()
            await cache.removeAll()
            #expect(await cache.data(for: url) == nil)
        }
    }

    @Test("Запись после очистки снова читается")
    func storeAfterRemoveAllIsReadable() async throws {
        let url = URL(string: "https://example.com/a")!
        let payload = Data("after".utf8)
        try await withCache { cache in
            await cache.store(Data("before".utf8), for: url)
            await cache.removeAll()
            await cache.store(payload, for: url)
            #expect(await cache.data(for: url) == payload)
        }
    }

    @Test("Очистка одного кэша не трогает другой")
    func removeAllDoesNotAffectAnotherCache() async throws {
        let url = URL(string: "https://example.com/a")!
        let kept = Data("kept".utf8)
        try await withCache { left in
            try await withCache { right in
                await left.store(Data("left".utf8), for: url)
                await right.store(kept, for: url)
                await left.removeAll()
                #expect(await left.data(for: url) == nil)
                #expect(await right.data(for: url) == kept)
            }
        }
    }

    @Test("Очистка не удаляет соседний файл родительского каталога")
    func removeAllDoesNotDeleteSiblingFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sibling = root.appending(path: "sibling.txt")
        let siblingBytes = Data("stay".utf8)
        try siblingBytes.write(to: sibling)
        let cache = try DiskCache(
            directory: root.appending(path: "cache", directoryHint: .isDirectory),
            maxSize: 50_000_000,
            ttl: 86_400
        )
        let url = URL(string: "https://example.com/a")!
        await cache.store(Data("cached".utf8), for: url)
        await cache.removeAll()
        let storedSibling = try Data(contentsOf: sibling)
        #expect(storedSibling == siblingBytes)
        var isDirectory = ObjCBool(false)
        let cachePath = root.appending(path: "cache").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: cachePath, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

@Suite("Потоки")
struct DiskConcurrencyTests {
    @Test("Параллельные записи разных адресов читаются после барьера")
    func concurrentStoresOfDistinctURLsRemainReadable() async throws {
        let payloads = (0..<32).map { Data([UInt8($0)]) }
        try await withCache { cache in
            await withTaskGroup(of: Void.self) { group in
                for (index, payload) in payloads.enumerated() {
                    let url = URL(string: "https://example.com/item/\(index)")!
                    group.addTask {
                        await cache.store(payload, for: url)
                    }
                }
            }
            for (index, payload) in payloads.enumerated() {
                let url = URL(string: "https://example.com/item/\(index)")!
                #expect(await cache.data(for: url) == payload)
            }
        }
    }

    @Test("Параллельные записи одного адреса оставляют один из наборов байтов")
    func concurrentStoresOfSameURLLeaveOnePayload() async throws {
        let url = URL(string: "https://example.com/same")!
        let payloads = (0..<16).map { Data("payload-\($0)".utf8) }
        try await withCache { cache in
            await withTaskGroup(of: Void.self) { group in
                for payload in payloads {
                    group.addTask {
                        await cache.store(payload, for: url)
                    }
                }
            }
            let stored = await cache.data(for: url)
            #expect(payloads.contains { $0 == stored })
        }
    }

    @Test("Гонка очистки и записи оставляет кэш пригодным")
    func concurrentRemoveAllLeavesCacheUsable() async throws {
        let url = URL(string: "https://example.com/after")!
        let payload = Data("after".utf8)
        try await withCache { cache in
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<20 {
                    let item = URL(string: "https://example.com/r/\(index)")!
                    group.addTask {
                        await cache.store(Data([1]), for: item)
                    }
                    group.addTask {
                        await cache.removeAll()
                    }
                }
            }
            await cache.removeAll()
            await cache.store(payload, for: url)
            #expect(await cache.data(for: url) == payload)
        }
    }
}

private func allocatedSize(of payload: Data, for url: URL) async throws -> Int {
    try await withCache { cache in
        await cache.store(payload, for: url)
        return try allocatedSize(of: cacheFile(in: await cache.directory, for: url))
    }
}
