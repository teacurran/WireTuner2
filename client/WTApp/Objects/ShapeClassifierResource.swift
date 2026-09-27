import Foundation
import WTGeometry
import WTModel

/// The bundled shape model (selecting.adoc, "Select Similar"; IMG-030): an optional resource,
/// `ShapeClassifier.wtmodel` (the Core ML model's uncompiled bytes under an extension Xcode does
/// not compile, trained by tools/shape-classifier).  A build without it has no *Shape* item and
/// nothing else changes.
enum ShapeClassifierResource {
    static let name = "ShapeClassifier"
    static let fileExtension = "wtmodel"

    /// The model in `bundle`, nil when the build does not carry it.
    static func url(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: name, withExtension: fileExtension)
    }

    /// The classification over the model in `bundle`; nil without the model (or when it does not
    /// load).
    static func load(from bundle: Bundle = .main) async -> ShapeClassification? {
        guard let url = url(in: bundle), let classifier = try? await ShapeClassifier.load(modelAt: url) else { return nil }
        return ShapeClassification(classifier: classifier)
    }
}
