import SwiftUI

struct MetricPill: View {
    enum Prominence {
        case subtle
        case strong
    }

    let text: String
    let systemImage: String
    var prominence: Prominence = .subtle

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
            .font(.caption.weight(.medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(prominence == .strong ? .primary : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(prominence == .strong ? .regularMaterial : .thinMaterial, in: .capsule)
            .overlay {
                Capsule()
                    .stroke(.quaternary, lineWidth: 1)
            }
    }
}
