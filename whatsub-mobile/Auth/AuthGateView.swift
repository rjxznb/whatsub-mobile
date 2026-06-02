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
                VStack(spacing: 10) {
                    // Brand wordmark — matches the desktop onboarding intro:
                    // Caveat (cursive) bold, "what" white + "Sub" brand-blue.
                    (Text("what").foregroundColor(.white)
                        + Text("Sub").foregroundColor(.whatsubAccent))
                        .font(.custom("Caveat-Bold", size: 80))
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

                if let error = vm.errorMessage {
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

            sendCodeButton
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

            // Resend-code line: when cooled down, also shows a 倒计时 next to
            // "重新发送" so the user understands why it's disabled.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let remaining = vm.sendRetrySeconds(at: ctx.date)
                HStack(spacing: 14) {
                    Button("← 换个邮箱") { vm.backToEmail() }
                        .font(.footnote)
                        .foregroundStyle(.whatsubInkMuted)
                    if remaining > 0 {
                        Text("· \(remaining) 秒后可重发")
                            .font(.footnote)
                            .foregroundStyle(.whatsubInkFaint)
                    } else {
                        Button("重新发送") {
                            Task { await vm.sendCode() }
                        }
                        .font(.footnote)
                        .foregroundStyle(.whatsubAccent)
                        .disabled(vm.busy)
                    }
                }
            }
        }
    }

    /// 发送验证码 button — TimelineView drives a per-second tick so the
    /// countdown label refreshes without us managing a separate Timer.
    private var sendCodeButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let remaining = vm.sendRetrySeconds(at: ctx.date)
            Button {
                Task { await vm.sendCode() }
            } label: {
                let label: String = {
                    if vm.busy { return "发送中…" }
                    if remaining > 0 { return "请等待 \(remaining) 秒" }
                    return "发送验证码"
                }()
                primaryLabel(label, dimmed: remaining > 0)
            }
            .disabled(vm.busy || remaining > 0)
        }
    }

    private func primaryLabel(_ text: String, dimmed: Bool = false) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                (dimmed ? Color.whatsubAccent.opacity(0.45) : Color.whatsubAccent),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(.white)
    }
}
