import CryptoKit
import CreateML
import Foundation

private let modelId = "premium-insight-v1"
private let schemaVersion = 1
private let targetColumn = "targetScore"
private let confidenceColumn = "targetConfidence"
private let featureColumns = [
    "cpCap",
    "rankIndex",
    "rating",
    "score",
    "roleScore",
    "matchupCount",
    "matchupMean",
    "counterCount",
    "counterMean",
    "movesetCount",
    "chargedMoveCount"
]

enum PremiumInsightTask: String, CaseIterable, Codable {
    case matchupImpact
    case teamOptimizer
    case draftSimulator
    case metaTrend
    case battleFrontier
    case cupReadiness
    case buildPlanner
    case scanInbox
    case battleLog
}

struct Options {
    let dataRoot: URL
    let catalogURL: URL
    let outputRoot: URL
    let dryRun: Bool

    static func parse(_ arguments: [String]) throws -> Options {
        var dataRoot: URL?
        var catalogURL: URL?
        var outputRoot: URL?
        var dryRun = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--data-root":
                index += 1
                dataRoot = try valueURL(arguments, index: index, flag: argument)
            case "--catalog":
                index += 1
                catalogURL = try valueURL(arguments, index: index, flag: argument)
            case "--output":
                index += 1
                outputRoot = try valueURL(arguments, index: index, flag: argument)
            case "--dry-run":
                dryRun = true
            case "--help", "-h":
                printUsage()
                Foundation.exit(0)
            default:
                throw TrainerError.invalidArguments("Unknown argument: \(argument)")
            }
            index += 1
        }

        guard let dataRoot, let catalogURL, let outputRoot else {
            throw TrainerError.invalidArguments("Missing --data-root, --catalog, or --output.")
        }
        return Options(dataRoot: dataRoot, catalogURL: catalogURL, outputRoot: outputRoot, dryRun: dryRun)
    }

    private static func valueURL(_ arguments: [String], index: Int, flag: String) throws -> URL {
        guard arguments.indices.contains(index) else {
            throw TrainerError.invalidArguments("Missing value for \(flag).")
        }
        return URL(fileURLWithPath: arguments[index], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }
}

struct Catalog: Decodable {
    let version: String
    let sourceCommit: String
    let bundleHash: String
    let generatedAt: String
}

struct TrainingRow {
    let task: PremiumInsightTask
    let cpCap: Double
    let rankIndex: Double
    let rating: Double
    let score: Double
    let roleScore: Double
    let matchupCount: Double
    let matchupMean: Double
    let counterCount: Double
    let counterMean: Double
    let movesetCount: Double
    let chargedMoveCount: Double
    let targetScore: Double
    let targetConfidence: Double

    var csvValues: [String] {
        [
            cpCap,
            rankIndex,
            rating,
            score,
            roleScore,
            matchupCount,
            matchupMean,
            counterCount,
            counterMean,
            movesetCount,
            chargedMoveCount,
            targetScore,
            targetConfidence
        ].map { String(format: "%.6f", $0) }
    }
}

struct PremiumInsightManifest: Encodable {
    let modelId: String
    let schemaVersion: Int
    let modelVersion: String
    let dataVersion: String
    let trainedAt: String
    let tasks: [PremiumInsightArtifact]
}

struct PremiumInsightArtifact: Encodable {
    let task: PremiumInsightTask
    let artifactPath: String
    let sha256: String
    let inputFeatureNames: [String]
    let scoreOutputName: String
    let confidenceOutputName: String?
    let additionalOutputNames: [String]
    let metrics: PremiumInsightMetrics
}

struct PremiumInsightMetrics: Encodable {
    let rowCount: Int
    let rootMeanSquaredError: Double?
    let maximumError: Double?
}

enum TrainerError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case invalidCatalog(URL)
    case missingRankings(URL)
    case noTrainingRows
    case insufficientTaskRows(PremiumInsightTask, Int)

    var description: String {
        switch self {
        case .invalidArguments(let message):
            return message
        case .invalidCatalog(let url):
            return "Could not decode catalog at \(url.path)."
        case .missingRankings(let url):
            return "No rankings directory found at \(url.path)."
        case .noTrainingRows:
            return "No ranking rows were found for Premium Insight training."
        case .insufficientTaskRows(let task, let count):
            return "Not enough rows to train \(task.rawValue): \(count)."
        }
    }
}

struct PremiumInsightTrainer {
    let fileManager = FileManager.default

    func run(options: Options) throws {
        let catalog = try loadCatalog(options.catalogURL)
        let trainedAt = iso8601Now()
        let modelVersion = "\(catalog.sourceCommit.prefix(12))-\(trainedAt.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: ""))"
        let immutableDirectory = options.outputRoot
            .appending(path: "ml", directoryHint: .isDirectory)
            .appending(path: "versions", directoryHint: .isDirectory)
            .appending(path: catalog.version, directoryHint: .isDirectory)
            .appending(path: modelId, directoryHint: .isDirectory)
        let datasetDirectory = options.outputRoot
            .appending(path: "training-data", directoryHint: .isDirectory)
            .appending(path: catalog.version, directoryHint: .isDirectory)
        let currentDirectory = options.outputRoot
            .appending(path: "ml", directoryHint: .isDirectory)
            .appending(path: "current", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: immutableDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: datasetDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)

        let rows = try buildRows(dataRoot: options.dataRoot)
        guard rows.isEmpty == false else { throw TrainerError.noTrainingRows }

        var artifacts: [PremiumInsightArtifact] = []
        for task in PremiumInsightTask.allCases {
            let taskRows = rows.filter { $0.task == task }
            guard taskRows.count >= 12 else { throw TrainerError.insufficientTaskRows(task, taskRows.count) }
            let csvURL = datasetDirectory.appending(path: "\(task.rawValue)-training.csv")
            try writeCSV(rows: taskRows, to: csvURL)

            let modelURL = immutableDirectory.appending(path: "\(task.rawValue).mlmodel")
            let metrics: PremiumInsightMetrics
            if options.dryRun {
                metrics = PremiumInsightMetrics(rowCount: taskRows.count, rootMeanSquaredError: nil, maximumError: nil)
                try Data("dry-run model placeholder for \(task.rawValue)\n".utf8).write(to: modelURL, options: .atomic)
            } else {
                metrics = try trainRegressor(task: task, csvURL: csvURL, modelURL: modelURL, catalog: catalog, modelVersion: modelVersion)
            }

            artifacts.append(PremiumInsightArtifact(
                task: task,
                artifactPath: "/ml/versions/\(catalog.version)/\(modelId)/\(task.rawValue).mlmodel",
                sha256: try sha256Hex(for: modelURL),
                inputFeatureNames: featureColumns,
                scoreOutputName: targetColumn,
                confidenceOutputName: nil,
                additionalOutputNames: [],
                metrics: metrics
            ))
        }

        let manifest = PremiumInsightManifest(
            modelId: modelId,
            schemaVersion: schemaVersion,
            modelVersion: modelVersion,
            dataVersion: catalog.version,
            trainedAt: trainedAt,
            tasks: artifacts
        )
        try writeJSON(manifest, to: immutableDirectory.appending(path: "manifest.json"))
        try writeJSON(manifest, to: currentDirectory.appending(path: "\(modelId).json"))

        print("Premium Insight training complete")
        print("Data version: \(catalog.version)")
        print("Artifacts: \(immutableDirectory.path)")
    }

    private func loadCatalog(_ url: URL) throws -> Catalog {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Catalog.self, from: data)
        } catch {
            throw TrainerError.invalidCatalog(url)
        }
    }

    private func buildRows(dataRoot: URL) throws -> [TrainingRow] {
        let rankingsDirectory = dataRoot.appending(path: "rankings", directoryHint: .isDirectory)
        guard let enumerator = fileManager.enumerator(at: rankingsDirectory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw TrainerError.missingRankings(rankingsDirectory)
        }

        var rows: [TrainingRow] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rankings-"),
                  fileURL.pathExtension == "json",
                  let cpCap = cpCap(from: fileURL),
                  let category = category(from: fileURL) else {
                continue
            }

            let payload = try Data(contentsOf: fileURL)
            guard let rankings = try JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else {
                continue
            }

            for (index, ranking) in rankings.enumerated() {
                rows.append(contentsOf: rowsForRanking(
                    ranking,
                    cpCap: Double(cpCap),
                    rankIndex: Double(index + 1),
                    category: category
                ))
            }
        }
        return rows
    }

    private func rowsForRanking(
        _ ranking: [String: Any],
        cpCap: Double,
        rankIndex: Double,
        category: String
    ) -> [TrainingRow] {
        let rating = numeric(ranking["rating"]) ?? 500
        let score = numeric(ranking["score"]) ?? clamped(rating / 10, min: 0, max: 100)
        let matchupRatings = ratings(from: ranking["matchups"])
        let counterRatings = ratings(from: ranking["counters"])
        let moves = ranking["moves"] as? [String: Any]
        let chargedMoves = moves?["chargedMoves"] as? [[String: Any]] ?? []
        let rowBase = RowBase(
            cpCap: cpCap,
            rankIndex: rankIndex,
            rating: rating,
            score: score,
            roleScore: roleScore(category),
            matchupCount: Double(matchupRatings.count),
            matchupMean: mean(matchupRatings),
            counterCount: Double(counterRatings.count),
            counterMean: mean(counterRatings),
            movesetCount: Double((ranking["moveset"] as? [Any])?.count ?? 0),
            chargedMoveCount: Double(chargedMoves.count)
        )

        return PremiumInsightTask.allCases.map { task in
            TrainingRow(
                task: task,
                cpCap: rowBase.cpCap,
                rankIndex: rowBase.rankIndex,
                rating: rowBase.rating,
                score: rowBase.score,
                roleScore: rowBase.roleScore,
                matchupCount: rowBase.matchupCount,
                matchupMean: rowBase.matchupMean,
                counterCount: rowBase.counterCount,
                counterMean: rowBase.counterMean,
                movesetCount: rowBase.movesetCount,
                chargedMoveCount: rowBase.chargedMoveCount,
                targetScore: targetScore(for: task, base: rowBase),
                targetConfidence: targetConfidence(base: rowBase)
            )
        }
    }

    private func trainRegressor(
        task: PremiumInsightTask,
        csvURL: URL,
        modelURL: URL,
        catalog: Catalog,
        modelVersion: String
    ) throws -> PremiumInsightMetrics {
        let table = try MLDataTable(contentsOf: csvURL)
        let (trainingData, validationData) = table.randomSplit(by: 0.8, seed: 21)
        let regressor = try MLRegressor(
            trainingData: trainingData,
            targetColumn: targetColumn,
            featureColumns: featureColumns
        )
        let evaluation = regressor.evaluation(on: validationData)
        if fileManager.fileExists(atPath: modelURL.path()) {
            try fileManager.removeItem(at: modelURL)
        }
        try regressor.write(to: modelURL, metadata: MLModelMetadata(
            author: "IV League",
            shortDescription: "Premium Insight \(task.rawValue) model trained from PvPoke data.",
            license: nil,
            version: modelVersion,
            additional: [
                "modelId": modelId,
                "schemaVersion": String(schemaVersion),
                "dataVersion": catalog.version,
                "sourceCommit": catalog.sourceCommit,
                "bundleHash": catalog.bundleHash,
                "generatedAt": catalog.generatedAt
            ]
        ))
        return PremiumInsightMetrics(
            rowCount: table.rows.count,
            rootMeanSquaredError: evaluation.isValid ? evaluation.rootMeanSquaredError : nil,
            maximumError: evaluation.isValid ? evaluation.maximumError : nil
        )
    }

    private func writeCSV(rows: [TrainingRow], to url: URL) throws {
        let header = (featureColumns + [targetColumn, confidenceColumn]).joined(separator: ",")
        let body = rows.map { $0.csvValues.joined(separator: ",") }.joined(separator: "\n")
        try "\(header)\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try Data("\n".utf8).append(to: url)
    }

    private func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func cpCap(from url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("rankings-") else { return nil }
        return Int(name.dropFirst("rankings-".count))
    }

    private func category(from url: URL) -> String? {
        let components = url.pathComponents
        guard let rankingsIndex = components.lastIndex(of: "rankings"),
              components.count > rankingsIndex + 2 else {
            return nil
        }
        return components[rankingsIndex + 2]
    }
}

private struct RowBase {
    let cpCap: Double
    let rankIndex: Double
    let rating: Double
    let score: Double
    let roleScore: Double
    let matchupCount: Double
    let matchupMean: Double
    let counterCount: Double
    let counterMean: Double
    let movesetCount: Double
    let chargedMoveCount: Double
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}

private func printUsage() {
    print("""
    PremiumInsightTrainer

    Required:
      --data-root <path>   Usually src/data
      --catalog <path>     Usually dist/v1/catalog.json
      --output <path>      Output directory for ml/current and ml/versions artifacts

    Optional:
      --dry-run            Build datasets and manifest shape without training Create ML models
    """)
}

private func numeric(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
        value
    case let value as Int:
        Double(value)
    case let value as NSNumber:
        value.doubleValue
    case let value as String:
        Double(value)
    default:
        nil
    }
}

private func ratings(from value: Any?) -> [Double] {
    guard let rows = value as? [[String: Any]] else { return [] }
    return rows.compactMap { numeric($0["rating"]) }
}

private func mean(_ values: [Double]) -> Double {
    guard values.isEmpty == false else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

private func roleScore(_ category: String) -> Double {
    switch category {
    case "leads":
        0.9
    case "switches", "safe-switches":
        0.8
    case "closers":
        0.7
    case "attackers":
        0.6
    case "consistency":
        0.5
    case "chargers":
        0.4
    default:
        0.65
    }
}

private func targetScore(for task: PremiumInsightTask, base: RowBase) -> Double {
    switch task {
    case .matchupImpact:
        return clamped(abs(base.matchupMean - base.counterMean) / 10 + base.score * 0.45, min: 0, max: 100)
    case .teamOptimizer:
        return clamped(base.score * 0.7 + base.roleScore * 30, min: 0, max: 100)
    case .draftSimulator:
        return clamped(base.score * 0.55 + base.rating / 20 + base.roleScore * 15, min: 0, max: 100)
    case .metaTrend:
        return clamped(100 - log10(base.rankIndex + 1) * 22 + base.score * 0.2, min: 0, max: 100)
    case .battleFrontier:
        return clamped(base.score * 0.5 + base.matchupMean / 20 + base.counterMean / 25, min: 0, max: 100)
    case .cupReadiness:
        return clamped(base.score * 0.65 + min(base.chargedMoveCount, 4) * 5 + base.movesetCount * 3, min: 0, max: 100)
    case .buildPlanner:
        return clamped(base.score * 0.6 + (base.cpCap >= 10000 ? 8 : 0) + min(base.movesetCount, 3) * 4, min: 0, max: 100)
    case .scanInbox:
        return clamped(base.score * 0.75 + min(base.matchupCount, 5) * 2, min: 0, max: 100)
    case .battleLog:
        return clamped(base.score * 0.5 + (500 - abs(base.matchupMean - 500)) / 10, min: 0, max: 100)
    }
}

private func targetConfidence(base: RowBase) -> Double {
    let evidence = min(base.matchupCount + base.counterCount, 10) / 10
    let moveCoverage = min(base.movesetCount, 3) / 3
    return clamped(0.4 + evidence * 0.4 + moveCoverage * 0.2, min: 0, max: 1)
}

private func clamped(_ value: Double, min lower: Double, max upper: Double) -> Double {
    Swift.max(lower, Swift.min(upper, value))
}

private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    try PremiumInsightTrainer().run(options: options)
} catch let error as TrainerError {
    FileHandle.standardError.write(Data("\(error.description)\n".utf8))
    printUsage()
    Foundation.exit(2)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    Foundation.exit(1)
}
