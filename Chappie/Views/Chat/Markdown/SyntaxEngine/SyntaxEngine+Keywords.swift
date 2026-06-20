// SyntaxEngine+Keywords.swift
// Chappie

// Keyword and builtin tables for all supported languages.
// Each language has its own static let — extend here when adding new languages.

extension SyntaxEngine {

    static let swiftKeywords: [String] = [
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

    static let pythonKeywords: [String] = [
        "def", "class", "import", "from", "as", "return", "if", "elif", "else",
        "for", "while", "try", "except", "finally", "raise", "with", "pass",
        "break", "continue", "lambda", "yield", "global", "nonlocal", "del",
        "assert", "and", "or", "not", "in", "is", "None", "True", "False",
        "async", "await", "self", "cls"
    ]

    static let pythonBuiltins: [String] = [
        "print", "len", "range", "type", "isinstance", "int", "str", "float",
        "bool", "list", "dict", "set", "tuple", "enumerate", "zip", "map",
        "filter", "sorted", "reversed", "sum", "min", "max", "abs", "round",
        "open", "input", "super", "property", "staticmethod", "classmethod",
        "hasattr", "getattr", "setattr", "delattr", "vars", "dir", "repr",
        "format", "chr", "ord", "hex", "bin", "oct", "id", "hash",
        "__init__", "__name__", "__main__", "__str__", "__repr__"
    ]

    static let jsKeywords: [String] = [
        "function", "const", "let", "var", "class", "extends", "import", "export",
        "default", "return", "if", "else", "for", "while", "do", "try", "catch",
        "finally", "throw", "new", "this", "super", "typeof", "instanceof",
        "switch", "case", "break", "continue", "of", "in", "from", "async",
        "await", "null", "undefined", "true", "false", "static", "get", "set",
        "delete", "void", "yield"
    ]

    static let jsBuiltins: [String] = [
        "console", "Promise", "Array", "Object", "String", "Number", "Boolean",
        "Math", "Date", "JSON", "Error", "Map", "Set", "WeakMap", "WeakSet",
        "Symbol", "Proxy", "Reflect", "fetch", "setTimeout", "setInterval",
        "clearTimeout", "clearInterval", "parseInt", "parseFloat", "isNaN",
        "isFinite", "encodeURIComponent", "decodeURIComponent",
        "document", "window", "navigator", "location", "history",
        "localStorage", "sessionStorage", "XMLHttpRequest", "WebSocket",
        "process", "Buffer", "require", "module", "exports", "__dirname"
    ]

    static let tsKeywords: [String] = jsKeywords + [
        "interface", "type", "enum", "namespace", "declare", "abstract",
        "readonly", "private", "public", "protected", "implements",
        "keyof", "never", "unknown", "any", "infer"
    ]

    static let kotlinKeywords: [String] = [
        "fun", "val", "var", "class", "object", "interface", "enum", "sealed",
        "data", "abstract", "open", "final", "override", "private", "public",
        "protected", "internal", "companion", "import", "package", "return",
        "if", "else", "when", "for", "while", "do", "try", "catch", "finally",
        "throw", "throws", "is", "as", "in", "out", "by", "init", "constructor",
        "this", "super", "null", "true", "false", "suspend", "inline", "reified",
        "typealias", "lateinit", "lazy", "it", "apply", "let", "run", "also", "with"
    ]

    static let rustKeywords: [String] = [
        "fn", "let", "mut", "const", "static", "struct", "enum", "trait",
        "impl", "use", "mod", "pub", "crate", "self", "super", "type",
        "where", "for", "while", "loop", "if", "else", "match", "return",
        "break", "continue", "in", "as", "ref", "move", "box", "dyn",
        "async", "await", "unsafe", "extern", "true", "false", "None", "Some",
        "Ok", "Err", "Vec", "String", "Option", "Result", "Box", "Rc", "Arc"
    ]

    static let goKeywords: [String] = [
        "func", "var", "const", "type", "struct", "interface", "map", "chan",
        "package", "import", "return", "if", "else", "for", "range", "switch",
        "case", "default", "break", "continue", "goto", "fallthrough",
        "go", "select", "defer", "nil", "true", "false",
        "int", "int8", "int16", "int32", "int64",
        "uint", "uint8", "uint16", "uint32", "uint64",
        "float32", "float64", "complex64", "complex128",
        "string", "bool", "byte", "rune", "error", "any"
    ]

    static let goBuiltins: [String] = [
        "make", "new", "len", "cap", "append", "copy", "delete",
        "close", "panic", "recover", "print", "println"
    ]

    static let javaKeywords: [String] = [
        "public", "private", "protected", "static", "final", "abstract",
        "class", "interface", "enum", "extends", "implements", "import",
        "package", "return", "if", "else", "for", "while", "do", "try",
        "catch", "finally", "throw", "throws", "new", "this", "super",
        "instanceof", "switch", "case", "default", "break", "continue",
        "void", "int", "long", "double", "float", "boolean", "char",
        "byte", "short", "null", "true", "false", "synchronized",
        "volatile", "transient", "native", "strictfp", "assert"
    ]

    static let cKeywords: [String] = [
        "int", "long", "short", "char", "float", "double", "void",
        "unsigned", "signed", "const", "static", "extern", "register",
        "volatile", "auto", "inline", "restrict",
        "if", "else", "for", "while", "do", "switch", "case", "default",
        "break", "continue", "return", "goto",
        "struct", "union", "enum", "typedef",
        "sizeof", "NULL", "true", "false",
        "#include", "#define", "#ifdef", "#ifndef", "#endif", "#pragma"
    ]

    static let bashKeywords: [String] = [
        "echo", "export", "source", "cd", "ls", "mkdir", "rm", "mv", "cp",
        "cat", "grep", "sed", "awk", "find", "chmod", "chown", "sudo",
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
        "case", "esac", "in", "function", "return", "exit", "local",
        "read", "set", "unset", "shift", "trap", "exec", "eval",
        "true", "false", "test", "kill", "sleep", "printf", "pwd"
    ]

    static let sqlKeywords: [String] = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "EXISTS",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "ON",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "AS", "DISTINCT", "ALL", "UNION", "INTERSECT", "EXCEPT",
        "NULL", "IS", "LIKE", "BETWEEN", "CASE", "WHEN", "THEN", "ELSE", "END",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "DEFAULT",
        "NOT NULL", "AUTO_INCREMENT", "SERIAL", "RETURNING",
        "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
        "INT", "INTEGER", "VARCHAR", "TEXT", "BOOLEAN", "DATE", "TIMESTAMP", "FLOAT", "NUMERIC"
    ]

    static let sqlBuiltins: [String] = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST",
        "UPPER", "LOWER", "TRIM", "LENGTH", "SUBSTRING", "REPLACE",
        "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP", "EXTRACT",
        "ROW_NUMBER", "RANK", "DENSE_RANK", "OVER", "PARTITION",
        "CONCAT", "ROUND", "FLOOR", "CEIL", "ABS", "MOD", "POWER"
    ]
}
