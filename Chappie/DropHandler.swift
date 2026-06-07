// DropHandler.swift
// Chappie
//
// Handles all drag & drop into the main chat area:
//   1. Regular files from Finder (.fileURL) → attached to message
//   2. Folders from Finder (.folder) → added as projects
//   3. macOS screenshot thumbnails (Cmd+Shift+4) — detected by image typeId + no file-url
//      → loadFileRepresentation writes PNG to temp, we copy it and load as AttachedFile
//
// WHY officeUTTypes: Finder registers Office files with their own UTTypes
// (e.g. org.openxmlformats.wordprocessingml.document) in addition to .fileURL.
// SwiftUI's onDrop(of:) rejects the drop before validateDrop fires if the registered
// types don't match the accepted list — so Office UTTypes must be included explicitly.

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import ChappieCore

// MARK: - Office UTTypes

/// Known Office format UTTypes that Finder registers alongside .fileURL.
/// Required in onDrop(of:) so SwiftUI doesn't reject the drag before validateDrop fires.
let officeUTTypes: [UTType] = [
    UTType("org.openxmlformats.wordprocessingml.document"),
    UTType("org.openxmlformats.spreadsheetml.sheet"),
    UTType("org.openxmlformats.presentationml.presentation"),
    UTType("public.rtf"),
    UTType("com.microsoft.word.doc"),
    UTType("com.microsoft.excel.xls"),
    UTType("com.microsoft.powerpoint.ppt"),
].compactMap { $0 }

// MARK: - SilentDropDelegate

/// Accepts file/folder/screenshot drops silently — no visual overlay.
/// Routes each drop to the appropriate handler closure.
final class SilentDropDelegate: DropDelegate {

    var onFilesDropped: ([NSItemProvider]) -> Void = { _ in }
    var onFoldersDropped: ([NSItemProvider]) -> Void = { _ in }
    var onImageProviders: ([NSItemProvider]) -> Void = { _ in }
    var isThinkingGetter: () -> Bool = { false }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
            || info.hasItemsConforming(to: [.folder])
            || info.hasItemsConforming(to: [.data])
            || info.hasItemsConforming(to: officeUTTypes)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard !isThinkingGetter() else { return false }

        // Collect all providers without duplicates.
        // WHY ObjectIdentifier: NSItemProvider identity via === is unreliable — macOS may
        // vend different wrapper objects for the same underlying drag item when queried
        // with different UTType lists. ObjectIdentifier on the same object instance is stable.
        // We deduplicate by combining both identity AND registered type fingerprint to catch
        // cases where the system returns distinct objects for the same drag item.
        var seen = Set<String>()
        var allProviders: [NSItemProvider] = []

        func addIfNew(_ provider: NSItemProvider) {
            // Fingerprint = sorted registered type identifiers joined — unique per drag item
            let fingerprint = provider.registeredTypeIdentifiers.sorted().joined(separator: "|")
            if seen.insert(fingerprint).inserted {
                allProviders.append(provider)
            }
        }

        for p in info.itemProviders(for: [.fileURL, .folder, .data]) { addIfNew(p) }
        for p in info.itemProviders(for: officeUTTypes) { addIfNew(p) }

        guard !allProviders.isEmpty else { return false }

        var imageProviders: [NSItemProvider] = []
        var fileOrDirProviders: [NSItemProvider] = []

        for provider in allProviders {
            let typeIds = provider.registeredTypeIdentifiers
            let hasFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            let hasFolder  = provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier)
            // Screenshot thumbnail: has image type but no file URL backing
            let hasImage   = typeIds.contains { UTType($0)?.conforms(to: .image) == true }
            // Office file: has one of our known Office UTTypes
            let hasOffice  = typeIds.contains { id in officeUTTypes.contains { $0.identifier == id } }

            if hasImage && !hasFileURL && !hasFolder {
                imageProviders.append(provider)
            } else if hasFileURL || hasFolder || hasOffice {
                fileOrDirProviders.append(provider)
            }
        }

        if !imageProviders.isEmpty {
            onImageProviders(imageProviders)
        }

        if !fileOrDirProviders.isEmpty {
            // Resolve to real URLs first, then route by isDirectory — ground truth, not type hints.
            // WHY: NSItemProvider.registeredTypeIdentifiers often includes BOTH .fileURL and .folder
            // for any filesystem item, so type-based routing misclassifies files as folders.
            Task {
                var fileProviders: [NSItemProvider] = []
                var folderProviders: [NSItemProvider] = []

                for provider in fileOrDirProviders {
                    // Prefer .fileURL; fall back to Office UTType for files Finder registers
                    // only under their own UTType without .fileURL.
                    let typeId: String
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        typeId = UTType.fileURL.identifier
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier) {
                        typeId = UTType.folder.identifier
                    } else if let officeId = provider.registeredTypeIdentifiers.first(where: { id in
                        officeUTTypes.contains { $0.identifier == id }
                    }) {
                        typeId = officeId
                    } else {
                        continue
                    }

                    let url: URL? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, _ in
                            if let data = item as? Data,
                               let resolved = URL(dataRepresentation: data, relativeTo: nil) {
                                continuation.resume(returning: resolved)
                            } else if let resolved = item as? URL {
                                continuation.resume(returning: resolved)
                            } else {
                                continuation.resume(returning: nil)
                            }
                        }
                    }

                    guard let url else { continue }
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

                    if exists && isDir.boolValue {
                        folderProviders.append(provider)
                    } else if exists {
                        fileProviders.append(provider)
                    }
                }

                await MainActor.run {
                    if !folderProviders.isEmpty { self.onFoldersDropped(folderProviders) }
                    if !fileProviders.isEmpty   { self.onFilesDropped(fileProviders) }
                }
            }
        }

        return !imageProviders.isEmpty || !fileOrDirProviders.isEmpty
    }
}

// MARK: - Drop Resolution Helpers

/// Resolves folder providers to URLs and adds them as projects.
func resolveFolderDrop(_ providers: [NSItemProvider], addProject: @escaping (URL) -> Void) {
    Task {
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.folder.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let resolved = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: resolved)
                    } else if let resolved = item as? URL {
                        continuation.resume(returning: resolved)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let url {
                await MainActor.run { addProject(url) }
            }
        }
    }
}

/// Resolves file providers to URLs and appends them to attachments.
func resolveDroppedFiles(_ providers: [NSItemProvider], attachments: Binding<[AttachedFile]>) {
    Task {
        var urls: [URL] = []
        for provider in providers {
            // Prefer .fileURL; fall back to Office UTType if needed
            let typeId: String
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                typeId = UTType.fileURL.identifier
            } else if let officeId = provider.registeredTypeIdentifiers.first(where: { id in
                officeUTTypes.contains { $0.identifier == id }
            }) {
                typeId = officeId
            } else {
                continue
            }

            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, error in
                    guard error == nil else { continuation.resume(returning: nil); return }
                    if let data = item as? Data,
                       let resolved = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: resolved)
                    } else if let resolved = item as? URL {
                        continuation.resume(returning: resolved)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let url { urls.append(url) }
        }

        let fileURLs = urls.filter { url in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return exists && !isDir.boolValue
        }

        await MainActor.run {
            let existingNames = Set(attachments.wrappedValue.map(\.filename))
            let newFiles = fileURLs
                .compactMap { AttachedFile.load(from: $0) }
                .filter { !existingNames.contains($0.filename) }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                attachments.wrappedValue.append(contentsOf: newFiles)
            }
        }
    }
}

/// Handles screenshot thumbnail drops (Cmd+Shift+4).
///
/// WHY loadFileRepresentation: screenshot providers carry raw image data, not a file URL.
/// loadFileRepresentation writes the image to a temp file — we copy it before the callback
/// returns (system deletes the temp file immediately after), then load as AttachedFile.
func resolveImageProviders(_ providers: [NSItemProvider], attachments: Binding<[AttachedFile]>) {
    Task {
        var loaded: [AttachedFile] = []

        for provider in providers {
            let imageTypeId = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            }
            guard let typeId = imageTypeId else { continue }

            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeId) { fileURL, error in
                    guard let fileURL, error == nil else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ChappieShot-\(UUID().uuidString).\(fileURL.pathExtension)")
                    do {
                        try FileManager.default.copyItem(at: fileURL, to: dest)
                        continuation.resume(returning: dest)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }

            if let url {
                if let file = AttachedFile.load(from: url) { loaded.append(file) }
                try? FileManager.default.removeItem(at: url)
            }
        }

        guard !loaded.isEmpty else { return }

        await MainActor.run {
            let existingNames = Set(attachments.wrappedValue.map(\.filename))
            let unique = loaded.filter { !existingNames.contains($0.filename) }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                attachments.wrappedValue.append(contentsOf: unique)
            }
        }
    }
}
