import AZDesign
import ChatData
import Foundation
import Testing
@testable import ToolsScenes

/// docs/ui/navigation.md › Weekly usage: the ring, its level and color, the percentage, the tooltip, the popover's
/// lines and when the ring is hidden, as V2's.
@MainActor
@Suite("Weekly usage")
struct WeeklyUsageTests {
    /// Sunday 1 November 2026, 14:00 in Paris.
    let resetsAt = Date(timeIntervalSince1970: 1_793_538_000)
    let paris = TimeZone(identifier: "Europe/Paris")!
    var now: Date { resetsAt.addingTimeInterval(-3_600) }

    func usage(_ utilization: Double, status: String = "allowed", overageStatus: String? = nil, reason: String? = nil,
               inUse: Bool? = nil) -> PlanUsage {
        PlanUsage(utilization: utilization, resetsAt: resetsAt, status: status, overageStatus: overageStatus, overageDisabledReason: reason,
                  isUsingOverage: inUse)
    }

    func shown(_ usage: PlanUsage?, at date: Date? = nil, locale: String = "fr_FR") -> WeeklyUsage? {
        WeeklyUsage(usage, now: date ?? now, locale: Locale(identifier: locale), timeZone: paris)
    }

    @Test("Hidden without a value, and from the reset time on")
    func hidden() {
        #expect(shown(nil) == nil)
        #expect(shown(usage(0.5), at: resetsAt) == nil)
        #expect(shown(usage(0.5), at: resetsAt.addingTimeInterval(1)) == nil)
        #expect(shown(usage(0.5), at: resetsAt.addingTimeInterval(-1)) != nil)
    }

    @Test("Normal under 80 %, near the limit from 80 %, limited at 100 % or rejected; success, warning, danger")
    func levels() throws {
        #expect(try #require(shown(usage(0.79))).level == .normal)
        #expect(try #require(shown(usage(0.8))).level == .nearLimit)
        #expect(try #require(shown(usage(0.99))).level == .nearLimit)
        #expect(try #require(shown(usage(0.85, status: "allowed_warning"))).level == .nearLimit)
        #expect(try #require(shown(usage(1))).level == .limited)
        #expect(try #require(shown(usage(1.04))).level == .limited)
        #expect(try #require(shown(usage(0.3, status: "rejected"))).level == .limited)
        #expect(try #require(shown(usage(0.2))).color == .success)
        #expect(try #require(shown(usage(0.9))).color == .warning)
        #expect(try #require(shown(usage(0.3, status: "rejected"))).color == .danger)
    }

    @Test("The percentage is rounded to the nearest and capped at 100; the ring is at most full")
    func percentage() throws {
        let rounded = try #require(shown(usage(0.685)))
        #expect(rounded.percentage == 69 && rounded.fraction == 0.685)
        #expect(rounded.percentageLine == "69% used")
        #expect(rounded.tooltip == "Weekly usage: 69% used")
        #expect(try #require(shown(usage(0.684))).percentage == 68)
        let over = try #require(shown(usage(1.04)))
        #expect(over.percentage == 100 && over.fraction == 1)
        #expect(try #require(shown(usage(0))).percentageLine == "0% used")
    }

    @Test("The reset line: the weekday in English, the time in the Mac's format and time zone")
    func resetLine() throws {
        #expect(try #require(shown(usage(0.5), locale: "fr_FR")).resetLine == "resets Sun 14:00")
        #expect(try #require(shown(usage(0.5), locale: "en_GB")).resetLine == "resets Sun 14:00")
        let twelveHour = try #require(shown(usage(0.5), locale: "en_US")).resetLine
        #expect(twelveHour.hasPrefix("resets Sun 2:00") && twelveHour.hasSuffix("PM"))
    }

    @Test("The overage line: the CLI's values with spaces, the reason and in use when present")
    func overageLine() throws {
        #expect(try #require(shown(usage(0.5))).overageLine == nil)
        #expect(try #require(shown(usage(0.5, reason: "out_of_credits"))).overageLine == nil, "No status, no line")
        #expect(try #require(shown(usage(0.5, overageStatus: "rejected", reason: "out_of_credits", inUse: false))).overageLine
            == "Overage: rejected · out of credits")
        #expect(try #require(shown(usage(0.5, overageStatus: "allowed_warning", inUse: true))).overageLine == "Overage: allowed warning · in use")
        #expect(try #require(shown(usage(0.5, overageStatus: "allowed"))).overageLine == "Overage: allowed")
    }
}
