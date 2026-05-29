// ShakeEffect.swift
// Chappie
//
// Reusable spring-shake animation for locked UI elements.
//
// USAGE:
//   .modifier(ShakeOnTap(isLocked: isThinking))
//
// BEHAVIOR:
//   When isLocked == true and the user taps — the view shakes left-right
//   like a spring ("I don't want to be pressed!").
//   When isLocked == false — tap passes through normally (no shake, no intercept).
//
// WHY THIS APPROACH:
//   Replaces the old opacity(0.5) dimming during isThinking.
//   Elements stay fully visible and readable — only blocked taps produce feedback.
//   The shake is short (0.4s), spring-based, and does NOT block the hit area —
//   a transparent overlay intercepts the tap only when locked.

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

/// Modifier that intercepts taps when locked and plays a spring-shake animation.
///
/// - When `isLocked == false`: modifier is invisible — taps pass through to the real button.
/// - When `isLocked == true`: a transparent overlay catches the tap and triggers the shake.
struct ShakeOnTap: ViewModifier {

    /// When true — taps are intercepted and a shake is played instead.
    let isLocked: Bool

    @State private var shakePhase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Apply shake geometry to the wrapped view
            .modifier(ShakeEffect(animatableData: shakePhase))
            // Transparent tap interceptor — only active when locked
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

    /// Intercepts taps when `isLocked == true` and plays a spring-shake animation.
    /// When `isLocked == false` — has zero effect on the view.
    func shakeOnTap(isLocked: Bool) -> some View {
        modifier(ShakeOnTap(isLocked: isLocked))
    }
}
