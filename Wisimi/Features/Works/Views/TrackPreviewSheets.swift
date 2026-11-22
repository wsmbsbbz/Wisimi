import SwiftUI
import UIKit

struct ImagePreviewSheet: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ZoomableRemoteImage(url: url)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TextReaderSheet: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var errorMessage: String?
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    ScrollView {
                        Text(text.isEmpty ? "（空文件）" : text)
                            .font(.body)
                            .lineSpacing(6)
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("无法预览文本", systemImage: "doc.text")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") {
                            reloadToken += 1
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let text, !text.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: text)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .task(id: "\(url.absoluteString)-\(reloadToken)") {
            await load()
        }
    }

    private func load() async {
        text = nil
        errorMessage = nil
        do {
            let data = try await Data.load(from: url)
            text = try await Task.detached(priority: .userInitiated) {
                try TrackTextDecoder.decode(data)
            }.value
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ZoomableRemoteImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
            } else if didFail {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        image = nil
        didFail = false
        do {
            let data = try await Data.load(from: url)
            guard !Task.isCancelled else { return }
            guard let loadedImage = UIImage(data: data) else {
                didFail = true
                return
            }
            image = loadedImage
        } catch is CancellationError {
        } catch {
            didFail = true
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView
        scrollView.onLayout = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.layoutImage(in: scrollView)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.imageSize = image.size
        context.coordinator.layoutImage(in: scrollView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        var imageSize: CGSize = .zero
        private var lastImageSize: CGSize = .zero
        private var lastBoundsSize: CGSize = .zero

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        func layoutImage(in scrollView: UIScrollView) {
            guard imageSize.width > 0, imageSize.height > 0, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            guard imageSize != lastImageSize || scrollView.bounds.size != lastBoundsSize else { return }
            let scale = min(scrollView.bounds.width / imageSize.width, scrollView.bounds.height / imageSize.height)
            let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            imageView?.frame = CGRect(origin: .zero, size: fittedSize)
            scrollView.contentSize = fittedSize
            scrollView.zoomScale = 1
            lastImageSize = imageSize
            lastBoundsSize = scrollView.bounds.size
            centerImage(in: scrollView)
        }

        @objc func toggleZoom(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let width = scrollView.bounds.width / 2
                let height = scrollView.bounds.height / 2
                scrollView.zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
            }
        }

        private func centerImage(in scrollView: UIScrollView) {
            let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: verticalInset, right: horizontalInset)
        }
    }

    final class ZoomScrollView: UIScrollView {
        var onLayout: ((UIScrollView) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(self)
        }
    }
}
