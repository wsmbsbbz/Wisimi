import SwiftUI

enum SelectionRowStyle {
    case single
    case multiple
}

/// Form 中的选择行。使用默认按钮样式，整行（含行内边距）都能点击并显示系统按压高亮。
struct SelectionRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    let isSelected: Bool
    let style: SelectionRowStyle
    var isLoading = false
    let action: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    indicator
                }
                .contentShape(.rect)
            }
            .tint(.primary)
            .disabled(isLoading)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            accessory()
        }
    }

    @ViewBuilder private var indicator: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
        } else {
            switch style {
            case .single:
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            case .multiple:
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension SelectionRow where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        isSelected: Bool,
        style: SelectionRowStyle,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            isSelected: isSelected,
            style: style,
            isLoading: isLoading,
            action: action,
            accessory: { EmptyView() }
        )
    }
}
