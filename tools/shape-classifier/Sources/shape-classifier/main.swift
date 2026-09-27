import CreateML
import Foundation
import WTGeometry

// shape-classifier: the training set, training and evaluation of Select Similar's shape model
// (IMG-030).
//
//   swift run -c release shape-classifier fixtures   write the labelled fixture set (fixtures.txt)
//   swift run -c release shape-classifier train      train on the training set, evaluate, write the model
//   swift run -c release shape-classifier evaluate   evaluate the committed model on the fixture set
//   swift run -c release shape-classifier all        fixtures, then train
//
// The training set is `Corpus.make(perClass: 1500, seed: 1)`: regenerated, never committed.  The
// fixture set is `Corpus.make(perClass: 182, seed: 2)` (2,002 paths, every class, half drawn the
// way the tools draw and half imported from SVG), committed as path data so the WTGeometry tests
// read exactly what was evaluated.  Features are WTGeometry's `ShapeFeatures`, the app's own.

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let fixturesURL = repository.appendingPathComponent("tools/shape-classifier/fixtures.txt")
let modelURL = repository.appendingPathComponent("client/WTApp/Objects/Resources/ShapeClassifier.wtmodel")

func writeFixtures() throws {
    let samples = Corpus.make(perClass: 182, seed: 2)
    let lines = samples.map { "\($0.label.rawValue)\t\($0.source.rawValue)\t\(PathData.write($0.contours))" }
    try (lines.joined(separator: "\n") + "\n").write(to: fixturesURL, atomically: true, encoding: .utf8)
    print("wrote \(samples.count) fixtures to \(fixturesURL.path)")
}

func readFixtures() throws -> [(label: ShapeClass, source: String, contours: [Contour])] {
    try String(contentsOf: fixturesURL, encoding: .utf8).split(separator: "\n").map { line in
        let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
        return (ShapeClass(rawValue: fields[0])!, fields[1], PathData.parse(fields[2]))
    }
}

func train() throws {
    let samples = Corpus.make(perClass: 1500, seed: 1)
    var columns: [String: [Double]] = Dictionary(uniqueKeysWithValues: ShapeFeatures.names.map { ($0, []) })
    var labels: [String] = []
    for sample in samples {
        guard let features = ShapeFeatures(sample.contours) else { continue }
        labels.append(sample.label.rawValue)
        for (name, value) in zip(ShapeFeatures.names, features.values) { columns[name]!.append(value) }
    }
    var dictionary: [String: MLDataValueConvertible] = columns.mapValues { $0 }
    dictionary[ShapeClassifier.label] = labels
    let table = try MLDataTable(dictionary: dictionary)
    let parameters = MLBoostedTreeClassifier.ModelParameters(validation: .none, maxDepth: 5, maxIterations: 40, minLossReduction: 0,
                                                             minChildWeight: 0.1, randomSeed: 7, stepSize: 0.3, earlyStoppingRounds: nil,
                                                             rowSubsample: 0.9, columnSubsample: 0.8)
    let classifier = try MLBoostedTreeClassifier(trainingData: table, targetColumn: ShapeClassifier.label, featureColumns: ShapeFeatures.names,
                                                 parameters: parameters)
    print("training accuracy \(String(format: "%.2f", (1 - classifier.trainingMetrics.classificationError) * 100))% on \(labels.count) paths")
    let metadata = MLModelMetadata(author: "WireTuner", shortDescription: "Select Similar shape classes from ShapeFeatures (IMG-030)",
                                   license: "Trained on the synthetic corpus of tools/shape-classifier; no third-party data", version: "1")
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ShapeClassifier.mlmodel")
    try? FileManager.default.removeItem(at: staging)
    try classifier.write(to: staging, metadata: metadata)
    try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: modelURL)
    try FileManager.default.copyItem(at: staging, to: modelURL)
    let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int) ?? 0
    print("wrote \(modelURL.path) (\(size) bytes)")
}

func evaluate() async throws {
    let classifier = try await ShapeClassifier.load(modelAt: modelURL)
    let fixtures = try readFixtures()
    let features = fixtures.map { ShapeFeatures($0.contours) }
    let clock = ContinuousClock()
    _ = classifier.classify(Array(features.compactMap { $0 }.prefix(8)))
    let started = clock.now
    let predicted = classifier.classify(features.compactMap { $0 })
    let elapsed = clock.now - started
    let extraction = clock.measure { _ = fixtures.map { ShapeFeatures($0.contours) } }
    print("feature extraction of \(fixtures.count) paths: \(extraction)")
    let all = features.compactMap { $0 }
    let parallel = clock.now
    _ = await classifier.classifyInBackground(all + all)
    print("parallel classification of \(all.count * 2) paths: \(clock.now - parallel)")
    var index = 0
    var confusion: [ShapeClass: [ShapeClass: Int]] = [:]
    var correct = 0
    for (fixture, feature) in zip(fixtures, features) {
        var guess: ShapeClass?
        if feature != nil {
            guess = predicted[index]
            index += 1
        }
        confusion[fixture.label, default: [:]][guess ?? .group, default: 0] += 1
        if guess == fixture.label { correct += 1 }
    }
    print(String(format: "fixture accuracy %.2f%% (%d of %d), classified in %@", Double(correct) * 100 / Double(fixtures.count), correct,
                 fixtures.count, "\(elapsed)"))
    for label in ShapeClass.modelled {
        let row = confusion[label] ?? [:]
        let total = row.values.reduce(0, +)
        let misses = row.filter { $0.key != label }.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
        print(String(format: "  %-18@ %5.1f%%  %@", label.rawValue as NSString, Double(row[label] ?? 0) * 100 / Double(max(total, 1)), misses as NSString))
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "all"
switch command {
case "fixtures":
    try writeFixtures()
case "train":
    try train()
    try await evaluate()
case "evaluate":
    try await evaluate()
default:
    try writeFixtures()
    try train()
    try await evaluate()
}
