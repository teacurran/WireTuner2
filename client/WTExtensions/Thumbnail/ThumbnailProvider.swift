import AppKit
import QuickLookThumbnailing

/// The Finder icon of a `.wiretuner` package (saving.adoc, "Quick Look and Spotlight"; IO-034):
/// `thumbnail.png` read from the zip's central directory, fitted to the request, with the
/// *Offline changes* badge when the package holds unsynced changes (`PackagePeek`).
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void) {
        do {
            let peek = try PackagePeek(url: request.fileURL)
            guard let image = peek.thumbnailImage(fitting: request.maximumSize, scale: request.scale) else {
                throw PackagePeek.Failure.missing(PackagePeek.thumbnailName)
            }
            let size = CGSize(width: CGFloat(image.width) / request.scale, height: CGFloat(image.height) / request.scale)
            handler(QLThumbnailReply(contextSize: size) { context in
                context.draw(image, in: CGRect(origin: .zero, size: size))
                return true
            }, nil)
        } catch {
            handler(nil, error)
        }
    }
}
