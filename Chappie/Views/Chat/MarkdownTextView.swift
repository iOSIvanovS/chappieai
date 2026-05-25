// MarkdownTextView.swift
// Chappie
//
// ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
// Чаппи в ответах активно использует markdown: блоки кода на Swift/bash,
// инлайн-код, жирный текст, заголовки. Стандартный SwiftUI Text не поддерживает
// блоки кода с подсветкой синтаксиса. Этот компонент закрывает этот пробел.
//
// ДИЗАЙН-ФИЛОСОФИЯ (Apple HIG + Xcode Intelligence Panel):
// - Блоки кода: тёмный фон (#1E1E1E), как в Xcode Default Dark theme.
//   Это создаёт чёткий визуальный контраст с обычным текстом.
// - Типографика: SF Pro Text 14pt с lineSpacing 5 — оптимально для чтения
//   длинных технических ответов. Apple рекомендует 1.4–1.6× line-height.
// - Инлайн-код: моноширный шрифт — как в GitHub/Notion.
// - Кнопка копирования в блоке кода — стандарт всех современных IDE и чатов.
//
// АРХИТЕКТУРА ПАРСЕРА:
// Используем простой линейный парсер строк — не RegEx, не AST.
// Причина: Swift-ответы Чаппи имеют предсказуемую структуру.
// Полноценный markdown-парсер (CommonMark) избыточен и добавил бы зависимость.
// Наш парсер обрабатывает:
//   1. Блоки кода: ```язык\n...\n```
//   2. Заголовки: # ## ###
//   3. Жирный: **text**
//   4. Инлайн-код: `code`
//   5. Обычный текст с правильной типографикой
//
// ВАЖНО (macOS 26):
// Оператор `+` для Text deprecated в macOS 26 — вместо него нужно использовать
// Text("\(Text(...).bold())") — строковую интерполяцию SwiftUI.
// Метод buildInlineText() использует именно этот подход.

import SwiftUI

// MARK: - Модель блоков

/// Структурная единица разобранного markdown-текста.
///
/// Весь текст разбивается на последовательность блоков,
/// каждый из которых рендерится своим способом.
private enum MarkdownBlock: Identifiable {
    /// Обычный текст с поддержкой инлайн-разметки (жирный, курсив, инлайн-код)
    case paragraph(String)
    /// Заголовок уровня 1–3
    case heading(String, level: Int)
    /// Блок кода с опциональным языком
    case codeBlock(code: String, language: String?)
    /// Горизонтальный разделитель ---
    case divider

    var id: String {
        switch self {
        case .paragraph(let t): return "p_\(t.prefix(40))"
        case .heading(let t, let l): return "h\(l)_\(t.prefix(40))"
        case .codeBlock(let c, _): return "code_\(c.prefix(40))"
        case .divider: return "div_\(UUID().uuidString)"
        }
    }
}

// MARK: - Парсер Markdown

/// Линейный парсер markdown-текста в последовательность блоков.
///
/// ПОЧЕМУ НЕ AttributedString / markdown init:
/// AttributedString(markdown:) не поддерживает блоки кода с подсветкой синтаксиса.
/// Нам нужен полный контроль над рендером каждого блока.
private struct MarkdownParser {

    /// Разбирает строку markdown на массив блоков.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // --- Блок кода: начинается с ```
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1

                // Собираем строки до закрывающего ```
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                // Пропускаем закрывающий ```
                if i < lines.count { i += 1 }

                let code = codeLines.joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)
                blocks.append(.codeBlock(
                    code: code,
                    language: lang.isEmpty ? nil : lang
                ))
                continue
            }

            // --- Горизонтальный разделитель
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" {
                blocks.append(.divider)
                i += 1
                continue
            }

            // --- Заголовки # ## ###
            if line.hasPrefix("### ") {
                blocks.append(.heading(String(line.dropFirst(4)), level: 3))
                i += 1
                continue
            }
            if line.hasPrefix("## ") {
                blocks.append(.heading(String(line.dropFirst(3)), level: 2))
                i += 1
                continue
            }
            if line.hasPrefix("# ") {
                blocks.append(.heading(String(line.dropFirst(2)), level: 1))
                i += 1
                continue
            }

            // --- Пустая строка: разделитель параграфов
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // --- Обычный параграф: накапливаем соседние строки в один блок.
            // Это важно чтобы не создавать отдельный параграф на каждую строку.
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty
                    || next.hasPrefix("```")
                    || next.hasPrefix("# ")
                    || next.hasPrefix("## ")
                    || next.hasPrefix("### ")
                    || nextTrimmed == "---" {
                    break
                }
                paragraphLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }
}

// MARK: - Главный компонент

/// Рендерит markdown-текст с поддержкой блоков кода, заголовков и инлайн-разметки.
///
/// Используется вместо простого `Text()` в пузырях сообщений Чаппи.
struct MarkdownTextView: View {

    let text: String
    var textColor: Color = .primary
    var fontSize: CGFloat = 14

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Рендер блоков

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let rawText):
            InlineTextView(text: rawText, fontSize: fontSize, color: textColor)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let rawText, let level):
            headingView(text: rawText, level: level)

        case .codeBlock(let code, let language):
            CodeBlockView(code: code, language: language)

        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    // MARK: - Заголовки

    @ViewBuilder
    private func headingView(text: String, level: Int) -> some View {
        switch level {
        case 1:
            InlineTextView(text: text, fontSize: fontSize + 6, color: textColor)
                .fontWeight(.bold)
                .padding(.top, 4)
        case 2:
            InlineTextView(text: text, fontSize: fontSize + 3, color: textColor)
                .fontWeight(.semibold)
                .padding(.top, 2)
        default:
            InlineTextView(text: text, fontSize: fontSize + 1, color: textColor)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Инлайн-текст

/// Рендерит строку с инлайн-разметкой (**bold**, *italic*, `code`).
///
/// ПОЧЕМУ ОТДЕЛЬНЫЙ VIEW (не функция возвращающая Text):
/// В macOS 26 оператор `+` для Text deprecated — Apple рекомендует строковую
/// интерполяцию `Text("\(Text(...).bold())")`. Но этот подход не поддерживает
/// произвольное количество сегментов в цикле.
///
/// РЕШЕНИЕ: используем AttributedString с явными атрибутами шрифта.
/// Это единственный способ надёжно смешивать жирный/курсив/моноширный
/// в одной строке без deprecated API в macOS 26.
private struct InlineTextView: View {

    let text: String
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        Text(buildAttributedString())
            .foregroundStyle(color)
            .textSelection(.enabled)
    }

    /// Строит AttributedString с инлайн-разметкой.
    ///
    /// Порядок обработки важен: ** перед *, чтобы **bold** не путался с *italic*.
    private func buildAttributedString() -> AttributedString {
        var result = AttributedString()
        var remaining = text

        // Базовые атрибуты: шрифт, цвет
        var baseContainer = AttributeContainer()
        baseContainer.font = .system(size: fontSize)

        while !remaining.isEmpty {

            // --- Жирный: **text**
            if let openRange = remaining.range(of: "**"),
               let closeRange = remaining.range(of: "**", range: openRange.upperBound..<remaining.endIndex) {

                // Добавляем текст ДО маркера как обычный
                let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !before.isEmpty {
                    var seg = AttributedString(before)
                    seg.font = .system(size: fontSize)
                    result.append(seg)
                }

                // Добавляем жирный текст
                let boldText = String(remaining[openRange.upperBound..<closeRange.lowerBound])
                var seg = AttributedString(boldText)
                seg.font = .system(size: fontSize, weight: .bold)
                result.append(seg)

                remaining = String(remaining[closeRange.upperBound...])
                continue
            }

            // --- Инлайн-код: `code`
            if let openRange = remaining.range(of: "`"),
               let closeRange = remaining.range(of: "`", range: openRange.upperBound..<remaining.endIndex) {

                let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !before.isEmpty {
                    var seg = AttributedString(before)
                    seg.font = .system(size: fontSize)
                    result.append(seg)
                }

                let codeText = String(remaining[openRange.upperBound..<closeRange.lowerBound])
                var seg = AttributedString(codeText)
                // Моноширный шрифт, чуть меньше — стандарт для инлайн-кода
                seg.font = .system(size: fontSize - 1, design: .monospaced)
                result.append(seg)

                remaining = String(remaining[closeRange.upperBound...])
                continue
            }

            // --- Курсив: *text* (только одиночная звёздочка)
            if let openRange = remaining.range(of: "*"),
               let closeRange = remaining.range(of: "*", range: openRange.upperBound..<remaining.endIndex) {

                // Убеждаемся что это не ** (двойная)
                let nextIdx = remaining.index(after: openRange.lowerBound)
                if nextIdx < remaining.endIndex && remaining[nextIdx] == "*" {
                    // Это ** — добавляем первый символ как обычный и идём дальше
                    var seg = AttributedString(String(remaining[remaining.startIndex...openRange.lowerBound]))
                    seg.font = .system(size: fontSize)
                    result.append(seg)
                    remaining = String(remaining[nextIdx...])
                    continue
                }

                let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !before.isEmpty {
                    var seg = AttributedString(before)
                    seg.font = .system(size: fontSize)
                    result.append(seg)
                }

                let italicText = String(remaining[openRange.upperBound..<closeRange.lowerBound])
                var seg = AttributedString(italicText)
                seg.font = Font.system(size: fontSize).italic()
                result.append(seg)

                remaining = String(remaining[closeRange.upperBound...])
                continue
            }

            // Нет маркеров — весь оставшийся текст обычный
            var seg = AttributedString(remaining)
            seg.font = .system(size: fontSize)
            result.append(seg)
            break
        }

        return result
    }
}

// MARK: - Блок кода

/// Рендерит блок кода в стиле Xcode Intelligence Panel.
///
/// ДИЗАЙН (вдохновлён Xcode 26 Intelligence):
/// - Тёмный фон: #1E1E1E (Xcode Default Dark)
/// - Заголовок: язык слева, кнопка копирования справа
/// - Шрифт: SF Mono 12.5pt — стандарт Xcode
/// - Горизонтальный скролл для длинных строк
/// - Скруглённые углы 8pt — как карточки в macOS 26
struct CodeBlockView: View {

    let code: String
    let language: String?

    @State private var copied = false

    /// Фон блока кода — тёмный в обоих режимах.
    /// Код всегда лучше читается на тёмном фоне (стандарт всех IDE).
    private let codeBackground = Color(red: 0.118, green: 0.118, blue: 0.118) // #1E1E1E

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // --- Заголовок блока кода ---
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.6))
                    .padding(.leading, 12)

                Spacer()

                // Кнопка копирования — стандарт GitHub, Notion, ChatGPT.
                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(copied ? "Скопировано" : "Копировать")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(copied
                        ? Color(red: 0.4, green: 0.8, blue: 0.4)
                        : Color(red: 0.6, green: 0.6, blue: 0.6)
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: copied)
            }
            .padding(.vertical, 4)
            .background(Color(red: 0.145, green: 0.145, blue: 0.145))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(red: 0.25, green: 0.25, blue: 0.25))
                    .frame(height: 1)
            }

            // --- Тело блока кода ---
            // ScrollView по горизонтали для длинных строк — стандарт IDE.
            ScrollView(.horizontal, showsIndicators: false) {
                SyntaxHighlightedText(code: code, language: language)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(4)
                    .padding(12)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .background(codeBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.25, green: 0.25, blue: 0.25), lineWidth: 1)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { copied = false }
        }
    }
}

// MARK: - Подсветка синтаксиса Swift

/// Рендерит код с базовой подсветкой синтаксиса для Swift.
///
/// ЦВЕТОВАЯ СХЕМА (Xcode Default Dark):
/// - Ключевые слова: #FC5FA3 (розово-красный)
/// - Типы/классы: #5DD8FF (голубой)
/// - Строки: #FC6A5D (оранжево-красный)
/// - Числа: #D0BF69 (золотистый)
/// - Комментарии: #6C7986 (серый)
/// - Обычный код: #F8F8F2 (почти белый)
private struct SyntaxHighlightedText: View {

    let code: String
    let language: String?

    var body: some View {
        if language?.lowercased() == "swift" {
            Text(highlightSwift(code))
        } else {
            Text(code)
                .foregroundStyle(Color(red: 0.97, green: 0.97, blue: 0.95))
        }
    }

    private func highlightSwift(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = Color(red: 0.97, green: 0.97, blue: 0.95)

        let keywords = [
            "func", "var", "let", "class", "struct", "enum", "protocol",
            "extension", "import", "return", "if", "else", "guard", "switch",
            "case", "default", "for", "while", "do", "try", "catch", "throw",
            "throws", "async", "await", "actor", "nonisolated", "isolated",
            "public", "private", "internal", "fileprivate", "open",
            "static", "final", "override", "mutating", "nonmutating",
            "init", "deinit", "self", "super", "nil", "true", "false",
            "in", "is", "as", "where", "some", "any", "typealias",
            "@MainActor", "@Observable", "@State", "@Binding", "@Environment",
            "@Published", "@StateObject", "@ObservedObject", "Task", "MainActor"
        ]

        let keywordColor = Color(red: 0.988, green: 0.373, blue: 0.639)
        for keyword in keywords {
            applyColor(keywordColor, toWord: keyword, in: &result)
        }

        applyTypeHighlighting(color: Color(red: 0.365, green: 0.847, blue: 1.0), in: &result)
        applyStringHighlighting(color: Color(red: 0.988, green: 0.416, blue: 0.365), in: &result)
        applyNumberHighlighting(color: Color(red: 0.816, green: 0.749, blue: 0.412), in: &result)
        // Комментарии последними — перекрывают всё остальное внутри себя
        applyCommentHighlighting(color: Color(red: 0.424, green: 0.475, blue: 0.525), in: &result)

        return result
    }

    /// Применяет цвет к точным вхождениям слова с учётом границ.
    private func applyColor(_ color: Color, toWord word: String, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var searchRange = str.startIndex..<str.endIndex

        while let range = str.range(of: word, options: .literal, range: searchRange) {
            let isBoundedLeft = range.lowerBound == str.startIndex
                || (!str[str.index(before: range.lowerBound)].isLetter
                    && str[str.index(before: range.lowerBound)] != "_")
            let isBoundedRight = range.upperBound == str.endIndex
                || (!str[range.upperBound].isLetter
                    && str[range.upperBound] != "_"
                    && !str[range.upperBound].isNumber)

            if isBoundedLeft && isBoundedRight {
                if let attrRange = Range(range, in: attrStr) {
                    attrStr[attrRange].foregroundColor = color
                }
            }
            searchRange = range.upperBound..<str.endIndex
        }
    }

    /// Подсвечивает типы (слова с заглавной буквы).
    private func applyTypeHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex
        while i < str.endIndex {
            guard str[i].isUppercase else {
                i = str.index(after: i)
                continue
            }
            var j = i
            while j < str.endIndex && (str[j].isLetter || str[j].isNumber || str[j] == "_") {
                j = str.index(after: j)
            }
            if str.distance(from: i, to: j) > 1 {
                if let attrRange = Range(i..<j, in: attrStr) {
                    attrStr[attrRange].foregroundColor = color
                }
            }
            i = j < str.endIndex ? j : str.endIndex
        }
    }

    /// Подсвечивает строковые литералы (в двойных кавычках).
    private func applyStringHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex
        var inString = false
        var stringStart = str.startIndex

        while i < str.endIndex {
            if str[i] == "\"" && !inString {
                inString = true
                stringStart = i
            } else if str[i] == "\"" && inString {
                inString = false
                let end = str.index(after: i)
                if let attrRange = Range(stringStart..<end, in: attrStr) {
                    attrStr[attrRange].foregroundColor = color
                }
            } else if str[i] == "\\" && inString {
                i = str.index(after: i)
                if i >= str.endIndex { break }
            }
            i = str.index(after: i)
        }
    }

    /// Подсвечивает числовые литералы.
    private func applyNumberHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex

        while i < str.endIndex {
            guard str[i].isNumber else {
                i = str.index(after: i)
                continue
            }
            let isBoundedLeft = i == str.startIndex
                || (!str[str.index(before: i)].isLetter && str[str.index(before: i)] != "_")
            if !isBoundedLeft {
                i = str.index(after: i)
                continue
            }
            var j = i
            while j < str.endIndex && (str[j].isNumber || str[j] == "." || str[j] == "_") {
                j = str.index(after: j)
            }
            if let attrRange = Range(i..<j, in: attrStr) {
                attrStr[attrRange].foregroundColor = color
            }
            i = j < str.endIndex ? j : str.endIndex
        }
    }

    /// Подсвечивает однострочные комментарии (// ...).
    private func applyCommentHighlighting(color: Color, in attrStr: inout AttributedString) {
        let str = String(attrStr.characters)
        var i = str.startIndex

        while i < str.endIndex {
            guard i < str.index(before: str.endIndex) else { break }
            let next = str.index(after: i)
            if str[i] == "/" && str[next] == "/" {
                var j = next
                while j < str.endIndex && str[j] != "\n" {
                    j = str.index(after: j)
                }
                if let attrRange = Range(i..<j, in: attrStr) {
                    attrStr[attrRange].foregroundColor = color
                }
                i = j < str.endIndex ? str.index(after: j) : str.endIndex
            } else {
                i = str.index(after: i)
            }
        }
    }
}

// MARK: - Preview

#Preview("Markdown с кодом") {
    ScrollView {
        MarkdownTextView(text: """
        Вот как это работает:

        ## Архитектура

        Используем паттерн **MVVM** с `@Observable` макросом.

        ```swift
        // Главная ViewModel
        @Observable
        @MainActor
        final class ChappieViewModel {
            var messages: [ChatMessage] = []
            var isThinking: Bool = false

            func send(prompt: String) async {
                isThinking = true
                defer { isThinking = false }
                let result = try await orchestrator.process(prompt)
                messages.append(.message(isUser: false, text: result))
            }
        }
        ```

        Также нужно настроить **конфигурацию** в `AppConfig.swift`.

        ---

        ### Важно

        Не забудь добавить *ключ API* в настройки.
        """)
        .padding()
    }
    .frame(width: 600, height: 500)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Только код") {
    CodeBlockView(
        code: """
        func greet(name: String) -> String {
            // Формируем приветствие
            let greeting = "Привет, \\(name)!"
            return greeting
        }
        """,
        language: "swift"
    )
    .padding()
    .frame(width: 600)
    .background(Color(NSColor.windowBackgroundColor))
}
