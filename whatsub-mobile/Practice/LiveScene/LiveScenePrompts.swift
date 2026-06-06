import Foundation

/// Two system prompts that drive the LiveScene flow:
///
///   1. `promptDerivationPrompt(scene:)` — fed to a one-shot `chat()` call.
///       Returns a `SpeakingPrompt` JSON envelope.
///   2. `gradingPrompt(prompt:userTranscript:)` — fed to a one-shot
///       `chat()` call after the user speaks. Returns a `SceneGrade`
///       JSON envelope.
///
/// Both prompts are the PRODUCT — the wording determines how good the
/// exercise feels — so they live in one auditable place rather than
/// inlined into the client. Mirrors the
/// `RoleplayPrompts.scenePrompt / turnSystemPrompt` split.
///
/// 2026-06-05.
enum LiveScenePrompts {

    // MARK: - 1. Prompt derivation (Vision labels → speaking task)

    static func promptDerivationMessages(scene: SceneContext) -> [ChatMessage] {
        let system = """
        你是英语口语练习教练。下面会告诉你一张图片里被本机 Vision API 识别出的关键标签 + 人数 / 动物数。请基于这些信息,设计一个 short speaking task,让中文母语英语学习者用英语口头描述这个场景,并预先准备一个 native-style 参考答案(用户练完后/卡壳时可参考)。

        硬约束:
        - **只输出 JSON**,不要任何前后缀文字、不要 markdown 围栏。
        - `promptEn`: 1-2 句英文,描述用户要做什么(e.g. "Describe what you see in this scene — focus on the bicycles and what time of day it might be."),自然不要僵硬。**全英文**,不要中英混合。
        - `sampleAnswer`: **25-50 词**的英文示范答案,native 风格,自然贯穿 targetVocab 里的 **至少 3 个**短语。不要堆砌单词、要像真人在 1 分钟内随口描述这个场景。**全英文**,不要双语对照。这是「提示」按钮的第二次点击 + 复盘时的参考答案。
        - `sampleAnswerZh`: 上面 `sampleAnswer` 的**中文翻译**——意思对应、自然中文表达,不要逐字直译。30-60 字。**全中文**,不要双语对照。这是「提示」按钮的第一次点击,目的是让中文母语学习者先在中文里把意思想清楚,再去说英语。
        - `targetVocab`: **严格 3-5 个** English phrases(绝不超过 5;多了客户端会截掉),全部小写、保留完整 phrasal 形态("lean against" 而非 "lean"),从图片标签里自然引出 + 适配难度。
        - `difficulty`: 1=A2(常见物简单形容词)、2=B1(组合 + 一两个介词短语)、3=B2(时态、情境推断、不直观搭配)。根据标签复杂度判断,不确定就 2。
        - 不要假装看到 Vision 没识别出的东西(没标签里有"sunset" 就不要写 "describe the sunset")。
        - 标签太少 / 太普通(就一个"indoor")时,生成开放式提问("Describe this room and what you would do here"),不要强行编细节,sampleAnswer 也保持 generic 一点。

        输出格式(exactly):
        {
          "promptEn": "...",
          "sampleAnswer": "...",
          "sampleAnswerZh": "...",
          "targetVocab": ["...", "..."],
          "difficulty": 2
        }
        """

        let user = """
        Vision 识别出的场景信息:
        \(scene.llmDescription)

        现在请输出 JSON。
        """

        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }

    // MARK: - 2. Grading (user transcript → SceneGrade)

    static func gradingMessages(
        prompt: SpeakingPrompt,
        userTranscript: String
    ) -> [ChatMessage] {
        // Build the per-vocab JSON skeleton so the LLM knows the EXACT
        // shape + length to emit (mirrors the QuickChat / Roleplay verdict
        // pattern — explicit skeletons reduce JSON-shape drift).
        let vocabSkeleton = prompt.targetVocab.map {
            "  {\"phrase\":\"\($0)\",\"attempted\":<bool>,\"correct\":<bool>,\"note\":\"<中文纠正或空>\"}"
        }.joined(separator: ",\n")

        let system = """
        你是英语口语练习教练。下面是用户被给的 speaking prompt + 他/她刚才用英语录下来的回答(已经过 ASR 转写,可能有口误或识别错的词)。请给一个简洁、鼓励但诚实的评分。

        **不需要**写参考答案——客户端在 prompt 派生阶段已经预先有了 `sampleAnswer`,review 屏会展示那个,这一轮你只关心 score / feedback / 每条 vocab 的命中。

        硬约束:
        - **只输出 JSON**,不要任何前后缀文字、不要 markdown 围栏。
        - `score`: 1-5 整数。**评分锚定**:1=几乎没说 / 跑题;2=能开口但语法多错、vocab 没碰;3=基本完成、有一些可改进点;4=自然、命中大部分 vocab、小瑕疵;5=接近母语水平 + 全部 vocab 自然用上。**不要默认 4 或 5**——大多数学习者第一次说应该是 3。
        - `feedback`: **2-3 句中文**评语。第 1 句说做得好的地方,第 2-3 句说能改的(比如 "leaning to → leaning against","two person → two people")。不要空话(避免"加油!不错!继续努力!")。
        - `vocabHits`: 严格 \(prompt.targetVocab.count) 条(跟下面 targetVocab 数量一致),每条:
          - `attempted`: 用户**这一次回答**里有没有尝试使用该 phrase(form 可以略变,如 "leaning"/"leaned"/"leans" 都算 "lean against" 的尝试)
          - `correct`: 尝试了 AND 语法 + 搭配 + 上下文都对
          - `note`: 简短中文纠正,没尝试 / 完全对则留空字符串

        - ASR 转写可能有错(比如把 "bike" 听成 "bok")。如果用户说的内容**意思对但词形错**,judge 倾向于 attempted=true + 简短 note 标注疑似 ASR 错。
        - 不要纠正用户的 accent — 你看不到音频,只能看到文本。

        Speaking prompt: \(prompt.promptEn)
        Target vocab: \(prompt.targetVocab.joined(separator: ", "))

        输出格式(exactly):
        {
          "score": 3,
          "feedback": "...",
          "vocabHits": [
        \(vocabSkeleton)
          ]
        }
        """

        let user = """
        用户的英语回答(ASR 转写):

        \(userTranscript.isEmpty ? "(空白 — 用户没说话或 ASR 没捕捉到)" : userTranscript)

        现在请按上面格式输出 JSON。
        """

        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }
}
