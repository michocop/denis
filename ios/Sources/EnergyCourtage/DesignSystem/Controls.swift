import SwiftUI

// MARK: - Segmented control

/// The `Actives | Archivées` picker: a white pill sliding over a grey track,
/// with the selected label in brand blue rather than black.
public struct SegmentedPicker<Value: Hashable>: View {

    /// A named type rather than a tuple: `ForEach` needs an identity, and
    /// Swift has no key paths into tuple members.
    public struct Option: Identifiable {
        public let value: Value
        public let title: String
        public var id: Value { value }

        public init(_ value: Value, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    private let options: [Option]
    @Binding private var selection: Value
    @Namespace private var pill

    public init(selection: Binding<Value>, options: [Option]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(isSelected ? Theme.Palette.brand : Theme.Palette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Theme.Radius.segmentPill,
                                                 style: .continuous)
                                    .fill(Theme.Palette.surface)
                                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.segmented, style: .continuous)
                .fill(Theme.Palette.track)
        )
    }
}

// MARK: - Search field

public struct SearchField: View {
    private let placeholder: String
    @Binding private var text: String

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19))
                .foregroundStyle(Theme.Palette.textSecondary)
            TextField(placeholder, text: $text)
                .font(Theme.Typography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 14)
        .cardSurface(radius: Theme.Radius.field)
    }
}

// MARK: - Status banner

/// The green "Contrat signé. Disponible dans l'onglet Documents" strip.
public struct StatusBanner: View {
    private let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.Palette.successText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.Palette.successSoft)
            )
    }
}

// MARK: - Refresh banner

/// "De nouveaux éléments sont disponibles" + Actualiser.
///
/// The source app truncates this label; here it wraps instead, because a
/// notice the user cannot read is not a notice.
public struct RefreshBanner: View {
    private let action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Text("De nouveaux éléments sont disponibles")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.s)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Actualiser")
                }
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, 12)
                .background(Capsule().fill(Theme.Palette.brand))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .cardSurface(radius: 28)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Buttons

public struct SecondaryActionButton: View {
    private let title: String
    private let systemImage: String?
    private let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.s) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.brand)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .stroke(Theme.Palette.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

public struct PrimaryActionButton: View {
    private let title: String
    private let action: () -> Void
    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                        .fill(Theme.Palette.brand)
                )
        }
        .buttonStyle(.plain)
    }
}

public struct TertiaryActionButton: View {
    private let title: String
    private let action: () -> Void
    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.brand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                        .fill(Theme.Palette.track)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stage comment dialog

/// The centred read-only comment modal. Deliberately not a bottom sheet: the
/// source app dims the screen and floats a card.
public struct StageCommentDialog: View {
    private let stageLabel: String
    private let message: String
    private let onClose: () -> Void

    public init(stageLabel: String, message: String, onClose: @escaping () -> Void) {
        self.stageLabel = stageLabel; self.message = message; self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: Theme.Spacing.l) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.Palette.brand)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Theme.Palette.brandSoft))

                VStack(spacing: 2) {
                    Text("Commentaire pour l'étape")
                    Text("\"\(stageLabel)\"")
                }
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("Message")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    ScrollView {
                        Text(message)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Spacing.l)
                    }
                    .frame(maxHeight: 320)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .fill(Theme.Palette.track)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Text("Fermer")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.button,
                                                 style: .continuous)
                                    .fill(Theme.Palette.brand)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.modal, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .padding(.horizontal, Theme.Spacing.gutter)
        }
        .transition(.opacity)
    }
}

/// Label above a bordered field — the form treatment used throughout the app.
public struct LabelledField<Content: View>: View {
    private let label: String
    private let content: Content

    public init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            content
                .font(Theme.Typography.body)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .stroke(Theme.Palette.hairline, lineWidth: 1)
                )
        }
    }
}
