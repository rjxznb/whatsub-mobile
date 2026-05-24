# iOS 订阅（Phase 3）+ 云端配额翻转 — Design

**Date:** 2026-05-24
**Status:** design — pending user review before plan
**Depends on:** iOS monetization Phase 1（后端 entitlement）+ Phase 2A（Apple verifier）+ Phase 2B（买断墙）已 shipped/deployed。本 Phase 接 `docs/superpowers/plans/2026-05-24-ios-monetization-NEXT-STEPS.md` 的 B 段。

## Problem / Goal

把 **50 个云端视频额度**从「绑桌面 license」改成「绑 iOS 订阅」，给 license 用户做一个 App-Store-合规的订阅购买入口（月 ¥12 / 年 ¥88），让**持续的 OSS 存储成本**对上**持续的订阅收入**（经济学原则：付费模型匹配成本结构——存储是 recurring 成本，所以用 recurring 付费而非一次性买断换无限）。

订阅**只对 license 用户展示**：只有 licensed 桌面端能产出 OSS 视频（桌面 yt-dlp→转码→上传 OSS；iOS 端 in-app import 只抓字幕，从不创建 OSS 对象；iOS 推送路径也得有在线的桌面），所以非 license 用户填不满 OSS，卖给他们存储额度毫无意义。详见 `feedback-monetization-oss-quota` memory。

## Key decisions（brainstorming 已确认）

1. **配额翻转：** `quotaLimit` 从 `hasActiveLicense ? 50 : 3` 改为 `iosSubActive ? 50 : 3`。**license 单独不再给 50**——要 50 必须订阅。内测期无真实付费用户，用户已认可此降级。
2. **`iosSubActive` 本地查（不进 `requireSession`）：** 把 `quotaLimit` 改成 async，在三个拦截 handler（`/sync`、`/quota`、`/import-queue`）里 `getIosEntitlements(email, now)`。理由：改动面最小（语料库/`/me` 路径不多查一次），爆炸半径低；`getIosEntitlements` 是 email 主键查询，便宜。
3. **存量不动（grandfather）：** 拦截只在 push/sync 关口（数现有 `video_key` 数量）。已同步的 >3 个视频不删；订阅前只是不能再加新的。`GET /quota` 对这类用户可能返回 `used:50, limit:3`（无害；内测期基本只有 owner 自己）。
4. **订阅入口 = 被动 + 主动两个：**
   - **被动：** `MeView` 现有「云端同步」卡片（#145）升级成订阅区，仅 `hasActiveLicense == true` 时显示。
   - **主动：** license 用户在 push 路径撞到 `quota_exceeded`（403）时弹 `SubscriptionUpsellSheet`；**订阅成功后自动重试那次 push**。
5. **无优惠（intro offer）：** v1 直上 ¥12/¥88，无首月免费/特价。最简 StoreKit 代码 + 最简 Apple 自动续订披露。日后想加可在 ASC 配 + 补代码。
6. **app 解锁逻辑不动：** `appUnlocked`（`DTOs.swift:32`）已含 `iosSubActive == true`。license 用户本就解锁，订阅只影响配额。无需改门禁。
7. **后端订阅管线已就绪、不动：** `iap.ts` `/verify` 已处理 `kind:'subscription'`（`setSubscription`）；`/notifications` 已处理完整 ASSN 生命周期（`SUBSCRIBED`/`DID_RENEW`/`DID_CHANGE_RENEWAL_STATUS`/`OFFER_REDEEMED`→`extendSubscription`，`EXPIRED`/`REFUND`→`expireSubscription`）；`db.ts` 方法齐全。本 Phase **不碰** iap.ts/db.ts/verifier。

## 商品 ID（App Store Connect 已建）

- 订阅组 **whatSub pro**（ID `22110396`）：`whatsub_pro_month`（¥12）/ `whatsub_pro_year`（¥88）
- 买断（非消耗型，已上线）：`cc.eversay.whatsub.mobile.fullunlock`（¥18）
- App 数字 Apple ID：`6771697837`

## Architecture / components

### A. 后端（whatsub-license）— 唯一改动：配额翻转

文件：`src/routes/library.ts`

- 现状（`library.ts:9-10`）：
  ```ts
  const quotaLimit = (c) => (c.get('hasActiveLicense') ? 50 : 3);
  ```
- 改为按 email 异步查 entitlement：
  ```ts
  async function quotaLimitFor(db, email, now) {
    const ent = await db.getIosEntitlements(email, now);
    return ent.iosSubActive ? 50 : 3;
  }
  ```
- 三处调用点改成 `await quotaLimitFor(db, email, Date.now())`：
  - `POST /sync`（`library.ts:51`，videoKey 且非已有 OSS 视频时的拦截）
  - `GET /quota`（`library.ts:94`，返回 `{used, limit}`）
  - `POST /import-queue`（`library.ts:128`，push 早拦截，`committed = ownerVideoCount + pendingImportCount`）
- `getIosEntitlements(email, now)` 已存在（`db.ts:1981`，返回 `{iosBuyout, iosSubActive, subProductId, trialExpiresAt}`，`iosSubActive = sub_expires_at != null && sub_expires_at > now`）。
- **不改** `requireSession`、`iap.ts`、`db.ts`、`appleVerifier.ts`。

### B. iOS — StoreManager 扩展（`Store/StoreManager.swift`）

- 商品 ID 常量加：
  ```swift
  static let subMonthID = "whatsub_pro_month"
  static let subYearID  = "whatsub_pro_year"
  ```
- `loadProducts()` 改成一次加载三个：`Product.products(for: [buyoutProductID, subMonthID, subYearID])`，按 id 分发到 `@Published var buyoutProduct / subMonth / subYear`。
- 新增 `purchaseSubscription(_ product: Product) async -> Bool`：与 `purchaseBuyout()` 同一套（`product.purchase()` → `process(verification)` → `reportVerifiedJWS`（→ `/iap/verify`，已支持 subscription）→ `transaction.finish()` → refreshMe）。可与 `purchaseBuyout` 抽出共用的 `purchase(_ product:)`。
- `Transaction.updates` 监听 + `restore()` 已覆盖续订/恢复/换机（reports 任意 verified entitlement 给后端）——**无需改**，只要新商品被 StoreKit 认作 currentEntitlement 即自动上报。
- （可选）镜像 `hasLocalBuyout` 加一个 `hasLocalSub`（扫 `Transaction.currentEntitlements` 找未过期的订阅商品），供离线显示；真值仍以后端 `/me` 的 `iosSubActive` 为准。

### C. iOS — 共享购买子视图（新建 `Store/SubscriptionOptionsView.swift`）

抽出被动区和撞墙弹窗都复用的购买 UI：
- 月 / 年两个购买按钮（显示 `product.displayPrice` + 周期），点按 → `store.purchaseSubscription(_:)`，`purchaseInProgress` 时显示 spinner。
- 「恢复购买」按钮 → `store.restore()`。
- **自动续订披露文案**（Apple 必需）："订阅自动续订，可随时在『设置 › Apple ID › 订阅』取消" + 隐私政策 / Apple EULA 链接（复用 `PaywallView` 的 `privacyURL` / `termsURL`）。
- `store.lastError` 显示。
- 接受一个可选 `onPurchased: () -> Void` 回调，供撞墙弹窗在订阅成功后自动重试。

### D. iOS — MeView 订阅区（被动入口，`Me/MeView.swift`）

把现有「云端同步」Section（`MeView.swift:25-34`）按授权状态分支：

- `hasActiveLicense == true` 且 `iosSubActive == true`（已订阅）：
  - 显示 `云端视频 used/limit`（已是 50）+「已订阅 · {套餐}」（套餐由 `currentUser?.subProductId` 映射月/年）+ 系统「管理订阅」入口（用 `.manageSubscriptionsSheet(isPresented:)`——app 是 iOS 16+，原生可用）。
- `hasActiveLicense == true` 且未订阅：
  - 显示 `used/limit`（如 `2/3`）+ 一句"订阅解锁 50 个云端额度" + 内嵌 `SubscriptionOptionsView`（月¥12/年¥88 + 恢复 + 披露）。
- `hasActiveLicense == false`（非 license / 仅买断）：
  - **不变**——保留现有纯文字配额卡（`MeView.swift:30` 那段 + `:36-45` 的"购买授权请前往官网"），不给订阅入口（填不了 OSS）。

刷新：MeView 的 `.task` 已 `refreshMe()` + `libraryQuota`；订阅成功后 `purchaseSubscription` 内的 refreshMe 会更新 `currentUser`，再补一次 `libraryQuota` 刷新 used/limit。

### E. iOS — 撞墙弹窗（主动入口）

触发点：push 路径（`ImportViewModel.pushToDesktop` / `pushURL` → `WhatsubAPI.enqueueImport`，`ImportViewModel.swift:115`）。iOS 的 in-app import sync 是 captions-only（无 `videoKey`），永远不撞配额墙，所以**只有 push 路径需要接线**。

- **`WhatsubAPI.enqueueImport`（`WhatsubAPI.swift:72`）**：让它能区分 `quota_exceeded`(403) 并带出 `used/limit`。当前用 `postExpectingOk` 吞掉了 body —— 改成捕获 403 时解析 `{error, used, limit}`，抛一个可辨识的 `APIError`（新增 case，如 `.quotaExceeded(used: Int, limit: Int)`，`APIError.swift` 现有 `quota_exceeded`→文字映射保留作兜底）。
- **`ImportViewModel`**：`pushToDesktop` catch 到 `.quotaExceeded` 时，置一个新状态 `state = .quotaWall(used, limit)`（而非泛化 `.error`）。
- **`ImportView`（视图层，有 `appState`）**：观察到 `.quotaWall`：
  - `hasActiveLicense == true` → `.sheet` 弹 `SubscriptionUpsellSheet`（内含 `SubscriptionOptionsView`，标题如"升级到 50 个云端额度"）。`onPurchased` 回调里 `await vm.pushToDesktop(token:)` **自动重试**这次推送（订阅生效后配额变 50，重试通过）。
  - `hasActiveLicense == false` → 仍只显示原文字 `云端视频已达上限…`（他们订不了）。

## 精确逻辑

- 配额判定全部服务端 `iosSubActive ? 50 : 3`；客户端只读 `/quota` 显示，不自行判定（客户端可绕过，护的是 OSS）。
- 订阅成功链路：iOS `purchaseSubscription` → StoreKit 验签 → `reportVerifiedJWS`(JWS) → `POST /api/license/iap/verify` → 后端 verifier 验 → `setSubscription(email, expiresDate, productId, txnId)` → 写 `ios_entitlements.sub_expires_at` → `/me` 下次返回 `iosSubActive=true` → 配额查询返回 50。
- 续订/退款/过期由 ASSN webhook（`/api/license/iap/notifications`）维护 `sub_expires_at`，**已实现**。
- 自动重试 push：仅在 `.quotaWall` 且订阅成功后触发一次；若重试仍失败（极端竞态）走普通 error 显示，不无限重试。

## Testing

- **后端（本机可测，pg-mem）：** 更新 `library-quota` 测试——把"license→50 / 无 license→3"改成"`iosSubActive=true`→50 / 否则 3"，覆盖 `/sync`、`/quota`、`/import-queue` 三条；新增"license 但未订阅→3"、"订阅但无 license→（理论上）50（注：实际只对 license 用户展示购买，但后端纯看 iosSubActive）"两个 case。部署前 `pnpm test` + `tsc` 全绿。
- **iOS：** Windows 不能编译 Swift，靠 CI 编译 + TestFlight 沙盒手测：
  - 沙盒 Apple ID 买月/年订阅 → `/me` 转 `iosSubActive=true` → MeView 显示"已订阅"+ 配额 50。
  - license 用户推第 4 个视频 → 撞墙弹窗 → 沙盒订阅 → 自动重试推送成功。
  - 「恢复购买」（重装后）恢复订阅。
  - 「管理订阅」入口能打开系统订阅页。

## Rollout 顺序（重要）

B1（后端翻转）+ iOS **必须一起上**。单独翻后端会把现有 license 用户（含 owner 自己）掉到 3 且无处升级。顺序：
1. 建分支同时做后端 + iOS。
2. 后端 `pnpm test` + typecheck 全绿（本机）。
3. 推 iOS 到 TestFlight（**要 owner 授权**——会烧 Apple cert 槽）。
4. 部署后端翻转到 prod（server `47.93.87.206`，仓库 CLAUDE.md「Build + deploy」runbook；**要 owner 授权**）。
5. 沙盒测一笔订阅 → 配额变 50。
6. 部署后到 owner 沙盒订阅之间，owner 账号卡在上限 3（已同步视频保留）——内测期可接受。

## 合规 / 审核

- 订阅按钮须含价格 + 周期 + 自动续订披露 + 隐私 + EULA（无外部购买链接，anti-steering）。
- 订阅只有 license 用户够得到 → 公开上架时给苹果的审核演示账号本身得是 license 用户才能测订阅（进 NEXT-STEPS 公开上架清单 C 段）。

## Out of scope（YAGNI）

- 优惠/intro offer（首月免费、首月特价）。
- 非 license 用户的订阅入口（他们填不了 OSS）。
- 升/降级套餐（proration）的特殊 UI——交给系统「管理订阅」页。
- 后端 entitlement / verifier / ASSN 任何改动（已就绪）。

## Key file pointers

- 后端配额：`whatsub-license/src/routes/library.ts`（`quotaLimit` 9-10、调用点 51/94/128）+ `src/lib/db.ts`（`getIosEntitlements` 1981）
- iOS Store：`whatsub-mobile/Store/StoreManager.swift` + 新建 `Store/SubscriptionOptionsView.swift`
- iOS MeView：`whatsub-mobile/Me/MeView.swift`（云端同步 Section 25-34）
- iOS 撞墙：`Networking/WhatsubAPI.swift`（enqueueImport 72）+ `Networking/APIError.swift`（quota_exceeded 24）+ `Import/ImportViewModel.swift`（pushToDesktop 115）+ `Import/ImportView.swift`
- 复用范式：`whatsub-mobile/Paywall/PaywallView.swift`（购买按钮 + 恢复 + 隐私/EULA）
- 上游设计：`docs/superpowers/specs/2026-05-24-ios-monetization-design.md`、`docs/superpowers/plans/2026-05-24-ios-monetization-NEXT-STEPS.md`（B 段）
