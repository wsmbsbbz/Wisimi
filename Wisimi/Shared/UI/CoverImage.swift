import SwiftUI

struct CoverImage: View {
    enum ContentMode {
        case fill
        case fit
    }

    let url: URL?
    let cornerRadius: CGFloat
    var size: CGSize? = nil
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                if contentMode == .fill {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    image
                        .resizable()
                        .scaledToFit()
                }
            case .failure:
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }
        .frame(width: size?.width, height: size?.height)
        .frame(maxWidth: size == nil ? .infinity : nil)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .clipped()
    }
}
