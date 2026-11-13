import Foundation
import Testing
@testable import pixie

private final class Probe: Sendable, CustomStringConvertible {
    let id: Int
    private let onDeinit: (@Sendable () -> Void)?

    init(id: Int, onDeinit: (@Sendable () -> Void)? = nil) {
        self.id = id
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit?()
    }

    var description: String {
        "Probe(\(id))"
    }
}

private final class DeinitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func makeCache() -> any ImageMemoryCache<Probe> {
    MemoryCache<Probe>(totalCostLimit: 10_000_000, countLimit: 10_000)
}

private func expectIndependentKeys(_ lhs: String, _ rhs: String) {
    let cache = makeCache()
    let left = Probe(id: 1)
    let right = Probe(id: 2)
    cache.set(left, for: lhs, cost: 1)
    cache.set(right, for: rhs, cost: 1)
    #expect(cache.value(for: lhs) === left)
    #expect(cache.value(for: rhs) === right)
}

@Suite("Промах и попадание")
struct HitAndMissTests {
    @Test("Неизвестный ключ возвращает nil до первой записи")
    func unknownKeyReturnsNilBeforeAnyWrite() {
        let cache = makeCache()
        #expect(cache.value(for: "missing") == nil)
    }

    @Test("Повторный промах не создаёт запись")
    func repeatedMissDoesNotInsert() {
        let cache = makeCache()
        cache.set(Probe(id: 1), for: "other", cost: 1)
        #expect(cache.value(for: "missing") == nil)
        #expect(cache.value(for: "missing") == nil)
    }

    @Test("Запись читается тем же экземпляром")
    func setThenValueReturnsSameInstance() {
        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: "k", cost: 1)
        #expect(cache.value(for: "k") === probe)
    }

    @Test("Повторное чтение возвращает тот же экземпляр")
    func repeatedReadReturnsSameInstance() {
        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: "k", cost: 1)
        let first = cache.value(for: "k")
        let second = cache.value(for: "k")
        #expect(first === probe)
        #expect(second === first)
    }

    @Test("Разные ключи не затирают друг друга")
    func distinctKeysDoNotOverwriteEachOther() {
        let cache = makeCache()
        let first = Probe(id: 1)
        let second = Probe(id: 2)
        cache.set(first, for: "a", cost: 1)
        cache.set(second, for: "b", cost: 1)
        #expect(cache.value(for: "b") === second)
        #expect(cache.value(for: "a") === first)
    }

    @Test("Ключи-префиксы хранятся раздельно")
    func prefixKeysStayIndependent() {
        expectIndependentKeys("a", "ab")
    }

    @Test("Регистр ключа значим")
    func keyCaseIsSignificant() {
        expectIndependentKeys("a", "A")
    }

    @Test("Пробел в ключе значим")
    func keyWhitespaceIsSignificant() {
        expectIndependentKeys("a", "a ")
    }

    @Test("Числовые строки с разной длиной — разные ключи")
    func numericLookingKeysStayIndependent() {
        expectIndependentKeys("0", "00")
    }

    @Test("Пустая строка сохраняется и читается")
    func emptyStringKeyRoundTrips() {
        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: "", cost: 1)
        #expect(cache.value(for: "") === probe)
    }

    @Test("Пробелы, перевод строки, emoji и длинный ключ читаются отдельно")
    func unusualKeysRoundTripIndependently() {
        let keys = [
            "   ",
            "\n",
            "🦊",
            String(repeating: "ы", count: 50_000),
        ]
        let cache = makeCache()
        let probes = keys.indices.map { Probe(id: $0) }
        for (key, probe) in zip(keys, probes) {
            cache.set(probe, for: key, cost: 1)
        }
        for (key, probe) in zip(keys, probes) {
            #expect(cache.value(for: key) === probe)
        }
    }

    @Test("Одинаковые строки, созданные отдельно, попадают в одну запись")
    func separatelyCreatedEqualStringsShareAnEntry() {
        let keyA = String(decoding: Array("album-cover".utf8), as: UTF8.self)
        let keyB = "album-" + "cover"
        #expect(keyA == keyB)

        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: keyA, cost: 1)
        #expect(cache.value(for: keyB) === probe)
    }

    @Test("Кэш не нормализует Unicode: NFC и NFD остаются разными ключами")
    func nfcAndNFDStayDistinctKeys() {
        let nfc = "é"
        let nfd = "e\u{0301}"
        // Swift считает эти строки равными. NSString сравнивает коды и не сводит формы.
        #expect(nfc == nfd)

        let cache = makeCache()
        let composed = Probe(id: 1)
        let decomposed = Probe(id: 2)
        cache.set(composed, for: nfc, cost: 1)
        cache.set(decomposed, for: nfd, cost: 1)
        #expect(cache.value(for: nfc) === composed)
        #expect(cache.value(for: nfd) === decomposed)
    }
}

@Suite("Запись и замена")
struct WriteAndReplaceTests {
    @Test("Повторная запись по тому же ключу подменяет значение")
    func repeatedSetReplacesValue() {
        let cache = makeCache()
        let old = Probe(id: 1)
        let new = Probe(id: 2)
        cache.set(old, for: "k", cost: 1)
        cache.set(new, for: "k", cost: 2)
        #expect(cache.value(for: "k") === new)
        #expect(cache.value(for: "k") !== old)
    }

    @Test("Повторная запись того же экземпляра и стоимости остаётся читаемой")
    func settingSameInstanceAndCostKeepsEntry() {
        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: "k", cost: 4)
        cache.set(probe, for: "k", cost: 4)
        #expect(cache.value(for: "k") === probe)
    }

    @Test("Один экземпляр читается из двух ключей")
    func sameInstanceCanBeStoredUnderTwoKeys() {
        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: "a", cost: 1)
        cache.set(probe, for: "b", cost: 1)
        #expect(cache.value(for: "a") === probe)
        #expect(cache.value(for: "b") === probe)
    }

    @Test("Нулевая стоимость сохраняет объект")
    func zeroCostStillStores() {
        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: "k", cost: 0)
        #expect(cache.value(for: "k") === probe)
    }

    @Test("Разная стоимость не меняет читаемый экземпляр")
    func costDoesNotChangeRetrievedInstance() {
        let cache = makeCache()
        let cheap = Probe(id: 1)
        let expensive = Probe(id: 2)
        cache.set(cheap, for: "cheap", cost: 1)
        cache.set(expensive, for: "expensive", cost: 1_000_000)
        #expect(cache.value(for: "cheap") === cheap)
        #expect(cache.value(for: "expensive") === expensive)
    }

    @Test("Чтение не удаляет запись")
    func readDoesNotRemoveEntry() {
        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: "k", cost: 1)
        #expect(cache.value(for: "k") === probe)
        #expect(cache.value(for: "k") === probe)
    }
}

@Suite("removeAll")
struct RemoveAllTests {
    @Test("Очистка удаляет все ключи")
    func removeAllDropsEveryKey() {
        let cache = makeCache()
        cache.set(Probe(id: 1), for: "a", cost: 1)
        cache.set(Probe(id: 2), for: "b", cost: 1)
        cache.removeAll()
        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") == nil)
    }

    @Test("Очистка пустого кэша безопасна")
    func removeAllOnEmptyCacheIsSafe() {
        let cache = makeCache()
        cache.removeAll()
        #expect(cache.value(for: "missing") == nil)
    }

    @Test("Повторная очистка безопасна")
    func secondRemoveAllIsSafe() {
        let cache = makeCache()
        cache.set(Probe(id: 1), for: "k", cost: 1)
        cache.removeAll()
        cache.removeAll()
        #expect(cache.value(for: "k") == nil)
    }

    @Test("Запись после очистки снова читается")
    func setAfterRemoveAllIsReadable() {
        let cache = makeCache()
        cache.set(Probe(id: 1), for: "k", cost: 1)
        cache.removeAll()
        let probe = Probe(id: 2)
        cache.set(probe, for: "k", cost: 1)
        #expect(cache.value(for: "k") === probe)
    }

    @Test("Очистка одного кэша не трогает другой")
    func removeAllDoesNotAffectAnotherCache() {
        let left = makeCache()
        let right = makeCache()
        let leftProbe = Probe(id: 1)
        let rightProbe = Probe(id: 2)
        left.set(leftProbe, for: "k", cost: 1)
        right.set(rightProbe, for: "k", cost: 1)
        left.removeAll()
        #expect(left.value(for: "k") == nil)
        #expect(right.value(for: "k") === rightProbe)
    }
}

@Suite("Удержание")
struct RetentionTests {
    @Test("Кэш удерживает объект после отпускания локальной ссылки")
    func cacheRetainsValueAfterLocalReferenceDrops() {
        let cache = makeCache()
        weak var weakProbe: Probe?
        autoreleasepool {
            let probe = Probe(id: 7)
            weakProbe = probe
            cache.set(probe, for: "k", cost: 1)
        }
        let fetched = cache.value(for: "k")
        #expect(fetched != nil)
        #expect(fetched === weakProbe)
    }

    @Test("Замена отпускает предыдущий объект без внешней ссылки")
    func replaceReleasesPreviousValueWithoutExternalReference() {
        let cache = makeCache()
        let counter = DeinitCounter()
        autoreleasepool {
            let old = Probe(id: 1) { counter.increment() }
            cache.set(old, for: "k", cost: 1)
        }
        #expect(counter.value == 0)

        autoreleasepool {
            cache.set(Probe(id: 2), for: "k", cost: 1)
        }
        #expect(counter.value == 1)
        #expect(cache.value(for: "k")?.id == 2)
    }

    @Test("Очистка отпускает объекты без внешней ссылки")
    func removeAllReleasesValuesWithoutExternalReference() {
        let cache = makeCache()
        let counter = DeinitCounter()
        autoreleasepool {
            let probe = Probe(id: 1) { counter.increment() }
            cache.set(probe, for: "k", cost: 1)
        }
        #expect(counter.value == 0)

        autoreleasepool {
            cache.removeAll()
        }
        #expect(counter.value == 1)
        #expect(cache.value(for: "k") == nil)
    }

    @Test("Внешняя ссылка не даёт замене деинициализировать объект")
    func replaceDoesNotDeinitializeWhileExternalReferenceLives() {
        let cache = makeCache()
        let counter = DeinitCounter()
        let old = Probe(id: 1) { counter.increment() }
        cache.set(old, for: "k", cost: 1)
        let replacement = Probe(id: 2)
        autoreleasepool {
            cache.set(replacement, for: "k", cost: 1)
        }
        #expect(counter.value == 0)
        #expect(cache.value(for: "k") === replacement)
        _ = old
    }

    @Test("Внешняя ссылка не даёт очистке деинициализировать объект")
    func removeAllDoesNotDeinitializeWhileExternalReferenceLives() {
        let cache = makeCache()
        let counter = DeinitCounter()
        let old = Probe(id: 1) { counter.increment() }
        cache.set(old, for: "k", cost: 1)
        autoreleasepool {
            cache.removeAll()
        }
        #expect(counter.value == 0)
        #expect(cache.value(for: "k") == nil)
        _ = old
    }
}

@Suite("Лимиты MemoryCache")
struct LimitTests {
    @Test("Нулевые лимиты оставляют объекты читаемыми")
    func zeroLimitsStoreObjects() {
        let cache = MemoryCache<Probe>(totalCostLimit: 0, countLimit: 0)
        let probes = (0..<3).map { Probe(id: $0) }
        for (index, probe) in probes.enumerated() {
            cache.set(probe, for: "\(index)", cost: 1_000_000)
        }
        for (index, probe) in probes.enumerated() {
            #expect(cache.value(for: "\(index)") === probe)
        }
    }

    @Test("Нулевой totalCostLimit хранит объекты в пределах countLimit")
    func zeroTotalCostLimitStoresWithinCountLimit() {
        let cache = MemoryCache<Probe>(totalCostLimit: 0, countLimit: 10)
        let probes = (0..<3).map { Probe(id: $0) }
        for (index, probe) in probes.enumerated() {
            cache.set(probe, for: "\(index)", cost: 1_000)
        }
        for (index, probe) in probes.enumerated() {
            #expect(cache.value(for: "\(index)") === probe)
        }
    }

    @Test("Нулевой countLimit хранит объекты в пределах totalCostLimit")
    func zeroCountLimitStoresWithinCostLimit() {
        let cache = MemoryCache<Probe>(totalCostLimit: 100, countLimit: 0)
        let probes = (0..<3).map { Probe(id: $0) }
        for (index, probe) in probes.enumerated() {
            cache.set(probe, for: "\(index)", cost: 20)
        }
        for (index, probe) in probes.enumerated() {
            #expect(cache.value(for: "\(index)") === probe)
        }
    }

    @Test("Объекты внутри обоих лимитов читаются сразу после записи")
    func valuesRemainImmediatelyWhenWithinBothLimits() {
        let cache = MemoryCache<Probe>(totalCostLimit: 100, countLimit: 10)
        let probes = (0..<5).map { Probe(id: $0) }
        for (index, probe) in probes.enumerated() {
            cache.set(probe, for: "item-\(index)", cost: 10)
        }
        for (index, probe) in probes.enumerated() {
            #expect(cache.value(for: "item-\(index)") === probe)
        }
    }

    @Test("Один объект дешевле лимита и при countLimit не ниже единицы читается")
    func singleObjectUnderCostLimitIsReadable() {
        let cache = MemoryCache<Probe>(totalCostLimit: 100, countLimit: 1)
        let probe = Probe(id: 1)
        cache.set(probe, for: "k", cost: 99)
        #expect(cache.value(for: "k") === probe)
    }

    @Test("Объект со стоимостью, равной totalCostLimit, читается")
    func objectCostEqualToTotalCostLimitIsReadable() {
        let cache = MemoryCache<Probe>(totalCostLimit: 64, countLimit: 4)
        let probe = Probe(id: 1)
        cache.set(probe, for: "k", cost: 64)
        #expect(cache.value(for: "k") === probe)
    }

    @Test("Сумма стоимостей, равная totalCostLimit, читается целиком")
    func costsSummingToTheLimitStayReadable() {
        let cache = MemoryCache<Probe>(totalCostLimit: 10, countLimit: 5)
        let left = Probe(id: 1)
        let right = Probe(id: 2)
        cache.set(left, for: "a", cost: 4)
        cache.set(right, for: "b", cost: 6)
        #expect(cache.value(for: "a") === left)
        #expect(cache.value(for: "b") === right)
    }

    @Test("Число объектов, равное countLimit, читается сразу после записи")
    func objectCountEqualToCountLimitIsReadable() {
        let cache = MemoryCache<Probe>(totalCostLimit: 100, countLimit: 3)
        let probes = (0..<3).map { Probe(id: $0) }
        for (index, probe) in probes.enumerated() {
            cache.set(probe, for: "\(index)", cost: 1)
        }
        for (index, probe) in probes.enumerated() {
            #expect(cache.value(for: "\(index)") === probe)
        }
    }

    @Test("Повторная запись уменьшает стоимость и освобождает бюджет")
    func replacingEntryWithLowerCostFreesBudget() {
        let cache = MemoryCache<Probe>(totalCostLimit: 10, countLimit: 10)
        cache.set(Probe(id: 1), for: "a", cost: 10)
        let cheaper = Probe(id: 2)
        cache.set(cheaper, for: "a", cost: 1)
        let other = Probe(id: 3)
        cache.set(other, for: "b", cost: 9)
        #expect(cache.value(for: "a") === cheaper)
        #expect(cache.value(for: "b") === other)
    }

    @Test("Повторная запись того же ключа не занимает второй слот countLimit")
    func replacementDoesNotConsumeAnotherCountSlot() {
        let cache = MemoryCache<Probe>(totalCostLimit: 10_000, countLimit: 2)
        cache.set(Probe(id: 1), for: "a", cost: 1)
        cache.set(Probe(id: 2), for: "a", cost: 1)
        let latest = Probe(id: 3)
        cache.set(latest, for: "a", cost: 1)
        let other = Probe(id: 4)
        cache.set(other, for: "b", cost: 1)
        #expect(cache.value(for: "a") === latest)
        #expect(cache.value(for: "b") === other)
    }

    @Test("Нулевая стоимость не вытесняет запись на весь бюджет")
    func zeroCostEntriesDoNotEvictAFullBudgetEntry() {
        let cache = MemoryCache<Probe>(totalCostLimit: 10, countLimit: 50)
        let full = Probe(id: 1)
        cache.set(full, for: "full", cost: 10)
        let zeros = (0..<20).map { Probe(id: $0 + 2) }
        for (index, probe) in zeros.enumerated() {
            cache.set(probe, for: "z\(index)", cost: 0)
        }
        #expect(cache.value(for: "full") === full)
        for (index, probe) in zeros.enumerated() {
            #expect(cache.value(for: "z\(index)") === probe)
        }
    }

    @Test("Лимиты сохраняются после очистки")
    func limitsRemainAfterRemoveAll() {
        let cache = MemoryCache<Probe>(totalCostLimit: 30, countLimit: 3)
        cache.set(Probe(id: 1), for: "old", cost: 30)
        cache.removeAll()
        let probes = (0..<3).map { Probe(id: $0) }
        for (index, probe) in probes.enumerated() {
            cache.set(probe, for: "n\(index)", cost: 10)
        }
        #expect(cache.value(for: "old") == nil)
        for (index, probe) in probes.enumerated() {
            #expect(cache.value(for: "n\(index)") === probe)
        }
    }

    @Test("Превышение лимита не падает и не возвращает чужой объект")
    func exceedingLimitsReturnsStoredInstanceOrNil() {
        // NSCache может вытеснить запись сразу или оставить её.
        let byCost = MemoryCache<Probe>(totalCostLimit: 10, countLimit: 100)
        let expensive = Probe(id: 1)
        byCost.set(expensive, for: "k", cost: 11)
        let storedExpensive = byCost.value(for: "k")
        #expect(storedExpensive == nil || storedExpensive === expensive)

        let byCount = MemoryCache<Probe>(totalCostLimit: 10_000, countLimit: 1)
        let first = Probe(id: 1)
        let second = Probe(id: 2)
        byCount.set(first, for: "a", cost: 1)
        byCount.set(second, for: "b", cost: 1)
        let storedFirst = byCount.value(for: "a")
        let storedSecond = byCount.value(for: "b")
        #expect(storedFirst == nil || storedFirst === first)
        #expect(storedSecond == nil || storedSecond === second)
    }
}

@Suite("Потоки")
struct ConcurrencyTests {
    @Test("Кэш пишется и читается из Task.detached")
    func cacheIsUsableFromDetachedTask() async {
        let cache = makeCache()
        let probe = Probe(id: 1)
        let found = await Task.detached { () -> Probe? in
            cache.set(probe, for: "k", cost: 1)
            return cache.value(for: "k")
        }.value
        #expect(found === probe)
    }

    @Test("Параллельные записи разных ключей читаются после барьера")
    func concurrentSetsOfDistinctKeysRemainReadable() async {
        let cache = makeCache()
        let probes = (0..<128).map { Probe(id: $0) }
        await withTaskGroup(of: Void.self) { group in
            for (index, probe) in probes.enumerated() {
                let key = "\(index)"
                group.addTask {
                    cache.set(probe, for: key, cost: 1)
                }
            }
        }
        for (index, probe) in probes.enumerated() {
            #expect(cache.value(for: "\(index)") === probe)
        }
    }

    @Test("Параллельные чтения возвращают тот же экземпляр")
    func concurrentReadsReturnTheStoredInstance() async {
        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: "k", cost: 1)
        let readings = await withTaskGroup(of: [Probe?].self, returning: [[Probe?]].self) { group in
            for _ in 0..<64 {
                group.addTask {
                    var seen: [Probe?] = []
                    seen.reserveCapacity(50)
                    for _ in 0..<50 {
                        seen.append(cache.value(for: "k"))
                    }
                    return seen
                }
            }
            var batches: [[Probe?]] = []
            for await batch in group {
                batches.append(batch)
            }
            return batches
        }
        #expect(readings.count == 64)
        for batch in readings {
            #expect(batch.count == 50)
            for value in batch {
                #expect(value === probe)
            }
        }
    }

    @Test("Параллельные записи одного ключа оставляют один из экземпляров")
    func concurrentSetsOfSameKeyLeaveOneWrittenInstance() async {
        let cache = makeCache()
        let probes = (0..<64).map { Probe(id: $0) }
        await withTaskGroup(of: Void.self) { group in
            for probe in probes {
                group.addTask {
                    cache.set(probe, for: "k", cost: 1)
                }
            }
        }
        let stored = cache.value(for: "k")
        #expect(probes.contains { $0 === stored })
    }

    @Test("Чтение во время записи возвращает nil или записанный экземпляр")
    func concurrentReadDuringSetReturnsNilOrThatInstance() async {
        let cache = makeCache()
        let probe = Probe(id: 1)
        let readings = await withTaskGroup(of: [Probe?].self, returning: [[Probe?]].self) { group in
            group.addTask {
                for _ in 0..<400 {
                    cache.set(probe, for: "k", cost: 1)
                }
                return []
            }
            for _ in 0..<8 {
                group.addTask {
                    var seen: [Probe?] = []
                    seen.reserveCapacity(400)
                    for _ in 0..<400 {
                        seen.append(cache.value(for: "k"))
                    }
                    return seen
                }
            }
            var batches: [[Probe?]] = []
            for await batch in group {
                batches.append(batch)
            }
            return batches
        }
        for batch in readings {
            for value in batch {
                #expect(value == nil || value === probe)
            }
        }
    }

    @Test("Гонка очистки и доступа не оставляет кэш сломанным")
    func concurrentRemoveAllLeavesCacheUsable() async {
        let cache = makeCache()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                let key = "k\(index)"
                let probe = Probe(id: index)
                group.addTask {
                    cache.set(probe, for: key, cost: 1)
                    _ = cache.value(for: key)
                }
                group.addTask {
                    cache.removeAll()
                }
            }
        }
        cache.removeAll()
        for index in 0..<32 {
            #expect(cache.value(for: "k\(index)") == nil)
        }
        let fresh = Probe(id: 999)
        cache.set(fresh, for: "after", cost: 1)
        #expect(cache.value(for: "after") === fresh)
    }

    @Test("value(for:) вызывается синхронно с главного актора")
    @MainActor
    func valueForKeyIsSynchronousOnMainActor() {
        let cache = makeCache()
        let probe = Probe(id: 1)
        cache.set(probe, for: "cell", cost: 1)
        let value = cache.value(for: "cell")
        #expect(value === probe)
    }
}
