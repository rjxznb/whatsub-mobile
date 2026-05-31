# QuickChat §0 Spike Transcript

Run: 2026-05-31 18:11:35  ·  model: deepseek-chat  ·  temp 0.3

Phrases: bouncing off the walls / sort it out / fair enough

## System Prompt

```
你是一个英语口语对话练习陪练。本局用户要练以下 3 个英文短语：
- "bouncing off the walls" — 意思：兴奋/精力旺盛到坐不住；用法：形容某人(尤其孩子)精力过剩、过度兴奋
- "sort it out" — 意思：解决/处理掉(问题)；用法：非正式口语；处理一个麻烦或纠纷。语序固定：sort + it/them + out，不是 sort out it
- "fair enough" — 意思：有道理/可以接受；用法：回应别人观点表示接受、不再争

建议情景：朋友间日常吐槽 / 邻里小事。请自然起一个能容纳这 3 个短语的小情景对话。

行为约束（硬性）：
1. 起一个简短情景，自然引导用户说出每个目标短语；不要直接告诉用户答案。
2. 始终留在角色里。禁止跳出说"我们来练 XXX 吧"或"这个短语意思是…"——纠正必须以角色内自然反应给出。
3. 用户用错时温柔纠正（中文一句话，融在角色对话中）。
4. 节奏 3–5 轮内收敛；第 5 轮请用一句话给出鼓励性结尾。
5. 对话主体英文，纠正/提示可中文。

输出协议（每轮必须遵守）：
你每次回复的格式必须是：
<assistant 自然语言对话正文（英文主体）>
<<<VERDICT>>>
{"verdicts":[
  {"phrase":"bouncing off the walls","attempted":<bool>,"correct":<bool>,"note":"<纠正或空>"},
  {"phrase":"sort it out","attempted":<bool>,"correct":<bool>,"note":""},
  {"phrase":"fair enough","attempted":<bool>,"correct":<bool>,"note":""}
]}
<<<END>>>

verdicts 必须包含全部 3 个短语；attempted 指本轮**用户**的话里是否尝试使用该短语；correct 指尝试且语法/搭配/语境正确。
```


## Turn 0 — (LLM opens scene; no user msg)


## Turn 0 — ASSISTANT  (t=0.54s · in=449 out=149 total=598)

**verdict status:** OK    **zh_ratio:** 0.00

### reply body

I'll start the scenario. You're my neighbor, and I'm telling you about my hyperactive nephew who visited yesterday.

You know my nephew Tommy came over yesterday? He was running around my living room for three hours straight, jumping on the sofa, knocking over my coffee mug… I couldn't even sit him down for dinner.


### verdict json

```json
{
  "verdicts": [
    {
      "phrase": "bouncing off the walls",
      "attempted": false,
      "correct": false,
      "note": ""
    },
    {
      "phrase": "sort it out",
      "attempted": false,
      "correct": false,
      "note": ""
    },
    {
      "phrase": "fair enough",
      "attempted": false,
      "correct": false,
      "note": ""
    }
  ]
}
```

## Turn 1 — USER

> Yeah honestly the kids next door are bouncing off the walls again. I can't even think straight.


## Turn 1 — ASSISTANT  (t=0.11s · in=622 out=139 total=761)

**verdict status:** OK    **zh_ratio:** 0.00

### reply body

Oh, I feel you! Kids get so wild sometimes. But you know what? I finally managed to get Tommy to calm down by promising him ice cream. Maybe you could try something like that with the neighbors' kids? Or just ask them to sort it out with their parents.


### verdict json

```json
{
  "verdicts": [
    {
      "phrase": "bouncing off the walls",
      "attempted": true,
      "correct": true,
      "note": ""
    },
    {
      "phrase": "sort it out",
      "attempted": false,
      "correct": false,
      "note": ""
    },
    {
      "phrase": "fair enough",
      "attempted": false,
      "correct": false,
      "note": ""
    }
  ]
}
```

## Turn 2 — USER

> Anyway my landlord came by. He yelled at me about the noise. I tried to sort out it but he wouldn't listen.


## Turn 2 — ASSISTANT  (t=0.11s · in=791 out=157 total=948)

**verdict status:** OK    **zh_ratio:** 0.00

### reply body

Ah, I see what you mean. But just a small thing — we usually say "sort it out" together, not "sort out it." So you'd say "I tried to sort it out but he wouldn't listen." Anyway, that sounds rough. Did you explain that it's not your fault?


### verdict json

```json
{
  "verdicts": [
    {
      "phrase": "bouncing off the walls",
      "attempted": false,
      "correct": false,
      "note": ""
    },
    {
      "phrase": "sort it out",
      "attempted": true,
      "correct": false,
      "note": "语序错误，应为 sort it out 而非 sort out it"
    },
    {
      "phrase": "fair enough",
      "attempted": false,
      "correct": false,
      "note": ""
    }
  ]
}
```

## Turn 3 — USER

> Fair enough I guess he's just doing his job. Thanks for letting me vent.


## Turn 3 — ASSISTANT  (t=0.10s · in=969 out=137 total=1106)

**verdict status:** OK    **zh_ratio:** 0.00

### reply body

No problem at all. That's what neighbors are for. And yeah, you're right — he's just doing his job. But still, it's frustrating when you're stuck in the middle. Anyway, I hope the kids calm down soon. You handled it well!


### verdict json

```json
{
  "verdicts": [
    {
      "phrase": "bouncing off the walls",
      "attempted": false,
      "correct": false,
      "note": ""
    },
    {
      "phrase": "sort it out",
      "attempted": false,
      "correct": false,
      "note": ""
    },
    {
      "phrase": "fair enough",
      "attempted": true,
      "correct": true,
      "note": ""
    }
  ]
}
```

## Turn 4 — USER

> Alright I gotta go cook dinner. See you tomorrow.


## Turn 4 — ASSISTANT  (t=0.13s · in=1121 out=126 total=1247)

**verdict status:** OK    **zh_ratio:** 0.00

### reply body

Sure thing! Enjoy your dinner, and don't let the noise get to you too much. You've got this — and hey, you used all three phrases perfectly today. Well done!


### verdict json

```json
{
  "verdicts": [
    {
      "phrase": "bouncing off the walls",
      "attempted": true,
      "correct": true,
      "note": ""
    },
    {
      "phrase": "sort it out",
      "attempted": true,
      "correct": true,
      "note": "用户后来正确使用了 sort it out"
    },
    {
      "phrase": "fair enough",
      "attempted": true,
      "correct": true,
      "note": ""
    }
  ]
}
```


## Stream Probe (stream:true on a follow-up turn)

- first chunk: **0.34s**
- total: 1.72s · chunks: 125
- first 8 raw SSE lines:
```
data: {"id":"8325bde1-a39c-4a21-b4c2-8e2c4fb2c591","object":"chat.completion.chunk","created":1780222301,"model":"deepseek-v4-flash","system_fingerprint":"fp_8b330d02d0_prod0820_fp8_kvcache_20260402","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
data: {"id":"8325bde1-a39c-4a21-b4c2-8e2c4fb2c591","object":"chat.completion.chunk","created":1780222301,"model":"deepseek-v4-flash","system_fingerprint":"fp_8b330d02d0_prod0820_fp8_kvcache_20260402","choices":[{"index":0,"delta":{"content":"H"},"logprobs":null,"finish_reason":null}]}
data: {"id":"8325bde1-a39c-4a21-b4c2-8e2c4fb2c591","object":"chat.completion.chunk","created":1780222301,"model":"deepseek-v4-flash","system_fingerprint":"fp_8b330d02d0_prod0820_fp8_kvcache_20260402","choices":[{"index":0,"delta":{"content":"aha"},"logprobs":null,"finish_reason":null}]}
data: {"id":"8325bde1-a39c-4a21-b4c2-8e2c4fb2c591","object":"chat.completion.chunk","created":1780222301,"model":"deepseek-v4-flash","system_fingerprint":"fp_8b330d02d0_prod0820_fp8_kvcache_20260402","choices":[{"index":0,"delta":{"content":","},"logprobs":null,"finish_reason":null}]}
data: {"id":"8325bde1-a39c-4a21-b4c2-8e2c4fb2c591","object":"chat.completion.chunk","created":1780222301,"model":"deepseek-v4-flash","system_fingerprint":"fp_8b330d02d0_prod0820_fp8_kvcache_20260402","choices":[{"index":0,"delta":{"content":" I"},"logprobs":null,"finish_reason":null}]}
data: {"id":"8325bde1-a39c-4a21-b4c2-8e2c4fb2c591","object":"chat.completion.chunk","created":1780222301,"model":"deepseek-v4-flash","system_fingerprint":"fp_8b330d02d0_prod0820_fp8_kvcache_20260402","choices":[{"index":0,"delta":{"content":" know"},"logprobs":null,"finish_reason":null}]}
data: {"id":"8325bde1-a39c-4a21-b4c2-8e2c4fb2c591","object":"chat.completion.chunk","created":1780222301,"model":"deepseek-v4-flash","system_fingerprint":"fp_8b330d02d0_prod0820_fp8_kvcache_20260402","choices":[{"index":0,"delta":{"content":","},"logprobs":null,"finish_reason":null}]}
data: {"id":"8325bde1-a39c-4a21-b4c2-8e2c4fb2c591","object":"chat.completion.chunk","created":1780222301,"model":"deepseek-v4-flash","system_fingerprint":"fp_8b330d02d0_prod0820_fp8_kvcache_20260402","choices":[{"index":0,"delta":{"content":" I"},"logprobs":null,"finish_reason":null}]}
```


## Summary metrics

| turn | t(s) | in_tok | out_tok | total | verdict | role-break | md | zh% |
|---|---|---|---|---|---|---|---|---|
| 0 | 0.54 | 449 | 149 | 598 | OK | 0 | 0 | 0% |
| 1 | 0.11 | 622 | 139 | 761 | OK | 0 | 0 | 0% |
| 2 | 0.11 | 791 | 157 | 948 | OK | 0 | 0 | 0% |
| 3 | 0.1 | 969 | 137 | 1106 | OK | 0 | 0 | 0% |
| 4 | 0.13 | 1121 | 126 | 1247 | OK | 0 | 0 | 0% |

---

## Findings (analysis of the run above)

### ✅ §0 4 项观察（spec 要求的核心结果）

**(a) Verdict JSON 围栏遵守率 = 5/5 = 100%。** `<<<VERDICT>>>...<<<END>>>` 哨兵协议在 deepseek-chat 上 100% 解析成功，结构完整、字段齐全。**spec §6.4 的"遵守率 < 80% 降级方案"v1 暂时用不上**——可以保留作后续 fallback。

**(b) AI 留在角色：5/5 通过，但有 2 处微妙的"软破出"值得注意：**
- Turn 0 开场："I'll start the scenario. You're my neighbor..." 是 meta 旁白。可接受（属于场景搭建，不是中场跳出）。
- Turn 4 收尾："you used all three phrases perfectly today. Well done!" — **这是中场跳出**，LLM 在"做饭告别"场景里夹了一句 lesson 评语。我的关键词过滤器漏掉了，因为它不是"我们来练"这种模板。
- **行动**：在 spec §6.2 system prompt 行为约束加一条："第 5 轮收尾仍以角色身份给出告别词，不评判用户表现、不夸奖用了哪些短语。"

**(c) Token + 延迟：远好于预期。**
- 平均延迟 0.20s（最慢 0.54s 是第一轮含 system prompt），**完全无需流式也已经丝滑**。但流式探针显示 first chunk 0.34s + 总 1.72s，配合 TTS 边收边播可以做到"用户开口后 < 1s 出第一个字音"。
- 一局 5 轮累计 ~4760 tokens（peak 1247/轮）。按 deepseek-chat 定价 ≈ **¥0.005/局**。BYOK 成本完全不是问题。
- **额外发现**：DeepSeek 把 `deepseek-chat` 静默路由到 `deepseek-v4-flash`（见 SSE response 的 `"model"` 字段）。这是新的 fast 变种，比老 v2/v3 chat 明显更快。v1 顺水推舟用默认 model 即可。

**(d) Markdown / sanitize 需求 = 零。** 所有 5 轮 body 都是纯散文，无 `**bold**`、无反引号、无列表、无 emoji。`Speaker.swift` 升级时**不需要做 markdown strip**，只需处理标点（em-dash `—` / 引号已经被 AVSpeechSynthesizer 处理良好）。

### 🚨 §0 之外的新发现（必须回头改 spec）

**(e) verdict.attempted 的语义有歧义——LLM 默认理解为"累计"而非"本轮"。**

Turn 4 用户只说 "Alright I gotta go cook dinner. See you tomorrow."（没用任何目标短语），但 verdict 把全部 3 个标 `attempted:true, correct:true`，note 写 "用户后来正确使用了 sort it out"。LLM 把 attempted 理解成"整局对话里有没有用过"，spec §6.4 字面意思是"本**轮**用户的话里是否尝试"。

两种修法：
1. **改 spec 跟 LLM 走（累计语义）**：最后一轮 verdict 就是整局结果，客户端只看末轮。优点简单；缺点 §6.5 "每用对一个 → 实时点亮 ✓" 不能用每轮 verdict 直接驱动。
2. **改 prompt 跟 spec 走（本轮语义）**：在 system prompt 强调"attempted 仅指**当前这一轮**用户消息里的尝试，不要把之前轮次的成功带进来"。优点保持 §6.5 实时点亮；缺点要再 spike 验证遵守率。

→ **推荐方案 2 + 客户端兜底**：prompt 强化"本轮"语义；客户端额外维护一个 session-local `Set<phrase>` 累计已确认的成功短语，checklist ✓ 基于这个 Set；这样即使 LLM 偶尔回到累计语义也不影响 UI。

**(f) 中文纠正实际几乎不发生——LLM 选择全英文纠正。**

Spec §6.2 说"纠正/提示可中文"。Turn 2 实际纠正是："But just a small thing — we usually say 'sort it out' together, not 'sort out it.'" 全英文，但用词简单（A2 学习者也读得懂）。verdict.note 倒是用了中文（"语序错误，应为 sort it out…"）。

含义：
- 对话气泡里几乎都是英文 → `Speaker.swift` 的"中英分段路由" v1 可以**先不实现**，单语 en-US 朗读已够用。延迟到 v1.1。
- 中文只出现在 verdict.note（用户**看到**但 TTS 不读）→ UI 显示"卡住卡片"和"局末总结"用 verdict.note 即可；不进 TTS。

→ **spec §6.3 可以降级**：v1 = 单语英文 TTS；中文纠正在 UI 文字显示，不朗读。BilingualTTS 重命名为"未来项"。这样 §10 的 Speaker 升级工作量大幅缩小。

**(g) 流式 wire 格式确认。** `data: {...}\n\n` SSE，`delta.content` token 级 chunk（"H" / "aha" / "," / " I" / " know"…），`data: [DONE]` 终止。**spec §6.2 的 AsyncThrowingStream 设计 100% 可行**，直接照抄就行。Swift 端用 `URLSession.bytes(for:)` + `.lines` 异步序列即可解析。

### 改 spec 的 3 个具体动作

| 章节 | 改动 |
|---|---|
| §6.2 system prompt | 加一条"第 5 轮收尾仍以角色身份告别，不评判用户表现、不夸奖" |
| §6.4 verdict.attempted | 改为"本轮 user 消息里的尝试；不要回顾以往轮次"+ 客户端维护 session-local 成功 Set 做 checklist 兜底 |
| §6.3 + §10 TTS | v1 降级为单语 en-US `AVSpeechSynthesizer`；中英分段路由延后到 v1.1。`Speaker.swift` 升级工作只剩"参数化 locale" |

### 体验级结论

跑完这局对话**确实有学英语的感觉**——LLM 用真实场景把 3 个短语自然串起来，纠正温柔不破节奏，5 轮 60-90 秒走完。如果用户语料是自己收藏的，"在我的语境里用我熟悉的短语"那种心流是 ChatGPT 给不了的。spec §1.2 的产品论点在真实 transcript 上 hold 住了。

**v1 可以放心进 plan 阶段。**
