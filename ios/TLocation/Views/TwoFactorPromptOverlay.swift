import SwiftUI

/// A presentation-independent 2FA surface.
///
/// Self-maintenance can now rebuild a remembered Apple developer session during
/// launch/foreground work, so the verification UI cannot live only inside the
/// Account screen. This overlay is attached to RootView and SettingsView. It
/// avoids stacking another SwiftUI sheet on top of the app's existing sheets.
struct TwoFactorPromptOverlayModifier: ViewModifier {
    @ObservedObject private var twoFactor = TwoFactorPromptCoordinator.shared
    @State private var verificationCode = ""

    func body(content: Content) -> some View {
        content.overlay {
            if twoFactor.isPresenting {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()

                    VStack(alignment: .leading, spacing: 16) {
                        Label("Apple Verification", systemImage: "person.badge.key.fill")
                            .font(.headline)

                        Text("Enter the six-digit code Apple sent to a trusted device or phone number.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("Six-digit code", text: $verificationCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .textFieldStyle(.roundedBorder)

                        if let message = twoFactor.validationMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        HStack {
                            Button("Cancel", role: .cancel) {
                                verificationCode = ""
                                twoFactor.cancel()
                            }

                            Spacer()

                            Button("Continue") {
                                twoFactor.submit(verificationCode)
                                verificationCode = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).count != 6
                            )
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: 420)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                    )
                    .padding(24)
                }
                .zIndex(10_000)
            }
        }
    }
}
