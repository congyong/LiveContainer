//
//  LCScreenshot.swift
//  LiveContainerSwiftUI
//
//  把视图渲成 JPEG 回传给调用方（AI 看图判断更省事，比让模型猜布局靠谱）。
//  drawHierarchy 拿到的是屏幕上的真实合成结果；拿不到时退回 layer.render。
//

import UIKit

enum LCScreenshot {

    /// - Parameters:
    ///   - maxWidth: 超过就等比缩小（省带宽，AI 也不需要原分辨率）
    ///   - quality: JPEG 质量 0–1
    static func jpeg(of view: UIView, maxWidth: CGFloat = 1290, quality: CGFloat = 0.7) -> Data? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { ctx in
            let drew = view.drawHierarchy(in: bounds, afterScreenUpdates: false)
            if !drew {
                view.layer.render(in: ctx.cgContext)
            }
        }

        let target: UIImage
        if bounds.width > maxWidth {
            let scale = maxWidth / bounds.width
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let f = UIGraphicsImageRendererFormat.default()
            f.scale = 1
            target = UIGraphicsImageRenderer(size: size, format: f).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            target = image
        }
        return target.jpegData(compressionQuality: quality)
    }

    /// windowId 为空时截当前 key window（整个 LiveContainer 界面）
    @MainActor
    static func capture(windowId: String?, maxWidth: CGFloat, quality: CGFloat) -> Data? {
        guard let view = LCWindowManager.captureView(windowId) else { return nil }
        return jpeg(of: view, maxWidth: maxWidth, quality: quality)
    }
}
