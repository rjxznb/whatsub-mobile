import SwiftUI
import PhotosUI

/// Main UI for the 拍照识别短语 flow. Sheet root. Drives a
/// `PhotoReviewViewModel` through its phases — picker → OCR → analyze
/// → review → sync → done.
///
/// 2026-06-04 (拍照识别短语).
struct PhotoReviewView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: StoreManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = PhotoReviewViewModel()

    // Picker presentation flags.
    @State private var showCamera = false
    @State private var pickedImage: UIImage?
    @State private var galleryPick: PhotosPickerItem?
    /// 订阅 Pro sheet — shown when an LLM error came back with
    /// `.subscribeUpsell` kind. Sheet attached at view root so phase
    /// churn underneath doesn't tear it down.
    @State private var showSubscribe = false

    var body: some View {
        NavigationStack {
            content
                .background(Color.whatsubBg.ignoresSafeArea())
                // Renamed 2026-06-05 (拍照识别短语 → 拍照翻译). The new
                // name foregrounds the immediate user value (翻译) and lets
                // "加入语料库" stay a secondary CTA inside the flow. Code +
                // docstrings still reference 拍照识别短语 as the historical
                // file context (matches git blame); user-facing string only.
                .navigationTitle("拍照翻译")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
                .sheet(isPresented: $showCamera) {
                    PhotoCameraPicker(image: $pickedImage)
                        .ignoresSafeArea()
                }
                .onChange(of: pickedImage) { newImage in
                    guard let img = newImage else { return }
                    pickedImage = nil
                    Task { await vm.setImage(img) }
                }
                .onChange(of: galleryPick) { newItem in
                    guard let item = newItem else { return }
                    galleryPick = nil
                    Task {
                        if let img = await PhotoLibraryPicker.resolve(item) {
                            await vm.setImage(img)
                        }
                    }
                }
        }
    }

    // MARK: - phase-driven content

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .empty:
            emptyState
        case .ocring:
            spinnerState(label: "正在识别照片里的文字…")
        case .ocred:
            ocredState
        case .analyzing:
            spinnerState(label: "AI 正在翻译并提取重点短语…")
        case .reviewing:
            reviewingState
        case .syncing(let progress):
            spinnerState(label: progress)
        case .done(let added, let failed):
            doneState(added: added, failed: failed)
        case .error(let failure):
            errorState(failure: failure)
        }
    }

    // MARK: - phases

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.whatsubAccent)
            Text("拍一张含英文的照片")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.whatsubInk)
            Text("AI 会识别文字、翻译整段、并提取出值得学的英文短语 —— 你挑要加入语料库的那几条。")
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            sourceButtonRow
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sourceButtonRow: some View {
        HStack(spacing: 12) {
            if deviceHasCamera {
                Button { showCamera = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.fill").font(.title2)
                        Text("拍照").font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .foregroundStyle(.whatsubInk)
                    .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            PhotosPicker(selection: $galleryPick, matching: .images, photoLibrary: .shared()) {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle").font(.title2)
                    Text("从相册").font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .foregroundStyle(.whatsubInk)
                .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func spinnerState(label: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            if let img = vm.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            ProgressView().tint(.whatsubAccent)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var ocredState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                photoThumb
                Text("识别到的英文 (可手动编辑)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.whatsubInkMuted)
                TextEditor(text: Binding(
                    get: { vm.ocrText },
                    set: { vm.editOCRText($0) }
                ))
                .frame(minHeight: 160)
                .padding(8)
                .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.whatsubInk)
                .scrollContentBackground(.hidden)

                Button {
                    Task { await vm.analyze() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                        Text("AI 翻译 + 提取重点短语")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(Color.whatsubAccent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button("重拍 / 换一张") { vm.objectWillChange.send() ; resetToEmpty() }
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var reviewingState: some View {
        if let a = vm.analysis {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    photoThumb
                    BilingualHighlightView(
                        english: vm.ocrText,
                        translation: a.translation,
                        phrases: a.phrases,
                        selected: vm.selected,
                        onTogglePhrase: { vm.toggle($0) }
                    )

                    if a.phrases.isEmpty {
                        Text("没提取到值得学习的短语 —— 可以重拍清楚一点,或者编辑 OCR 文本后重试")
                            .font(.caption)
                            .foregroundStyle(.whatsubInkMuted)
                            .multilineTextAlignment(.leading)
                            .padding(.vertical, 12)
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                if !a.phrases.isEmpty {
                    bottomSyncBar
                }
            }
        }
    }

    private var bottomSyncBar: some View {
        Button {
            guard let token = appState.session?.sessionToken else { return }
            Task { await vm.sync(token: token) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.up.fill")
                Text("加入语料库 (\(vm.selectedCount))")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(
                vm.selectedCount == 0
                    ? Color.whatsubInkFaint
                    : Color.whatsubAccent,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .disabled(vm.selectedCount == 0)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .padding(.top, 8)
        .background(Color.whatsubBg)
    }

    private func doneState(added: Int, failed: Int) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("已加入 \(added) 条到云端语料库")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.whatsubInk)
            if failed > 0 {
                Text("有 \(failed) 条同步失败,稍后可重新拍照重试")
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
            }
            Spacer()
            HStack(spacing: 12) {
                Button("再拍一张") { resetToEmpty() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .foregroundStyle(.whatsubAccent)
                    .background(Color.whatsubBgElev, in: Capsule())
                Button("完成") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.whatsubAccent, in: Capsule())
            }
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Kind-driven error state. `.subscribeUpsell` shows a 「订阅 Pro」 CTA
    /// + secondary 重新开始 link; others just get 重新开始.
    private func errorState(failure: RemoteFailure) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text(failure.message)
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            VStack(spacing: 12) {
                if failure.kind == .subscribeUpsell {
                    Button {
                        showSubscribe = true
                    } label: {
                        Label("订阅 Pro", systemImage: "star.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 22).padding(.vertical, 10)
                            .foregroundStyle(.black)
                            .background(Color.whatsubAccent, in: Capsule())
                    }
                    Button("重新开始") { resetToEmpty() }
                        .font(.footnote)
                        .foregroundStyle(.whatsubInkMuted)
                } else {
                    Button("重新开始") { resetToEmpty() }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Color.whatsubAccent, in: Capsule())
                }
            }
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSubscribe) {
            SubscribeSheet(onPurchased: {
                Task {
                    await appState.refreshMe()
                    resetToEmpty()
                }
            })
            .environmentObject(store)
        }
    }

    // MARK: - helpers

    @ViewBuilder
    private var photoThumb: some View {
        if let img = vm.image {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func resetToEmpty() {
        // Reaches into the VM by re-init; cheaper than threading a
        // reset() through every state. SwiftUI rebinds the @StateObject
        // when the parent view re-mounts; for a sheet's lifetime this
        // approach is acceptable (only one user at a time).
        pickedImage = nil
        galleryPick = nil
        showCamera = false
        // We can't replace @StateObject; instead drive VM to a clean
        // state. Easiest: dismiss the sheet entirely (re-open gives a
        // fresh VM).
        dismiss()
    }
}
