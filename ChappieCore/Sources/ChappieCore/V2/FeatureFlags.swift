// FeatureFlags.swift
// Master switch for the V2 thread-isolation architecture.
//
// HOW TO USE:
//   if FeatureFlags.useThreadIsolationV2 { ... } else { ... }
//
// HOW TO ROLL BACK:
//   Set useThreadIsolationV2 = false — the entire V2 code path goes dark.
//   The old code continues to work as if V2 never existed.
//
// WHEN TO DELETE THIS FILE:
//   After V2 is fully shipped, old code is removed, and the flag is always true —
//   delete this file and all `if FeatureFlags.useThreadIsolationV2` branches.

public enum FeatureFlags {
    // Enables the V2 thread-isolation architecture:
    // - New SwiftData container (V2 stack)
    // - SystemPromptBuilder replaces hardcoded prompt in AIOrchestrator
    // - ToolAccessController replaces static ToolAccessControl
    // - Per-thread ProviderSnapshot instead of global AIProviderStore
    // - UserDefaults replaced by SwiftData for all persistent state
    public static let useThreadIsolationV2: Bool = true
}
