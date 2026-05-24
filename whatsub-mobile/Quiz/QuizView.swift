import SwiftUI

struct QuizView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = QuizViewModel()
    @Environment(\.dismiss) private var dismiss

    private var token: String? { appState.session?.sessionToken }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                switch vm.phase {
                case .pickScope: scopePicker
                case .loading: ProgressView().tint(.whatsubAccent)
                case .insufficient:
                    centered(icon: "tray", title: "短语不够测验", sub: "该语料库至少需要 4 个有释义的短语")
                case .allMastered: allMasteredBody
                case .error(let m): centered(icon: "exclamationmark.triangle", title: m, sub: "")
                case .quizzing: quizBody
                }
            }
            .navigationTitle("单词卡测验")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { dismiss() }.tint(.whatsubAccent) } }
            .navigationDestination(for: String.self) { PhraseDetailView(phrase: $0) }
            .onChange(of: vm.revealed) { revealed in
                if revealed { SoundFX.correct() }
            }
        }
    }

    private var scopePicker: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.play").font(.system(size: 48)).foregroundStyle(.whatsubAccent)
            Text("选择测验范围").font(.headline).foregroundStyle(.whatsubInk)
            Button { startScope(.publicCorpus) } label: { scopeLabel("公共语料库") }
            Button { startScope(.mine) } label: { scopeLabel("我的语料库") }
            Spacer()
        }.padding(32)
    }

    private func scopeLabel(_ t: String) -> some View {
        Text(t).fontWeight(.semibold).frame(maxWidth: .infinity).padding()
            .background(Color.whatsubAccent).foregroundStyle(.black).cornerRadius(12)
    }

    @ViewBuilder private var quizBody: some View {
        if let q = vm.question {
            VStack(spacing: 16) {
                header
                Text(q.card.phraseRaw)
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(.whatsubInk)
                    .multilineTextAlignment(.center).padding(.horizontal).padding(.top, 8)
                if let ipa = IPADict.shared.lookup(q.card.phraseRaw) {
                    Text("/\(ipa)/")
                        .font(.callout)
                        .foregroundStyle(.whatsubInkMuted)
                }
                ForEach(q.options, id: \.self) { opt in optionButton(q, opt) }
                if vm.revealed { revealPanel(q) }
                Spacer()
            }.padding(20)
        }
    }

    private var header: some View {
        HStack {
            Text("已掌握 \(vm.masteredCount)/\(vm.poolCount)").font(.caption).foregroundStyle(.whatsubInkMuted)
            Spacer()
            if vm.streak > 0 { Text("连对 \(vm.streak) 🔥").font(.caption).foregroundStyle(.whatsubAccent) }
        }
    }

    private func optionButton(_ q: QuizQuestion, _ opt: String) -> some View {
        let isWrong = vm.ruledOut.contains(opt)
        let isCorrectRevealed = vm.revealed && opt == q.correct
        return Button { vm.answer(opt) } label: {
            HStack {
                Text(opt).foregroundStyle(.whatsubInk).multilineTextAlignment(.leading)
                Spacer()
                if isWrong { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                if isCorrectRevealed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isCorrectRevealed ? Color.green.opacity(0.15)
                    : isWrong ? Color.red.opacity(0.12)
                    : Color.whatsubBgElev,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .disabled(isWrong || vm.revealed)
    }

    private func revealPanel(_ q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(q.card.meaningZh).font(.headline).foregroundStyle(.whatsubInk)
            if let u = q.card.usageNote, !u.isEmpty {
                Text(u).font(.subheadline).foregroundStyle(.whatsubInkSoft)
            }
            if let c = q.card.contextSentence, !c.isEmpty {
                Text(c).font(.caption).foregroundStyle(.whatsubInkMuted)
            }
            NavigationLink("看完整详情", value: q.card.phraseNormalized)
                .font(.caption).tint(.whatsubAccent)
            Button { vm.next() } label: {
                Text("继续").fontWeight(.semibold).frame(maxWidth: .infinity).padding()
                    .background(Color.whatsubAccent).foregroundStyle(.black).cornerRadius(12)
            }.padding(.top, 4)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }

    private var allMasteredBody: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("🎉").font(.system(size: 60))
            Text("本库已全部掌握").font(.headline).foregroundStyle(.whatsubInk)
            Button("重置本库进度") { vm.reset() }.buttonStyle(.bordered).tint(.whatsubAccent)
            Spacer()
        }.padding(32)
    }

    private func centered(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.whatsubAccent)
            Text(title).font(.headline).foregroundStyle(.whatsubInk).multilineTextAlignment(.center)
            if !sub.isEmpty {
                Text(sub).font(.footnote).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
            }
            Spacer()
        }.padding(32)
    }

    private func startScope(_ s: QuizScope) {
        guard let t = token else { return }
        Task { await vm.start(scope: s, token: t) }
    }
}
