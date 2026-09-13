// OnionSkinRendering.swift
//
// Shared, platform-independent onion-skin state used by the canvas renderers.

import Foundation

/// The frame selection and settings that determine the onion-skin layers.
/// Keeping this separate from CALayer/NSView/UIKit code makes invalidation
/// behavior testable on every platform.
struct OnionSkinRenderState: Equatable {
    let currentFrame: Int
    let frameCount: Int
    let enabled: Bool
    let frameCountToShow: Int
    let opacity: Double

    var previousFrame: Int? {
        guard enabled, currentFrame > 0, currentFrame < frameCount else { return nil }
        return currentFrame - 1
    }

    var olderPreviousFrame: Int? {
        guard enabled, frameCountToShow >= 2, currentFrame > 1, currentFrame < frameCount else { return nil }
        return currentFrame - 2
    }

    func needsRedraw(comparedTo previous: OnionSkinRenderState?) -> Bool {
        self != previous
    }
}
