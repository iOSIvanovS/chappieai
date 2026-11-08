// EULAView.swift
// Chappie
//
// Terms of Use shown on first launch.
// Must be accepted before the user can proceed to onboarding or the main app.
//
// TRIGGER:
// Shown when AppState.shared.shouldShowEULA == true (UserDefaults flag "eulaAccepted").
// Acceptance calls AppState.shared.acceptEULA() — sets the flag, never shown again.
//
// WINDOW:
// On appear — centers the window via NSApp.mainWindow?.center().
// Size is controlled by .defaultSize(480×600) in ChappieApp.
// No automatic resizing after acceptance — user is free to resize as they wish.
//
// LEGAL PURPOSE:
// Establishes that Chappie is a developer tool, not an autonomous agent.
// All responsibility for actions taken with the tool lies with the user.
// Developer (Sergey) is not liable for any consequences of tool usage.

import SwiftUI

struct EULAView: View {

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
                eulaCard
                Spacer()
            }
            .padding(40)
        }
        .onAppear {
            // Center the window on screen when EULA appears.
            // WHY: .defaultPosition(.center) is a hint that macOS may ignore
            // if there's a saved window position. center() is the reliable call.
            NSApp.mainWindow?.center()
        }
    }

    // MARK: - Card

    private var eulaCard: some View {
        VStack(spacing: 28) {

            // Header
            VStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)

                Text("eula.title")
                    .font(.largeTitle.bold())

                Text("eula.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Agreement text
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    eulaSection(
                        icon: "wrench.and.screwdriver.fill",
                        title: String(localized: "eula.section1_title"),
                        body: String(localized: "eula.section1_body")
                    )

                    eulaSection(
                        icon: "person.fill.checkmark",
                        title: String(localized: "eula.section2_title"),
                        body: String(localized: "eula.section2_body")
                    )

                    eulaSection(
                        icon: "exclamationmark.shield.fill",
                        title: String(localized: "eula.section3_title"),
                        body: String(localized: "eula.section3_body")
                    )

                    eulaSection(
                        icon: "brain.head.profile",
                        title: String(localized: "eula.section4_title"),
                        body: String(localized: "eula.section4_body")
                    )

                    eulaSection(
                        icon: "checkmark.seal.fill",
                        title: String(localized: "eula.section5_title"),
                        body: String(localized: "eula.section5_body")
                    )
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 320)

            // Accept button
            Button {
                AppState.shared.acceptEULA()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("eula.accept")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return)
        }
        .padding(40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 540)
    }

    // MARK: - Section Helper

    private func eulaSection(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
