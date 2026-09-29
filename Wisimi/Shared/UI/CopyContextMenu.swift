import SwiftUI
import UIKit

extension View {
    func copyContextMenu(_ text: String, label: String) -> some View {
        contextMenu {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("复制\(label)", systemImage: "doc.on.doc")
            }
        }
    }
}
