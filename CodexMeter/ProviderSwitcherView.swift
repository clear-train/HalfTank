import SwiftUI

/// Source switcher for the popover header.
///
/// A pill of segments is the clearest affordance while only a few quota sources
/// exist, and the sliding highlight makes the switch legible. Past three sources
/// the segments stop fitting the popover width, so the same control collapses
/// into a menu instead of compressing labels into unreadable stubs.
struct ProviderSwitcherView: View {
    let accounts: [StoredQuotaAccount]
    let selectionID: String
    let title: (StoredQuotaAccount) -> String
    let select: (String) -> Void

    /// Segments need roughly this much width per source before the labels start
    /// truncating at the popover's fixed content width.
    private static let segmentedLimit = 3

    @Namespace private var highlight

    private var usesMenu: Bool { accounts.count > Self.segmentedLimit }

    private var selectedAccount: StoredQuotaAccount {
        accounts.first { $0.id == selectionID } ?? StoredQuotaAccount.defaultAccount()
    }

    var body: some View {
        Group {
            if usesMenu {
                menuSwitcher
            } else {
                segmentedSwitcher
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("settings.provider.source"))
    }

    // MARK: - Segmented form

    private var segmentedSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(accounts) { account in
                segment(for: account)
            }
        }
        .padding(3)
        .modifier(GlassCapsuleBackground())
        .animation(.easeInOut(duration: 0.2), value: selectionID)
    }

    private func segment(for account: StoredQuotaAccount) -> some View {
        let isSelected = account.id == selectionID
        return Button {
            guard !isSelected else { return }
            select(account.id)
        } label: {
            Text(title(account))
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(.primary.opacity(0.12))
                            .matchedGeometryEffect(id: "provider-selection", in: highlight)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Menu form

    private var menuSwitcher: some View {
        Menu {
            ForEach(accounts) { account in
                let isSelected = account.id == selectionID
                Button {
                    guard !isSelected else { return }
                    select(account.id)
                } label: {
                    if isSelected {
                        Label(title(account), systemImage: "checkmark")
                    } else {
                        Text(title(account))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(selectedAccount))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(GlassCapsuleBackground())
    }
}

/// Rounded glass surface shared by both switcher forms: native Liquid Glass on
/// macOS 26, material plus a hairline edge on earlier supported systems.
private struct GlassCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}
