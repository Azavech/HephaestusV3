import AZDesign
import ChatData
import Foundation
import SwiftUI

/// What the status bar's Weekly usage ring and its popover show of the Claude plan's weekly usage, as V2's
/// (docs/ui/navigation.md › Weekly usage).
struct WeeklyUsage: Equatable {
    enum Level: Equatable {
        /// Under 80 % used.
        case normal
        /// From 80 % used.
        case nearLimit
        /// 100 % used or more, or the CLI's `status` is `rejected`.
        case limited
    }

    /// How much of the ring is filled, 0 to 1.
    let fraction: Double
    /// `utilization` × 100 rounded to the nearest, capped at 100.
    let percentage: Int
    let level: Level
    /// "resets Sun 14:00".
    let resetLine: String
    /// "Overage: rejected · out of credits"; nil when the CLI sent no overage status.
    let overageLine: String?

    /// Nil without a value, or from its reset time on at `now`: the ring is hidden.
    init?(_ usage: PlanUsage?, now: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        guard let usage, !usage.hasExpired(at: now) else { return nil }
        fraction = min(max(usage.utilization, 0), 1)
        percentage = Int((fraction * 100).rounded())
        if usage.status == "rejected" || usage.utilization >= 1 {
            level = .limited
        } else if usage.utilization >= 0.8 {
            level = .nearLimit
        } else {
            level = .normal
        }
        let weekday = Self.weekday(usage.resetsAt, timeZone: timeZone), time = Self.time(usage.resetsAt, locale: locale, timeZone: timeZone)
        resetLine = String(localized: "resets \(weekday) \(time)", bundle: #bundle,
                           comment: "The weekly usage popover: when the week resets, such as resets Sun 14:00")
        if let status = usage.overageStatus {
            var parts = [Self.spaced(status)]
            if let reason = usage.overageDisabledReason { parts.append(Self.spaced(reason)) }
            if usage.isUsingOverage == true {
                parts.append(String(localized: "in use", bundle: #bundle, comment: "The weekly usage popover: the overage is in use"))
            }
            let overage = parts.joined(separator: " · ")
            overageLine = String(localized: "Overage: \(overage)", bundle: #bundle,
                                 comment: "The weekly usage popover: the CLI's overage status, such as Overage: rejected · out of credits")
        } else {
            overageLine = nil
        }
    }

    /// "69% used".
    var percentageLine: String {
        String(localized: "\(percentage)% used", bundle: #bundle, comment: "The weekly usage popover: the part of the week's limit used")
    }

    /// The ring's tooltip and VoiceOver label: "Weekly usage: 69% used".
    var tooltip: String {
        String(localized: "Weekly usage: \(percentage)% used", bundle: #bundle, comment: "The status bar's weekly usage ring, its tooltip")
    }

    /// Green, orange or red, as V2's ring.
    var color: SemanticColor {
        switch level {
        case .normal: .success
        case .nearLimit: .warning
        case .limited: .danger
        }
    }

    /// The weekday abbreviated in English, `Mon` to `Sun`, as the CLI's `/usage` writes it.
    static func weekday(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    /// The time in the Mac's short time format: `14:00`, or `2:00 PM` with a 12-hour clock.
    static func time(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// A CLI value with spaces for underscores: `out_of_credits` → `out of credits`.
    static func spaced(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
    }
}

/// The status bar's Weekly usage item: a 12-point ring filled to the part used, in the level's color, on a `divider`
/// track, as the composer's context ring; a click opens the popover.
struct WeeklyUsageItem: View {
    let usage: WeeklyUsage
    @State private var showsPopover = false

    var body: some View {
        Button { showsPopover = true } label: {
            UsageRing(fraction: usage.fraction, color: usage.color.color)
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .help(usage.tooltip)
        .accessibilityLabel(usage.tooltip)
        .accessibilityIdentifier("statusBar.weeklyUsage")
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            WeeklyUsagePopover(usage: usage)
        }
    }
}

/// A ring 12 points wide, filled clockwise from the top to `fraction`, on a `divider` track.
struct UsageRing: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.divider, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// The weekly usage popover: the title, the percentage, the reset and the overage status.
struct WeeklyUsagePopover: View {
    let usage: WeeklyUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Weekly usage", bundle: #bundle, comment: "The weekly usage popover's title")
                .bold()
            Text(verbatim: usage.percentageLine)
                .monospacedDigit()
            Text(verbatim: usage.resetLine)
            if let overage = usage.overageLine {
                Text(verbatim: overage)
            }
        }
        .font(.callout)
        .foregroundStyle(.textPrimary)
        .padding(12)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statusBar.weeklyUsage.popover")
    }
}

/// A report for the previews: `utilization` used, the week resetting next Sunday at 20:00.
func previewPlanUsage(_ utilization: Double, status: String = "allowed", overageStatus: String? = "rejected",
                      reason: String? = "out_of_credits") -> PlanUsage {
    let sunday = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 20, minute: 0, weekday: 1), matchingPolicy: .nextTime)
        ?? Date().addingTimeInterval(3 * 86_400)
    return PlanUsage(utilization: utilization, resetsAt: sunday, status: status, overageStatus: overageStatus, overageDisabledReason: reason,
                     isUsingOverage: false)
}

#Preview("Weekly Usage Popover", traits: .sizeThatFitsLayout) {
    if let usage = WeeklyUsage(previewPlanUsage(0.685), now: Date()) {
        WeeklyUsagePopover(usage: usage)
    }
}
