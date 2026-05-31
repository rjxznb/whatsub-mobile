# 需求文档：语料库驱动的 AI 语音对话练习（快速对话 / 短语闯关）

> 状态：需求草案（待实现）
> 平台：whatsub-mobile（iOS，SwiftUI，iOS 16+）
> 日期：2026-05-31（v2 patch：流式/裁决/选词优先级/合规/中断状态机 - 见 §0）
> 这份文档是自包含的：实现者不需要任何额外对话上下文。先读「2. 现状数据模型」把心智模型对齐，再读需求。

---

## 0. 实现前必做：1 小时 spike（写 plan 之前）

进 plan/implement 之前，**先用真实 LLM 跑一遍最危险的未知数**——比直接动工省一天返工。

手工 spike 步骤（无需 iOS 代码，curl / Postman 即可）：

1. 拿 3 个真实个人语料短语（含 `phraseRaw` + `meaningZh` + `usageNote` + 一个共同 `tag`）。
2. 按 §6.2 + §6.4 写完整 system prompt（含 per-turn verdict 围栏要求）。
3. 用 DeepSeek API（或你 BYOK 的实际厂商）**手工跑 5 轮 user/assistant**（你或另一个 LLM 扮 user）。
4. 用 `stream: true` 至少跑一次，确认 SSE 行分隔 + `data: {...}` + `delta.content` 拼接的实际 wire 形状。

**记录 4 个观察**（决定 v1 能否落地的事实）：
- (a) 每轮 verdict JSON 围栏的遵守率（10 次有几次格式坏）
- (b) AI 滑出角色当"教练"的概率（说"我们来练 sort it out 吧"而不是留在情景里）
- (c) 一局总 token 用量 + 平均每轮延迟（决定 §9 的成本/UX 上限）
- (d) AI 回复里有没有 markdown / emoji / 括号注释 / 中英混排标点（决定 §6.3 分段路由要不要先做 sanitize）

若 (a) < 8/10：改用 sentinel 围栏（如 `<<<VERDICT>>>...<<<END>>>`）或 DeepSeek 的 structured output（function calling）。
若 (b) 高：在 system prompt 里加 few-shot 示例锁住人设。
若 (c) 单轮 > 8s：必须流式（见 §6.2）+ 缩 prompt。

**spike 产物**：一份真实 transcript（贴回这个文件 §0 末尾）+ 4 条观察结论。后续 plan 引用这份事实，不再凭空设计。

### 0.1 Spike 结果（2026-05-31 已跑完）

**详细 transcript**：见同目录 `2026-05-31-spike-transcript.md`（5 轮真实 DeepSeek 对话 + stream probe + findings 分析）。

**4 项观察的实际结果**：

| 项 | 预期 | 实测 |
|---|---|---|
| (a) verdict 围栏遵守率 | ≥80%（否则降级）| **5/5 = 100%**。哨兵协议工作良好，§6.4 降级方案 v1 用不上 |
| (b) AI 留在角色 | 担心高破出率 | 5/5 通过，但**第 5 轮收尾时 LLM 会跳出夸奖用户**——已在 §6.2 system prompt 加约束 |
| (c) token + 延迟 | 担心慢 | 平均 **0.2s/轮**（远低于 1s 目标）；一局 ~4760 tokens ≈ **¥0.005**；deepseek-chat 实际路由到 deepseek-v4-flash fast 变种 |
| (d) markdown / sanitize | 担心 LLM 加粗 / 反引号坏 TTS | **零 markdown 出现**，纯散文。Speaker 升级无需 markdown strip |

**Spike 触发的 3 个 spec 修订**（已 patch 进下面对应章节）：

1. **§6.4 verdict.attempted 语义歧义**：LLM 默认理解为"本局累计"，spec 字面是"本轮"。改 prompt 强化"本轮"语义，**并由客户端维护 session-local 成功 Set 做 checklist 兜底**（防 LLM 漂回累计语义）。
2. **§6.2 第 5 轮收尾约束**：LLM 实测会在告别场景里夹"you used all three phrases perfectly today, well done!"——破角色。system prompt 加一条"第 5 轮收尾仍以角色身份告别，不评判用户表现"。
3. **§6.3 + §10 中英分段 TTS 降级为 v1.1**：LLM 实测**全英文纠正**，中文只出现在 verdict.note（UI 文字，不进 TTS）。v1 单语 en-US `AVSpeechSynthesizer` 即够用，`Speaker.swift` 升级只剩"参数化 locale"。BilingualTTS 移到 §12 后续。

**结论：v1 可以放心进 plan 阶段。** 流式 wire 格式（`data:` SSE + `delta.content` + `[DONE]`）已确认，§6.2 流式实现可以照抄。

---

## 1. 背景与定位

### 1.1 要解决的问题

whatsub-mobile 目前已经形成一条**被动学习链**：

```
刷视频/读双语字幕(输入) → 插件划词收藏到语料库(采集) → 单词卡测验(识别/认得)
```

唯独缺**最后一环：产出（把短语真正说出来、用出来）**。识别 ≠ 会用——单词卡能测出你「认得」一个短语，但测不出你「能在对话里用出来」。

本功能 = 补上这一环：**一个用你自己收藏的语料库短语、逼你开口说出来的 AI 语音对话。**

### 1.2 为什么这不是又一个 ChatGPT / 豆包

一个孤立的 AI 对话毫无意义——通用对话 ChatGPT/豆包碾压。本功能唯一的、别人结构上抄不走的价值是**数据壁垒**：

- 它只聊**你自己从真实视频/网页上划词收藏的短语**（个人语料库）
- 它知道**你哪些短语单词卡答熟了、哪些还没**（`quiz_progress`）
- 卡住时它能直接弹出**你划词那一刻的原句**（`contextSentence`）让你复习

> **一句话定位**：「用你上周收藏、单词卡还没答熟的那几个短语，在一个小情景里逼你开口说出来。」

### 1.3 设计铁律（最重要，违反即失败）

1. **永远不能是一个开放聊天框。** 一旦变成「随便跟 AI 聊」，就当场输给 ChatGPT。每一局对话都必须**锚定到用户语料库里的具体短语**。
2. **结构本身就是差异化。** 模式是「清掉今天的生词」（有目标、有反馈、有进度），不是自由对话。
3. **快速、低摩擦。** 一局 2–3 个短语、60–90 秒。首页一键进入，系统自动配词配场景，不让用户做选择题。

---

## 2. 现状数据模型（已核实，实现者必读）

whatsub-mobile 里有**三个互不相同**的「短语/单词」仓库。本功能**只用语料库**，但实现者必须分清，别再混：

| 仓库 | 范围 | 来源 | 掌握度追踪 | 可播放音频 | 关键文件 |
|---|---|---|---|---|---|
| **语料库 corpus** | 云端、跨设备 | 插件划词(网页/YouTube) + 公共策展 | ✅ `quiz_progress.json`（单词卡）| ❌ 只有 YouTube embed（需 VPN）| `Corpus/`、`Networking/DTOs.swift`、`Networking/WhatsubAPI.swift` |
| **视频单词本 VocabStore** | 本地、按 Library 视频分册 | 看同步视频时手动存 | ❌ 无 | ✅ OSS 音频 | `Vocab/VocabStore.swift`、`Vocab/VocabModels.swift` |
| **视频解析 Cue** | 随 Library 视频（云）| 导入时 AI 解析 | — | ✅ OSS | `Networking/DTOs.swift` 中 `Cue` |

> ⚠️ **本功能只读语料库（corpus）。** 视频单词本和视频解析已分别被现有的 `跟读(ShadowSheet)`/`听抄(ClozeSheet)` 覆盖，本功能不碰它们。

### 2.1 语料库短语的确切字段（`Networking/DTOs.swift`）

个人语料（`GET /api/corpus/mine` → `MineResponse.items: [MineItem]`）：

```swift
struct MineItem {
    let phraseNormalized: String   // 归一化键（建议作为掌握度/去重的主键）
    let phraseRaw: String          // 原始短语，如 "bouncing off the walls"
    let meaningZh: String?         // 中文意思
    let usageNote: String?         // 用法笔记
    let contextSentence: String    // ★ 划词那一刻的英文原句（纯文字，复习主力）
    let source: CorpusSource       // 出处
    let contributedAt: Int64
    let tags: [String]             // 场景标签（含 18 官方场景，见 CorpusTag）
}

struct CorpusSource {
    let kind: String          // youtube | webpage | pdf | curator
    let url: String
    let title: String?
    let timestampSec: Double?  // 只有 kind=="youtube" 才有 → ▶ 跳回片段（需 VPN）
}
```

公共语料（`/browse` → `BrowsePhrase`）：`phraseNormalized/phraseRaw/meaningZh/usageNote/tags`，**无 `contextSentence`、无 per-instance 出处**。

### 2.2 复习材料的两个层级（关键澄清）

- **默认复习（纯文字，零门槛、人人可用、无需 VPN/联网）**：`contextSentence` + `meaningZh` + `usageNote`。这三个是**文字字段**，已随语料缓存在本地（`corpus_cache.json`，见 `Corpus/CorpusCache.swift`）。
- **加成复习（VPN 门控、仅部分短语有）**：当 `source.kind == "youtube"` 且用户挂了 VPN，提供 `▶ 看原片那一句`（YouTube 嵌入，复用 `Components/YouTubeEmbedView.swift`，跳到 `timestampSec`）。

### 2.3 已有的掌握度（识别层）

`Quiz/QuizProgressStore.swift` + `quiz_progress.json`：单词卡（英→中选择题）的掌握度，mastery threshold + weighted selection。**这是「认得」的信号来源**。实现者需确认其主键（预期是 `phraseNormalized` 或 `phraseRaw`）并在选词逻辑中复用。

### 2.4 已有的、可复用的能力

| 能力 | 现有实现 | 本功能怎么用 |
|---|---|---|
| 设备端 ASR（语音转文字）| `Practice/ShadowSheet.swift`：`SFSpeechRecognizer(en-US)`，`requiresOnDeviceRecognition`，麦克风+语音权限流程 | **直接照搬这套录音→转写流程**采集用户的话 |
| BYOK LLM 调用 | `LLM/ChatCompletionsClient.swift`（**当前是非流式** `stream:false`），`LLM/LlmSettings.swift`（Keychain 里的 key）| 跑对话 + 当裁判。**v1 必须新增流式分支**——见 §6.2 |
| TTS 朗读 | `Quiz/Speaker.swift`（单词卡朗读封装，`AVSpeechSynthesizer`）| **起点**；扩展时**升级 Speaker 本体**支持中英分段，单词卡 + QuickChat 共用一份，不要在 `Practice/QuickChat/` 再开一份 `BilingualTTS.swift`（见 §10）|
| 文本比对 | `Practice/TextDiff.swift`（逐词 diff）| 廉价预判「用户这句里到底有没有出现目标短语」|
| 语料读取/缓存 | `Corpus/CorpusViewModel.swift`、`Corpus/CorpusCache.swift` | 取候选短语 |
| 出处片段播放 | `Components/YouTubeEmbedView.swift`、`Corpus/PhraseDetailView.swift` 的 ▶ seek | 加成复习 |

---

## 3. 范围

### 3.1 本期（v1）做什么

**只做 Mode ①「快速对话 / 短语闯关」**：系统从语料库选 2–3 个短语 → 生成一个能容下它们的小情景对话 → 用户开口（或打字）说话 → AI 留在角色里接话并判定短语是否被正确使用 → 卡住可复习 → 局末回写「产出掌握度」。

### 3.2 明确不做（非目标）

- ❌ **音素级发音评分**：LLM 做不到；真评分需专门语音 API（讯飞/Azure），留作后续付费可选项。（注：Library 视频侧的 `跟读(ShadowSheet)` 已用「ASR 逐词比对」做了粗版发音反馈，本功能不重复。）
- ❌ **场景角色扮演（Mode ②）/ 原片复刻（Mode ③）**：后续迭代。
- ❌ **后端改动**：v1 全部本地 + BYOK LLM，**不需要改 `whatsub-license` 后端**（与单词卡同样是 client-side only）。
- ❌ **production 掌握度跨设备同步**：v1 纯本地（镜像 quiz_progress 的本地策略），后续再考虑上云。
- ❌ **公共语料入池**：v1 词池**只用个人语料**（个性化最强、护城河最深）。公共语料留作后续「想多学点新的」扩展 / 冷启动兜底。

### 3.3 待用户确认的产品决策（已给推荐默认，实现按默认走即可）

1. **静默降级模式**：通勤/公共场合开不了口。推荐 **v1 同时支持「语音」和「打字」两种作答方式**，语音为主、打字为兜底（同一局内可切换）。
2. **每局短语数**：推荐 **3 个**（编情景自然、又够快）。

---

## 4. 三态掌握模型（功能的脊椎）

每个短语有两条独立的掌握度，把现有单词卡和本功能焊成一个连续体：

```
新收藏 ──单词卡答对(认得)──▶ recognition ──对话里用对(会用)──▶ production
        (quiz_progress.json)                (production_progress.json，新增)
```

- **recognition**：来自 `quiz_progress.json`（已有）。
- **production**：本功能新增的 `production_progress.json`（见 §5）。
- **黄金练习对象** = `认得了(recognition 达标) 但 还没会用(production 未达标)` 的短语——i+1 甜区。

---

## 5. 新增本地存储：`production_progress.json`

镜像 `Quiz/QuizProgressStore.swift` 的「init 时 load、mutation 后 rewrite」模式，写到 `Documents/production_progress.json`。

建议结构（`[phraseNormalized: ProductionProgress]`）：

```swift
struct ProductionProgress: Codable {
    var phraseNormalized: String
    var usedCorrectCount: Int       // 累计「在对话里正确用出」次数
    var attemptCount: Int           // 累计尝试（含用错）
    var lastErrorNote: String?      // 最近一次用错的纠正（喂下次 + 错误档案）
    var lastPracticedAt: Double     // epoch seconds，用于间隔复习到期判断
    var masteredAt: Double?         // 达到「会用」阈值的时间，nil = 未会用
}
```

- **会用阈值**：建议 `usedCorrectCount >= 2`（间隔达成，不要一局内刷满）→ 置 `masteredAt`。
- **间隔复习**：`masteredAt != nil` 但距 `lastPracticedAt` 超过 N 天 → 重新进入候选池（回捞）。N 建议 7 天，可调。

---

## 6. 功能需求：Mode ① 快速对话

### 6.1 选词逻辑（quiz_progress + production_progress 驱动）

开练前，在**个人语料库**上算每个短语的优先级，分层：

| 层级 | 条件 | 权重 |
|---|---|---|
| Tier 1（最高）| recognition 达标（认得）且 production 未达标（没说过/说错过）| 最高——graduate-ready 甜区 |
| Tier 2 | production 曾达标但已到期（间隔复习回捞）| 高 |
| Tier 3 | 新收藏、未测验也未产出 | 中（靠 §6.5 复习救生索可行）|
| 排除 | production 已达标且未到期 | 不选 |

**选词优先级（v2 patch — 反转了之前的"场景硬约束"）**：

```
Tier 优先 = 硬约束        ← 必须从最高可用 Tier 抽
同 tag    = 软加分        ← 能凑则凑，凑不齐不强求
```

理由：真实用户语料分布几乎一定是稀疏长尾（20 个短语散在 12 个 tag 里）。若把"同 tag" 设成硬约束，Tier 1 甜区几乎从来凑不齐 3 个同 tag——结果系统每天都在用 Tier 3 新词凑场景，**跳过了用户最该练的那批**，本功能的核心价值就丢了。

**具体算法**：
1. 取 Tier 1 全集；按 tag 分桶；找最大桶 ≥ 3 → 直接抽 3 个，end。
2. Tier 1 任何 tag 都不满 3 → Tier 1 抽 2（同 tag 优先）+ Tier 2/3 同 tag 凑 1。
3. 全跨 tag 兜底：Tier 1 不足 3，按 Tier 顺序补齐至 3。
4. 在最终选出的 3 个里，把它们共同/主导的 tag（若有）传给 §6.2 的 prompt 作为"建议场景"；否则让 LLM 自行设一个"能容下这些的日常情景"——**fallback 应该是常态而不是例外**。

候选池内**加权随机**抽取（随机保新鲜感，加权保有用）。

**冷启动**：个人语料 < 3 条时，本功能入口置灰或提示「先去用插件划词收藏一些短语」。（v1 不引入公共语料兜底。）

**间隔复习的 UI 提醒不需要单做**：每次开局重算选词时，到期的 Tier 2 自动进池就够了；不用专门的"今日复习"页。

### 6.2 对话生成（BYOK LLM，复用 + 扩展 `ChatCompletionsClient`）

**⚠️ 流式 + DeepSeek 实测延迟极低（spike: 0.2s/轮）。** 严格意义上"非流式 + 0.5s 延迟"对单轮 60-90 秒的对话也勉强可用，但**v1 仍然要做流式**——因为 (i) TTS 边收边播能把"用户开口 → 听到第一字音"压到 < 1s（spike 流式 first chunk 0.34s）；(ii) 用户配的不一定是 DeepSeek，换 Claude/Gemini 等慢厂商时差距更显著；(iii) Swift `AsyncThrowingStream` 实现成本不高。当前 `ChatCompletionsClient.chat(messages:) async throws -> String` 走的是 `stream: false`，import/CollectSheet 现状不变。

**v1 实现要求**：给 `ChatCompletionsClient` 加一个流式分支（不动现有 import/CollectSheet 的非流式调用）：

```swift
// 新增，不替换：
func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
```

- `"stream": true` + 按 `data: {...}\n\n` 行分隔解析 SSE
- 提取 `choices[0].delta.content` chunk，yield 给调用方
- 终止 sentinel `data: [DONE]` → finish stream
- 错误（HTTP 非 2xx / JSON 坏 / 网络中断）→ `continuation.finish(throwing:)`

QuickChat 拿到 chunk 后**边收边显示 + 边送 TTS 切句播放**（按句号/问号切，凑够一句立刻丢 `AVSpeechSynthesizer`），让用户第 1 秒就听到第一句，而不是等完整段。

**一局对话用一个 system prompt 启动**，要求 LLM **同时扮演三个角色**：情景里的对话方 + 温柔的教练 + 暗中的裁判。

System prompt 必须包含：
- 目标短语清单（每个带 `phraseRaw` + `meaningZh` + `usageNote`）
- 建议场景（§6.1 选词逻辑给出的主导 tag）或「请自行设一个能自然容纳这些短语的日常情景」
- 行为约束：
  - 起一个简短情景，**自然引导用户说出每个目标短语**（别直接告诉用户答案）
  - **始终留在角色里**——禁止跳出说"我们来练 XXX 吧"；纠正以角色内自然反应给出
  - 用户用错时温柔纠正（中文一句话，融在角色对话中）；spike 实测 LLM 会全英文纠正且用词简单，**v1 接受全英文纠正**，强求中文不必要
  - 控制节奏：3–5 轮内收敛
  - **第 5 轮收尾约束（spike 发现 LLM 会破角色）**：第 5 轮请仍以角色身份给出告别词；**不要**评判用户表现、**不要**夸奖"你今天用对了几个短语"、**不要**做 lesson summary——评判由客户端 UI 在局末根据 verdict 数据呈现
  - 默认中文为辅、英文为主（对话主体英文，verdict.note 用中文便于学习者复盘）
- **输出格式硬约束**：每轮回复正文之后**必须**紧跟一个围栏块（客户端 strip 后再显示给用户），见 §6.4 的裁判结构。

### 6.3 TTS 输出（v1 单语英文；中英分段延后到 v1.1）

- v1 用 **Apple `AVSpeechSynthesizer`**（免费、设备端、零配置、离线），以 `Quiz/Speaker.swift` 为起点扩展。
- **v1 单语英文朗读即可**（spike 实测证伪了"中英混排"的担忧）：LLM 实测会用**全英文 + 用词简单**的方式做纠正，并把中文翻译信息放到 `verdict.note`。verdict.note 是**给眼睛看的 UI 文字**（卡住卡片 / 局末总结显示），**不进 TTS**。所以对话气泡的 TTS 输入实际是单一 en-US 语料。
- `Speaker.swift` 升级范围 = "参数化 locale + 音色 + 速率"，**不需要中英分段路由**。单词卡（zh-CN 短语朗读）和 QuickChat（en-US 对话朗读）共用升级后的 Speaker。
- 英文用 `enhanced/premium` 神经音（需用户在系统设置下载更好的音色，可检测+提示，但不强制）。
- **流式 TTS 切句喂**：从 LLM 流式 chunk 拼出句子（碰到 `.` `?` `!` 或换行），凑够一句立刻丢 `AVSpeechSynthesizer.speak(_:)`，下一句续上——而不是等整段完了再朗读。
- 后续 v1.1+（见 §12）：若实际用户配的 LLM 输出更多中文纠正，再补中英分段路由 + Azure 神经音升级。

### 6.4 判定（LLM 当裁判，判「内容」不判「发音」）

- **能判**：用户有没有用上目标短语、用得对不对（时态/搭配/语境）。
- **不判**：发音准不准（不是本功能职责）。

判定来源 = 跑对话的同一个 LLM。**v1 承诺 per-turn verdict**（不是 §6.5 实时点亮 checklist 的唯一可能实现）。

**LLM 每轮回复的硬性输出协议**：

```
<assistant 自然语言对话正文>
<<<VERDICT>>>
{"verdicts":[
  {"phrase":"bouncing off the walls","attempted":true,"correct":true,"note":""},
  {"phrase":"sort it out","attempted":true,"correct":false,"note":"时态应为过去式 sorted it out"},
  {"phrase":"fair enough","attempted":false,"correct":false,"note":""}
]}
<<<END>>>
```

- 用 `<<<VERDICT>>>` / `<<<END>>>` 哨兵（不用 ```json 围栏，因为 LLM 在角色对话里偶尔会用 markdown 反引号）
- 流式收 chunk 时实时扫哨兵：见到 `<<<VERDICT>>>` → 之后的 chunk 不进对话气泡 / 不送 TTS，进 verdict buffer；见到 `<<<END>>>` → parse JSON → 触发 checklist ✓ 动画 + 反馈音。
- LLM 偶尔会忘记输出 verdict（spike §0 (a) 项已度量）；缺失 = 等价于 verdict 全 `attempted:false`，不报错。
- 若 spike 测得 verdict 遵守率 < 80%，**降级方案**：每 N 轮（或局末）单独发一次"裁判调用"，输入对话历史，要求只返回 verdict JSON——成本翻倍但格式更可靠。

**attempted 的语义必须是"本轮 user 消息里的尝试"，不是累计**（spike 发现 LLM 默认会用累计语义）：
- system prompt 必须显式强调："`attempted` 指**仅**本轮 user 消息里有没有尝试使用该短语；不要把之前轮次里的成功带进来。"
- **客户端必须做兜底**：维护一个 session-local `Set<phraseNormalized>` 记录"已在某轮被 verdict 确认为 correct 的短语"。每轮新 verdict 进来时，把 `attempted && correct` 的短语加进 Set。**§6.5 checklist ✓ 的点亮基于这个 Set，不是直接读最新 verdict**——这样即使 LLM 偶尔漂回累计语义（false positive）或忘标（false negative），UI 也稳定。
- 局末 `production_progress.json` 写入也基于这个 Set（每个 phrase 最多 +1 usedCorrectCount，不会因 LLM 重复标 correct 而灌水）。

**廉价预判**：用 `Practice/TextDiff.swift` 或子串匹配，先在 ASR 文本里检测目标短语是否出现（含 stemming：`sort it out` ↔ `sorted it out`），作为 `attempted` 的辅助信号（防 LLM 漏判）。

**从宽原则（重要）**：ASR 会听错 → 可能误判「你没说」。所以：
- 判定一律从宽，模糊算用户对；
- 提供「我说对了」手动覆盖按钮，用户点了就按正确回写（更新上面那个 session-local Set）。

### 6.5 交互流程（storyboard）

```
[首页] 点「快速对话」(一下，不选场景，系统自动配)
         ↓
[抽词]  淡入 1 秒："今天练 3 个你还不熟的：bouncing off the walls / sort it out / fair enough"
         ↓
[对话]  顶部 = 3 个短语的待点亮 checklist
         AI 起一个能容下这 3 个短语的小情景（如：朋友抱怨房东）
         用户「按麦说」(或切「打字」) → ASR → AI 留在角色接话 + 暗中判定
         每用对一个 → 对应 ✓ 点亮 + 轻反馈音（复用 Quiz/SoundFX.swift）
         (3–5 轮，60–90 秒)
         ↓
[卡住?] 某短语憋不出 → 点它 →
         默认弹卡片：contextSentence(原句) + meaningZh + usageNote   ← 纯文字，无 VPN
         加成(source.kind==youtube && 有VPN)：多一个「▶ 看原片那一句」
         → 看完返回继续
         ↓
[局末]  "你用对了 2/3。'sort it out' 时态错了(应 sorted it out)。
         'fair enough' 没用上 → 明天回捞。"
         → 回写 production_progress.json（§5）
         按钮：[再来一局] [复习没说好的]
```

### 6.5.1 中断与边界状态机

语音对话比单词卡脆得多——任何时刻可能：返回首页 / 切后台 / 锁屏 / 电话进来 / Siri 抢麦 / Bluetooth 耳机断开。**v1 必须处理**：

| 事件 | 行为 |
|---|---|
| 用户主动退出（返回上一级 / 关掉 sheet）| 已经累计到的 verdict 立刻落 `production_progress.json`（不丢，不等局末汇总）|
| App 切后台（`scenePhase != .active`）| 暂停 `AVAudioEngine` 录音 + 暂停 `AVSpeechSynthesizer`；正在飞的 LLM 流式请求**继续在 background URLSession 里跑完**，但 chunk 入 buffer 不渲染 |
| App 回前台 | **不自动恢复**——展示一个"继续 / 结束这局"二选一；选继续就把 buffered chunk 渲染 + 续 ASR；选结束就走 §6.5 [局末] 流程 |
| 电话进来 / Siri 抢麦（`AVAudioSession.interruptionNotification`）| 同"切后台" |
| 麦克风权限被撤回 | 自动切到"打字"模式 + 提示 |
| LLM 流式 30 秒无新 chunk | 客户端超时 → 当本轮无输出处理，allow 用户再说一次或结束 |

写在 `QuickChatViewModel` 里的一个有限状态机比散在各 callback 里靠谱：`idle | recording | thinking | speaking | paused | summarizing | done`。

### 6.6 入口位置

建议放在「语料库」tab（与单词卡并列，因为它俩同源、是「认得→会用」的连续关卡）。具体 UI 位置由实现者按现有 `Corpus/CorpusView.swift` 布局决定。

**入口文案的合规约束（见 §9.7）**：不要用「AI 助理」「智能对话」「ChatGPT」等字样；用「对话陪练」「短语应用」「开口练」之类。

---

## 7. 一局对话的数据流（落到字段名）

```
【开练前 · 全本地/缓存，零服务器】
1. 读个人语料：CorpusCache / CorpusViewModel → [MineItem]
2. 读 quiz_progress.json（recognition 掌握度）
3. 读 production_progress.json（production 掌握度，§5）
4. 选词逻辑(§6.1) → 定场景(tags) + 3 个目标短语(MineItem)
5. 拼 system prompt(§6.2)：每个短语带 phraseRaw/meaningZh/usageNote + 场景 + 裁判格式

【每轮 · 重活全在设备端/厂商，你的服务器零负载】
6. 用户按麦 → AVAudioRecorder 录音 → SFSpeechRecognizer(en-US, on-device) → 文字
   （或：用户打字输入）
7. 进对话历史 → ChatCompletionsClient 流式调用 BYOK LLM
8. LLM 流式回复（留在角色）→ TextDiff 预判 attempted → 收集 §6.4 裁决
9. TTS：回复按中英分段 → AVSpeechSynthesizer 顺序播放
10. UI：双语显示该轮对话 + checklist 实时点亮

【卡住 · 本地】
11. 弹 contextSentence + meaningZh + usageNote；youtube+VPN 时加 ▶ 原片

【局末 · 回写本地】
12. 汇总 §6.4 裁决 → 更新 production_progress.json（usedCorrectCount/attemptCount/lastErrorNote/lastPracticedAt/masteredAt）
13. UI 总结 + 间隔复习排期
```

---

## 8. 技术架构与「破服务器」约束

语音对话三段，**重活全部不落在 whatsub-license 服务器上**：

| 环节 | 跑在哪 | 服务器负载 |
|---|---|---|
| 听（ASR）| Apple `SFSpeechRecognizer`，设备端 | 零 |
| 想（LLM）| BYOK 云厂商（DeepSeek/Claude…），算力是厂商的 | 零（不经过我们后端，客户端直连厂商，沿用 import 现状）|
| 说（TTS）| Apple `AVSpeechSynthesizer`，设备端 | 零 |

→ **v1 不需要任何后端改动，也不依赖我们那台服务器的算力。**

---

## 9. 风险与权衡（已知，需在实现中处理）

1. **ASR 听错** → 误判「没说」。对策：判定从宽 + 「我说对了」手动覆盖（§6.4）。
2. **回合制延迟**：ASR→LLM→TTS 串行 = 对讲机式轮流说，**不是 ChatGPT 那种可打断的丝滑**。对学口语够用。缓解：流式 LLM（§6.2）+ TTS 边出句边播、文字先于音频出现。
3. **TTS 自然度 + 中英混排**：Apple 中文音色一般、英文较好；混排必须分段路由（§6.3）。自然度不满意时后续可换 Azure。
4. **BYOK token 成本**：多轮对话每轮塞全部 history → token 用量随轮数线性涨。**v1 硬上限**：每局对话 ≤ 5 轮，第 5 轮 LLM 必须自然收尾（system prompt 里硬性写明"第 5 轮请用一句话给出鼓励性结尾"）；前端到第 5 轮强制不再发新 user msg、直接进 §6.5 [局末]。
5. **mic / 语音识别权限**：`Info.plist` 需 `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`（确认 ShadowSheet 已加则复用）。
6. **冷启动**：语料 < 3 条时入口置灰/提示（§6.1）。
7. **App Store 审核 + 中国合规风险（高优先级）**：iOS 客户端刚因 OpenAI 字样被 Apple 第二轮 reject。新加"AI 对话"功能会触发新一轮重点审查：
   - **Guideline 1.1/1.2 (UGC + AI-generated content)**：审核员八成会要求"举报 AI 回复"按钮 + EULA 段落写明"对话由用户自配的第三方 AI 服务生成"+ 屏蔽机制。**v1 必须自带**：对话气泡上长按 → "上报这条回复"（v1 可以只是 mailto 给 admin 邮箱，不做后端）。
   - **DST/MIIT 生成式 AI 备案**：跟 OpenAI 字样同源；BYOK 论点（"app 不内置 AI 服务，仅访问用户自填端点"）能复用且强——但要在用户首次进入功能时显式声明（一次性弹窗 + "已了解"），文案样例：「本功能调用您在「我的 → LLM 设置」中自行配置的第三方语言模型服务。whatSub 不内置任何 AI 服务，不存储您的对话内容。」
   - **元数据 / UI 文案审计**：app 内任何按钮、提示、说明文档、ASC 截图、关键词都不能出现 `AI`/`ChatGPT`/`OpenAI`/`GPT`/`大模型助理`/`智能对话`。允许用：`对话陪练`、`开口练`、`短语应用`、`语料练习`。
   - **默认 LLM 配置不预填境外厂商**：现已默认 DeepSeek（境内厂商），符合现状；保持不变。
   - **本节产出物**：第一次进入 QuickChat 的一次性合规弹窗 + 对话气泡长按上报 + 文案审计 checklist，需要在 plan 里专门列任务。
8. **LlmSettings 单一配置同时驱动 import 解析 + QuickChat 对话**：v1 不分两套，但用户若把 model 配成 `deepseek-reasoner`（慢便宜，适合长 import 解析）→ QuickChat 体验会崩。在 LlmSettings 页加一行说明文字，并在 §12 备忘"未来 QuickChat 可单独指定 model"。
9. **production 阈值 = 2 偏宽**（§5）：叠加从宽判定 + 手动覆盖，假阳性会偏高。但 7 天后回捞 self-correcting，v1 接受为"速度优先"权衡；若 telemetry 显示回捞率异常高，后续提到 3。

---

## 10. 复用 / 新增清单

**复用 + 就地升级（不要复制重写）**：
- ASR 录音→转写流程：照搬 `Practice/ShadowSheet.swift`
- LLM 调用：`LLM/ChatCompletionsClient.swift` + `LLM/LlmSettings.swift`
  - **升级该 client**：新增 `func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>`（见 §6.2），现有非流式 `chat` 不动（import/CollectSheet 继续用）。
- TTS：**升级 `Quiz/Speaker.swift` 本体**支持参数化 locale + 速率（v1 单语，spike 已证无需中英分段——见 §6.3）。单词卡和 QuickChat 共用——**不要**在 `Practice/QuickChat/` 再开一份 `BilingualTTS.swift`。中英分段路由延后到 v1.1（§12）。
- 短语出现预判：`Practice/TextDiff.swift`
- 语料读取/缓存：`Corpus/CorpusCache.swift`、`Corpus/CorpusViewModel.swift`、`MineItem`/`/api/corpus/mine`
- recognition 掌握度：`Quiz/QuizProgressStore.swift`
- 反馈音/触感：`Quiz/SoundFX.swift`
- 出处片段：`Components/YouTubeEmbedView.swift`

**新增**（建议放 `Practice/QuickChat/`）：
- `ProductionProgressStore.swift`（§5，镜像 QuizProgressStore）
- `PhraseSelector.swift`（§6.1 选词逻辑：Tier 优先硬约束 + 同 tag 软加分）
- `ConversationEngine.swift`（§6.2/§6.4：拼 prompt、驱动 `ChatCompletionsClient.stream`、流式扫 `<<<VERDICT>>>`/`<<<END>>>` 哨兵、解析裁决、提前哨兵后分流：对话 chunk → UI/TTS，verdict chunk → buffer）
- `QuickChatViewModel.swift`（§6.5.1 有限状态机：`idle | recording | thinking | speaking | paused | summarizing | done`）
- `QuickChatView.swift` + 子视图（§6.5 storyboard：3 短语 checklist / 录音按钮 / 打字 fallback / 卡住卡片 / 局末总结）
- `ComplianceGate.swift`（§9.7：首次进入功能时的一次性合规弹窗 + UserDefaults flag）
- 数据模型：`ChatTurn`、`PhraseVerdict`、`SessionResult`

---

## 11. 验收标准

1. 从「语料库」tab 一键进入快速对话，无需选场景/选词。
2. 系统自动选出 3 个**优先「认得未会用」（Tier 1 硬约束）**的个人语料短语；能凑同 tag 就同 tag，凑不齐就跨 tag + LLM 自找情景（fallback 是常态）。
3. 对话能用语音（设备端 ASR）**或**打字作答；语音走在线/离线 SFSpeechRecognizer。
4. AI 留在情景角色里，自然引导用户用出目标短语，用错时给中文纠正；不跳出说"我们来练 XXX 吧"。
5. **LLM 走流式**：用户开口后第 1 秒内开始听到 AI 第一句（TTS 边收 chunk 边播）；顶部 checklist 在短语被正确用出时实时点亮 + 反馈音（由 per-turn `<<<VERDICT>>>` 哨兵触发）。
6. 卡住点短语 → 弹 `contextSentence`+`meaningZh`+`usageNote`（无 VPN/离线可用）；youtube 出处 + VPN 时额外出现 ▶ 原片。
7. 局末显示「用对 X/3」+ 每个短语的纠正/未用提示，并正确回写 `production_progress.json`。任意中途退出（返回/切后台/电话）已计算的 verdict **不丢**。
8. `usedCorrectCount` 跨多局累积达阈值 → 标记「会用」(`masteredAt`)；到期后回捞。
9. AI 回复的 TTS 以 en-US 流畅朗读（`Quiz/Speaker.swift` 升级为参数化 locale + 速率；中英分段路由已按 §6.3 决定延后到 v1.1）。
10. 每局对话 ≤ 5 轮硬上限，第 5 轮 LLM 自然收尾。
11. 首次进入功能展示一次性合规弹窗（§9.7）；对话气泡支持长按"上报这条回复"。
12. UI 文案、入口文字、ASC 截图均不含 `AI`/`ChatGPT`/`OpenAI`/`GPT` 字样。
13. 全程不调用 whatsub-license 后端的任何新端点（仅 BYOK 厂商 + 设备端能力）。

---

## 12. 后续迭代（非 v1，仅备忘）

- Mode ②：场景角色扮演（更开放，按 tag 选场景）
- Mode ③：原片复刻（重播真实片段后接话；受 YT/VPN 限制，优先用有 OSS 视频的来源）
- production 掌握度上云、跨设备
- 真音素级发音评分：接讯飞 / Azure 发音评估（付费、联网，可选增值）
- **中英分段 TTS 路由 `BilingualTTS`**：若 v1 上线后 telemetry / 用户反馈显示中文纠正比例上升（更换 LLM 厂商后可能），把 Speaker 升级为按语言切段 + 各段 locale 音色顺序合成（spike 已证 v1 默认 DeepSeek 用不到）
- TTS 升级 Azure 神经音
- 词池纳入公共语料（「想多学点新的」）
