//
//  InputBarView.swift
//  Chappie
//
//  WHY THIS FILE EXISTS:
//  Input panel — standalone UI component with its own logic:
//  - multiline TextField limited to 10 lines
//  - disabled when no workspace selected or Chappie is thinking
//  - send on Enter, newline on ⌥+Enter
//  - emoji picker button that opens a popover with emoji categories
//  Extracted from ContentView so it can be modified independently.
//

import SwiftUI

// MARK: - Emoji Data

/// Emoji categories shown in the picker popover.
private struct EmojiCategory {
    let icon: String
    let name: String
    let emojis: [String]
}

private let emojiCategories: [EmojiCategory] = [
    EmojiCategory(icon: "⭐️", name: "Частые", emojis: [
        "😀","😂","🥹","😍","🤔","😎","🥳","😅","🙏","👍",
        "❤️","🔥","✅","🚀","💡","🎉","👀","💪","🤝","✨"
    ]),
    EmojiCategory(icon: "😀", name: "Смайлики", emojis: [
        "😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃",
        "😉","😊","😇","🥰","😍","🤩","😘","😗","😚","😙",
        "🥲","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫",
        "🤔","🤐","🤨","😐","😑","😶","😏","😒","🙄","😬",
        "🤥","😌","😔","😪","🤤","😴","😷","🤒","🤕","🥴",
        "😵","🤯","🤠","🥸","😎","🤓","🧐","😕","😟","🙁",
        "😮","😯","😲","😳","🥺","🥹","😦","😧","😨","😰",
        "😥","😢","😭","😱","😖","😣","😞","😓","😩","😫",
        "🥱","😤","😡","😠","🤬","😈","👿","💀","☠️","🤡"
    ]),
    EmojiCategory(icon: "👍", name: "Жесты", emojis: [
        "👍","👎","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙",
        "👈","👉","👆","🖕","👇","☝️","👍","✋","🤚","🖐",
        "🖖","👋","🤙","💪","🦾","🖕","✍️","🤝","🙌","👏",
        "🫶","🤲","🙏","✊","👊","🤛","🤜","👐","🫴","🫳"
    ]),
    EmojiCategory(icon: "❤️", name: "Сердечки", emojis: [
        "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔",
        "❤️‍🔥","❤️‍🩹","❣️","💕","💞","💓","💗","💖","💘","💝",
        "💟","☮️","✝️","☯️","🫀","💌","💋","🫦","😻","💑"
    ]),
    EmojiCategory(icon: "🐶", name: "Животные", emojis: [
        "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯",
        "🦁","🐮","🐷","🐸","🐵","🙈","🙉","🙊","🐔","🐧",
        "🐦","🦆","🦅","🦉","🦇","🐺","🐗","🐴","🦄","🐝",
        "🐛","🦋","🐌","🐞","🐜","🦟","🦗","🐢","🐍","🦎"
    ]),
    EmojiCategory(icon: "🍕", name: "Еда", emojis: [
        "🍕","🍔","🌮","🌯","🥙","🧆","🥚","🍳","🥘","🍲",
        "🍜","🍝","🍛","🍣","🍱","🥟","🦪","🍤","🍙","🍚",
        "🍘","🍥","🥮","🍡","🧁","🍰","🎂","🍮","🍭","🍬",
        "🍫","🍿","🍩","🍪","🌰","🥜","🍯","🧃","🥤","🧋"
    ]),
    EmojiCategory(icon: "🚀", name: "Символы", emojis: [
        "✅","❌","⭕️","🔴","🟠","🟡","🟢","🔵","🟣","⚫️",
        "⚪️","🟤","🔶","🔷","🔸","🔹","🔺","🔻","💠","🔘",
        "🔲","🔳","▪️","▫️","◾","◽","◼️","◻️","🟥","🟧",
        "🚀","💡","🔥","⚡️","💥","🌟","✨","🎉","🎊","🏆",
        "🥇","🎯","🎪","🎭","🎨","🖼","🎬","🎤","🎧","🎵"
    ])
]

// MARK: - Emoji Picker Popover

/// Grid-based emoji picker shown in a popover.
private struct EmojiPickerView: View {
    
    let onSelect: (String) -> Void
    
    // Track selected category tab
    @State private var selectedCategory = 0
    
    // Emoji grid columns — 10 per row
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 10)
    
    var body: some View {
        VStack(spacing: 0) {
            
            // Category tabs
            HStack(spacing: 0) {
                ForEach(emojiCategories.indices, id: \.self) { index in
                    Button(action: { selectedCategory = index }) {
                        Text(emojiCategories[index].icon)
                            .font(.system(size: 16))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                selectedCategory == index
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            
            Divider()
            
            // Emoji grid for selected category
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(emojiCategories[selectedCategory].emojis, id: \.self) { emoji in
                        Button(action: { onSelect(emoji) }) {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(height: 180)
        }
        .frame(width: 340)
    }
}

// MARK: - InputBarView

/// Bottom input panel for the chat.
///
/// Contains a multiline TextField, an emoji picker button, and a send button.
/// Disabled when:
/// - no workspace selected (nowhere to write files)
/// - Chappie is thinking (can't send a new request while previous is in progress)
struct InputBarView: View {
    
    /// Text the user is typing.
    /// Binding so ContentView can reset the field after sending.
    @Binding var prompt: String
    
    /// Flag: is a workspace selected. Without a workspace, input is blocked.
    let isWorkspaceSelected: Bool
    
    /// Flag: Chappie is thinking. While thinking — input is blocked.
    let isThinking: Bool
    
    /// Callback triggered when the user presses "Send".
    /// Send logic lives in ViewModel, not here — component just signals.
    let onSend: () -> Void
    
    /// Controls emoji picker popover visibility.
    @State private var showEmojiPicker = false
    
    /// Computed flag: can the user send right now.
    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && isWorkspaceSelected
        && !isThinking
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                
                TextField(
                    "Напиши сообщение... (Enter — отправить, ⌥+Enter — перенос)",
                    text: $prompt,
                    axis: .vertical  // Allow vertical growth
                )
                .textFieldStyle(.roundedBorder)
                // Limit growth: min 1 line, max 10.
                // Prevents long prompts from taking over the screen.
                .lineLimit(1...10)
                .onSubmit {
                    // onSubmit fires on Enter.
                    // ⌥+Enter inserts a newline — standard TextField behavior.
                    onSend()
                }
                .disabled(!isWorkspaceSelected || isThinking)
                
                // Emoji picker button — opens popover above the input bar
                Button(action: { showEmojiPicker.toggle() }) {
                    Text("😊")
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Вставить эмодзи")
                .popover(isPresented: $showEmojiPicker, arrowEdge: .top) {
                    EmojiPickerView { emoji in
                        // Append emoji at end of current text
                        prompt += emoji
                        showEmojiPicker = false
                    }
                }
                // Align with bottom of TextField on multiline input
                .padding(.bottom, 4)
                
                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                // Small bottom offset so button aligns with TextField bottom edge
                // when multiline input is active
                .padding(.bottom, 2)
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
        .padding(.horizontal)
        .padding(.bottom, 16)
    }
}

#Preview {
    VStack {
        Spacer()
        InputBarView(
            prompt: .constant(""),
            isWorkspaceSelected: true,
            isThinking: false,
            onSend: { print("Send!") }
        )
    }
    .frame(width: 600, height: 200)
}
