// EmojiPickerView.swift
// Chappie
//
// Grid-based emoji picker shown in a popover above the input bar.
// Organized into categories with a tab bar for navigation.

import SwiftUI

// MARK: - Emoji Data

struct EmojiCategory {
    let icon: String
    let nameKey: LocalizedStringKey
    let emojis: [String]
}

let emojiCategories: [EmojiCategory] = [
    EmojiCategory(icon: "⭐️", nameKey: "emoji.category.frequent", emojis: [
        "😀","😂","🥹","😍","🤔","😎","🥳","😅","🙏","👍",
        "❤️","🔥","✅","🚀","💡","🎉","👀","💪","🤝","✨"
    ]),
    EmojiCategory(icon: "😀", nameKey: "emoji.category.smileys", emojis: [
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
    EmojiCategory(icon: "👍", nameKey: "emoji.category.gestures", emojis: [
        "👍","👎","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙",
        "👈","👉","👆","🖕","👇","☝️","✋","🤚","🖐","🖖",
        "👋","💪","🦾","✍️","🤝","🙌","👏","🫶","🤲","🙏",
        "✊","👊","🤛","🤜","👐","🫴","🫳","🫵","🤙","🫱"
    ]),
    EmojiCategory(icon: "❤️", nameKey: "emoji.category.hearts", emojis: [
        "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔",
        "❤️‍🔥","❤️‍🩹","❣️","💕","💞","💓","💗","💖","💘","💝",
        "💟","☮️","✝️","☯️","🫀","💌","💋","🫦","😻","💑"
    ]),
    EmojiCategory(icon: "🐶", nameKey: "emoji.category.animals", emojis: [
        "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯",
        "🦁","🐮","🐷","🐸","🐵","🙈","🙉","🙊","🐔","🐧",
        "🐦","🦆","🦅","🦉","🦇","🐺","🐗","🐴","🦄","🐝",
        "🐛","🦋","🐌","🐞","🐜","🦟","🦗","🐢","🐍","🦎"
    ]),
    EmojiCategory(icon: "🍕", nameKey: "emoji.category.food", emojis: [
        "🍕","🍔","🌮","🌯","🥙","🧆","🥚","🍳","🥘","🍲",
        "🍜","🍝","🍛","🍣","🍱","🥟","🦪","🍤","🍙","🍚",
        "🍘","🍥","🥮","🍡","🧁","🍰","🎂","🍮","🍭","🍬",
        "🍫","🍿","🍩","🍪","🌰","🥜","🍯","🧃","🥤","🧋"
    ]),
    EmojiCategory(icon: "🚀", nameKey: "emoji.category.symbols", emojis: [
        "✅","❌","⭕️","🔴","🟠","🟡","🟢","🔵","🟣","⚫️",
        "⚪️","🟤","🔶","🔷","🔸","🔹","🔺","🔻","💠","🔘",
        "🔲","🔳","▪️","▫️","◾","◽","◼️","◻️","🟥","🟧",
        "🚀","💡","🔥","⚡️","💥","🌟","✨","🎉","🎊","🏆",
        "🥇","🎯","🎪","🎭","🎨","🖼","🎬","🎤","🎧","🎵"
    ])
]

// MARK: - EmojiPickerView

/// Grid-based emoji picker shown in a popover above the input bar.
struct EmojiPickerView: View {

    let onSelect: (String) -> Void

    @State private var selectedCategory = 0

    // 10 emoji per row, fixed 30pt cells
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 10)

    var body: some View {
        VStack(spacing: 0) {
            // Category tab bar
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

            // Emoji grid for the selected category
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
