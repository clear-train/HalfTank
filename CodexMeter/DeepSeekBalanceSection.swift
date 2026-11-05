import SwiftUI

/// Money-first presentation for a prepaid balance such as DeepSeek's.
///
/// A balance has no reset cycle, so the section leads with the amount and only
/// mentions the ring when the user configured a budget for it.
struct DeepSeekBalanceSection: View {
    let balance: DeepSeekBalanceSnapshot
    let budget: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("balance.title"))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(L10n.format("balance.updated_format", L10n.formattedDateTime(balance.fetchedAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let line = balance.preferred {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(DeepSeekBalanceFormat.amount(line.total, currency: line.currency))
                        .font(.title2.weight(.semibold).monospacedDigit())

                    Text(L10n.string("balance.remaining"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(L10n.format(
                    "balance.breakdown_format",
                    DeepSeekBalanceFormat.amount(line.toppedUp, currency: line.currency),
                    DeepSeekBalanceFormat.amount(line.granted, currency: line.currency)
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)

                if balance.lines.count > 1 {
                    Text(balance.lines
                        .filter { $0.currency != line.currency }
                        .map { DeepSeekBalanceFormat.amount($0.total, currency: $0.currency) }
                        .joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !balance.isAvailable {
                Label(L10n.string("balance.unavailable"), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if budget <= 0 {
                Text(L10n.string("balance.budget_hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
