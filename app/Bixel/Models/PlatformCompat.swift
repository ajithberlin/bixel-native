// PlatformCompat.swift
//
// Cross-platform abstractions bridging AppKit (macOS) and UIKit (iOS/iPadOS).
// Provides unified types and helpers for images, colors, pasteboard operations,
// and PNG generation so domain models and views remain portable.

import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
public typealias PlatformView = NSView
public typealias PlatformViewRepresentable = NSViewRepresentable
public typealias PlatformEdgeInsets = NSEdgeInsets
#elseif os(iOS)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
public typealias PlatformView = UIView
public typealias PlatformViewRepresentable = UIViewRepresentable
public typealias PlatformEdgeInsets = UIEdgeInsets
#endif

// MARK: - PlatformImage Helpers

extension PlatformImage {
    /// Obtains a CGImage representation across macOS and iOS.
    var cgImageRef: CGImage? {
        #if os(macOS)
        return self.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #elseif os(iOS)
        return self.cgImage
        #endif
    }
}

/// Creates a PlatformImage from a CGImage.
func makePlatformImage(cgImage: CGImage) -> PlatformImage {
    #if os(macOS)
    return NSImage(cgImage: cgImage, size: .zero)
    #elseif os(iOS)
    return UIImage(cgImage: cgImage)
    #endif
}

/// Creates a PlatformImage from raw data.
func makePlatformImage(data: Data) -> PlatformImage? {
    #if os(macOS)
    return NSImage(data: data)
    #elseif os(iOS)
    return UIImage(data: data)
    #endif
}

// MARK: - SwiftUI Image Extensions

extension Image {
    /// Renders a platform image (NSImage on macOS, UIImage on iOS) in SwiftUI.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #elseif os(iOS)
        self.init(uiImage: platformImage)
        #endif
    }
}

// MARK: - Cross-Platform PNG Encoding

/// Encodes a CGImage to PNG Data using ImageIO (available on macOS and iOS).
func pngData(from cgImage: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        return nil
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

/// Encodes raw 32-bit RGBA pixel buffer to PNG Data.
func pngData(from pixels: [UInt8], width: Int, height: Int) -> Data? {
    guard let cg = makeCGImage(pixels: pixels, width: width, height: height) else { return nil }
    return pngData(from: cg)
}

// MARK: - PlatformPasteboard

enum PlatformPasteboard {
    static func copy(string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = string
        #endif
    }

    static func copy(pngData: Data) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(pngData, forType: .png)
        #elseif os(iOS)
        UIPasteboard.general.setData(pngData, forPasteboardType: "public.png")
        #endif
    }

    static func pastePNGData() -> Data? {
        #if os(macOS)
        return NSPasteboard.general.data(forType: .png)
        #elseif os(iOS)
        return UIPasteboard.general.data(forPasteboardType: "public.png")
        #endif
    }
}
