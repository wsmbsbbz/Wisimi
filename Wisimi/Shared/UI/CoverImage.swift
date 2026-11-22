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
    var placeholderWhenMissing = false
    @State private var localImage: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let url, url.isFileURL {
                if loadedURL != url {
                    ProgressView()
                } else if let localImage {
                    artwork(Image(uiImage: localImage))
                } else {
                    placeholder
                }
            } else if url == nil, placeholderWhenMissing {
                placeholder
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): artwork(image)
                    case .failure: placeholder
                    default: ProgressView()
                    }
                }
            }
        }
        .task(id: url) {
            guard let url, url.isFileURL else {
                localImage = nil
                loadedURL = nil
                return
            }
            let data = try? await Data.load(from: url)
            guard !Task.isCancelled else { return }
            localImage = data.flatMap { UIImage(data: $0) }
            loadedURL = url
        }
        .frame(width: size?.width, height: size?.height)
        .frame(maxWidth: size == nil ? .infinity : nil)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .clipped()
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
    }

    private func artwork(_ image: Image) -> some View {
        image.resizable().aspectRatio(contentMode: contentMode == .fill ? .fill : .fit)
    }
}
