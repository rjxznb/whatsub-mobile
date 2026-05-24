# 新会话启动 prompt（whatSub）

> 复制下面整段，粘进新会话（在 `C:\Users\renjx\Desktop\whatsub-mobile` 启动，本仓 CLAUDE.md + memory 会自动加载）。

---

我在继续开发 whatSub —— 一个英语学习产品生态。动手前先读上下文。

【产品整体】whatSub 把 YouTube/B站 等视频处理成英语学习材料（双语字幕 + 语料库短语 + 单词卡）。
生态 = 桌面端"生产"数据、iOS/插件"消费"、后端"服务"、官网"营销"。5 个仓：

| 仓 | 本地路径 | 角色 |
|---|---|---|
| whatsub-mobile  | C:\Users\renjx\Desktop\whatsub-mobile  | iOS 消费端 (SwiftUI, iOS16+)，**当前主要工作** |
| whatsub-license | C:\Users\renjx\Desktop\whatsub-license | 后端 (Hono+Postgres，部署在阿里云 47.93.87.206) |
| Get_Video       | C:\Users\renjx\Desktop\Get_Video       | 桌面端 (Tauri；client/=React，src-tauri/=Rust；生产 library 数据) |
| whatsub-website | C:\Users\renjx\Desktop\whatsub-website | 官网 (Next.js 静态站 whatsub.eversay.cc，含隐私/条款页) |
| whatsub-plugin  | C:\Users\renjx\Desktop\whatsub-plugin  | 浏览器插件 (Chrome/Edge，贡献语料) |

【开始前请读】
1. 本仓 CLAUDE.md + 我的 memory（都会自动加载；重点看 memory 里的 project_roadmap、feedback_monetization_oss_quota）。
2. 其他端的项目文档（手动读）：
   - C:\Users\renjx\Desktop\whatsub-license\CLAUDE.md   （后端 + 部署 runbook + /api/iap/* IAP）
   - C:\Users\renjx\Desktop\Get_Video\CLAUDE.md         （桌面端整体；React 端细节看 Get_Video\client\CLAUDE.md）
   - C:\Users\renjx\Desktop\whatsub-website\CLAUDE.md   （官网 + 部署）
   - C:\Users\renjx\Desktop\whatsub-plugin\CLAUDE.md    （插件）
3. 当前进度 + 后续计划入口：
   C:\Users\renjx\Desktop\whatsub-mobile\docs\superpowers\plans\2026-05-24-ios-monetization-NEXT-STEPS.md

【当前状态 2026-05-24】iOS 收费已落地：1天试用→硬付费墙→¥18 一次性买断(StoreKit2)，
已实现+部署+推 TestFlight #147；后端 entitlement + Apple verifier 已上 prod (env=Sandbox)；隐私页已发布。
接下来：① 我去 App Store Connect 设沙盒 webhook + 沙盒真机测；
② Phase 3（iOS 订阅 ¥12月/¥88年 UI，仅 license 用户 + 后端额度切 iosSubActive?50:3，未做，要先写 plan）；
③ 公开上架（后端 env→Production + 审核预过期演示账号）。

【工作约定】
- 用 superpowers 流程：brainstorming → writing-plans → subagent-driven-development。
- 后端可本机 pnpm test/typecheck；iOS 在 Windows 不能编译 Swift，靠 CI/TestFlight 验证。
- 部署 prod / 推 TestFlight 前先问我授权（仓库 CLAUDE.md 里有 SSH+构建+部署 runbook，本机有 Docker + ~/.ssh/id_ed25519，你可以照着做）。
- 永远不要打印/泄露任何密钥、.env、.p8、token。
- 推 TestFlight 会烧 Apple cert 槽；后端 main 是部署源。

读完先给我一句话：当前状态总结 + 你建议的下一步，等我确认再动手。
