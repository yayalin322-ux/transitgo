import UIKit

/// Shared JPEG-compress-then-base64-encode step for anything the app lets users attach
/// a photo to (place reviews, user-submitted landmarks) — keeps the encoding and size
/// cap consistent with what the backend's `validPhoto` actually accepts.
enum PhotoUpload {
    /// Downscales to a reasonable max dimension and compresses until under the size cap
    /// (matches the backend's 2,000,000-char data: URI limit), or nil if that's not
    /// achievable (never sends a truncated/corrupt image).
    static func encode(_ image: UIImage, maxDimension: CGFloat = 1280, maxDataURILength: Int = 1_900_000) -> String? {
        let scaled = downscale(image, maxDimension: maxDimension)
        for quality in stride(from: 0.7, through: 0.2, by: -0.1) {
            guard let jpeg = scaled.jpegData(compressionQuality: quality) else { continue }
            let uri = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            if uri.count <= maxDataURILength { return uri }
        }
        return nil
    }

    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

/// Decodes a `data:image/...;base64,...` URI back into a displayable image.
enum DataURIImage {
    static func decode(_ uri: String) -> UIImage? {
        guard let commaIndex = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: commaIndex)...])) else { return nil }
        return UIImage(data: data)
    }
}
