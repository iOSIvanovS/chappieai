//
//  DB.swift
//  AdeptSK
//
//  Created by   Сергей on 08.10.2025.
//

import Foundation
import SwiftData

class DB {
            
    class func getSome<T: Codable>(_ relation: Relation) -> T? {
        if let container = try? ModelContainer(for: Record.self) {
            let context = ModelContext(container)
            if let record = ((try? context.fetch(FetchDescriptor<Record>())) ?? []).filter({ $0.relation == relation.rawValue }).first {
                let jsonDecoder = JSONDecoder()
                if let data = record.data {
                    return try? jsonDecoder.decode(T.self, from: data)
                }
            }
        }
        return nil
    }
    
    class func getAllElements<T: Codable>(_ relation: Relation) -> [T] {
        if let container = try? ModelContainer(for: Record.self) {
            let context = ModelContext(container)
            if let record = ((try? context.fetch(FetchDescriptor<Record>())) ?? []).filter({ $0.relation == relation.rawValue }).first {
                let jsonDecoder = JSONDecoder()
                if let data = record.data {
                    return (try? jsonDecoder.decode(Array<T>.self, from: data)) ?? []
                }
            }
        }
        return []
    }
    
    class func getElement<T: Codable & Identifiable>(_ relation: Relation, id: T.ID) -> T? {
        let results: [T] = getElements(relation, ids: [id])
        return results.first
    }
    
    class func getElements<T: Codable & Identifiable>(_ relation: Relation, ids: [T.ID]) -> [T] {
        if let container = try? ModelContainer(for: Record.self) {
            let context = ModelContext(container)
            if let record = ((try? context.fetch(FetchDescriptor<Record>())) ?? []).filter({ $0.relation == relation.rawValue }).first {
                let jsonDecoder = JSONDecoder()
                if let data = record.data, let elements = try? jsonDecoder.decode(Array<T>.self, from: data) {
                    return elements.filter({ ids.contains($0.id) })
                }
            }
        }
        return []
    }
    
    class func saveSome<T: Codable>(_ some: T, for relation: Relation) {
        if let container = try? ModelContainer(for: Record.self) {
            let context = ModelContext(container)
            context.insert(Record(relation: relation, data: some.encodeAsJSON))
            try? context.save()
        }
    }
    
    class func saveElement<T: Codable & Identifiable>(_ element: T, for relation: Relation) {
        saveElements([element], for: relation)
    }
    
    class func saveElements<T: Codable & Identifiable>(_ elements: [T], for relation: Relation) {
                
        if let container = try? ModelContainer(for: Record.self) {
            let context = ModelContext(container)
            if let record = ((try? context.fetch(FetchDescriptor<Record>())) ?? []).filter({ $0.relation == relation.rawValue }).first {
                let jsonDecoder = JSONDecoder()
                if let data = record.data, var savedElements = (try? jsonDecoder.decode(Array<T>.self, from: data)) {
                    
                    var elementsDict = [T.ID : T]()
                    for element in elements {
                        elementsDict[element.id] = element
                    }
                    
                    for i in 0 ..< savedElements.count {
                        let id = savedElements[i].id
                        if let element = elementsDict[id] {
                            savedElements[i] = element
                            elementsDict.removeValue(forKey: id)
                        }
                    }
                    
                    var elementsForAdd = [T]()
                    for element in elements {
                        if let element = elementsDict[element.id] {
                            elementsForAdd.append(element)
                        }
                    }
    
                    savedElements += elementsForAdd
                    
                    record.data = savedElements.encodeAsJSON
                    context.insert(record)
                } else {
                    record.data = elements.encodeAsJSON
                    context.insert(record)
                }
            } else {
                context.insert(Record(relation: relation, data: elements.encodeAsJSON))
            }
            try? context.save()
        }
    }
    
    class func deleteAll(_ relation: Relation) {
        if let container = try? ModelContainer(for: Record.self) {
            let context = ModelContext(container)
            if let record = ((try? context.fetch(FetchDescriptor<Record>())) ?? []).filter({ $0.relation == relation.rawValue }).first {
                context.delete(record)
                try? context.save()
            }
        }
    }
    
    class func deleteElement<T: Codable & Identifiable>(_ type: T.Type, id: T.ID, for relation: Relation) {
        deleteElements(type, ids: [id], for: relation)
    }
    
    class func deleteElements<T: Codable & Identifiable>(_ : T.Type, ids: [T.ID], for relation: Relation) {
        if let container = try? ModelContainer(for: Record.self) {
            let context = ModelContext(container)
            if let record = ((try? context.fetch(FetchDescriptor<Record>())) ?? []).filter({ $0.relation == relation.rawValue }).first {
                let jsonDecoder = JSONDecoder()
                if let data = record.data, var savedElements = (try? jsonDecoder.decode(Array<T>.self, from: data)) {
                    savedElements = savedElements.filter({ !ids.contains($0.id) })
                    record.data = savedElements.encodeAsJSON
                    context.insert(record)
                }
                try? context.save()
            }
        }
    }
    
    class func deleteElement<T: Codable & Identifiable>(_ element: T, for relation: Relation) {
        deleteElements([element], for: relation)
    }
    
    class func deleteElements<T: Codable & Identifiable>(_ elements: [T], for relation: Relation) {
        if let container = try? ModelContainer(for: Record.self) {
            let context = ModelContext(container)
            if let record = ((try? context.fetch(FetchDescriptor<Record>())) ?? []).filter({ $0.relation == relation.rawValue }).first {
                let jsonDecoder = JSONDecoder()
                if let data = record.data, var savedElements = (try? jsonDecoder.decode(Array<T>.self, from: data)) {
                    savedElements = savedElements.filter({ element in
                        !elements.contains(where: { $0.id == element.id })
                    })
                    record.data = savedElements.encodeAsJSON
                    context.insert(record)
                }
                try? context.save()
            }
        }
    }
    
    class func clearAllDB() {
        if let container = try? ModelContainer(for: Record.self) {
            let context = ModelContext(container)
            try? context.delete(model: Record.self)
            try? context.save()
        }
    }
    
    enum Relation: String, Codable {
        case ZNVR_Task, ZNVR_Job, remarks, prescriptionRusgidro, generalSignaturesSettings, userReps, quickReps
    }
    
    @Model class Record {
        @Attribute(.unique) var relation: String
        private var encryptedData: Data?
        
        var data: Data? {
            
            get {
                if let encryptedData {
                    CryptoManager.decrypt(encryptedData)
                } else {
                    nil
                }
            }
            
            set {
                if let newValue, let data = CryptoManager.encrypt(newValue) {
                    encryptedData = data
                }
            }
        }
        
        init(relation: Relation, data: Data) {
            self.relation = relation.rawValue
            self.encryptedData = CryptoManager.encrypt(data)
        }
    }
}
