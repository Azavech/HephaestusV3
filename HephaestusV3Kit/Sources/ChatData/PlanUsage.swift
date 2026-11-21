import FileStorage
import Foundation
import MCPKit
import ProjectData

/// `<data folder>/plan-usage.yml`: the newest weekly usage of the Claude account, which the CLI reports in any
/// chat with a `rate_limit_event` line (docs/data.md › Plan usage file). The status bar shows it
/// (docs/ui/navigation.md › Weekly usage). V2's file without its `received`.
public struct PlanUsage: Codable, Sendable, Hashable {
    public var schema: Int
    /// The part of the week's limit used: 0 or more, usually up to 1; more than 1 past the limit.
    public var utilization: Double
    /// When the weekly window resets: from then on the value isn't shown.
    public var resetsAt: Date
    /// The CLI's `status`, for the window that limits the account now: `allowed`, `allowed_warning` or `rejected`.
    public var status: String
    /// The CLI's `overageStatus`, such as `rejected`.
    public var overageStatus: String?
    /// The CLI's `overageDisabledReason`, such as `out_of_credits`.
    public var overageDisabledReason: String?
    public var isUsingOverage: Bool?
    public var unknownKeys: YAMLMapping

    public init(schema: Int = 1, utilization: Double, resetsAt: Date, status: String, overageStatus: String? = nil,
                overageDisabledReason: String? = nil, isUsingOverage: Bool? = nil, unknownKeys: YAMLMapping = [:]) {
        self.schema = schema
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.status = status
        self.overageStatus = overageStatus
        self.overageDisabledReason = overageDisabledReason
        self.isUsingOverage = isUsingOverage
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "utilization", "resetsAt", "status", "overageStatus", "overageDisabledReason",
                                         "isUsingOverage"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        utilization = try c.required("utilization")
        guard utilization.isFinite, utilization >= 0 else { throw c.invalid("utilization", "use a number of 0 or more") }
        resetsAt = try c.requiredDate("resetsAt")
        status = try c.required("status")
        overageStatus = try c.optional("overageStatus")
        overageDisabledReason = try c.optional("overageDisabledReason")
        isUsingOverage = try c.optional("isUsingOverage")
        for (key, value) in [("status", status), ("overageStatus", overageStatus), ("overageDisabledReason", overageDisabledReason)] {
            guard let value else { continue }
            guard Self.isLine(value) else { throw c.invalid(key, "use one line that isn't empty") }
        }
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        // Swift's shortest form, `0.68`, where Yams would write `6.8e-1`.
        try c.encode(RawYAML.scalar(RawYAML.Scalar(utilization.description, tag: "tag:yaml.org,2002:float", style: .plain)), "utilization")
        try c.encodeDate(resetsAt, "resetsAt")
        try c.encode(status, "status")
        try c.encodeOptional(overageStatus, "overageStatus")
        try c.encodeOptional(overageDisabledReason, "overageDisabledReason")
        try c.encodeOptional(isUsingOverage, "isUsingOverage")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// True from the reset time on: the value isn't shown.
    public func hasExpired(at now: Date) -> Bool {
        resetsAt <= now
    }

    /// The same report: every value but the unknown keys.
    func reports(sameAs other: PlanUsage) -> Bool {
        var other = other
        other.unknownKeys = unknownKeys
        return self == other
    }

    /// The report of a `rate_limit_event` line's `rate_limit_info` (docs/data.md › Stream mapping): nil without the
    /// weekly window's `utilization`, 0 or more, and `resetsAt`, or without a `status` of one line. The five-hour
    /// window and the others aren't read.
    static func report(_ info: JSONValue?) -> PlanUsage? {
        func line(_ value: JSONValue?) -> String? {
            guard let text = value?.stringValue, isLine(text) else { return nil }
            return text
        }
        guard let info = info?.objectValue, let week = info["unifiedWindows"]?["seven_day"],
              let utilization = week["utilization"]?.doubleValue, utilization.isFinite, utilization >= 0,
              let resetsAt = week["resetsAt"]?.doubleValue, resetsAt.isFinite,
              let status = line(info["status"]) else { return nil }
        return PlanUsage(utilization: utilization, resetsAt: Date(timeIntervalSince1970: resetsAt).truncatedToSeconds, status: status,
                         overageStatus: line(info["overageStatus"]), overageDisabledReason: line(info["overageDisabledReason"]),
                         isUsingOverage: info["isUsingOverage"]?.boolValue)
    }

    /// One line that isn't empty.
    private static func isLine(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(where: \.isNewline)
    }
}

extension DataFolder {
    /// `plan-usage.yml`: the Claude plan's newest weekly usage.
    public var planUsageFile: URL { url.appendingPathComponent("plan-usage.yml") }

    /// The kept weekly usage: nil when the file is missing; an invalid file is set aside as `plan-usage.yml.invalid`
    /// and gives nil.
    func readPlanUsage() -> PlanUsage? {
        do {
            return try YAMLFile.read(PlanUsage.self, at: planUsageFile)
        } catch {
            if case .invalidFile = error {
                let aside = invalidCopy(of: planUsageFile)
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: planUsageFile, to: aside)
            }
            return nil
        }
    }
}

extension ChatSession {
    /// A chat's CLI reported the weekly usage: a report that differs from the kept value replaces it, then the file
    /// is written with the kept value's unknown keys; an equal one changes nothing. A failed write keeps the value.
    func receive(planUsage report: PlanUsage) {
        if let kept = planUsage, kept.reports(sameAs: report) { return }
        var usage = report
        usage.unknownKeys = planUsage?.unknownKeys ?? [:]
        planUsage = usage
        guard let folder = projects.dataFolder else { return }
        try? YAMLFile.write(usage, to: folder.planUsageFile)
    }
}
