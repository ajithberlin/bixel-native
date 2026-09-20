// AnimationExporter.swift
//
// Native GIF and MP4 Video export engine for Bixel Studio animations.
// Uses ImageIO for animated GIFs and AVFoundation for H.264 MP4 videos.

import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum AnimationExporter {
    /// Scale raw pixel array using crisp nearest-neighbor interpolation.
    static func scalePixelsNearestNeighbor(pixels: [UInt8], width: Int, height: Int, scale: Int) -> [UInt8] {
        guard scale > 1, width > 0, height > 0 else { return pixels }
        let outW = width * scale
        let outH = height * scale
        var scaled = [UInt8](repeating: 0, count: outW * outH * 4)
        for y in 0..<outH {
            let srcY = y / scale
            let dstRowOffset = y * outW * 4
            let srcRowOffset = srcY * width * 4
            for x in 0..<outW {
                let srcX = x / scale
                let srcIdx = srcRowOffset + srcX * 4
                let dstIdx = dstRowOffset + x * 4
                scaled[dstIdx] = pixels[srcIdx]
                scaled[dstIdx + 1] = pixels[srcIdx + 1]
                scaled[dstIdx + 2] = pixels[srcIdx + 2]
                scaled[dstIdx + 3] = pixels[srcIdx + 3]
            }
        }
        return scaled
    }

    // MARK: - Animated GIF Export

    /// Generate an animated GIF data buffer from the editor model frames.
    static func generateGIFData(model: EditorModel, scale: Int = 4) -> Data? {
        guard model.frameCount > 0, model.width > 0, model.height > 0 else { return nil }
        let scale = max(1, scale)
        let w = model.width * scale
        let h = model.height * scale

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.gif.identifier as CFString,
            model.frameCount,
            nil
        ) else { return nil }

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0 // Infinite loop
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let defaultDelay = 1.0 / max(1.0, model.fps)

        for i in 0..<model.frameCount {
            let rawPixels = model.compositeFrame(i)
            let scaledPixels = scalePixelsNearestNeighbor(
                pixels: rawPixels,
                width: model.width,
                height: model.height,
                scale: scale
            )
            guard let cgImage = makeCGImage(pixels: scaledPixels, width: w, height: h) else { continue }

            let durationMs = model.document.frameDuration(i)
            let delaySeconds = durationMs > 0 ? Double(durationMs) / 1000.0 : defaultDelay

            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delaySeconds,
                    kCGImagePropertyGIFUnclampedDelayTime: delaySeconds
                ]
            ]
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// Export animated GIF and present the platform-appropriate save panel or share sheet.
    static func exportGIF(model: EditorModel, scale: Int = 4) {
        guard let gifData = generateGIFData(model: model, scale: scale) else {
            model.operationError = "Failed to encode animated GIF."
            return
        }

        let filename = "animation-\(model.width * scale)x\(model.height * scale)@\(scale)x.gif"

        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = filename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try gifData.write(to: url)
            } catch {
                DispatchQueue.main.async { model.operationError = error.localizedDescription }
            }
        }
        #elseif os(iOS)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try gifData.write(to: tempURL)
            shareItems([tempURL])
        } catch {
            model.operationError = error.localizedDescription
        }
        #endif
    }

    // MARK: - Video (MP4) Export

    /// Export an MP4 video of the animation, looping up to `minimumDuration` seconds if needed.
    static func exportVideo(model: EditorModel, scale: Int = 4, minimumDuration: Double = 3.0) {
        guard model.frameCount > 0, model.width > 0, model.height > 0 else {
            model.operationError = "No frames to export."
            return
        }

        let scale = max(1, scale)
        var outW = model.width * scale
        var outH = model.height * scale
        // H.264 requires even dimensions
        if outW % 2 != 0 { outW += 1 }
        if outH % 2 != 0 { outH += 1 }

        let defaultDelay = 1.0 / max(1.0, model.fps)

        // Pre-render scaled CGImages and timings
        var frames: [(image: CGImage, duration: Double)] = []
        var oneLoopDuration: Double = 0
        for i in 0..<model.frameCount {
            let rawPixels = model.compositeFrame(i)
            let scaledPixels = scalePixelsNearestNeighbor(
                pixels: rawPixels,
                width: model.width,
                height: model.height,
                scale: scale
            )
            guard let cg = makeCGImage(pixels: scaledPixels, width: model.width * scale, height: model.height * scale) else { continue }
            let durationMs = model.document.frameDuration(i)
            let duration = durationMs > 0 ? Double(durationMs) / 1000.0 : defaultDelay
            frames.append((cg, duration))
            oneLoopDuration += duration
        }

        guard !frames.isEmpty else {
            model.operationError = "Could not render animation frames for video export."
            return
        }

        // Loop repeats for short animations so they play well on social media & QuickTime
        let loopCount = (minimumDuration > 0 && oneLoopDuration > 0 && oneLoopDuration < minimumDuration)
            ? max(1, Int(ceil(minimumDuration / oneLoopDuration)))
            : 1

        let filename = "animation-\(outW)x\(outH)@\(scale)x.mp4"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try renderMP4(
                    frames: frames,
                    loopCount: loopCount,
                    width: outW,
                    height: outH,
                    outputURL: tempURL
                )

                DispatchQueue.main.async {
                    #if os(macOS)
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.mpeg4Movie]
                    panel.nameFieldStringValue = filename
                    panel.begin { response in
                        guard response == .OK, let destURL = panel.url else {
                            try? FileManager.default.removeItem(at: tempURL)
                            return
                        }
                        do {
                            if FileManager.default.fileExists(atPath: destURL.path) {
                                try FileManager.default.removeItem(at: destURL)
                            }
                            try FileManager.default.moveItem(at: tempURL, to: destURL)
                        } catch {
                            model.operationError = error.localizedDescription
                        }
                    }
                    #elseif os(iOS)
                    let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try? FileManager.default.removeItem(at: finalURL)
                    }
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: finalURL)
                        shareItems([finalURL])
                    } catch {
                        model.operationError = error.localizedDescription
                    }
                    #endif
                }
            } catch {
                DispatchQueue.main.async {
                    model.operationError = "Video encoding failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func renderMP4(
        frames: [(image: CGImage, duration: Double)],
        loopCount: Int,
        width: Int,
        height: Int,
        outputURL: URL
    ) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_500_000, width * height * 8),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else {
            throw NSError(domain: "AnimationExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input."])
        }

        writer.add(writerInput)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "AnimationExporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing video."])
        }

        writer.startSession(atSourceTime: .zero)

        var currentTime = 0.0
        let timeScale: Int32 = 600

        for _ in 0..<loopCount {
            for frame in frames {
                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                }

                guard let pb = createPixelBuffer(from: frame.image, pool: adaptor.pixelBufferPool, width: width, height: height) else {
                    continue
                }

                let cmTime = CMTime(seconds: currentTime, preferredTimescale: timeScale)
                adaptor.append(pb, withPresentationTime: cmTime)
                currentTime += frame.duration
            }
        }

        writerInput.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        var writerError: Error?
        writer.finishWriting {
            if writer.status == .failed {
                writerError = writer.error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let writerError {
            throw writerError
        }
    }

    private static func createPixelBuffer(
        from cgImage: CGImage,
        pool: CVPixelBufferPool?,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        } else {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
        }

        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pb
    }

    #if os(iOS)
    private static func shareItems(_ items: [Any]) {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }

        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(activityVC, animated: true)
    }
    #endif
}
