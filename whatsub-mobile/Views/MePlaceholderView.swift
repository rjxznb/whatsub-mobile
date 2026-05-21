import SwiftUI

struct MePlaceholderView: View {
    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "v\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                List {
                    Section("账号") {
                        Text("未登录 · Phase 2 接邮箱 OTP")
                            .foregroundStyle(.whatsubInkMuted)
                    }
                    .listRowBackground(Color.whatsubBgElev)

                    Section("关于") {
                        LabeledContent("版本", value: versionString)
                            .foregroundStyle(.whatsubInk)
                        Link("官网 whatsub.eversay.cc", destination: URL(string: "https://whatsub.eversay.cc")!)
                            .foregroundStyle(.whatsubAccent)
                    }
                    .listRowBackground(Color.whatsubBgElev)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("我的")
        }
    }
}

#Preview { MePlaceholderView() }
