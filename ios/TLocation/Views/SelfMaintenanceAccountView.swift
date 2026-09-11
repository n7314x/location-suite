import SwiftUI

struct SelfMaintenanceAccountView: View {
    @ObservedObject private var maintenance = SelfMaintenanceService.shared
    @ObservedObject private var twoFactor = TwoFactorPromptCoordinator.shared

    @AppStorage(UserDefaults.Keys.appleAccountEmail) private var appleAccount = ""
    @AppStorage(UserDefaults.Keys.rememberApplePassword) private var rememberPassword = false
    @AppStorage(UserDefaults.Keys.anisettePrimaryEndpoint)
    private var anisetteEndpoint = SelfMaintenanceService.defaultAnisetteEndpoint
    @AppStorage(UserDefaults.Keys.anisetteFallbackEndpoints)
    private var anisetteFallbacks = SelfMaintenanceService.defaultAnisetteFallbacks

    @State private var password = ""
    @State private var verificationCode = ""

    var body: some View {
        Form {
            Section("Apple Account") {
                TextField("Apple Account", text: $appleAccount)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                SecureField("Password", text: $password)
                    .textContentType(.password)

                Toggle("Remember Password on This iPhone", isOn: $rememberPassword)

                Text(rememberPassword
                     ? "The password is stored only in the iOS Keychain for this device and is available only while the phone is unlocked."
                     : "The password is held only for this sign-in and is not persisted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if maintenance.isSignedIn {
                    Button("Sign Out", role: .destructive) {
                        password = ""
                        maintenance.signOut()
                    }
                    .disabled(maintenance.isWorking)
                } else {
                    Button {
                        Task {
                            await maintenance.signIn(
                                appleID: appleAccount,
                                password: password,
                                rememberPassword: rememberPassword,
                                primaryAnisetteEndpoint: anisetteEndpoint,
                                fallbackAnisetteEndpoints: anisetteFallbacks
                            )
                            password = ""
                        }
                    } label: {
                        if maintenance.isWorking {
                            Label("Signing In…", systemImage: "person.crop.circle.badge.clock")
                        } else {
                            Label("Sign In / Test Developer Session", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    .disabled(maintenance.isWorking || appleAccount.isEmpty || password.isEmpty)
                }
            }

            if !maintenance.availableTeams.isEmpty {
                Section("Developer Team") {
                    Picker(
                        "Personal Team",
                        selection: Binding(
                            get: { maintenance.selectedTeamIdentifier ?? "" },
                            set: { identifier in
                                guard !identifier.isEmpty else { return }
                                Task { await maintenance.selectTeam(identifier) }
                            }
                        )
                    ) {
                        Text("Choose…").tag("")
                        ForEach(maintenance.availableTeams) { team in
                            Text(team.displayName).tag(team.identifier)
                        }
                    }
                    .disabled(maintenance.isWorking)
                    Text("Choose the team identifier shown in the currently installed Location Suite provisioning profile. Refresh stops without creating an App ID if the team does not match.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Anisette v3") {
                TextField("Primary Server", text: $anisetteEndpoint)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Fallback Servers", text: $anisetteFallbacks, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Text("Use HTTPS v3 endpoints, separated by commas or new lines. The Apple password and verification code are sent only to Apple, never to the anisette service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let endpoint = maintenance.activeAnisetteEndpoint {
                    LabeledContent("Active Server", value: endpoint)
                }
            }

            if let message = maintenance.statusMessage {
                Section("Status") {
                    Label(
                        message,
                        systemImage: maintenance.lastError == nil
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(maintenance.lastError == nil ? .green : .orange)
                    if let error = maintenance.lastError {
                        Text(error.category.rawValue)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Account & Signing")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: rememberPassword) { _, isEnabled in
            if !isEnabled { maintenance.forgetRememberedPassword() }
        }
        .sheet(
            isPresented: Binding(
                get: { twoFactor.isPresenting },
                set: { if !$0, twoFactor.isPresenting { twoFactor.cancel() } }
            )
        ) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Six-digit code", text: $verificationCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        if let message = twoFactor.validationMessage {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                    } footer: {
                        Text("Enter the code Apple sent to a trusted device or phone number. It is never stored or logged.")
                    }
                }
                .navigationTitle("Apple Verification")
                .navigationBarTitleDisplayMode(.inline)
                .interactiveDismissDisabled()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            verificationCode = ""
                            twoFactor.cancel()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Continue") {
                            twoFactor.submit(verificationCode)
                            verificationCode = ""
                        }
                    }
                }
            }
        }
    }
}
