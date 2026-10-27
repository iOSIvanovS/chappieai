// PDFToolsRoutingTests.swift
//
// The app side of the PDF tools: every other reader refuses a PDF and points to the pdf_* tools,
// the pdf tools are classified (deny by default) and show up in the tool list, and they check the
// mandatory page before any round trip to the helper.

import Testing
import Foundation
@testable import ChappieCore

struct PDFToolsRoutingTests {

    private func makeService(root: URL) async -> ToolExecutionService {
        let service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaces: [(name: "P", url: root)]),
            memoryManager: MemoryManager(workspaceURL: root),
            socketPath: "/tmp/chappie-pdf-tests-nonexistent.sock"
        )
        let info = ActiveMemoryContext.ProjectInfo(id: UUID(), name: "P")
        let settings = ProjectSettings(agentRole: .executor, isProgrammingProject: true, devEnvironment: .xcode)
        await service.setMemoryContextAndSettings(
            context: ActiveMemoryContext(threadId: UUID(), projects: [info], threadTerminalAccess: .none),
            settings: [info.id: settings]
        )
        return service
    }

    private func call(_ tool: String, _ json: String) -> AIToolCall {
        AIToolCall(id: "t1", type: "function", function: AIToolCallFunction(name: tool, arguments: json))
    }

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Classification

    @Test func pdfToolsAreClassifiedAndExposed() async throws {
        for name in PDFGuidance.toolNames {
            #expect(ToolPolicy.capability(of: name) != nil, "\(name) has no row in ToolPolicy")
        }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = await makeService(root: root)
        let tools = await service.availableTools.map(\.function.name)
        for name in PDFGuidance.toolNames { #expect(tools.contains(name), "\(name) is not offered to the model") }
    }

    @Test func pageIsRequiredForTextAndImageButNotForInfo() async throws {
        let tools = await makeServiceTools()
        let text = try #require(tools.first { $0.function.name == "pdf_page_as_txt" })
        let image = try #require(tools.first { $0.function.name == "pdf_page_as_image" })
        let info = try #require(tools.first { $0.function.name == "pdf_info" })
        #expect((text.function.parameters.required ?? []).contains("page"))
        #expect((image.function.parameters.required ?? []).contains("page"))
        #expect(!(info.function.parameters.required ?? []).contains("page"))
    }

    private func makeServiceTools() async -> [AITool] {
        let root = FileManager.default.temporaryDirectory
        let service = await makeService(root: root)
        return await service.availableTools
    }

    // MARK: - Other readers refuse a PDF

    @Test func readFileReadDocumentAndSearchRefuseAPDF() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("%PDF-1.4".utf8).write(to: root.appendingPathComponent("a.pdf"))
        let service = await makeService(root: root)

        for (tool, json) in [
            ("read_file", #"{"path":"a.pdf","project":"P"}"#),
            ("read_document", #"{"path":"a.pdf","project":"P"}"#),
            ("search_in_file", #"{"path":"a.pdf","query":"x","project":"P"}"#),
        ] {
            let result = await service.execute(call: call(tool, json))
            #expect(result.contains("pdf_info") && result.contains("pdf_page_as_txt"), "\(tool): \(result)")
            #expect(result.contains("does not read PDF"), "\(tool): \(result)")
        }
    }

    @Test func refusalOfAnAttachmentCarriesItsUUID() {
        let uuid = UUID().uuidString
        let message = PDFGuidance.refusal(tool: "fetch_attachment", attachmentUUID: uuid)
        #expect(message.contains(uuid))
        #expect(PDFGuidance.refusal(tool: "read_file").contains("path"))
    }

    @Test func pdfDetectionIsByExtensionAndCaseInsensitive() {
        #expect(PDFGuidance.isPDF(path: "a.pdf"))
        #expect(PDFGuidance.isPDF(path: "dir/Report.PDF"))
        #expect(!PDFGuidance.isPDF(path: "a.pdf.txt"))
        #expect(!PDFGuidance.isPDF(path: "pdf"))
    }

    // MARK: - Arguments checked before the helper is called

    @Test func missingPageIsRefusedWithoutTheHelper() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = await makeService(root: root)   // the socket does not exist: any helper call would fail differently

        for tool in ["pdf_page_as_txt", "pdf_page_as_image"] {
            let result = await service.execute(call: call(tool, #"{"path":"a.pdf","project":"P"}"#))
            #expect(result.contains("'page' is required"), "\(tool): \(result)")
        }
    }

    @Test func aNonPDFPathAndAMissingSourceAreRefused() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = await makeService(root: root)

        let notPDF = await service.execute(call: call("pdf_info", #"{"path":"a.txt","project":"P"}"#))
        #expect(notPDF.contains("not a .pdf"))
        let nothing = await service.execute(call: call("pdf_info", #"{}"#))
        #expect(nothing.contains("'path'") && nothing.contains("'uuid'"))
        let badUUID = await service.execute(call: call("pdf_info", #"{"uuid":"nope"}"#))
        #expect(badUUID.contains("valid UUID"))
    }

    // MARK: - Page picture travels like an Office picture

    @Test func aPagePictureIsAllowedToCarryImagesAndTheTextIsStillGuarded() {
        #expect(ToolExecutionService.documentImageTools.contains("pdf_page_as_image"))
        let image = ToolImageResult(text: "Page 1", images: [.init(label: "page 1", dataURI: "data:image/jpeg;base64,AAAA")])
        // Encoded once: JSON key order is not stable between two encodings.
        let encoded = image.encoded()
        #expect(OutputGuard.apply(toolName: "pdf_page_as_image", output: encoded) == encoded)

        let huge = ToolImageResult(text: String(repeating: "x", count: OutputGuard.readLimit + 1),
                                   images: [.init(label: "p", dataURI: "data:image/jpeg;base64,AAAA")])
        #expect(OutputGuard.apply(toolName: "pdf_page_as_image", output: huge.encoded()).contains("DATA NOT PASSED"))
    }

    @Test func pdfToolsAreNotMutatingAndGetTheStandardDeadline() {
        for name in PDFGuidance.toolNames {
            #expect(!ToolDeadlines.isMutating(name))
            #expect(ToolDeadlines.seconds(tool: name, arguments: "{}") == ToolDeadlines.standard)
        }
    }
}
