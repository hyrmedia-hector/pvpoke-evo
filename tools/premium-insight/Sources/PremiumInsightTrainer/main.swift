import CryptoKit
import CreateML
import Foundation

private let modelId = "premium-insight-v1"
private let schemaVersion = 1
private let targetColumn = "targetScore"
private let confidenceColumn = "targetConfidence"
private let baseFeatureColumns = [
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
private let scenarioProfileIds = [
    "standardSmart",
    "zeroShield",
    "twoShield",
    "shieldAdvantage",
    "shieldDeficit"
]
private let scenarioFeatureColumns = [
    "scenarioCount",
    "scenarioMeanScore",
    "scenarioFloorScore",
    "scenarioCeilingScore",
    "scenarioAverageVolatility",
    "scenarioAverageWinRate",
    "scenarioWorstTurns",
    "scenarioPacingCounterCount",
    "scenarioWorstResponsePenalty",
    "scenarioShieldDeltaMean",
    "scenarioWorstWinner",
    "scenarioAegislashPressure",
    "scenarioPacingCounterScore"
] + scenarioProfileIds.flatMap { id in
    [
        "scenario_\(id)_score",
        "scenario_\(id)_floor",
        "scenario_\(id)_volatility",
        "scenario_\(id)_winRate",
        "scenario_\(id)_turns",
        "scenario_\(id)_playerShields",
        "scenario_\(id)_opponentShields",
        "scenario_\(id)_shieldDelta",
        "scenario_\(id)_winner",
        "scenario_\(id)_pacingCounter",
        "scenario_\(id)_worstResponsePenalty"
    ]
}
private let featureColumns = baseFeatureColumns + scenarioFeatureColumns
private let draftScenarioOutputNames = [
    "scenarioPriority",
    "shieldReservePressure",
    "pacingCounterRisk",
    "worstResponseRisk"
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
    let features: [String: Double]
    let targetScore: Double
    let targetConfidence: Double

    var csvValues: [String] {
        (
            featureColumns.map { features[$0, default: 0] } + [
            targetScore,
            targetConfidence
            ]
        ).map { String(format: "%.6f", $0) }
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
                additionalOutputNames: task == .draftSimulator ? draftScenarioOutputNames : [],
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
        let counterIds = opponentIds(from: ranking["counters"])
        let moves = ranking["moves"] as? [String: Any]
        let chargedMoves = moves?["chargedMoves"] as? [[String: Any]] ?? []
        let chargedMoveIds = chargedMoves.compactMap { $0["moveId"] as? String }
        let rowBase = RowBase(
            speciesId: (ranking["speciesId"] as? String) ?? "",
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
            chargedMoveCount: Double(chargedMoves.count),
            chargedMoveIds: chargedMoveIds,
            counterIds: counterIds
        )

        return PremiumInsightTask.allCases.map { task in
            let features = featureValues(for: task, base: rowBase)
            return TrainingRow(
                task: task,
                features: features,
                targetScore: targetScore(for: task, base: rowBase, features: features),
                targetConfidence: targetConfidence(for: task, base: rowBase, features: features)
            )
        }
    }

    private func featureValues(for task: PremiumInsightTask, base: RowBase) -> [String: Double] {
        var features: [String: Double] = [
            "cpCap": base.cpCap,
            "rankIndex": base.rankIndex,
            "rating": base.rating,
            "score": base.score,
            "roleScore": base.roleScore,
            "matchupCount": base.matchupCount,
            "matchupMean": base.matchupMean,
            "counterCount": base.counterCount,
            "counterMean": base.counterMean,
            "movesetCount": base.movesetCount,
            "chargedMoveCount": base.chargedMoveCount
        ]

        if task == .draftSimulator {
            features.merge(draftScenarioFeatures(base: base), uniquingKeysWith: { _, rhs in rhs })
        }
        return features
    }

    private func draftScenarioFeatures(base: RowBase) -> [String: Double] {
        let scenarios = draftTrainingScenarios(base: base)
        let scores = scenarios.map(\.score)
        let floors = scenarios.map(\.ratingSwing)
        let volatilities = scenarios.map(\.volatility)
        let worst = scenarios.min(by: { $0.ratingSwing < $1.ratingSwing })
        let aegislashPressure = isAegislash(base.speciesId) ? 1.0 : 0.0
        let pacingCounterScore = pacingCounterScore(base: base)

        var features: [String: Double] = [
            "scenarioCount": Double(scenarios.count),
            "scenarioMeanScore": mean(scores),
            "scenarioFloorScore": floors.min() ?? 0,
            "scenarioCeilingScore": floors.max() ?? 0,
            "scenarioAverageVolatility": mean(volatilities),
            "scenarioAverageWinRate": mean(scenarios.map(\.winRate)),
            "scenarioWorstTurns": Double(scenarios.map(\.turns).max() ?? 0),
            "scenarioPacingCounterCount": Double(scenarios.filter { $0.pacingCounter > 0 }.count),
            "scenarioWorstResponsePenalty": max(0, -(floors.min() ?? 0)),
            "scenarioShieldDeltaMean": mean(scenarios.map(\.shieldDelta)),
            "scenarioWorstWinner": Double(worst?.winner ?? -1),
            "scenarioAegislashPressure": aegislashPressure,
            "scenarioPacingCounterScore": pacingCounterScore
        ]

        for row in scenarios {
            let prefix = "scenario_\(row.id)"
            features["\(prefix)_score"] = row.score
            features["\(prefix)_floor"] = row.ratingSwing
            features["\(prefix)_volatility"] = row.volatility
            features["\(prefix)_winRate"] = row.winRate
            features["\(prefix)_turns"] = Double(row.turns)
            features["\(prefix)_playerShields"] = Double(row.playerShields)
            features["\(prefix)_opponentShields"] = Double(row.opponentShields)
            features["\(prefix)_shieldDelta"] = row.shieldDelta
            features["\(prefix)_winner"] = Double(row.winner)
            features["\(prefix)_pacingCounter"] = row.pacingCounter
            features["\(prefix)_worstResponsePenalty"] = max(0, -row.ratingSwing)
        }
        return features
    }

    private func draftTrainingScenarios(base: RowBase) -> [DraftTrainingScenario] {
        let baseSwing = (base.score - 50) * 3.0
            + (base.matchupMean - 500) * 0.12
            - max(0, 500 - base.counterMean) * 0.10
        let counterPressure = max(0, 500 - base.counterMean)
        let chargedCoverage = min(base.chargedMoveCount, 4) / 4
        let pacingScore = pacingCounterScore(base: base)
        let aegislashPressure = isAegislash(base.speciesId) ? 1.0 : 0.0

        return draftScenarioProfiles.map { profile in
            let shieldDelta = Double(profile.playerShields - profile.opponentShields)
            let shieldSwing = shieldDelta * 55
            let shieldCount = Double(profile.playerShields + profile.opponentShields)
            let zeroShieldAdjustment = profile.id == "zeroShield"
                ? (pacingScore * 35 - aegislashPressure * 45)
                : 0
            let twoShieldAdjustment = profile.id == "twoShield"
                ? (chargedCoverage * 24 + aegislashPressure * 18)
                : 0
            let score = baseSwing + shieldSwing + zeroShieldAdjustment + twoShieldAdjustment
            let volatility = counterPressure * 0.25
                + abs(shieldDelta) * 35
                + (1 - min(base.matchupCount, 5) / 5) * 40
                + (aegislashPressure * (profile.id == "zeroShield" ? 45 : 15))
            let ratingSwing = score - volatility / 2
            let winRate = clamped((score + 250) / 500, min: 0, max: 1)
            let turns = Int(clamped(132 + shieldCount * 10 - pacingScore * 24, min: 80, max: 180).rounded())
            let pacingCounter = score < 0 && (turns <= 120 || volatility >= 100) ? 1.0 : 0.0
            return DraftTrainingScenario(
                id: profile.id,
                playerShields: profile.playerShields,
                opponentShields: profile.opponentShields,
                score: score,
                ratingSwing: ratingSwing,
                volatility: volatility,
                winRate: winRate,
                turns: turns,
                winner: ratingSwing >= 0 ? 0 : 1,
                pacingCounter: pacingCounter
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
    let speciesId: String
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
    let chargedMoveIds: [String]
    let counterIds: [String]
}

private struct DraftScenarioProfile {
    let id: String
    let playerShields: Int
    let opponentShields: Int
}

private struct DraftTrainingScenario {
    let id: String
    let playerShields: Int
    let opponentShields: Int
    let score: Double
    let ratingSwing: Double
    let volatility: Double
    let winRate: Double
    let turns: Int
    let winner: Int
    let pacingCounter: Double

    var shieldDelta: Double {
        Double(playerShields - opponentShields)
    }
}

private let draftScenarioProfiles = [
    DraftScenarioProfile(id: "standardSmart", playerShields: 1, opponentShields: 1),
    DraftScenarioProfile(id: "zeroShield", playerShields: 0, opponentShields: 0),
    DraftScenarioProfile(id: "twoShield", playerShields: 2, opponentShields: 2),
    DraftScenarioProfile(id: "shieldAdvantage", playerShields: 1, opponentShields: 0),
    DraftScenarioProfile(id: "shieldDeficit", playerShields: 0, opponentShields: 1)
]

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

private func opponentIds(from value: Any?) -> [String] {
    guard let rows = value as? [[String: Any]] else { return [] }
    return rows.compactMap { $0["opponent"] as? String }
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

private func targetScore(for task: PremiumInsightTask, base: RowBase, features: [String: Double]) -> Double {
    switch task {
    case .matchupImpact:
        return clamped(abs(base.matchupMean - base.counterMean) / 10 + base.score * 0.45, min: 0, max: 100)
    case .teamOptimizer:
        return clamped(base.score * 0.7 + base.roleScore * 30, min: 0, max: 100)
    case .draftSimulator:
        let scenarioFloor = features["scenarioFloorScore", default: 0]
        let scenarioMean = features["scenarioMeanScore", default: 0]
        let volatility = features["scenarioAverageVolatility", default: 0]
        return clamped(
            50 + scenarioMean / 8 + scenarioFloor / 12 - volatility / 18 + base.roleScore * 12,
            min: 0,
            max: 100
        )
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

private func targetConfidence(for task: PremiumInsightTask, base: RowBase, features: [String: Double]) -> Double {
    let evidence = min(base.matchupCount + base.counterCount, 10) / 10
    let moveCoverage = min(base.movesetCount, 3) / 3
    let baseConfidence = 0.4 + evidence * 0.4 + moveCoverage * 0.2
    guard task == .draftSimulator else {
        return clamped(baseConfidence, min: 0, max: 1)
    }
    let volatilityPenalty = min(features["scenarioAverageVolatility", default: 0] / 500, 0.25)
    let scenarioCoverage = min(features["scenarioCount", default: 0], 5) / 5
    return clamped(baseConfidence + scenarioCoverage * 0.08 - volatilityPenalty, min: 0, max: 1)
}

private func clamped(_ value: Double, min lower: Double, max upper: Double) -> Double {
    Swift.max(lower, Swift.min(upper, value))
}

private func isAegislash(_ speciesId: String) -> Bool {
    normalizedId(speciesId).contains("aegislash")
}

private func pacingCounterScore(base: RowBase) -> Double {
    let chargedMovePressure = base.chargedMoveIds.filter(isPaceChargedMove).isEmpty ? 0.0 : 0.45
    let counterPressure = base.counterIds.contains { normalizedId($0).contains("quagsire") } ? 0.35 : 0
    let moveDepth = min(base.chargedMoveCount, 3) / 3 * 0.20
    return clamped(chargedMovePressure + counterPressure + moveDepth, min: 0, max: 1)
}

private func isPaceChargedMove(_ moveId: String) -> Bool {
    switch normalizedMoveId(moveId) {
    case "AQUA_TAIL", "BODY_SLAM", "BRUTAL_SWING", "FIRE_PUNCH", "FOUL_PLAY", "SURF":
        return true
    default:
        return false
    }
}

private func normalizedId(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: "-", with: "_")
}

private func normalizedMoveId(_ value: String) -> String {
    value.uppercased().replacingOccurrences(of: "-", with: "_")
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
