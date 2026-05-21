import SwiftUI

struct AuthGateView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = AuthViewModel()
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.whatsubAccent)
                    Text("whatSub")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.whatsubInk)
                    Text(vm.step == .email ? "用邮箱登录 · 已购用户自动识别" : "验证码已发到 \(vm.email)")
                        .font(.callout)
                        .foregroundStyle(.whatsubInkMuted)
                        .multilineTextAlignment(.center)
                }

                if vm.step == .email {
                    emailField
                } else {
                    codeField
                }

                if let error = vm.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .onAppear { focused = true }
    }

    private var emailField: some View {
        VStack(spacing: 14) {
            TextField("you@example.com", text: $vm.email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(14)
                .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.whatsubInk)

            Button {
                Task { await vm.sendCode() }
            } label: {
                primaryLabel(vm.busy ? "发送中…" : "发送验证码")
            }
            .disabled(vm.busy)
        }
    }

    private var codeField: some View {
        VStack(spacing: 14) {
            TextField("6 位验证码", text: $vm.code)
                .keyboardType(.numberPad)
                .focused($focused)
                .padding(14)
                .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.whatsubInk)
                .onChange(of: vm.code) { newValue in
                    if newValue.count > 6 { vm.code = String(newValue.prefix(6)) }
                }

            Button {
                Task {
                    if let s = await vm.verify() {
                        appState.setSession(s)
                        await appState.refreshMe()
                    }
                }
            } label: {
                primaryLabel(vm.busy ? "验证中…" : "验证登录")
            }
            .disabled(vm.busy)

            Button("← 换个邮箱 / 重新发送") { vm.backToEmail() }
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
        }
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.whatsubAccent, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
    }
}
