// ToolDefinitions+JSONTools.swift
// ChappieCore
//
// json_info / json_schema / json_get / json_find. Read-only, any size of JSON file, answers stay small.

import Foundation

extension ToolExecutionService {

    func jsonTools(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let projectArg = AIToolProperty(type: "string", description: fileToolProjectArgDescription(for: allInfos))
        let pathArg = AIToolProperty(type: "string", description: "Relative path to the JSON file")
        let maxChars = AIToolProperty(
            type: "string",
            description: "Optional size limit of the answer in characters (default 8000, from 1000 to 40000). Raise it only when a result was cut."
        )
        let pathSyntax = """
        Paths inside the JSON are a JSON ARRAY of segments, not a dotted string, because keys contain dots: \
        ["strings", "chat.send.title", "localizations", "ru"]. A segment is a key, an integer array position \
        (0 first, -1 last), or a pattern: "*" any key or item, "add_*" / "?" glob, "**" this node and everything below it. \
        A literal * or ? in a key is written \\* or \\?.
        """

        return [
            AITool(function: AIFunctionDefinition(
                name: "json_info",
                description: """
                Facts about a JSON file of ANY size, in a few hundred tokens: size, lines, root type, nesting, counts by type, \
                top-level keys with sizes and line numbers, the largest containers, and the file's STYLE (indent, ' : ' or ': ', \
                line endings, escaping of '/' and non-ASCII, key order, how empty objects are written, comments, BOM).
                Use FIRST on any JSON file you have not seen, before read_file (which refuses big files anyway). \
                Works for package.json, tsconfig (comments allowed), Xcode .xcstrings, API dumps.
                """,
                parameters: AIToolParameters(
                    properties: ["path": pathArg, "project": projectArg, "max_chars": maxChars],
                    required: ["path", "project"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "json_schema",
                description: """
                The SHAPE of a JSON file without its data: which fields exist, their types, which are optional (with the place of \
                the first example), which hold several kinds, small sets of allowed string values, number ranges, array lengths. \
                A big map such as the 472 keys under "strings" is recognised as a DICTIONARY and described once, with sample keys \
                and the shape of its values.
                Use to learn the structure of a large file before searching or editing. `e.g. at [...]` in the answer is a path you \
                can pass to json_get to see a real example.
                \(pathSyntax)
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg, "project": projectArg,
                        "at": AIToolProperty(type: "string", description: "Optional JSON array path: describe only this part, for example [\"strings\"]. Wildcards merge all matches into one shape. Default: the whole file."),
                        "depth": AIToolProperty(type: "string", description: "How many levels of nesting to describe (default 6, 1 to 20)."),
                        "max_chars": maxChars
                    ],
                    required: ["path", "project"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "json_get",
                description: """
                Show one part of a JSON file. If the part fits (default 8000 characters), you get the file's OWN lines with line \
                numbers, exactly as written: use it to see the style and the exact text before an edit. If it is bigger, you get a \
                collapsed view where deep or long containers become `{… 472 keys}  // L120-L9800`; open any of them by passing its path.
                A wrong path is explained: where it stops working and which keys exist there.
                \(pathSyntax)
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg, "project": projectArg,
                        "at": AIToolProperty(type: "string", description: "JSON array path of the part to show, for example [\"strings\", \"Cancel\"]. Default: the whole file (collapsed if big)."),
                        "depth": AIToolProperty(type: "string", description: "Force the collapsed view with this many levels open. Omit to get the file's own lines when they fit."),
                        "max_chars": maxChars
                    ],
                    required: ["path", "project"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "json_find",
                description: """
                Search a JSON file by STRUCTURE, including what is MISSING. `at` chooses the subjects (every value that matches that \
                path), the conditions filter them (ALL must hold), and relative paths inside conditions start at the subject.
                Conditions: key (glob over the subject's own key), kind (object/array/string/number/bool/null), has / missing \
                (a relative path exists / does not exist), value_at + equals / not_equals / contains (compare the value found at a \
                relative path; strings decoded, other scalars as written: 5, true, null).
                Output: paths (default, with line numbers), keys, values, or count; group_by (relative path) counts subjects per value.
                Examples:
                - Entries without a Russian translation: at ["strings","*"], missing ["localizations","ru"], output keys.
                - Which translations are not yet 'translated': at ["strings","*","localizations","*"], value_at ["stringUnit","state"], not_equals "translated".
                - Every key that looks like a title anywhere: at ["**"], key "*title*", output values.
                - How many entries per state: at ["strings","*","localizations","ru"], group_by ["stringUnit","state"].
                \(pathSyntax)
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg, "project": projectArg,
                        "at": AIToolProperty(type: "string", description: "JSON array path choosing the subjects. Default: every value in the file."),
                        "key": AIToolProperty(type: "string", description: "Glob the subject's own key must match, for example \"add_*\"."),
                        "kind": AIToolProperty(type: "string", description: "The subject must be of this kind: object, array, string, number, bool or null."),
                        "has": AIToolProperty(type: "string", description: "JSON array path relative to the subject that must exist."),
                        "missing": AIToolProperty(type: "string", description: "JSON array path relative to the subject that must NOT exist."),
                        "value_at": AIToolProperty(type: "string", description: "JSON array path relative to the subject: the value that equals / not_equals / contains look at. Default: the subject itself."),
                        "equals": AIToolProperty(type: "string", description: "The value must equal this text."),
                        "not_equals": AIToolProperty(type: "string", description: "The value must differ from this text (a subject with no value at value_at passes)."),
                        "contains": AIToolProperty(type: "string", description: "The value must contain this text."),
                        "ignore_case": AIToolProperty(type: "string", description: "true: equals, not_equals and contains ignore case."),
                        "output": AIToolProperty(type: "string", description: "paths (default), keys, values or count."),
                        "show": AIToolProperty(type: "string", description: "JSON array path relative to the subject: value to print next to each result (paths) or instead of the subject (values)."),
                        "group_by": AIToolProperty(type: "string", description: "JSON array path relative to the subject: count subjects per distinct value found there."),
                        "limit": AIToolProperty(type: "string", description: "Most results to list (default 50, up to 500). The match count is always exact."),
                        "max_chars": maxChars
                    ],
                    required: ["path", "project"]
                )
            ))
        ]
    }
}
