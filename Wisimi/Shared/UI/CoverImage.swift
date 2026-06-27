import SwiftUI

struct CoverImage: View {
    let url: URL?
    let cornerRadius: CGFloat
    var size: CGSize? = nil

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }
        .frame(width: size?.width, height: size?.height)
        .frame(maxWidth: size == nil ? .infinity : nil, maxHeight: size == nil ? .infinity : nil)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .clipped()
    }
}
