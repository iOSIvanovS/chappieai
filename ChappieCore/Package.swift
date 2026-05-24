// swift-tools-version: 6.3
// Манифест Swift Package Manager для ChappieCore.
//
// СТРУКТУРА ПАКЕТА:
// - ChappieCore (library target) — основная бизнес-логика ИИ-ассистента
//
// ПОЧЕМУ ОТДЕЛЬНЫЙ ПАКЕТ:
// Разделение UI (Chappie.app) и бизнес-логики (ChappieCore) позволяет:
// 1. Тестировать логику независимо от UI
// 2. Переиспользовать ядро в других приложениях
// 3. Чётко разграничить ответственность слоёв
//
// ПОЧЕМУ ЗДЕСЬ НЕТ ТЕСТ-ТАРГЕТА:
// Тесты ChappieCore живут в корневом таргете ChappieCoreTests/ проекта Chappie.xcodeproj
// и запускаются через ChappieCoreTests.xctestplan (Xcode Test Plan).
// Это единственный источник истины для тестов — дублирование в Package.swift
// приводило к двум несинхронизированным наборам тестов, что создавало путаницу.
// Правило: тесты пишутся в ChappieCoreTests/, запускаются через Xcode.

import PackageDescription

let package = Package(
    name: "ChappieCore",
    platforms: [
        // macOS 26 — минимальная версия для поддержки Swift 6 Concurrency
        // и новейших SwiftUI API, которые использует Chappie.app
        .macOS(.v26)
    ],
    products: [
        // Библиотека экспортируется как dynamic/static (Xcode выбирает сам)
        .library(
            name: "ChappieCore",
            targets: ["ChappieCore"]
        ),
    ],
    targets: [
        // Основной таргет с исходным кодом
        .target(
            name: "ChappieCore"
        ),
        // ТЕСТ-ТАРГЕТ УДАЛЁН НАМЕРЕННО.
        // Все тесты живут в ChappieCoreTests/ и управляются через Xcode Test Plan.
        // См. ChappieCoreTests.xctestplan в корне проекта.
    ],
    swiftLanguageModes: [.v6]
)
