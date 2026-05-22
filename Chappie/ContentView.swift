//
//  ContentView.swift
//  Chappie
//
//  Created by   Сергей on 21.05.2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var viewModel = ChappieViewModel()
    @State private var prompt: String = ""

    var body: some View {
        NavigationSplitView {
            List {
                Section("Контекст") {
                    if let workspaceURL = viewModel.workspaceURL {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Рабочая папка:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(workspaceURL.lastPathComponent)
                                .font(.headline)
                        }
                        
                        Button("Сменить папку...") {
                            selectWorkspace()
                        }
                        .buttonStyle(.link)
                        .padding(.top, 4)
                        
                    } else {
                        Button("Выбрать папку проекта...") {
                            selectWorkspace()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Чаппи")
        } detail: {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if viewModel.messages.isEmpty {
                                HStack {
                                    Text("Привет, Дилан! Я - Чаппи. Выбери проект и скажи, что нужно сделать.")
                                        .padding()
                                        .background(Color(NSColor.windowBackgroundColor))
                                        .cornerRadius(10)
                                        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                                    Spacer()
                                }
                            } else {
                                ForEach(viewModel.messages) { msg in
                                    HStack {
                                        if msg.isUser { Spacer() }
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(msg.text)
                                                .foregroundStyle(msg.isUser ? .white : .primary)
                                                .textSelection(.enabled)
                                            
                                            // 🔥 Монетка и стоимость снизу справа (только для ИИ)
                                            if let cost = msg.cost {
                                                Text(String(format: "🪙 %.2f ₽", cost))
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                            }
                                        }
                                        .padding()
                                        .background(msg.isUser ? Color.accentColor : Color(NSColor.windowBackgroundColor))
                                        .cornerRadius(10)
                                        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                                        
                                        if !msg.isUser { Spacer() }
                                    }
                                    .id(msg.id)
                                }
                            }
                            
                            if viewModel.isThinking {
                                HStack {
                                    ProgressView()
                                        .padding()
                                        .background(Color(NSColor.windowBackgroundColor))
                                        .cornerRadius(10)
                                        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                                    Spacer()
                                }
                                .id("ThinkingIndicator")
                            }
                            
                            Spacer(minLength: 0)
                                .id("BottomSpacer")
                        }
                        .padding()
                    }
                    .onAppear {
                        // Скроллим вниз при первоначальной загрузке интерфейса
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            proxy.scrollTo("BottomSpacer", anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        // Небольшая задержка, чтобы UI успел обновить фреймы перед скроллом
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo("BottomSpacer", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.isThinking) { _, isThinking in
                        if isThinking {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    proxy.scrollTo("BottomSpacer", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Напиши, что нужно сделать?", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...10) // Поле может расширяться до 10 строк
                        .onSubmit {
                            // В macOS onSubmit для TextField(axis: .vertical) срабатывает по нажатию Return (Enter).
                            // Для переноса строки внутри поля используется Option+Return (⌥+Enter).
                            sendMessage()
                        }
                        .disabled(viewModel.workspaceURL == nil || viewModel.isThinking)
                    
                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.isEmpty || viewModel.workspaceURL == nil || viewModel.isThinking)
                    .padding(.bottom, 2) // Выравниваем кнопку по нижнему краю многострочного поля
                }
                .padding(12)
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .toolbar {
                // 🔥 Постоянный баланс в тулбаре
                ToolbarItem(placement: .primaryAction) {
                    if let balance = viewModel.currentBalance {
                        HStack(spacing: 4) {
                            Image(systemName: "creditcard.fill")
                                .foregroundColor(.green)
                            Text(String(format: "%.2f ₽", balance))
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    }
                }
            }
        }
        .background {
            Image("Chappie")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .opacity(0.5)
        }
    }
    
    private func selectWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Выберите папку проекта для Чаппи"
        
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.setWorkspace(url)
        }
    }
    
    private func sendMessage() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.send(prompt: prompt)
        prompt = ""
    }
}

#Preview {
    ContentView()
}
