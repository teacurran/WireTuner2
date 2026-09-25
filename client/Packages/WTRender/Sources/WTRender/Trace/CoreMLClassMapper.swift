// The *Photo* tracer's class map from the bundled semantic-segmentation model (IMG-029;
// tracing.adoc, "Client"): a compiled Core ML model (`PhotoSegmentation.mlmodelc`, a
// MobileNet-class DeepLab variant) run through `VNCoreMLRequest` on this Mac.  The model is an
// optional resource: without it `bundled(in:)` answers nil and the tracer falls back to subject and
// background.  The class names come from the model's `labels` metadata (comma separated, class 0
// first).

#if canImport(CoreML) && canImport(Vision)
import CoreGraphics
import CoreML
import Foundation
import Vision

public struct CoreMLClassMapper: Trace.ClassMapping, @unchecked Sendable {
    /// The resource name of the compiled model.
    public static let resource = "PhotoSegmentation"

    private let model: VNCoreMLModel
    private let names: [UInt16: String]

    /// The mapper over the model compiled into `bundle`; nil when the build does not carry it or
    /// it cannot be loaded.
    public static func bundled(in bundle: Bundle = .main) -> CoreMLClassMapper? {
        guard let url = bundle.url(forResource: resource, withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url), let vision = try? VNCoreMLModel(for: model) else {
            return nil
        }
        let labels = (model.modelDescription.metadata[.creatorDefinedKey] as? [String: String])?["labels"]?.split(separator: ",") ?? []
        var names: [UInt16: String] = [:]
        for (index, label) in labels.enumerated() where index > 0 {
            names[UInt16(index)] = label.trimmingCharacters(in: .whitespaces).capitalized
        }
        return CoreMLClassMapper(model: vision, names: names)
    }

    private init(model: VNCoreMLModel, names: [UInt16: String]) {
        self.model = model
        self.names = names
    }

    public func classMap(for image: CGImage) throws -> Trace.ClassMap? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let array = observation.featureValue.multiArrayValue, array.shape.count >= 2 else {
            return nil
        }
        let height = array.shape[array.shape.count - 2].intValue, width = array.shape[array.shape.count - 1].intValue
        var labels = [UInt16](repeating: 0, count: width * height)
        for index in labels.indices {
            labels[index] = UInt16(clamping: array[index].intValue)
        }
        return Trace.ClassMap(width: width, height: height, labels: labels, names: names)
    }
}
#endif
