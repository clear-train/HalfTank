import SwiftUI

/// Shows the community's daily reset probability. The disclaimer stays visible in
/// every state because the number is an estimate, never an OpenAI promise.
struct ResetForecastSection: View {
    let forecast: ResetForecast?
    let isLoading: Bool
    let errorMessage: String?
    let onOpenSource: () -> Void

    @State private var isShowingSignalHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let forecast {
                probabilityRow(forecast)
                metaRow(forecast)
                if !forecast.signals.isEmpty {
                    signalRow(forecast.signals)
                }
                disclaimerRow(forecast)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                disclaimerRow(nil)
            } else {
                Text(L10n.string("reset.forecast.loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                disclaimerRow(nil)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(L10n.string("reset.forecast.title"), systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            Button(action: onOpenSource) {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .help(L10n.string("reset.forecast.open_source"))
        }
    }

    private func probabilityRow(_ forecast: ResetForecast) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(forecast.probabilityPercent)%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()

                Text(statusText(forecast))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.55), Color.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geometry.size.width * forecast.probability))
                }
            }
            .frame(height: 6)
            .accessibilityLabel(L10n.format("reset.forecast.probability_format", forecast.probabilityPercent))
        }
    }

    private func statusText(_ forecast: ResetForecast) -> String {
        switch forecast.didResetToday {
        case true:
            return L10n.string("reset.forecast.status.reset_today")
        case false:
            return L10n.string("reset.forecast.status.no_reset_today")
        case nil:
            return ""
        }
    }

    private func metaRow(_ forecast: ResetForecast) -> some View {
        HStack(spacing: 12) {
            if let lastResetAt = forecast.lastResetAt {
                Text(L10n.format("reset.forecast.last_reset_format", Self.dayFormatter.string(from: lastResetAt)))
            }
            if let nextExpectedAt = forecast.nextExpectedAt {
                Text(L10n.format("reset.forecast.next_expected_format", Self.dayFormatter.string(from: nextExpectedAt)))
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func disclaimerRow(_ forecast: ResetForecast?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
            Text(L10n.string("reset.forecast.disclaimer"))
            if let forecast {
                Text("·")
                Text(L10n.format("reset.forecast.updated_format", L10n.formattedTime(forecast.fetchedAt)))
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Keeps the one-line summary compact and puts the explanation behind a
    /// help button. Hovering shows a tooltip and clicking expands the same text,
    /// because menu bar popovers do not always deliver tooltip tracking.
    private func signalRow(_ signals: [ResetForecastSignal]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(signalSummary(signals))
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    isShowingSignalHelp.toggle()
                } label: {
                    Image(systemName: isShowingSignalHelp ? "questionmark.circle.fill" : "questionmark.circle")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .help(signalHelp(signals))
                .accessibilityLabel(L10n.string("reset.forecast.signals.help_accessibility"))

                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if isShowingSignalHelp {
                signalHelpPanel(signals)
            }
        }
    }

    /// Lists every signal with its current value, impact, and meaning.
    private func signalHelpPanel(_ signals: [ResetForecastSignal]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("reset.forecast.signals.help_header"))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(signals) { signal in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(signalName(signal)) \(signal.value) (\(signalImpact(signal)))")
                        .fontWeight(.medium)
                    let helpKey = "reset.forecast.signal.\(signal.key).help"
                    let description = L10n.string(helpKey)
                    if description != helpKey {
                        Text(description)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.caption2)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func signalName(_ signal: ResetForecastSignal) -> String {
        let key = "reset.forecast.signal.\(signal.key)"
        let localized = L10n.string(key)
        return localized == key ? signal.key.capitalized : localized
    }

    private func signalImpact(_ signal: ResetForecastSignal) -> String {
        signal.impactPoints > 0 ? "+\(signal.impactPoints)" : "\(signal.impactPoints)"
    }

    /// Explains what the impact numbers are and what each signal measures.
    private func signalHelp(_ signals: [ResetForecastSignal]) -> String {
        var lines = [L10n.string("reset.forecast.signals.help_header")]
        for signal in signals {
            lines.append("")
            lines.append("\(signalName(signal)) \(signal.value) (\(signalImpact(signal)))")
            let helpKey = "reset.forecast.signal.\(signal.key).help"
            let description = L10n.string(helpKey)
            if description != helpKey {
                lines.append(description)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func signalSummary(_ signals: [ResetForecastSignal]) -> String {
        signals
            .map { signal in
                "\(signalName(signal)) \(signal.value) (\(signalImpact(signal)))"
            }
            .joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}
