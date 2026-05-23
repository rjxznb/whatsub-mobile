import SwiftUI

struct LlmSettingsView: View {
    @State private var baseUrl: String = ""
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var saved: Bool = false

    var body: some View {
        Form {
            Section(header: Text("接口地址").foregroundStyle(.whatsubInkMuted)) {
                TextField("https://api.deepseek.com/v1", text: $baseUrl)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .foregroundStyle(.whatsubInk)
            }
            Section(header: Text("API Key").foregroundStyle(.whatsubInkMuted)) {
                SecureField("sk-...", text: $apiKey)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .foregroundStyle(.whatsubInk)
            }
            Section(header: Text("模型").foregroundStyle(.whatsubInkMuted)) {
                TextField("deepseek-chat", text: $model)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .foregroundStyle(.whatsubInk)
            }
            Section {
                Button(action: save) {
                    HStack {
                        Spacer()
                        Text(saved ? "已保存" : "保存")
                            .fontWeight(.semibold)
                            .foregroundStyle(saved ? .whatsubHighlight : .whatsubAccent)
                        Spacer()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.whatsubBg)
        .navigationTitle("LLM 设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        let s = LlmSettingsStore.load()
        baseUrl = s.baseUrl
        apiKey = s.apiKey
        model = s.model
    }

    private func save() {
        var s = LlmSettings()
        s.baseUrl = baseUrl.trimmingCharacters(in: .whitespaces)
        s.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        s.model = model.trimmingCharacters(in: .whitespaces)
        LlmSettingsStore.save(s)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
    }
}

#Preview {
    NavigationStack {
        LlmSettingsView()
    }
    .preferredColorScheme(.dark)
}
