//
//  XcodeDocsGroupManager.swift
//  ChappieCore
//

// Менеджер синхронизации группы "📚 Docs" в Xcode Navigator.
//
// ЗАЧЕМ ЭТОТ КОМПОНЕНТ:
// Когда Чаппи создаёт architecture.md для нового таргета, файл появляется
// на диске, но остаётся невидимым в Xcode Navigator — проект не знает о нём.
// Этот менеджер автоматически обновляет Chappie.xcodeproj/project.pbxproj,
// добавляя или удаляя ссылки в группе "📚 Docs" при каждом запуске.
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ — ТЕКСТОВОЕ РЕДАКТИРОВАНИЕ PBXPROJ:
// Формат pbxproj — это НЕ стандартный JSON и НЕ XML. Это кастомный формат Apple
// (OpenStep property list). Парсить его через JSONDecoder нельзя (нет кавычек у ключей,
// есть комментарии). Использовать сторонние библиотеки — нарушает принцип минимальных
// зависимостей.
//
// ВЫБРАННЫЙ ПОДХОД: Точечное текстовое редактирование по уникальным маркерам.
// Наши объекты в pbxproj имеют предсказуемые ID с префиксом "87DOCS".
// Мы находим секцию Docs по этим маркерам и полностью её пересоздаём.
// Остальной pbxproj НЕ трогаем — это безопасно и предсказуемо.
//
// ИДЕМПОТЕНТНОСТЬ:
// Метод sync() безопасно вызывать при каждом запуске приложения.
// Если состояние уже актуально — файл не перезаписывается.
//
// УНИКАЛЬНЫЕ ID:
// Используем фиксированные ID вида 87DOCS000000000000000000X (где X = порядковый номер).
// "Корневой" architecture.md всегда имеет ID 87DOCS0001000000000000001.
// Таргеты получают ID начиная с 87DOCS0002000000000000002 в алфавитном порядке.
// Группа-контейнер "📚 Docs" всегда имеет ID 87DOCS0000000000000000000.
// Фиксированные ID позволяют легко найти и заменить наши записи без парсинга.

import Foundation

// MARK: - XcodeDocsGroupManager

/// Актор для синхронизации группы "📚 Docs" в Xcode Navigator.
///
/// Читает project.pbxproj как текст, находит наши уникальные маркеры и
/// точечно заменяет только секцию Docs. Остальное содержимое pbxproj
/// не изменяется — это гарантирует безопасность операции.
actor XcodeDocsGroupManager {

    // MARK: - Константы

    /// ID группы-контейнера "📚 Docs" в pbxproj.
    /// Фиксирован — чтобы группа всегда находилась по одному и тому же ID.
    private static let docsGroupID = "87DOCS0000000000000000000"

    /// ID файловой ссылки на корневой architecture.md (в корне воркспейса).
    /// Фиксирован — корневой файл всегда присутствует.
    private static let rootArchFileID = "87DOCS0001000000000000001"

    /// Начальный порядковый номер для ID таргетных файлов.
    /// Корневой файл занял 1, таргеты начинаются с 2.
    private static let targetFileIDStart = 2

    /// Имя файла Xcode проекта.
    private static let xcodeProjectName = "Chappie.xcodeproj"

    /// Имя файла pbxproj внутри .xcodeproj пакета.
    private static let pbxprojName = "project.pbxproj"

    // MARK: - Свойства

    /// URL корневой папки воркспейса (где лежит Chappie.xcodeproj).
    private let workspaceURL: URL

    private let fileManager = FileManager.default

    // MARK: - Инициализация

    init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    // MARK: - Публичный API

    /// Синхронизирует группу "📚 Docs" в pbxproj с текущим списком таргетов.
    ///
    /// Алгоритм:
    /// 1. Находим pbxproj рядом с воркспейсом.
    /// 2. Читаем его содержимое.
    /// 3. Генерируем новые блоки PBXFileReference и PBXGroup для наших файлов.
    /// 4. Если pbxproj уже содержит наши маркеры — заменяем только наши блоки.
    ///    Если маркеров нет — вставляем новые блоки в нужные места.
    /// 5. Убеждаемся что ссылка на группу есть в главной группе проекта.
    /// 6. Записываем обновлённый pbxproj только если он изменился.
    ///
    /// - Parameter targets: Список таргетов воркспейса (из MemoryManager.discoverTargets).
    ///   Корневой architecture.md добавляется автоматически — он всегда присутствует.
    func sync(targets: [WorkspaceTarget]) async {
        // Находим pbxproj — он лежит в <WorkspaceRoot>/Chappie.xcodeproj/project.pbxproj
        // Ищем сначала по имени проекта, затем ищем любой .xcodeproj в корне воркспейса
        guard let pbxprojURL = findPbxproj() else {
            print("[XcodeDocsGroupManager] ⚠️ project.pbxproj не найден — пропускаем синхронизацию Docs группы")
            return
        }

        guard let originalContent = try? String(contentsOf: pbxprojURL, encoding: .utf8) else {
            print("[XcodeDocsGroupManager] ⚠️ Не удалось прочитать project.pbxproj")
            return
        }

        // Строим описание всех файлов которые должны быть в группе:
        // - Корневой architecture.md (всегда первый)
        // - architecture.md каждого таргета (в алфавитном порядке, уже отсортированы MemoryManager)
        let docsEntries = buildDocsEntries(targets: targets)

        // Генерируем новое содержимое pbxproj с актуальной группой Docs
        let updatedContent = updatePbxproj(originalContent, docsEntries: docsEntries)

        // Записываем только если содержимое изменилось — не трогаем файл без причины.
        // Это важно: лишняя запись pbxproj сбрасывает timestamp и заставляет Xcode
        // перечитывать проект, что раздражает пользователя.
        if updatedContent != originalContent {
            do {
                try updatedContent.write(to: pbxprojURL, atomically: true, encoding: .utf8)
                print("[XcodeDocsGroupManager] ✅ Группа '📚 Docs' синхронизирована: \(docsEntries.count) файлов")
            } catch {
                print("[XcodeDocsGroupManager] ⚠️ Не удалось записать project.pbxproj: \(error)")
            }
        } else {
            print("[XcodeDocsGroupManager] ✓ Группа '📚 Docs' актуальна, изменений нет")
        }
    }

    // MARK: - Приватные методы

    /// Ищет файл project.pbxproj в воркспейсе.
    ///
    /// Стратегия поиска:
    /// 1. Сначала ищем Chappie.xcodeproj/project.pbxproj (знаем имя проекта).
    /// 2. Если не нашли — сканируем корень воркспейса на наличие любого .xcodeproj.
    ///
    /// Двухшаговый поиск нужен для универсальности: в будущем этот менеджер
    /// может использоваться для других проектов с другими именами.
    private func findPbxproj() -> URL? {
        // Шаг 1: Ищем по известному имени
        let knownURL = workspaceURL
            .appendingPathComponent(Self.xcodeProjectName)
            .appendingPathComponent(Self.pbxprojName)

        if fileManager.fileExists(atPath: knownURL.path) {
            return knownURL
        }

        // Шаг 2: Ищем любой .xcodeproj в корне воркспейса
        guard let contents = try? fileManager.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for url in contents {
            if url.pathExtension == "xcodeproj" {
                let pbxproj = url.appendingPathComponent(Self.pbxprojName)
                if fileManager.fileExists(atPath: pbxproj.path) {
                    return pbxproj
                }
            }
        }

        return nil
    }

    // MARK: - Модель данных для записей Docs

    /// Описание одного файла в группе "📚 Docs".
    ///
    /// Хранит всё необходимое для генерации двух строк в pbxproj:
    /// - PBXFileReference (описание файла)
    /// - Строка в children группы PBXGroup
    private struct DocsEntry {
        /// Уникальный ID в pbxproj (формат: 87DOCS000000000000000000X).
        let fileRefID: String

        /// Отображаемое имя в Xcode Navigator.
        /// Формат: "architecture.md (ИмяТаргета)" или "architecture.md (корень)".
        let displayName: String

        /// Относительный путь от корня воркспейса.
        /// Например: "architecture.md" или "Chappie/architecture.md".
        let relativePath: String
    }

    /// Строит список записей для группы Docs на основе текущих таргетов.
    ///
    /// Порядок:
    /// 1. Корневой architecture.md — всегда первый (ID: 87DOCS0001000000000000001).
    /// 2. Таргеты — в том порядке, в котором их передал MemoryManager
    ///    (App-таргет первым, затем библиотеки по алфавиту).
    ///
    /// ID для таргетов генерируются последовательно начиная с 2.
    /// Формат ID: "87DOCS" + порядковый номер дополненный нулями до 25 символов.
    private func buildDocsEntries(targets: [WorkspaceTarget]) -> [DocsEntry] {
        var entries: [DocsEntry] = []

        // Корневой файл — всегда первый с фиксированным ID
        entries.append(DocsEntry(
            fileRefID: Self.rootArchFileID,
            displayName: "architecture.md (корень)",
            relativePath: "architecture.md"
        ))

        // Таргеты — с последовательными ID начиная с 2
        for (index, target) in targets.enumerated() {
            let sequentialNumber = Self.targetFileIDStart + index

            // Формируем ID: "87DOCS" + число дополненное нулями до 19 символов
            // Итого: 6 + 19 = 25 символов — стандартная длина ID в pbxproj
            let paddedNumber = String(format: "%019d", sequentialNumber)
            let fileRefID = "87DOCS\(paddedNumber)"

            // Относительный путь от корня воркспейса до architecture.md таргета
            let relativePath = "\(target.name)/architecture.md"

            entries.append(DocsEntry(
                fileRefID: fileRefID,
                displayName: "architecture.md (\(target.name))",
                relativePath: relativePath
            ))
        }

        return entries
    }

    // MARK: - Генерация блоков pbxproj

    /// Генерирует строку PBXFileReference для одного файла.
    ///
    /// Формат строки соответствует стандарту pbxproj — скопирован с существующих записей.
    /// lastKnownFileType = net.daringfireball.markdown — правильный UTI для .md файлов.
    /// sourceTree = "<group>" — путь относительно корня проекта (главной группы).
    private func makeFileRefLine(_ entry: DocsEntry) -> String {
        // Формат: <ID> /* <имя> */ = {isa = PBXFileReference; ...};
        // Используем name для отображения и path для реального пути к файлу.
        // name нужен когда displayName отличается от имени файла.
        return "\t\t\(entry.fileRefID) /* \(entry.displayName) */ = {isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; name = \"\(entry.displayName)\"; path = \(entry.relativePath); sourceTree = \"<group>\"; };"
    }

    /// Генерирует строку для children группы PBXGroup.
    private func makeGroupChildLine(_ entry: DocsEntry) -> String {
        return "\t\t\t\t\(entry.fileRefID) /* \(entry.displayName) */,"
    }

    /// Генерирует полный блок PBXFileReference section для всех наших файлов.
    ///
    /// Блок обёрнут в маркеры начала/конца, которые мы используем для поиска
    /// при следующей синхронизации. Это позволяет точечно заменить только наши строки.
    private func makeFileRefsBlock(_ entries: [DocsEntry]) -> String {
        let fileRefLines = entries.map { makeFileRefLine($0) }.joined(separator: "\n")
        return """
        \t\t/* Ссылки на файлы архитектуры — только для навигации в Xcode, не участвуют в сборке */
        \(fileRefLines)
        """
    }

    /// Генерирует полный блок PBXGroup для группы "📚 Docs".
    ///
    /// Группа содержит только children — ссылки на файлы.
    /// name = "📚 Docs" — отображается в Xcode Navigator.
    /// sourceTree = "<group>" — пути относительны корню проекта.
    private func makeDocsGroupBlock(_ entries: [DocsEntry]) -> String {
        let childrenLines = entries.map { makeGroupChildLine($0) }.joined(separator: "\n")

        return """
        \t\t/* Группа 📚 Docs — только для навигации. Не содержит Build Phase, не копируется в бандл.
        \t\t   Позволяет открывать и редактировать все файлы architecture.md прямо из Xcode Navigator. */
        \t\t\(Self.docsGroupID) /* 📚 Docs */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \(childrenLines)
        \t\t\t);
        \t\t\tname = "📚 Docs";
        \t\t\tsourceTree = "<group>";
        \t\t};
        """
    }

    // MARK: - Обновление pbxproj

    /// Обновляет содержимое pbxproj: заменяет наши блоки на актуальные версии.
    ///
    /// Стратегия:
    /// А) Если pbxproj уже содержит наши маркеры (87DOCS...) — заменяем точечно.
    /// Б) Если маркеров нет (первый запуск на новом проекте) — вставляем в нужные места.
    ///
    /// Почему точечная замена безопасна:
    /// Все наши объекты имеют уникальный префикс "87DOCS" который не встречается
    /// в нативных объектах Xcode (те используют стандартный 24-символьный hex-ID).
    /// Это гарантирует что мы никогда не затронем чужие строки.
    private func updatePbxproj(_ content: String, docsEntries: [DocsEntry]) -> String {
        let hasDocsMarkers = content.contains(Self.docsGroupID)

        if hasDocsMarkers {
            // Режим обновления: заменяем существующие наши блоки
            return replaceExistingDocsBlocks(in: content, docsEntries: docsEntries)
        } else {
            // Режим первичной вставки: добавляем наши блоки в нужные места
            return insertDocsBlocks(into: content, docsEntries: docsEntries)
        }
    }

    /// Заменяет существующие блоки с нашими объектами на актуальные версии.
    ///
    /// Алгоритм для каждой секции:
    /// 1. Находим все строки с префиксом "87DOCS" (наши объекты).
    /// 2. Заменяем их на новый набор строк.
    ///
    /// Это работает потому что все наши строки содержат "87DOCS" — уникальный маркер.
    private func replaceExistingDocsBlocks(in content: String, docsEntries: [DocsEntry]) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var i = 0

        // Флаг: мы уже вставили новые FileRef строки в PBXFileReference секцию?
        var insertedFileRefs = false
        // Флаг: мы уже вставили новый блок группы в PBXGroup секцию?
        var insertedGroup = false

        while i < lines.count {
            let line = lines[i]

            // Пропускаем все строки которые относятся к нашим старым объектам.
            // Признак "наша строка": содержит "87DOCS" в любом месте.
            if line.contains("87DOCS") {
                // Если это первая встреченная строка с 87DOCS в PBXFileReference секции —
                // вставляем новые FileRef строки вместо всего старого блока.
                // Если это PBXGroup секция — вставляем новый блок группы.
                let isInFileRefSection = isInsideSection(lines: lines, currentIndex: i, sectionName: "PBXFileReference")
                let isInGroupSection = isInsideSection(lines: lines, currentIndex: i, sectionName: "PBXGroup")

                if isInFileRefSection && !insertedFileRefs {
                    // Вставляем новый блок FileReferences
                    let newBlock = makeFileRefsBlock(docsEntries)
                    result.append(newBlock)
                    insertedFileRefs = true
                    // Пропускаем все следующие строки с 87DOCS подряд
                    i += 1
                    while i < lines.count && (lines[i].contains("87DOCS") || isCommentLine(lines[i])) {
                        i += 1
                    }
                    continue
                } else if isInGroupSection && !insertedGroup {
                    // Вставляем новый блок группы.
                    // Нужно пропустить весь старый блок группы (до закрывающей скобки).
                    let newBlock = makeDocsGroupBlock(docsEntries)
                    result.append(newBlock)
                    insertedGroup = true
                    // Пропускаем весь старый блок группы до его закрывающей };
                    i += 1
                    var depth = 0
                    var foundGroupStart = false
                    while i < lines.count {
                        let currentLine = lines[i]
                        if currentLine.contains("{") { depth += 1; foundGroupStart = true }
                        if currentLine.contains("}") { depth -= 1 }
                        i += 1
                        if foundGroupStart && depth <= 0 { break }
                    }
                    continue
                } else {
                    // Дубликат или уже вставили — просто пропускаем
                    i += 1
                    continue
                }
            }

            result.append(line)
            i += 1
        }

        return result.joined(separator: "\n")
    }

    /// Проверяет, находится ли строка с данным индексом внутри указанной секции pbxproj.
    ///
    /// Секции в pbxproj обёрнуты в маркеры:
    ///   "/* Begin PBXFileReference section */"
    ///   "/* End PBXFileReference section */"
    ///
    /// Идём назад от текущей строки и ищем маркер Begin.
    private func isInsideSection(lines: [String], currentIndex: Int, sectionName: String) -> Bool {
        let beginMarker = "/* Begin \(sectionName) section */"
        let endMarker = "/* End \(sectionName) section */"

        // Ищем назад от текущей позиции
        var j = currentIndex
        while j >= 0 {
            if lines[j].contains(beginMarker) { return true }
            if lines[j].contains(endMarker) { return false }
            j -= 1
        }
        return false
    }

    /// Проверяет, является ли строка комментарием (начинается с /* или содержит только пробелы).
    private func isCommentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/*") || trimmed.isEmpty
    }

    /// Вставляет наши блоки в pbxproj при первичной установке (когда маркеров ещё нет).
    ///
    /// Места вставки:
    /// 1. PBXFileReference section — наши FileReference строки вставляются
    ///    перед маркером "/* End PBXFileReference section */".
    /// 2. PBXGroup section — наш блок группы вставляется
    ///    перед маркером "/* End PBXGroup section */".
    /// 3. Главная группа проекта — ссылка на нашу группу вставляется
    ///    в children главной группы (первым элементом).
    private func insertDocsBlocks(into content: String, docsEntries: [DocsEntry]) -> String {
        var result = content

        // 1. Вставляем FileReferences перед концом секции PBXFileReference
        let fileRefEndMarker = "/* End PBXFileReference section */"
        if result.contains(fileRefEndMarker) {
            let newFileRefs = makeFileRefsBlock(docsEntries) + "\n"
            result = result.replacingOccurrences(
                of: fileRefEndMarker,
                with: newFileRefs + fileRefEndMarker
            )
        }

        // 2. Вставляем блок группы перед концом секции PBXGroup
        let groupEndMarker = "/* End PBXGroup section */"
        if result.contains(groupEndMarker) {
            let newGroup = makeDocsGroupBlock(docsEntries) + "\n"
            result = result.replacingOccurrences(
                of: groupEndMarker,
                with: newGroup + groupEndMarker
            )
        }

        // 3. Добавляем ссылку на нашу группу в children главной группы проекта.
        //    Главная группа — это первый PBXGroup без имени (name отсутствует).
        //    Признак: содержит "children = (" и НЕ содержит "name =" в своём блоке.
        //    Ищем паттерн "children = (" в главной группе и вставляем наш ID первым.
        result = insertDocsGroupReferenceInMainGroup(result)

        return result
    }

    /// Вставляет ссылку на группу "📚 Docs" в children главной группы проекта.
    ///
    /// Главная группа — первый PBXGroup в секции, у которого нет поля "name".
    /// Это корневая группа Xcode Navigator. Наша группа Docs должна быть в ней первой.
    ///
    /// Маркер для вставки: строка "children = (" в главной группе.
    /// Вставляем нашу ссылку сразу после этой строки.
    private func insertDocsGroupReferenceInMainGroup(_ content: String) -> String {
        let docsGroupRef = "\t\t\t/* Группа документации — все файлы architecture.md видны в Navigator */\n\t\t\t\(Self.docsGroupID) /* 📚 Docs */,"

        // Разбиваем на строки для пообходного анализа.
        // let (а не var) — массив используется только для чтения при поиске.
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var i = 0
        var inserted = false

        while i < lines.count {
            let line = lines[i]

            // Ищем "children = (" в главной группе (без имени).
            // Главная группа — та, у которой нет поля "name =" в своём блоке.
            if !inserted && line.trimmingCharacters(in: .whitespaces) == "children = (" {
                let isMainGroup = checkIsMainGroup(lines: lines, childrenLineIndex: i)

                if isMainGroup {
                    result.append(line)
                    result.append(docsGroupRef)
                    inserted = true
                    i += 1
                    continue
                }
            }

            result.append(line)
            i += 1
        }

        return result.joined(separator: "\n")
    }

    /// Проверяет, является ли блок с "children = (" главной группой проекта.
    ///
    /// Главная группа не имеет поля "name =". Ищем вперёд от строки children
    /// до закрывающей "}" блока — если нет "name =" то это главная группа.
    private func checkIsMainGroup(lines: [String], childrenLineIndex: Int) -> Bool {
        var j = childrenLineIndex + 1
        var depth = 1 // Мы уже внутри children = (

        while j < lines.count && depth > 0 {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)

            // Конец блока children
            if trimmed == ");" && depth == 1 { break }

            // Конец всего блока группы — дошли без "name =", значит главная группа
            if trimmed == "};" { return true }

            // Если нашли "name =" — это именованная группа, не главная
            if trimmed.hasPrefix("name =") { return false }

            if trimmed.contains("{") { depth += 1 }
            if trimmed.contains("}") { depth -= 1 }

            j += 1
        }

        // Продолжаем смотреть после children до конца блока группы
        while j < lines.count {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            if trimmed == "};" { return true }
            if trimmed.hasPrefix("name =") { return false }
            j += 1
        }

        return false
    }
}
