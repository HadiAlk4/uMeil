import Foundation
import Testing

struct TestDefaultsTests {
    @Test func deletesItsPlistWhenFreed() throws {
        var name = ""
        do {
            let defaults = TestDefaults()
            name = defaults.name
            defaults.set(42, forKey: "answer")
            CFPreferencesAppSynchronize(name as CFString)
            #expect(FileManager.default.fileExists(atPath: TestDefaults.file(for: name).path(percentEncoded: false)))
        }
        #expect(!FileManager.default.fileExists(atPath: TestDefaults.file(for: name).path(percentEncoded: false)))
    }

    @Test func eachStoreStartsEmptyAndApart() {
        let first = TestDefaults()
        let second = TestDefaults()
        first.set("one", forKey: "key")
        #expect(second.string(forKey: "key") == nil)
        #expect(first.name != second.name)
    }

    @Test func sweepsOnlyOldLeftovers() throws {
        let folder = try TemporaryFolder()
        func plist(_ name: String, age: TimeInterval) throws -> URL {
            let url = folder.url.appending(path: name)
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(-age)],
                ofItemAtPath: url.path(percentEncoded: false)
            )
            return url
        }
        let old = try plist("\(TestDefaults.prefix)old.plist", age: 2 * TestDefaults.staleAge)
        let recent = try plist("\(TestDefaults.prefix)recent.plist", age: 60)
        let other = try plist("com.example.app.plist", age: 2 * TestDefaults.staleAge)

        TestDefaults.removeStaleSuites(olderThan: Date.now.addingTimeInterval(-TestDefaults.staleAge), in: folder.url)

        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: recent.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
    }
}
