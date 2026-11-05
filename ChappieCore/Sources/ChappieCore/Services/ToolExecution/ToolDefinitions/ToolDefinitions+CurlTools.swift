// ToolDefinitions+CurlTools.swift
// ChappieCore
//
// Curl-Chappie tool definitions: send HTTP requests to the hosts the user listed for this thread,
// with project secrets referenced by name (the model never sees their values).

import Foundation

extension ToolExecutionService {

    func curlTools(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let hosts = activeMemoryContext.curlHosts
        let hostText = hosts.isEmpty
            ? "No hosts are configured in this thread yet."
            : "Hosts of this thread: " + hosts.map { "\($0.name) = \($0.origin) [\($0.permission.rawValue)\($0.loginPath.isEmpty ? "" : ", login \($0.loginPath)")]" }.joined(separator: "; ") + "."

        // Names only: the model has to know what to call a secret, never what it contains.
        let keychain = CurlSecretKeychain()
        let secretEntries = allInfos.flatMap { info -> [CurlSecretCatalog.Entry] in
            let projectSettings = settings(of: info)
            guard projectSettings.agentRole == .executor else { return [] }
            return projectSettings.curlSecrets.map {
                CurlSecretCatalog.Entry(project: info.name, secret: $0, missing: keychain.missingFields(of: $0))
            }
        }
        let secretText = CurlSecretCatalog.describe(secretEntries)

        let project = AIToolProperty(type: "string", description: fileToolProjectArgDescription(for: allInfos) + " The project supplies the secrets.")
        let host = AIToolProperty(type: "string", description: "Host name or origin from the thread's host list. Use with `path` instead of a full `url`.")
        let url = AIToolProperty(type: "string", description: "Absolute URL on a listed host. May contain {{secret:name.field}} and {{var:name}} after the host, never inside the scheme or host.")
        let session = AIToolProperty(type: "string", description: "Name of the secret (bound to this host) the request acts as. Its session (token, cookies) is applied automatically. Omit for an anonymous request.")

        let references = """
        References: {{secret:name.login}}, {{secret:name.password}}, {{secret:name.value}} (project secrets bound to the request host; names may contain spaces and any letters) \
        and {{var:name}} (values saved in the session). Values are substituted by the app and never shown to you; tokens and cookies in responses are replaced by <redacted>.
        \(secretText)
        """

        return [
            AITool(function: AIFunctionDefinition(
                name: "curl_request",
                description: """
                Send an HTTP request to a host of this thread's allow-list and get status, headers and body (like Postman). \
                Each host has a permission: readOnly (GET/HEAD/OPTIONS), readAndLogin (also POST to its login path only) or full. \
                Redirects are not followed (you get the Location). Files are not downloaded. Non-ASCII text in JSON (\\uXXXX escapes) is shown decoded.
                \(references)
                \(hostText)
                Give one body at most: `json` (JSON text), `form` (object, sent urlencoded) or `text`.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "project": project,
                        "method": AIToolProperty(type: "string", description: "GET (default), HEAD, OPTIONS, POST, PUT, PATCH or DELETE."),
                        "url": url,
                        "host": host,
                        "path": AIToolProperty(type: "string", description: "Path (and optional query) on `host`, e.g. /api/issues."),
                        "query": AIToolProperty(type: "object", description: "Query parameters as an object."),
                        "headers": AIToolProperty(type: "object", description: "Extra headers as an object. Authorization and cookies come from the session; Cookie/Host cannot be set."),
                        "json": AIToolProperty(type: "string", description: "JSON request body as text."),
                        "form": AIToolProperty(type: "object", description: "Form body as an object, sent as application/x-www-form-urlencoded."),
                        "text": AIToolProperty(type: "string", description: "Raw text body."),
                        "content_type": AIToolProperty(type: "string", description: "Content-Type for `text`."),
                        "session": session,
                        "pick": AIToolProperty(type: "string", description: "Optional JSON array of paths to keep from a JSON body, e.g. [\"data.items[*].id\", \"paginate.total\"]. `[*]` takes every element of an array. A trailing `{a,b}` keeps only those fields of each object, e.g. `data.items[*].{id,name}` gives [{\"id\":1,\"name\":\"x\"}]. Returns {\"path\": value}; missing paths are null. Not applied to 4xx/5xx responses. Use it to keep large responses short; the full response stays available to curl_extract."),
                        "show_headers": AIToolProperty(type: "string", description: "Response headers: by default routine ones (CORS, cache, date, server, security) are folded into a count and every other header is shown. Pass \"all\" to see every header.")
                    ],
                    required: []
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "curl_session",
                description: """
                Manage a login session. action=login sends the login request ONCE (the host needs permission readAndLogin or full and the \
                path must be its login path), stores the values you point at and remembers how to apply them, so later curl_request calls with the same \
                `session` get the token automatically and a 401 re-logs in by itself. Sessions are shared by all threads and projects that use the same \
                credentials for the same host, so a login done once serves everyone.
                action=info shows what the session holds (values hidden); action=reset forgets it.
                \(references)
                Login example: method POST, host Dev, path /api/login/token, session "sk", form {"login":"{{secret:sk.login}}","password":"{{secret:sk.password}}"}, \
                extract [{"name":"access_token","from":"json:access_token"},{"name":"token_type","from":"json:token_type","sensitive":false}], \
                apply [{"header":"Authorization","template":"{{var:token_type}} {{var:access_token}}"}].
                `from` is json:dotted.path (arrays as items[0].id), header:Name or cookie:name.
                \(hostText)
                """,
                parameters: AIToolParameters(
                    properties: [
                        "project": project,
                        "action": AIToolProperty(type: "string", description: "login (default), info or reset."),
                        "method": AIToolProperty(type: "string", description: "Login request method, POST by default."),
                        "url": url,
                        "host": host,
                        "path": AIToolProperty(type: "string", description: "Login path on `host`."),
                        "headers": AIToolProperty(type: "object", description: "Extra headers for the login request."),
                        "json": AIToolProperty(type: "string", description: "JSON login body as text."),
                        "form": AIToolProperty(type: "object", description: "Form login body as an object."),
                        "text": AIToolProperty(type: "string", description: "Raw text login body."),
                        "content_type": AIToolProperty(type: "string", description: "Content-Type for `text`."),
                        "session": AIToolProperty(type: "string", description: "Name of the secret (bound to this host) whose credentials identify the session. Required for login."),
                        "extract": AIToolProperty(type: "string", description: "JSON array of rules: [{name, from, sensitive?}]. sensitive defaults to true (hidden everywhere)."),
                        "apply": AIToolProperty(type: "string", description: "JSON array of rules: [{header, template}] applied to every later request of the session."),
                        "force": AIToolProperty(type: "boolean", description: "Log in again even if the session already exists.")
                    ],
                    required: []
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "curl_extract",
                description: """
                Save a value from the LAST response of a session into a variable, to use as {{var:name}} in later requests \
                (e.g. the id of a created issue). Variables named like credentials are hidden by default.
                \(hostText)
                """,
                parameters: AIToolParameters(
                    properties: [
                        "project": project,
                        "host": host,
                        "session": session,
                        "name": AIToolProperty(type: "string", description: "Variable name: letters, digits, _ and -."),
                        "from": AIToolProperty(type: "string", description: "json:dotted.path, header:Name or cookie:name."),
                        "sensitive": AIToolProperty(type: "boolean", description: "Hide the value everywhere. Default: true for credential-like names, false otherwise.")
                    ],
                    required: ["host", "name", "from"]
                )
            ))
        ]
    }
}
