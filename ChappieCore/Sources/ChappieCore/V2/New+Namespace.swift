// New+Namespace.swift
// The `New` enum is a compile-time namespace for all V2 types.
//
// WHY A NAMESPACE:
//   V2 types need the "good" final names (Thread, Project, Provider, etc.)
//   but those names are already taken by V1 types. The `New.` prefix lets us
//   use the right names without renaming V1 — so V1 stays untouched and
//   the feature flag can flip back to it at any moment.
//
// GRADUATION PLAN:
//   When V1 is deleted, remove this file, rename all `New.Foo` → `Foo`,
//   and do a project-wide find-replace of "New." → "".
//
// NEVER instantiate `New` directly — it is a namespace only.

public enum New {}
