import Foundation

/// String-keyed dictionary that remembers insertion order. Importers collect points by name
/// (to merge duplicates) and use `values` so the points keep the order they have in the file.
struct InsertionOrderedDictionary<Value> {
    private(set) var keys: [String] = []
    private var storage: [String: Value] = [:]

    init() {}

    subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                // Updating an existing key keeps its original position
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    /// Values in insertion order.
    var values: [Value] { keys.compactMap { storage[$0] } }
    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }
}
