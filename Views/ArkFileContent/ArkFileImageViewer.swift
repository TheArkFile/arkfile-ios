// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#if os(iOS)
import SwiftUI
import UIKit

enum ArkFileImageZoom {
    static let initialScale: CGFloat = 1
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 128
    static let zoomInMultiplier: CGFloat = 1.6
    static let zoomOutMultiplier: CGFloat = 0.75
}

struct ArkFileImageViewer: View {
    let url: URL
    let title: String
    let controller: ArkFileImageReaderController
    @State private var imageSource: ArkFileImageSource?
    @State private var failedToLoad = false

    var body: some View {
        Group {
        if let imageSource {
            ArkFileZoomableImageView(source: imageSource, title: title, controller: controller)
                .ignoresSafeArea(edges: .bottom)
        } else if failedToLoad {
            Message(text: LocalString.arkfile_content_viewer_image_error)
        } else {
            LoadingDataView()
        }
        }
        .task(id: url) {
            imageSource = nil
            failedToLoad = false
            let loadedSource = await Task.detached(priority: .userInitiated) {
                ArkFileImageSource.load(at: url)
            }.value
            guard !Task.isCancelled else { return }
            imageSource = loadedSource
            failedToLoad = loadedSource == nil
        }
    }
}

struct ArkFileImageSource: @unchecked Sendable {
    let image: UIImage
    let pixelSize: CGSize
    private let readLease: ArkFileDirectReadLease?

    /// Preserve the original map pixels, matching ArkFile's pre-optimization
    /// renderer. UIImage keeps compressed file-backed image data lazy, while a
    /// single UIImageView avoids the concurrent full-image decodes that made
    /// the short-lived CATiledLayer implementation exhaust device memory.
    nonisolated static func load(at url: URL) -> ArkFileImageSource? {
        guard let readLease = ArkFileInstalledContentAccess.acquireDirectReadLease(for: url),
              let image = UIImage(contentsOfFile: readLease.url.fileSystemPath) else {
            return nil
        }
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        return ArkFileImageSource(
            image: image,
            pixelSize: pixelSize,
            readLease: readLease
        )
    }
}

@MainActor
final class ArkFileImageReaderController: ObservableObject {
    weak var scrollView: UIScrollView?

    func attach(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
    }

    func zoomOut() {
        guard let scrollView else { return }
        let targetScale = max(scrollView.minimumZoomScale, scrollView.zoomScale * ArkFileImageZoom.zoomOutMultiplier)
        scrollView.setZoomScale(targetScale, animated: true)
    }

    func zoomIn() {
        guard let scrollView else { return }
        let targetScale = min(scrollView.maximumZoomScale, scrollView.zoomScale * ArkFileImageZoom.zoomInMultiplier)
        scrollView.setZoomScale(targetScale, animated: true)
    }

    func scrollToTop() {
        scrollView?.setContentOffset(.zero, animated: true)
    }
}

private struct ArkFileZoomableImageView: UIViewRepresentable {
    let source: ArkFileImageSource
    let title: String
    let controller: ArkFileImageReaderController

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = ArkFileImageZoom.minimumScale
        scrollView.maximumZoomScale = ArkFileImageZoom.maximumScale
        scrollView.zoomScale = ArkFileImageZoom.initialScale
        scrollView.backgroundColor = .systemBackground
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let imageView = UIImageView(image: source.image)
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityLabel = title
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        controller.attach(scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        controller.attach(scrollView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}
#endif
