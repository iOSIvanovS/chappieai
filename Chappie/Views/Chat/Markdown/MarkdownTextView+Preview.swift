// MarkdownTextView+Preview.swift
// Chappie

import SwiftUI

#Preview("Multi-language highlighting — Dark") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            CodeBlockView(code: """
            def greet(name: str) -> str:
                # Say hello
                return f"Hello, {name}!"

            for i in range(10):
                print(greet("World"))
            """, language: "python")

            CodeBlockView(code: """
            const fetchUser = async (id: number): Promise<User> => {
                // Load user from API
                const res = await fetch(`/api/users/${id}`)
                return res.json()
            }
            """, language: "typescript")

            CodeBlockView(code: """
            fn main() {
                let mut v: Vec<i32> = Vec::new();
                // Push some values
                for i in 0..10 {
                    v.push(i * 2);
                }
                println!("{:?}", v);
            }
            """, language: "rust")

            CodeBlockView(code: """
            #!/bin/bash
            # Deploy script
            export ENV=production
            if [ "$1" == "--dry-run" ]; then
                echo "Dry run mode"
                exit 0
            fi
            cd /app && ./deploy.sh
            """, language: "bash")

            CodeBlockView(code: """
            SELECT u.name, COUNT(o.id) AS orders
            FROM users u
            LEFT JOIN orders o ON o.user_id = u.id
            WHERE u.active = true
            GROUP BY u.name
            ORDER BY orders DESC
            LIMIT 10;
            """, language: "sql")
        }
        .padding()
    }
    .frame(width: 650, height: 900)
    .background(Color(NSColor.windowBackgroundColor))
    .preferredColorScheme(.dark)
}

#Preview("Multi-language highlighting — Light") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            CodeBlockView(code: """
            import Foundation

            struct User {
                let id: UUID
                var name: String
                var isValid: Bool { !name.isEmpty }
            }

            func greet(_ user: User) -> String {
                return "Hello, \\(user.name)!"
            }
            """, language: "swift")

            CodeBlockView(code: """
            {
                "user": {
                    "id": 42,
                    "name": "Sergey",
                    "active": true,
                    "score": 3.14,
                    "address": null
                }
            }
            """, language: "json")

            CodeBlockView(code: """
            -- Users table
            CREATE TABLE users (
                id   SERIAL PRIMARY KEY,
                name VARCHAR(255) NOT NULL,
                role VARCHAR(50)  DEFAULT 'user'
            );

            SELECT id, name FROM users WHERE role = 'admin';
            """, language: "sql")
        }
        .padding()
    }
    .frame(width: 650, height: 700)
    .background(Color(NSColor.windowBackgroundColor))
    .preferredColorScheme(.light)
}

#Preview("Markdown with code — Light") {
    ScrollView {
        MarkdownTextView(text: """
        Here's how it works:

        ## Architecture

        Using the **MVVM** pattern with the `@Observable` macro.

        ```swift
        // Main ViewModel
        @Observable
        @MainActor
        final class ChappieViewModel {
            var messages: [ChatMessage] = []
            var isThinking: Bool = false
        }
        ```
        """)
        .padding()
    }
    .frame(width: 600, height: 400)
    .background(Color(NSColor.windowBackgroundColor))
    .preferredColorScheme(.light)
}
