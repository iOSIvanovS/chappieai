// JSONSchema.swift
// ChappieCore
//
// json_schema: the SHAPE of a JSON file without its data.
//
// Many nodes are merged into one Shape: all elements of an array become one "item" shape, all values
// of a dictionary become one "value" shape, a field that exists in only some objects is marked
// optional, a field that holds different kinds becomes a variant. For optional fields and for
// variants the shape remembers WHERE the first instance lives, so the model can open it with json_get.
//
// The build recurses only `maxLevels` deep (a small number), never as deep as the document, because
// tool code runs on threads with small stacks.

import Foundation

final class JSONShape {
    var count = 0
    var kindCounts: [JSONKind: Int] = [:]
    var firstOfKind: [JSONKind: Int] = [:]
    /// Containers that were not looked into because the level limit was reached.
    var cutBelow = false

    // Object
    var objectCount = 0
    var props: [(key: String, shape: JSONShape, presence: Int)] = []
    var isDictionary = false
    var dictEntries = 0
    var dictKeySample: [String] = []
    var dictValue: JSONShape?

    // Array
    var arrayCount = 0
    var item: JSONShape?
    var minLength = Int.max
    var maxLength = 0

    // Scalars
    var stringCount = 0
    var distinctStrings: [String] = []
    var distinctOverflow = false
    var firstString: String?
    var numberCount = 0
    var minNumber = Double.infinity
    var maxNumber = -Double.infinity
    var allIntegers = true
    var trueCount = 0
    var falseCount = 0

    static let enumLimit = 8
    static let dictionaryMinKeys = 20
    static let dictionaryUniformity = 0.8
}

enum JSONSchemaBuilder {

    static func build(_ doc: JSONDocument, nodes: [Int], level: Int = 0, maxLevels: Int) -> JSONShape {
        let shape = JSONShape()
        shape.count = nodes.count
        var objects: [Int] = [], arrays: [Int] = []

        for index in nodes {
            let node = doc.nodes[index]
            shape.kindCounts[node.kind, default: 0] += 1
            if shape.firstOfKind[node.kind] == nil { shape.firstOfKind[node.kind] = index }
            switch node.kind {
            case .object: objects.append(index)
            case .array: arrays.append(index)
            case .string: addString(doc, index, to: shape)
            case .number: addNumber(doc, index, to: shape)
            case .bool: doc.rawText(of: index) == "true" ? (shape.trueCount += 1) : (shape.falseCount += 1)
            case .null: break
            }
        }

        if level >= maxLevels {
            shape.cutBelow = (!objects.isEmpty || !arrays.isEmpty)
            shape.objectCount = objects.count
            shape.arrayCount = arrays.count
            return shape
        }
        if !objects.isEmpty { fillObject(doc, objects, into: shape, level: level, maxLevels: maxLevels) }
        if !arrays.isEmpty { fillArray(doc, arrays, into: shape, level: level, maxLevels: maxLevels) }
        return shape
    }

    // MARK: Scalars

    private static func addString(_ doc: JSONDocument, _ index: Int, to shape: JSONShape) {
        shape.stringCount += 1
        guard let text = doc.stringValue(of: index) else { return }
        if shape.firstString == nil { shape.firstString = text }
        guard !shape.distinctOverflow, !shape.distinctStrings.contains(text) else { return }
        if shape.distinctStrings.count >= JSONShape.enumLimit {
            shape.distinctOverflow = true
        } else {
            shape.distinctStrings.append(text)
        }
    }

    private static func addNumber(_ doc: JSONDocument, _ index: Int, to shape: JSONShape) {
        shape.numberCount += 1
        let raw = doc.rawText(of: index)
        if raw.contains(".") || raw.contains("e") || raw.contains("E") { shape.allIntegers = false }
        if let value = Double(raw) {
            shape.minNumber = min(shape.minNumber, value)
            shape.maxNumber = max(shape.maxNumber, value)
        }
    }

    // MARK: Objects

    private static func fillObject(
        _ doc: JSONDocument, _ objects: [Int], into shape: JSONShape, level: Int, maxLevels: Int
    ) {
        shape.objectCount = objects.count
        var order: [String] = []
        var children: [String: [Int]] = [:]
        var presence: [String: Int] = [:]
        var childKinds: [JSONKind: Int] = [:]
        var total = 0

        for object in objects {
            var seenHere = Set<String>()
            for child in doc.nodes[object].children {
                guard let key = doc.nodes[child].key else { continue }
                if children[key] == nil { order.append(key) }
                children[key, default: []].append(child)
                if seenHere.insert(key).inserted { presence[key, default: 0] += 1 }
                childKinds[doc.nodes[child].kind, default: 0] += 1
                total += 1
            }
        }

        if isDictionary(distinct: order.count, instances: objects.count, total: total, kinds: childKinds) {
            shape.isDictionary = true
            shape.dictEntries = total
            shape.dictKeySample = Array(order.prefix(4))
            shape.dictValue = build(doc, nodes: order.flatMap { children[$0] ?? [] }, level: level + 1, maxLevels: maxLevels)
            return
        }
        shape.props = order.map { key in
            (key, build(doc, nodes: children[key] ?? [], level: level + 1, maxLevels: maxLevels), presence[key] ?? 0)
        }
    }

    /// Many keys whose values are of one kind, and (over several objects) keys that rarely repeat.
    private static func isDictionary(distinct: Int, instances: Int, total: Int, kinds: [JSONKind: Int]) -> Bool {
        guard distinct >= JSONShape.dictionaryMinKeys, total > 0 else { return false }
        let dominant = kinds.values.max() ?? 0
        guard Double(dominant) / Double(total) >= JSONShape.dictionaryUniformity else { return false }
        if instances == 1 { return true }
        let averagePresence = Double(total) / Double(distinct * instances)
        return averagePresence < 0.5
    }

    // MARK: Arrays

    private static func fillArray(
        _ doc: JSONDocument, _ arrays: [Int], into shape: JSONShape, level: Int, maxLevels: Int
    ) {
        shape.arrayCount = arrays.count
        var elements: [Int] = []
        for array in arrays {
            let length = doc.nodes[array].children.count
            shape.minLength = min(shape.minLength, length)
            shape.maxLength = max(shape.maxLength, length)
            elements.append(contentsOf: doc.nodes[array].children)
        }
        if !elements.isEmpty {
            shape.item = build(doc, nodes: elements, level: level + 1, maxLevels: maxLevels)
        }
    }
}
