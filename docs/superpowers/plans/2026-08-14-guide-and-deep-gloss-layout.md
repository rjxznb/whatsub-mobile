# 视频学习导览与重点词深度解读布局优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让视频学习导览可滚动、重点词释义弹窗默认完整露出操作入口，并把深度解读结果改成清晰的信息卡片与项目符号列表。

**Architecture:** 保持 `LibraryDetailView`、后端 DTO 和缓存协议不变，把导览滚动边界收口在 `VideoLearningGuideCard` 内；`GlossSheet` 只调整 detent 与渲染；`DeepGlossPresentation` 提供稳定的分项展示数据和图标元数据。所有业务请求、收藏、重试和缓存路径继续复用现有实现。

**Tech Stack:** Swift 5.10、SwiftUI、XCTest、iOS 16+、XcodeGen；不新增第三方依赖。

## Global Constraints

- iOS 最低版本保持 16.0。
- 不修改 DeepGloss 或 LearningGuide 的后端 JSON schema。
- 不修改已有 Codable 持久化结构，旧缓存必须继续可读。
- 不给整个 `LibraryDetailView` 增加外层 `ScrollView`；字幕列表滚动结构保持不变。
- 所有新图标使用 SF Symbols，所有颜色复用项目现有主题色。
- Windows 本地没有 Xcode；测试命令在 macOS CI 执行，Windows 阶段按 test-first 顺序提交代码并运行 `git diff --check`。

---

## File Map

- `whatsub-mobile/Library/VideoLearningGuideCard.swift`：为展开正文增加有上限的内部滚动，不改变折叠标题和重点片段回调。
- `whatsub-mobile/Library/GlossSheet.swift`：将默认 sheet 高度改为 65%，点击深度解读时展开到 `.large`，渲染 section 信息卡片。
- `whatsub-mobile/Library/DeepGlossParser.swift`：把展示 section 从单个拼接字符串扩展为可逐条渲染的 `items`，并提供稳定图标映射。
- `whatsub-mobileTests/VideoLearningGuideLayoutTests.swift`：守住“标题在滚动区外、展开正文在有上限 ScrollView 中”的布局约束。
- `whatsub-mobileTests/GlossSheetLayoutTests.swift`：守住默认 fraction detent、large detent 和自动展开路径。
- `whatsub-mobileTests/DeepGlossTests.swift`：守住自然替换表达的条目顺序、图标映射和空字段过滤。

---

### Task 1: 视频学习导览展开内容可滚动

**Files:**
- Create: `whatsub-mobileTests/VideoLearningGuideLayoutTests.swift`
- Modify: `whatsub-mobile/Library/VideoLearningGuideCard.swift`

**Interfaces:**
- Consumes: `VideoLearningGuideCard.isExpanded`、`expandedContent(_:presentation:)`、`onSelectSegment`。
- Produces: `VideoLearningGuideLayout.maxExpandedHeight(for:) -> CGFloat`；展开正文使用独立纵向 `ScrollView`，折叠按钮仍位于滚动容器外。

- [ ] **Step 1: 写失败的布局守护测试**

新增测试文件：

```swift
import XCTest
@testable import whatsub_mobile

final class VideoLearningGuideLayoutTests: XCTestCase {
    func testExpandedGuideHeightAdaptsWithinReadableBounds() {
        XCTAssertEqual(VideoLearningGuideLayout.maxExpandedHeight(for: 667), 220)
        XCTAssertEqual(
            VideoLearningGuideLayout.maxExpandedHeight(for: 844),
            270.08,
            accuracy: 0.01
        )
        XCTAssertEqual(VideoLearningGuideLayout.maxExpandedHeight(for: 1_366), 340)
    }

    func testExpandedGuideUsesBoundedScrollBelowPersistentHeader() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "whatsub-mobile/Library/VideoLearningGuideCard.swift"
        ), encoding: .utf8)

        let toggle = try XCTUnwrap(source.range(of: "isExpanded.toggle()"))
        let scroll = try XCTUnwrap(source.range(
            of: "ScrollView(.vertical, showsIndicators: true)"
        ))
        XCTAssertLessThan(toggle.lowerBound, scroll.lowerBound)
        XCTAssertTrue(source.contains(
            ".frame(maxHeight: expandedContentMaxHeight)"
        ))
    }
}
```

- [ ] **Step 2: 在 macOS 环境确认测试先失败**

Run:

```bash
xcodegen generate --quiet
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:whatsub-mobileTests/VideoLearningGuideLayoutTests test
```

Expected: FAIL，因为源码中还没有 `VideoLearningGuideLayout`、纵向 `ScrollView` 和 `expandedContentMaxHeight`。

- [ ] **Step 3: 用有上限的内部 ScrollView 包裹展开正文**

在 `VideoLearningGuideCard.swift` 顶部为 `UIScreen` 增加 `import UIKit`，并加入纯布局规则：

```swift
enum VideoLearningGuideLayout {
    static func maxExpandedHeight(for screenHeight: CGFloat) -> CGFloat {
        min(max(screenHeight * 0.32, 220), 340)
    }
}
```

在 `VideoLearningGuideCard` 中加入：

```swift
private var expandedContentMaxHeight: CGFloat {
    VideoLearningGuideLayout.maxExpandedHeight(for: UIScreen.main.bounds.height)
}
```

将展开分支改为：

```swift
if isExpanded {
    ScrollView(.vertical, showsIndicators: true) {
        expandedContent(guide, presentation: presentation)
            .padding(.trailing, 2)
    }
    .frame(maxHeight: expandedContentMaxHeight)
    .transition(.opacity.combined(with: .move(edge: .top)))
}
```

不要移动上方负责 `isExpanded.toggle()` 的 Button，也不要改动 `onSelectSegment`。

- [ ] **Step 4: 运行定向测试**

Run:

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:whatsub-mobileTests/VideoLearningGuideLayoutTests \
  -only-testing:whatsub-mobileTests/VideoLearningGuidePresentationTests test
```

Expected: PASS；已有 `testSegmentSelectionSwitchesToSubtitlesCollapsesAndSeeks` 继续通过。

- [ ] **Step 5: 提交导览滚动改动**

```bash
git add whatsub-mobile/Library/VideoLearningGuideCard.swift \
  whatsub-mobileTests/VideoLearningGuideLayoutTests.swift
git commit -m "fix: make video learning guide scrollable"
```

---

### Task 2: 重点词释义 sheet 默认使用 65% 高度

**Files:**
- Modify: `whatsub-mobileTests/GlossSheetLayoutTests.swift`
- Modify: `whatsub-mobile/Library/GlossSheet.swift`

**Interfaces:**
- Consumes: `GlossSheet.selectedDetent` 和现有 `deepGlossButton(title:systemImage:)`。
- Produces: `GlossSheet.defaultDetent: PresentationDetent = .fraction(0.65)`；sheet 支持 `[defaultDetent, .large]`，深度解读触发前切到 `.large`。

- [ ] **Step 1: 将旧 340pt 断言改成新的失败断言**

把 `GlossSheetLayoutTests` 改为：

```swift
func testGlossStartsAtReadableFractionDetent() {
    XCTAssertEqual(GlossSheet.defaultDetent, .fraction(0.65))
}

func testLayoutKeepsActionsVisibleAndExpandsForDeepGloss() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = tests.deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent(
        "whatsub-mobile/Library/GlossSheet.swift"
    ), encoding: .utf8)

    let save = try XCTUnwrap(source.range(of: "if showsCollectionControl"))
    let deepContent = try XCTUnwrap(source.range(of: "deepGlossContent"))
    XCTAssertLessThan(save.lowerBound, deepContent.lowerBound)
    XCTAssertTrue(source.contains(
        "selectedDetent: PresentationDetent = Self.defaultDetent"
    ))
    XCTAssertTrue(source.contains(
        ".presentationDetents([Self.defaultDetent, .large]"
    ))
    XCTAssertTrue(source.contains("selectedDetent = .large"))
}
```

- [ ] **Step 2: 在 macOS 环境确认测试先失败**

Run:

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:whatsub-mobileTests/GlossSheetLayoutTests test
```

Expected: FAIL，因为 `defaultDetent` 尚不存在，源码仍使用 `.height(340)`。

- [ ] **Step 3: 替换默认 detent，保留 large 自动展开**

在 `GlossSheet` 中替换静态属性和状态初值：

```swift
static let defaultDetent: PresentationDetent = .fraction(0.65)
@State private var selectedDetent: PresentationDetent = Self.defaultDetent
```

将 sheet modifier 改为：

```swift
.presentationDetents([Self.defaultDetent, .large], selection: $selectedDetent)
```

保留 `deepGlossButton` 中现有的：

```swift
selectedDetent = .large
```

- [ ] **Step 4: 运行 detent 定向测试**

Run:

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:whatsub-mobileTests/GlossSheetLayoutTests test
```

Expected: PASS。

- [ ] **Step 5: 提交 sheet 高度改动**

```bash
git add whatsub-mobile/Library/GlossSheet.swift \
  whatsub-mobileTests/GlossSheetLayoutTests.swift
git commit -m "fix: enlarge highlight gloss sheet"
```

---

### Task 3: 深度解读使用信息卡片与项目符号列表

**Files:**
- Modify: `whatsub-mobileTests/DeepGlossTests.swift`
- Modify: `whatsub-mobile/Library/DeepGlossParser.swift`
- Modify: `whatsub-mobile/Library/GlossSheet.swift`

**Interfaces:**
- Consumes: `DeepGlossResult` 原有六个字段。
- Produces: `DeepGlossSection.items: [String]`、`DeepGlossSection.content: String`、`DeepGlossSectionKind.iconName: String`、`DeepGlossSectionKind.usesWarningStyle: Bool`；`GlossSheet` 用这些属性渲染卡片。

- [ ] **Step 1: 为列表条目和展示元数据写失败测试**

在 `DeepGlossTests` 中新增：

```swift
func testPresentationPreservesNaturalAlternativesAsSeparateItems() throws {
    let result = DeepGlossResult(
        contextualMeaning: "此处表示立刻。",
        toneAndSubtext: "语气直接。",
        slangOrIdiom: "",
        culturalContext: "",
        naturalAlternatives: ["right now", "at the moment"],
        usageWarning: "正式写作中谨慎使用。"
    )

    let sections = DeepGlossPresentation.visibleSections(for: result)
    let alternatives = try XCTUnwrap(sections.first {
        $0.kind == .naturalAlternatives
    })
    XCTAssertEqual(alternatives.items, ["right now", "at the moment"])
    XCTAssertEqual(alternatives.content, "right now\nat the moment")
}

func testEveryDeepGlossSectionHasStableIconMetadata() {
    XCTAssertEqual(DeepGlossSectionKind.contextualMeaning.iconName, "text.quote")
    XCTAssertEqual(
        DeepGlossSectionKind.toneAndSubtext.iconName,
        "bubble.left.and.text.bubble.right"
    )
    XCTAssertEqual(DeepGlossSectionKind.slangOrIdiom.iconName, "quote.bubble")
    XCTAssertEqual(DeepGlossSectionKind.culturalContext.iconName, "globe.asia.australia")
    XCTAssertEqual(DeepGlossSectionKind.naturalAlternatives.iconName, "list.bullet")
    XCTAssertEqual(DeepGlossSectionKind.usageWarning.iconName, "exclamationmark.triangle")
    XCTAssertTrue(DeepGlossSectionKind.usageWarning.usesWarningStyle)
    XCTAssertFalse(DeepGlossSectionKind.contextualMeaning.usesWarningStyle)
}
```

- [ ] **Step 2: 在 macOS 环境确认测试先失败**

Run:

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:whatsub-mobileTests/DeepGlossTests test
```

Expected: FAIL，因为 `items`、`iconName` 和 `usesWarningStyle` 尚不存在。

- [ ] **Step 3: 扩展纯展示模型，不改 Codable 结果模型**

在 `DeepGlossParser.swift` 中加入：

```swift
extension DeepGlossSectionKind {
    var iconName: String {
        switch self {
        case .contextualMeaning: return "text.quote"
        case .toneAndSubtext: return "bubble.left.and.text.bubble.right"
        case .slangOrIdiom: return "quote.bubble"
        case .culturalContext: return "globe.asia.australia"
        case .naturalAlternatives: return "list.bullet"
        case .usageWarning: return "exclamationmark.triangle"
        }
    }

    var usesWarningStyle: Bool { self == .usageWarning }
}

struct DeepGlossSection: Equatable {
    let kind: DeepGlossSectionKind
    let title: String
    let items: [String]

    var content: String { items.joined(separator: "\n") }

    init(kind: DeepGlossSectionKind, title: String, content: String) {
        self.init(kind: kind, title: title, items: [content])
    }

    init(kind: DeepGlossSectionKind, title: String, items: [String]) {
        self.kind = kind
        self.title = title
        self.items = items
    }
}
```

构造自然替换表达时保留数组：

```swift
DeepGlossSection(
    kind: .naturalAlternatives,
    title: "自然替换表达",
    items: result.naturalAlternatives
)
```

- [ ] **Step 4: 在 GlossSheet 中增加 section 卡片渲染函数**

将 loaded 分支的纯 `VStack` 替换为：

```swift
VStack(alignment: .leading, spacing: 10) {
    ForEach(
        Array(DeepGlossPresentation.visibleSections(for: result).enumerated()),
        id: \.offset
    ) { _, section in
        deepGlossSectionCard(section)
    }
}
```

新增渲染函数：

```swift
private func deepGlossSectionCard(_ section: DeepGlossSection) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Image(systemName: section.kind.iconName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(
                section.kind.usesWarningStyle ? Color.orange : Color.whatsubAccent
            )
            .frame(width: 28, height: 28)
            .background(
                (section.kind.usesWarningStyle ? Color.orange : Color.whatsubAccent)
                    .opacity(0.12),
                in: Circle()
            )

        VStack(alignment: .leading, spacing: 7) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.whatsubInk)

            if section.kind == .naturalAlternatives {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(Color.whatsubAccent)
                            .frame(width: 5, height: 5)
                        Text(item)
                            .font(.body)
                            .foregroundStyle(.whatsubInkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(section.content)
                    .font(.body)
                    .foregroundStyle(.whatsubInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(12)
    .background(
        (section.kind.usesWarningStyle ? Color.orange.opacity(0.07) : Color.whatsubBgElev),
        in: RoundedRectangle(cornerRadius: 12)
    )
}
```

- [ ] **Step 5: 运行深度解读与 sheet 布局测试**

Run:

```bash
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:whatsub-mobileTests/DeepGlossTests \
  -only-testing:whatsub-mobileTests/GlossSheetLayoutTests test
```

Expected: PASS；已有空 section 过滤测试继续通过。

- [ ] **Step 6: 提交深度解读展示改动**

```bash
git add whatsub-mobile/Library/DeepGlossParser.swift \
  whatsub-mobile/Library/GlossSheet.swift \
  whatsub-mobileTests/DeepGlossTests.swift
git commit -m "feat: improve deep gloss presentation"
```

---

### Task 4: 完整验证与视觉回归检查

**Files:**
- Verify: `whatsub-mobile/Library/VideoLearningGuideCard.swift`
- Verify: `whatsub-mobile/Library/GlossSheet.swift`
- Verify: `whatsub-mobile/Library/DeepGlossParser.swift`
- Verify: `whatsub-mobileTests/VideoLearningGuideLayoutTests.swift`
- Verify: `whatsub-mobileTests/GlossSheetLayoutTests.swift`
- Verify: `whatsub-mobileTests/DeepGlossTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 的最终实现。
- Produces: 可由 CI 构建、全量测试通过的 iOS 分支；不产生后端部署。

- [ ] **Step 1: 检查补丁质量和修改范围**

Run:

```bash
git diff origin/main...HEAD --check
git diff origin/main...HEAD --stat
git status --short
```

Expected: `--check` 无输出；工作区干净；修改仅包含规格、计划、三个 Swift 源文件和三个测试文件。

- [ ] **Step 2: 运行完整 simulator build 和单元测试**

Run:

```bash
xcodegen generate --quiet
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -project whatsub-mobile.xcodeproj -scheme whatsub-mobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
```

Expected: build 成功；全部 XCTest 通过且 0 failures。

- [ ] **Step 3: 在 simulator 做三项视觉检查**

检查同一个已解析视频：

1. 展开视频学习导览，标题保持可见，正文可滑到“重点片段”，字幕区仍在导览卡片下方。
2. 点击重点词，sheet 默认约占屏幕 65%，收藏和“深度解读”按钮均完整显示；点击深度解读后 sheet 展开到全屏。
3. 深度解读结果每个 section 为独立卡片；自然替换表达逐条带圆点；使用提醒为弱橙色样式。

Expected: 三项均符合规格，无按钮裁切、文本截断或滚动手势锁死。

- [ ] **Step 4: 如 CI 验证产生必要修复，单独提交**

仅在验证发现编译或布局问题时执行：

```bash
git add whatsub-mobile whatsub-mobileTests
git commit -m "fix: address guide and gloss layout verification"
```

若没有修复，不创建空提交。
