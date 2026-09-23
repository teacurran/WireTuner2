import XCTest

/// Screenshots for the book (TEST-002).  Every capture is attached to the test result; when
/// `WT_DOCS_IMAGES` names a directory (normally `docs/images`), it is also written there as
/// `<name>.png` so a guide page can include it.  `xcodebuild` passes a variable to the UI test
/// runner only with the `TEST_RUNNER_` prefix:
///
///     TEST_RUNNER_WT_DOCS_IMAGES="$PWD/docs/images" xcodebuild test -only-testing:WireTunerUITests ...
enum ScreenshotCapture {
    static let environmentKey = "WT_DOCS_IMAGES"

    /// The directory captures are written to, if any.
    static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Captures `element` (a window, a panel, the canvas) as `name`; returns the file written,
    /// if any.  Names are the book's image names: lower-case, hyphenated, no extension.
    @discardableResult
    @MainActor
    static func capture(_ element: XCUIElement, named name: String, in test: XCTestCase) throws -> URL? {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
        guard let directory = directory() else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("png")
        try screenshot.pngRepresentation.write(to: url)
        return url
    }
}
