import SwiftUI

/// The stats page's first row: time until full, time until empty, and the
/// power flowing right now. Both times always have a card, plugged in or
/// not — each says why when it has no number, rather than disappearing.
struct BatteryTimeCards: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        HStack(spacing: 10) {
            let full = BatteryTime.untilFull(snapshot)
            let empty = BatteryTime.untilEmpty(snapshot)
            StatCard(title: "Until full", value: full.value, detail: full.detail)
            StatCard(title: "Until empty", value: empty.value, detail: empty.detail)
            StatCard(title: "Power",
                     value: power.map { String(format: "%.1f W", $0) } ?? "—",
                     detail: powerDetail)
        }
    }

    /// The Mac's whole draw when the hardware reports it, which is what the
    /// time to empty is computed from; otherwise the pack's own flow.
    private var power: Double? {
        snapshot?.systemLoadWatts ?? snapshot?.watts
    }

    /// Which way the pack's current is flowing. The sign of
    /// `amperageMilliamps` is the source of truth; the label never guesses
    /// from the wattage alone.
    private var powerDetail: String {
        if snapshot?.systemLoadWatts != nil {
            guard let amperage = snapshot?.amperageMilliamps else { return "Mac's draw" }
            if amperage > 0 { return "Mac's draw, charging" }
            if amperage < 0 { return "Mac's draw, on battery" }
            return "Mac's draw, from adapter"
        }
        guard let amperage = snapshot?.amperageMilliamps else { return "Draw unknown" }
        if amperage > 0 { return "Into battery" }
        if amperage < 0 { return "From battery" }
        return "Idle"
    }
}

/// What the two time cards say. Pure, so every state is tested rather than
/// eyeballed: these strings are the page's whole answer to "how long".
enum BatteryTime {

    struct Card: Equatable {
        var value: String
        var detail: String
    }

    static func untilFull(_ snapshot: BatterySnapshot?) -> Card {
        guard let snapshot else { return Card(value: "—", detail: "Battery unavailable") }
        if let minutes = snapshot.timeToFullMinutes {
            return Card(value: formatted(minutes), detail: "Charging")
        }
        if snapshot.isFullyCharged == true { return Card(value: "Full", detail: "Charged") }
        if snapshot.isCharging == true { return Card(value: "—", detail: "Estimating…") }
        if snapshot.isExternalConnected == true {
            // Optimized charging, a charge limit, or a weak adapter: macOS
            // is holding the charge where it is.
            return Card(value: "On hold", detail: "Plugged in, not charging")
        }
        return Card(value: "—", detail: "Not plugged in")
    }

    static func untilEmpty(_ snapshot: BatterySnapshot?) -> Card {
        guard let snapshot else { return Card(value: "—", detail: "Battery unavailable") }
        // Plugged in, the battery is not draining: nothing to estimate.
        if snapshot.isExternalConnected == true {
            return Card(value: "On charger", detail: "Estimates once unplugged")
        }
        if let minutes = snapshot.timeToEmptyMinutes {
            return Card(value: formatted(minutes), detail: "macOS estimate")
        }
        if let minutes = snapshot.estimatedTimeToEmptyMinutes {
            return Card(value: formatted(minutes), detail: "At current use")
        }
        return Card(value: "—", detail: "Estimating…")
    }

    /// Minutes under an hour exactly; past an hour, to the nearest five
    /// minutes, so a live estimate does not tick by a minute on every
    /// sample and claim a precision it does not have.
    static func formatted(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(max(0, minutes))m" }
        let rounded = Int((Double(minutes) / 5).rounded()) * 5
        let remainder = rounded % 60
        return remainder == 0 ? "\(rounded / 60)h" : "\(rounded / 60)h \(remainder)m"
    }
}
