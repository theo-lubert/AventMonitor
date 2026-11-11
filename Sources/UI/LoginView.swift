import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var countryName = "France"
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var country: Country {
        Country.all.first { $0.name == countryName } ?? Country.all[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connexion").font(.callout.weight(.semibold))
            if model.awaitingCode {
                Text("Un code à 6 chiffres a été envoyé à \(model.codeSentTo).")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Code de vérification", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                    .focused($codeFocused)
                    .onSubmit(verify)
                HStack {
                    Button("Annuler") { model.cancelLogin(); code = "" }
                    Spacer()
                    Button("Se connecter", action: verify)
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.filter(\.isNumber).count < 6 || model.isBusy)
                }
                .onAppear { codeFocused = true }
            } else {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                SecureField("Mot de passe", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit(sendCode)
                Picker("Pays du compte", selection: $countryName) {
                    ForEach(Country.all) { Text($0.name).tag($0.name) }
                }
                HStack {
                    Text("Le même compte que l'app mobile.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Recevoir le code", action: sendCode)
                        .keyboardShortcut(.defaultAction)
                        .disabled(email.isEmpty || password.isEmpty || model.isBusy)
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear {
            if email.isEmpty { email = model.lastEmail }
            countryName = model.lastCountry
        }
    }

    private func sendCode() {
        guard !email.isEmpty, !password.isEmpty else { return }
        let pw = password
        Task {
            await model.sendCode(email: email, password: pw, country: country)
            if model.phase == .loggedIn || model.awaitingCode { password = "" }
        }
    }

    private func verify() {
        let c = code
        Task {
            await model.verify(code: c)
            if model.phase == .loggedIn { code = "" }
        }
    }
}
