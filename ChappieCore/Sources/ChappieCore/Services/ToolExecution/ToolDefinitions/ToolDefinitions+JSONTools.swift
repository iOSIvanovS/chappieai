// ToolDefinitions+JSONTools.swift
// ChappieCore
//
// json_info / json_schema / json_get / json_find (read-only) and json_edit (in-place changes).
// Any size of JSON file, answers stay small.

import Foundation

extension ToolExecutionService {

    func jsonTools(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let projectArg = AIToolProperty(type: "string", description: fileToolProjectArgDescription(for: allInfos))
        let pathArg = AIToolProperty(type: "string", description: "Relative path to the JSON file")
        let maxChars = AIToolProperty(
            type: "integer",
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
                        "depth": AIToolProperty(type: "integer", description: "How many levels of nesting to describe (default 6, 1 to 20)."),
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
                        "depth": AIToolProperty(type: "integer", description: "Force the collapsed view with this many levels open. Omit to get the file's own lines when they fit."),
                        "max_chars": maxChars
                    ],
                    required: ["path", "project"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "json_find",
                description: """
                Search a JSON file by STRUCTURE, including what is MISSING. `at` chooses the subjects (every value that matches that \
                path), the conditions filter them, and relative paths inside conditions start at the subject.
                Conditions (ALL must hold, unless match_any is true): key (glob over the subject's own key), kind \
                (object/array/string/number/bool/null), has / missing (a relative path exists / does not exist), and value_at + \
                equals / not_equals / contains / not_contains / same_as. Those last five compare the value found at value_at \
                (default: the subject itself); strings are decoded, other scalars as written (5, true, null).
                - same_as points at ANOTHER path of the same subject: "this value equals that one" — e.g. a translation that was \
                copied from English instead of written.
                match_any: true turns the conditions into OR, so one call answers "missing ru OR not translated" without merging \
                two results by hand.
                Output: paths (default, with line numbers), keys, values, or count; group_by (relative path) counts subjects per value.
                Examples:
                - Entries without a Russian translation: at ["strings","*"], missing ["localizations","ru"], output keys.
                - Which translations are not yet 'translated': at ["strings","*","localizations","*"], value_at ["stringUnit","state"], not_equals "translated".
                - Entries that need work, in ONE call: at ["strings","*"], missing ["localizations","ru"], match_any true, \
                value_at ["localizations","ru","stringUnit","state"], not_equals "translated", output keys.
                - Russian text copied from English: at ["strings","*"], value_at ["localizations","ru","stringUnit","value"], \
                same_as ["localizations","en","stringUnit","value"], output count.
                - Every key that looks like a title anywhere: at ["**"], key "*title*", output values.
                - How many entries per state: at ["strings","*","localizations","ru"], group_by ["stringUnit","state"].
                \(pathSyntax)
                Unknown argument names are refused rather than ignored: a near miss such as "equals_path" or "any_of" would \
                otherwise fall through and answer a DIFFERENT question with no sign of it.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg, "project": projectArg,
                        "at": AIToolProperty(type: "string", description: "JSON array path choosing the subjects. Default: every value in the file."),
                        "key": AIToolProperty(type: "string", description: "Glob the subject's own key must match, for example \"add_*\"."),
                        "kind": AIToolProperty(type: "string", description: "The subject must be of this kind: object, array, string, number, bool or null."),
                        "has": AIToolProperty(type: "string", description: "JSON array path relative to the subject that must exist."),
                        "missing": AIToolProperty(type: "string", description: "JSON array path relative to the subject that must NOT exist. This is how you match what is ABSENT."),
                        "value_at": AIToolProperty(type: "string", description: "JSON array path relative to the subject: the value that equals / not_equals / contains / not_contains / same_as look at. Default: the subject itself."),
                        "equals": AIToolProperty(type: "string", description: "The value must equal this text."),
                        "not_equals": AIToolProperty(type: "string", description: "The value must differ from this text (a subject with no value at value_at passes)."),
                        "contains": AIToolProperty(type: "string", description: "The value must contain this text."),
                        "not_contains": AIToolProperty(type: "string", description: "The value must NOT contain this text — text that was left in English, keys still holding a placeholder, and so on."),
                        "same_as": AIToolProperty(type: "string", description: "JSON array path relative to the subject: another place whose value this one must EQUAL. Comparison follows ignore_case."),
                        "ignore_case": AIToolProperty(type: "boolean", description: "true: equals, not_equals, contains, not_contains and same_as ignore case."),
                        "match_any": AIToolProperty(type: "boolean", description: "false (default): every given condition must hold. true: at least one must hold (OR)."),
                        "output": AIToolProperty(type: "string", description: "paths (default), keys, values or count."),
                        "show": AIToolProperty(type: "string", description: "JSON array path relative to the subject: value to print next to each result (paths) or instead of the subject (values)."),
                        "group_by": AIToolProperty(type: "string", description: "JSON array path relative to the subject: count subjects per distinct value found there."),
                        "limit": AIToolProperty(type: "integer", description: "Most results to list (default 50, up to 500). The match count is always exact."),
                        "max_chars": maxChars
                    ],
                    required: ["path", "project"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "json_edit",
                description: """
                Change a JSON file IN PLACE: only the bytes of the edited places change, every other byte (indent, separators, key \
                order, comments, escaping) stays exactly as it was. New keys and values are written in the file's own style \
                (see json_info). Several operations in one call; all paths refer to the file AS IT IS NOW, so the order of \
                operations does not matter. If anything is wrong NOTHING is written and every problem is listed.
                `edits` is a JSON array of operations:
                - {"op":"set","at":PATH,"value":ANY} replace the value at an existing path.
                - {"op":"delete","at":PATH} remove an object member or an array item (the commas are fixed).
                - {"op":"insert","at":CONTAINER_PATH,"key":"name","value":ANY,"position":P} add a member to an object (key required) \
                or an item to an array (no key). position (default "auto"): \
                in an object "auto" keeps an alphabetical object alphabetical and otherwise appends, and the choices are \
                "start", "end", "sorted" (alphabetical place, needs an alphabetical object), {"after":"key"}, {"before":"key"}; \
                in an array the choices are "start", "end" and an integer index (0 first, -1 the place of the last item, \
                counting from the end like a path segment) — an array has no keys, so {"after":...} does not apply there.
                - {"op":"rename","at":PATH,"to":"newKey"} rename an object member, value untouched.
                Every operation may carry "expect":VALUE (not for insert): the current value must equal it, otherwise the call is \
                refused. Use it when the file may have changed since you read it.
                Each `at` must match exactly ONE place. Value types are real JSON (a number is 5, not "5").
                Use dry_run=true to see the changed lines without writing. The answer shows every changed place, old and new lines.
                Example, add a Russian translation to an Xcode string catalog: \
                [{"op":"insert","at":["strings","Cancel","localizations"],"key":"ru","value":{"stringUnit":{"state":"translated","value":"Отмена"}}}]
                Use json_find first to learn what is missing, json_get to see the neighbours. Prefer this over write_file / patch_file \
                for JSON files: no need to read the file, no risk of breaking its format.
                \(pathSyntax)
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg, "project": projectArg,
                        "edits": AIToolProperty(
                            type: "array",
                            description: "The operations to apply, in any order. Up to 2000 per call.",
                            items: AIToolItemShape(
                                type: "object",
                                description: """
                                One operation. {"op":"set","at":PATH,"value":ANY}, {"op":"delete","at":PATH}, \
                                {"op":"insert","at":CONTAINER_PATH,"key":"name","value":ANY,"position":P}, \
                                {"op":"rename","at":PATH,"to":"newKey"}. Every op except insert may carry "expect":VALUE.
                                """
                            )
                        ),
                        "dry_run": AIToolProperty(type: "boolean", description: "true: check and show what would change, write nothing."),
                        "max_chars": maxChars
                    ],
                    required: ["path", "project", "edits"]
                )
            ))
        ]
    }
}
