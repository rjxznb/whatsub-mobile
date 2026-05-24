import SwiftUI

struct CorpusView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = CorpusViewModel()

    private var token: String? { appState.session?.sessionToken }
    @State private var showQuiz = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("语料库")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.whatsubInk)
                    Spacer()
                    Button { showQuiz = true } label: {
                        Label("单词卡", systemImage: "rectangle.stack.badge.play")
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.whatsubAccent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)

                Picker("", selection: Binding(
                    get: { vm.scope },
                    set: { s in Task { if let t = token { await vm.switchScope(s, token: t) } } }
                )) {
                    Text("公共").tag(CorpusScope.publicCorpus)
                    Text("我的").tag(CorpusScope.mine)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 8)

                if !vm.tags.isEmpty { tagChips }

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.whatsubBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { phrase in
                PhraseDetailView(phrase: phrase)
            }
            .task { if let t = token, !vm.loadedOnce { await vm.reload(token: t) } }
            .refreshable { if let t = token { await vm.reload(token: t) } }
            .sheet(isPresented: $showQuiz) {
                QuizView().environmentObject(appState)
            }
        }
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.tags) { t in
                    let on = vm.selectedTags.contains(t.tag)
                    Text("\(t.tag) \(t.count)")
                        .font(.caption).fontWeight(on ? .semibold : .regular)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(on ? Color.whatsubAccent.opacity(0.25) : Color.whatsubBgElev, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.whatsubAccent : .clear, lineWidth: 1))
                        .foregroundStyle(on ? .whatsubAccent : .whatsubInkSoft)
                        .onTapGesture { if let tok = token { Task { await vm.toggleTag(t.tag, token: tok) } } }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.browse.isEmpty && vm.mine.isEmpty {
            Spacer(); ProgressView().tint(.whatsubAccent); Spacer()
        } else if vm.licenseLocked {
            centered(icon: "lock", title: "公共语料库需会员",
                     sub: "购买 whatSub 会员后即可浏览公共语料库；\n「我的」语料库始终可用")
        } else if let err = vm.errorMessage {
            centered(icon: "exclamationmark.triangle", title: err, sub: "下拉重试")
        } else if vm.scope == .publicCorpus {
            if vm.browse.isEmpty {
                centered(icon: "books.vertical", title: "公共语料库暂无内容", sub: "管理员添加后这里会出现")
            } else {
                List(vm.browse) { p in
                    NavigationLink(value: p.phraseNormalized) {
                        PhraseRow(raw: p.phraseRaw, meaning: p.meaningZh, sub: nil, tags: p.tags)
                    }.listRowBackground(Color.whatsubBgElev)
                }.scrollContentBackground(.hidden)
            }
        } else {
            if vm.mine.isEmpty {
                centered(icon: "bookmark", title: "还没有收藏的短语", sub: "用 whatSub 插件在网页/视频里保存短语，\n这里就能看到")
            } else {
                List(vm.mine) { m in
                    NavigationLink(value: m.phraseNormalized) {
                        PhraseRow(raw: m.phraseRaw, meaning: m.meaningZh, sub: m.contextSentence, tags: m.tags)
                    }.listRowBackground(Color.whatsubBgElev)
                }.scrollContentBackground(.hidden)
            }
        }
    }

    private func centered(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.whatsubAccent)
            Text(title).font(.headline).foregroundStyle(.whatsubInk)
            Text(sub).font(.footnote).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
            Spacer()
        }.padding(32)
    }
}

private struct PhraseRow: View {
    let raw: String
    let meaning: String?
    let sub: String?
    let tags: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(raw).font(.system(size: 17, weight: .semibold)).foregroundStyle(.whatsubInk)
            if let m = meaning, !m.isEmpty {
                Text(m).font(.subheadline).foregroundStyle(.whatsubInkSoft).lineLimit(2)
            }
            if let s = sub, !s.isEmpty {
                Text(s).font(.caption).foregroundStyle(.whatsubInkMuted).lineLimit(1)
            }
            if !tags.isEmpty {
                Text(tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption2).foregroundStyle(.whatsubInkFaint)
            }
        }.padding(.vertical, 4)
    }
}
