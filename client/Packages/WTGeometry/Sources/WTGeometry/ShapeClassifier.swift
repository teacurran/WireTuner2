#if canImport(CoreML)
import CoreML
import Foundation

/// Select Similar's shape classifier (selecting.adoc, "Select Similar"; IMG-030): a small bundled
/// Core ML model -- a tree ensemble trained by `tools/shape-classifier` -- run through `MLModel`
/// directly (no Vision) over each path's `ShapeFeatures`.  It runs on the CPU, reads nothing but
/// the features it is given and makes no network calls; nothing leaves the Mac.
///
/// The model ships as an optional resource in its uncompiled form (`.mlmodel` bytes); `load`
/// compiles it into the temporary directory once.  Predictions are thread-safe, so one classifier
/// serves every window, and `classifyInBackground` runs a batch off the caller's actor.
public struct ShapeClassifier: @unchecked Sendable {
    /// The model's input columns and its output column.
    public static let label = "label"

    private let model: MLModel

    /// A classifier over the compiled model at `url` (an `.mlmodelc` directory).
    public init(compiledModelAt url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    /// The classifier of the uncompiled model at `url`, compiled once into the temporary directory.
    public static func load(modelAt url: URL) async throws -> ShapeClassifier {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("wt-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let source = staging.appendingPathComponent("ShapeClassifier.mlmodel")
        try FileManager.default.copyItem(at: url, to: source)
        let compiled = try await MLModel.compileModel(at: source)
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("wt-shape-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.moveItem(at: compiled, to: kept)
        return try ShapeClassifier(compiledModelAt: kept)
    }

    /// The class of one path's features; nil when the model gives no class it knows.
    public func classify(_ features: ShapeFeatures) -> ShapeClass? {
        classify([features])[0]
    }

    /// The class of each of `batch`, in order (one batch prediction).
    public func classify(_ batch: [ShapeFeatures]) -> [ShapeClass?] {
        guard !batch.isEmpty else { return [] }
        let providers: [any MLFeatureProvider] = batch.map(Self.provider)
        guard let results = try? model.predictions(from: MLArrayBatchProvider(array: providers), options: MLPredictionOptions()) else {
            return batch.map { _ in nil }
        }
        return (0..<results.count).map { index in
            (results.features(at: index).featureValue(for: Self.label)?.stringValue).flatMap(ShapeClass.init(rawValue:))
        }
    }

    /// `classify(_:)` off the caller's actor, in chunks of `chunk` paths predicted in parallel
    /// (predictions are thread-safe), the results in `batch` order.
    public func classifyInBackground(_ batch: [ShapeFeatures], chunk: Int = 512) async -> [ShapeClass?] {
        let size = max(chunk, 1)
        let starts = Array(stride(from: 0, to: batch.count, by: size))
        return await withTaskGroup(of: (Int, [ShapeClass?]).self) { group in
            for start in starts {
                let slice = Array(batch[start..<min(start + size, batch.count)])
                group.addTask(priority: .userInitiated) { (start, self.classify(slice)) }
            }
            var result = [ShapeClass?](repeating: nil, count: batch.count)
            for await (start, classes) in group {
                result.replaceSubrange(start..<(start + classes.count), with: classes)
            }
            return result
        }
    }

    /// The input of one path: each feature column as a double, made when the model asks for it.
    static func provider(_ features: ShapeFeatures) -> any MLFeatureProvider {
        FeatureColumns(values: features.values)
    }
}

/// One path's feature columns (`ShapeFeatures.names`) as the model reads them.
final class FeatureColumns: NSObject, MLFeatureProvider, @unchecked Sendable {
    static let index = Dictionary(uniqueKeysWithValues: ShapeFeatures.names.enumerated().map { ($1, $0) })
    static let names = Set(ShapeFeatures.names)
    let values: [Double]

    init(values: [Double]) {
        self.values = values
    }

    var featureNames: Set<String> { Self.names }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        Self.index[featureName].map { MLFeatureValue(double: values[$0]) }
    }
}
#endif
