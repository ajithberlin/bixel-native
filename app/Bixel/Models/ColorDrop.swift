// ColorDrop.swift
//
// Procreate-style "ColorDrop": drag a color out of the palette and drop it on
// the canvas to flood-fill the connected region under the drop point.
//
// The payload travels as JSON under a private pasteboard type, and the canvas
// views handle the drop natively (AppKit `NSDraggingDestination` on macOS,
// `UIDropInteraction` on iOS) so the drop never competes with the canvas's own
// image-file drag handling.

import Foundation

struct ColorDropPayload: Codable, Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    /// App-private pasteboard/UTI identifier (declared in both Info.plists).
    static let typeIdentifier = "com.bixel.studio.color-drop"

    init(_ color: BixelColor) {
        r = color.r
        g = color.g
        b = color.b
        a = color.a
    }

    var color: BixelColor { BixelColor(r: r, g: g, b: b, a: a) }

    var jsonData: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    init?(jsonData: Data) {
        guard let payload = try? JSONDecoder().decode(ColorDropPayload.self, from: jsonData) else { return nil }
        self = payload
    }
}
