// swift-tools-version: 6.3
// Манифест Swift Package Manager для ChappieCore.
//
// СТРУКТУРА ПАКЕТА:
// - ChappieCore (library target) — основная бизнес-логика ИИ-ассистента
// - ChappieCoreTests (test target) — юнит-тесты для акторов и сервисов
//
// ПОЧЕМУ ОТДЕЛЬНЫЙ ПАКЕТ:
// Разделение UI (Chappie.app) и бизнес-логики (ChappieCore) позволяет:
// 1. Тестировать логику независимо от UI
// 2. Переиспользовать ядро в других приложениях
// 3. Чётко разграничить ответственность слоёв

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
        // Тестовый таргет — зависит от ChappieCore, тестирует его публичный API
        .testTarget(
            name: "ChappieCoreTests",
            dependencies: ["ChappieCore"],
            path: "Tests/ChappieCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
