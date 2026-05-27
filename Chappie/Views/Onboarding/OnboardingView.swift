// OnboardingView.swift
// Chappie
//
// IT-10: First-launch onboarding screen.
// Replaces the old SettingsView-based onboarding (which only asked for an API key).
//
// FLOW:
// Step 1: User name (optional) — saved directly to global memory via viewModel.saveUserName()
// Step 2: First AI provider setup (required) — uses AddProviderSheet
//         Cannot proceed until at least one provider is validated and saved.
//
// The app does NOT allow entry until at least one provider is configured.
// User name is written straight to SwiftData global memory — no UserDefaults staging.

import SwiftUI
import ChappieCore

// MARK: - OnboardingView

struct OnboardingView: View {

    // MARK: - Dependencies

    // @Observable ViewModel — passed as a plain parameter (not @ObservedObject)
    var viewModel: ChappieViewModel

    // MARK: - State

    @State private var step: OnboardingStep = .welcome
    @State private var userName: String = ""
    @State private var showAddProvider: Bool = false

    private enum OnboardingStep {
        case welcome
        case provider
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Image("Chappie")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .opacity(0.3)

            VStack(spacing: 0) {
                Spacer()

                switch step {
                case .welcome:
                    welcomeStep
                case .provider:
                    providerStep
                }

                Spacer()
            }
            .padding(40)
        }
        .sheet(isPresented: $showAddProvider) {
            AddProviderSheet(
                providerStore: viewModel.providerStore,
                onSaved: {
                    showAddProvider = false
                    viewModel.reloadProviders()
                },
                onCancel: {
                    showAddProvider = false
                }
            )
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image("Chappie")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.accentColor.opacity(0.3), lineWidth: 2))

                Text("Привет! Я Чаппи.")
                    .font(.largeTitle.bold())

                Text("Универсальный AI-агент. Давайте познакомимся.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Как вас называть?", systemImage: "person.fill")
                    .font(.headline)

                TextField("Имя (необязательно)", text: $userName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16))
                    .frame(maxWidth: 320)

                Text("Нейронка будет обращаться к вам по имени")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                // Save directly to global memory — no UserDefaults staging needed.
                viewModel.saveUserName(userName)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    step = .provider
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Продолжить")
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return)
        }
        .padding(40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 480)
    }

    // MARK: - Step 2: Provider Setup

    private var providerStep: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)

                Text("Настройте AI-провайдера")
                    .font(.largeTitle.bold())

                Text("Чаппи работает с любым сервисом, совместимым с протоколом OpenAI.\nДобавьте эндпойнт, ключ и выберите модель.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Популярные сервисы:")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    hintRow(name: "AITunnel", url: "https://api.aitunnel.ru/v1/chat/completions")
                    hintRow(name: "OpenAI", url: "https://api.openai.com/v1/chat/completions")
                    hintRow(name: "Groq", url: "https://api.groq.com/openai/v1/chat/completions")
                    hintRow(name: "Ollama (local)", url: "http://localhost:11434/v1/chat/completions")
                }
            }
            .padding(16)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 420)

            Button {
                showAddProvider = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Добавить провайдера")
                        .font(.system(size: 16, weight: .semibold))
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    step = .welcome
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                    Text("Назад")
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 520)
    }

    // MARK: - Hint Row

    private func hintRow(name: String, url: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 90, alignment: .leading)
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
