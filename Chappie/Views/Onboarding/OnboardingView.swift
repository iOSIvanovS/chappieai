// OnboardingView.swift
// Chappie
//
// First-launch onboarding screen.
//
// FLOW:
// Step 1: User name (optional) — saved directly to global memory via viewModel.saveUserName()
// Step 2: First AI provider setup (required) — uses AddProviderSheet
//         Cannot proceed until at least one provider is validated and saved.
//
// The app does NOT allow entry until at least one provider is configured.
// User name is written straight to SwiftData global memory — no UserDefaults staging.
//
// NOTE: "Popular services" hint block removed — services change, hints go stale.

import SwiftUI
import ChappieCore

// MARK: - OnboardingView

struct OnboardingView: View {

    // MARK: - Dependencies

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

                Text("Чаппи работает с любым сервисом, совместимым с протоколом OpenAI.\nДобавьте эндпойнт, ключ и выберите модели.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

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
        .frame(maxWidth: 480)
    }
}
