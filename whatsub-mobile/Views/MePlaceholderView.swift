import SwiftUI

struct MePlaceholderView: View {
    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "v\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    Text("未登录 · Phase 2 接邮箱 OTP")
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("版本", value: versionString)
                    Link("官网 whatsub.eversay.cc", destination: URL(string: "https://whatsub.eversay.cc")!)
                }
            }
            .navigationTitle("我的")
        }
    }
}

#Preview { MePlaceholderView() }
