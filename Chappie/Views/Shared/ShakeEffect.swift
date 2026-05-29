// ShakeEffect.swift
// Chappie
//
// Reusable spring-shake animation for locked UI elements.
//
// USAGE:
//   .shakeOnTap(isLocked: isThinking)
//   // Do NOT use .disabled() together — it causes automatic opacity(0.5).
//   // shakeOnTap handles hit-testing suppression internally via allowsHitTesting.
//
// BEHAVIOR:
//   When isLocked == true:
//     - Real button tap is blocked via allowsHitTesting(false).
//     - A transparent overlay on top catches the tap and plays the shake animation.
//     - The element stays fully visible at opacity(1.0).
//   When isLocked == false:
//     - allowsHitTesting(true) — tap reaches the real button normally.
//     - No overlay, no shake, zero visual effect.
//
// WHY NOT .disabled():
//   SwiftUI automatically applies opacity(0.5) to .disabled() views and propagates
//   this through the environment — there is no reliable way to override it from outside.
//   Using allowsHitTesting(false) + overlay achieves the same blocking behavior
//   without any opacity side effects.

import SwiftUI

// MARK: - ShakeEffect

/// Animatable geometry effect that translates the view horizontally.
/// Used by ShakeOnTap to produce the left-right spring wobble.
struct ShakeEffect: GeometryEffect {

    /// Current shake phase — animated from 0 to 1 by SwiftUI.
    var animatableData: CGFloat

    // Total horizontal travel per half-cycle (pixels)
    private let amplitude: CGFloat = 4

    func effectValue(size: CGSize) -> ProjectionTransform {
        // sin curve: starts at 0, peaks at amplitude, returns to 0.
        // Multiplied by a decay envelope so it fades out naturally.
        let decay: CGFloat = 1 - animatableData          // 1 → 0 as animation progresses
        let cycles: CGFloat = 3                           // number of left-right oscillations
        let offset = amplitude * decay * sin(animatableData * .pi * cycles * 2)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

// MARK: - ShakeOnTap ViewModifier

/// Modifier that blocks taps when locked and plays a spring-shake animation.
///
/// Replaces .disabled() to avoid SwiftUI's automatic opacity(0.5) side effect.
/// Uses allowsHitTesting(false) on the real view + a transparent overlay that
/// catches the tap and triggers the shake — keeping the element fully visible.
struct ShakeOnTap: ViewModifier {

    /// When true — real taps are blocked and shake plays on tap.
    let isLocked: Bool

    @State private var shakePhase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Block real taps when locked — no opacity side effect unlike .disabled()
            .allowsHitTesting(!isLocked)
            // Apply shake geometry effect
            .modifier(ShakeEffect(animatableData: shakePhase))
            // Transparent overlay intercepts taps when locked and triggers shake
            .overlay(
                Group {
                    if isLocked {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                triggerShake()
                            }
                    }
                }
            )
    }

    // MARK: - Private

    /// Resets the phase to 0 then animates it to 1 — producing the shake curve.
    private func triggerShake() {
        shakePhase = 0
        withAnimation(.spring(response: 0.4, dampingFraction: 0.3)) {
            shakePhase = 1
        }
    }
}

// MARK: - View Extension

extension View {

    /// Blocks taps when `isLocked == true` and plays a spring-shake animation on tap.
    /// When `isLocked == false` — has zero effect on the view.
    ///
    /// Use this INSTEAD of .disabled() to avoid SwiftUI's automatic opacity(0.5).
    func shakeOnTap(isLocked: Bool) -> some View {
        modifier(ShakeOnTap(isLocked: isLocked))
    }
}
