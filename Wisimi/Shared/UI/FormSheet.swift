import SwiftUI

struct SheetSubmit {
    let title: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void
}

/// 弹层外壳：统一行内标题和工具栏；错误固定在底部，长列表滚动时也可见。
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
                .safeAreaInset(edge: .bottom) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.bar)
                    }
                }
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
