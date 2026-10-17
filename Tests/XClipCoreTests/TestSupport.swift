import Foundation
@testable import XClipCore

func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("xclip-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("test.db")
}
