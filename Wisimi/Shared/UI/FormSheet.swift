import SwiftUI

struct SheetSubmit {
    let title: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void
}

extension View {
    /// 错误固定在弹层底部，长列表滚动时也可见。
    func sheetErrorBar(_ message: String?) -> some View {
        safeAreaInset(edge: .bottom) {
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
            }
        }
    }
}

/// 弹层外壳：统一行内标题、工具栏和底部错误。
struct FormSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var submit: SheetSubmit?
    var errorMessage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            Form(content: content)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .sheetErrorBar(errorMessage)
                .toolbar {
                    if let submit {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(action: submit.action) {
                                if submit.isLoading {
                                    ProgressView()
                                } else {
                                    Text(submit.title)
                                }
                            }
                            .disabled(submit.isLoading || submit.isDisabled)
                        }
                    } else {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { dismiss() }
                        }
                    }
                }
        }
    }
}
