import SwiftUI
import PhotosUI

/// 实景口语练习 sheet. Phase-driven content tree: picker → Vision →
/// LLM prompt → press-and-hold record → LLM grade → review.
///
/// Reuses `PhotoCameraPicker` / `PhotosPicker` from the photo flow + the
/// `VoiceActivityRecorder` from QuickChat. The orb here is a simpler
/// push-to-talk button than QuickChat's full orb shell — single-round
/// exercise doesn't need scene-phase auto-flow.
///
/// 2026-06-05.
struct LiveSceneView: View {
    @StateObject private var vm = LiveSceneViewModel()
    @Environment(\.dismiss) private var dismiss

    // Picker presentation state — local to the view, kept out of vm
    // because they're pure UI surfaces, not business state.
    @State private var showCamera = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var cameraImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("实景口语练习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        vm.tearDown()
                        dismiss()
                    }
                }
            }
            // Camera capture sheet — present on demand from the picker buttons.
            // The gallery picker is the `PhotosPicker` view inside pickerView
            // (modern iOS 16+ API — it's a Button that opens the picker UI
            // directly, no `.photosPicker(isPresented:)` modifier needed).
            .sheet(isPresented: $showCamera) {
                PhotoCameraPicker(image: $cameraImage)
                    .ignoresSafeArea()
            }
            // Camera → vm pipeline.
            .onChange(of: cameraImage) { newImage in
                if let img = newImage {
                    cameraImage = nil   // reset binding so re-selection fires
                    Task { await vm.didPickImage(img) }
                }
            }
            // Gallery → vm pipeline.
            .onChange(of: photoPickerItem) { newItem in
                guard let item = newItem else { return }
                photoPickerItem = nil
                Task {
                    if let img = await PhotoLibraryPicker.resolve(item) {
                        await vm.didPickImage(img)
                    }
                }
            }
        }
    }

    // MARK: - phase router

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .picker:
            pickerView
        case .classifying:
            loadingView(text: "正在识别画面…")
        case .prompting:
            loadingView(text: "正在为你出题…")
        case let .ready(_, prompt):
            promptView(prompt: prompt, isRecording: false, livePartial: "")
        case let .recording(_, prompt, livePartial):
            promptView(prompt: prompt, isRecording: true, livePartial: livePartial)
        case .grading:
            loadingView(text: "正在评分…")
        case let .review(_, prompt, transcript, grade):
            reviewView(prompt: prompt, transcript: transcript, grade: grade)
        case let .error(msg):
            errorView(msg)
        }
    }

    // MARK: - picker

    private var pickerView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "eye.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.whatsubAccent)
            VStack(spacing: 8) {
                Text("拍一张你眼前的画面")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                Text("AI 会根据画面给你出一个英语口语题,练完会给评分 + 标准答案")
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            VStack(spacing: 12) {
                if deviceHasCamera {
                    Button {
                        showCamera = true
                    } label: {
                        Label("拍照", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.whatsubAccent, in: Capsule())
                            .foregroundStyle(.black)
                            .font(.body.weight(.semibold))
                    }
                }
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Label("从相册选", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.whatsubBgElev, in: Capsule())
                        .foregroundStyle(.whatsubInk)
                        .font(.body.weight(.semibold))
                }
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: - loading

    private func loadingView(text: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().tint(.whatsubAccent).scaleEffect(1.2)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
            Spacer()
        }
    }

    // MARK: - prompt (ready + recording share the same shape)

    @ViewBuilder
    private func promptView(prompt: SpeakingPrompt, isRecording: Bool, livePartial: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                difficultyRow(prompt.difficulty)
                Text(prompt.promptEn)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.promptZh)
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if !prompt.targetVocab.isEmpty {
                    vocabChips(prompt.targetVocab)
                }
                if isRecording && !livePartial.isEmpty {
                    Text(livePartial)
                        .font(.subheadline)
                        .foregroundStyle(.whatsubInk)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            recordButton(isRecording: isRecording)
                .padding(.bottom, 24)
        }
    }

    private func difficultyRow(_ difficulty: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(1...3, id: \.self) { i in
                Image(systemName: i <= difficulty ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(.whatsubAccent)
            }
            Text(["A2 · 简单", "B1 · 中等", "B2 · 进阶"][max(0, min(2, difficulty - 1))])
                .font(.caption2)
                .foregroundStyle(.whatsubInkMuted)
        }
    }

    private func vocabChips(_ vocab: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("建议用上")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
            // Use a horizontal scroll for safety on tiny screens — same
            // pattern as QuickChat's header chips.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vocab, id: \.self) { v in
                        Text(v)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.whatsubBgElev))
                            .foregroundStyle(.whatsubInk)
                    }
                }
            }
        }
    }

    private func recordButton(isRecording: Bool) -> some View {
        // Push-to-talk: a long-press DragGesture so we get start + end
        // signals reliably (TapGesture only fires on release; we need
        // continuous press detection). Same shape QuickChat's orb uses.
        let press = DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isRecording { vm.startRecording() }
            }
            .onEnded { _ in
                if isRecording { vm.endRecording() }
            }

        return VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.whatsubAccent)
                    .frame(width: 80, height: 80)
                    .scaleEffect(isRecording ? 1.0 + min(0.2, CGFloat(vm.audioLevel) * 0.4) : 1.0)
                    .animation(.easeOut(duration: 0.08), value: vm.audioLevel)
                Image(systemName: "mic.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.black)
            }
            .gesture(press)
            Text(isRecording ? "松开结束" : "按住说英语")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
        }
    }

    // MARK: - review

    private func reviewView(prompt: SpeakingPrompt, transcript: String, grade: SceneGrade) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                scoreCard(grade.score)
                section("你的回答") {
                    Text(transcript)
                        .font(.subheadline)
                        .foregroundStyle(.whatsubInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !grade.feedback.isEmpty {
                    section("点评") {
                        Text(grade.feedback)
                            .font(.subheadline)
                            .foregroundStyle(.whatsubInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !grade.modelAnswer.isEmpty {
                    section("参考答案") {
                        Text(grade.modelAnswer)
                            .font(.subheadline)
                            .foregroundStyle(.whatsubInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !grade.vocabHits.isEmpty {
                    section("目标短语") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(grade.vocabHits) { hit in
                                vocabHitRow(hit)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    vm.restart()
                } label: {
                    Text("再来一张")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.whatsubBgElev, in: Capsule())
                        .foregroundStyle(.whatsubInk)
                        .font(.body.weight(.semibold))
                }
                Button {
                    vm.tearDown()
                    dismiss()
                } label: {
                    Text("完成")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.whatsubAccent, in: Capsule())
                        .foregroundStyle(.black)
                        .font(.body.weight(.semibold))
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }

    private func scoreCard(_ score: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= score ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(i <= score ? .whatsubAccent : .whatsubInkFaint)
            }
            Spacer()
            Text("\(score) / 5")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
        }
        .padding(16)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
            content()
        }
    }

    private func vocabHitRow(_ hit: VocabHit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hit.correct ? "checkmark.circle.fill" :
                              hit.attempted ? "xmark.circle.fill" : "circle")
                .foregroundStyle(hit.correct ? .green :
                                 hit.attempted ? .red : .whatsubInkFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.phrase)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                if !hit.note.isEmpty {
                    Text(hit.note)
                        .font(.caption)
                        .foregroundStyle(.whatsubInkMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - error

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.whatsubInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                vm.dismissError()
            } label: {
                Text("重新选图片")
                    .padding(.horizontal, 32).padding(.vertical, 12)
                    .background(Color.whatsubAccent, in: Capsule())
                    .foregroundStyle(.black)
                    .font(.body.weight(.semibold))
            }
            Spacer()
        }
    }
}
