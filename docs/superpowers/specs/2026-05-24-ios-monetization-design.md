# iOS 收费模型（买断 + 订阅 + entitlement 后端）— Design

**Date:** 2026-05-24
**Status:** design — pending user review before plan

## Problem / Goal

今天 whatSub 手机端对**纯手机用户**（不用桌面、只在手机上看 YouTube 内嵌 + 双语字幕 + 语料库 + 单词卡）**没有任何收费**。同时云端同步视频是唯一持续花钱的资源（Aliyun OSS+CDN），目前把 50 额度绑在一次性的桌面 license 上，**用一次性付费对冲持续成本**不合理。

本设计引入 iOS 内购，建立三种独立权益，把"手机体验"和"持续存储"分别变现，并把云端额度从"一次性 license"改为"持续订阅"：

1. **手机端体验**：1 天免费试用 → 硬付费墙 → **买断（一次性 IAP ¥18）** 永久解锁 app + 公共语料库。
2. **云端 50 额度**：**订阅（自动续订 IAP，月 ¥12 / 年 ¥88）**，持续收入对冲持续存储成本。
3. **桌面 license**（网站购买，不变）：解锁桌面 + 手机端永久免费无墙 + 公共语料库（跨端）。

## 权益模型（已与用户确认）

| 用户 | 手机端能用？ | 公共语料库 | 云端额度 |
|---|---|---|---|
| 无 license、未买断 | 试用 **1 天** → 之后**硬付费墙**（任何功能不可用） | ❌ | — |
| 无 license、已买断（iOS 一次性 IAP） | ✅ 永久 | ✅ | 3（无桌面填不满，对其无意义） |
| 有 license（网站购买） | ✅ 永久、**不弹墙** | ✅ | 不订阅=3；**订阅后=50** |

判断逻辑（后端为权威，客户端据 `/me` 计算 UI）：
- **appUnlocked** = `hasLicense || iosBuyout || trialActive`（否则硬付费墙）
- **corpusAccess（公共语料库）** = `hasLicense || iosBuyout || trialActive`
- **cloudQuotaLimit** = `iosSubActive ? 50 : 3` （**从 `hasActiveLicense ? 50 : 3` 改过来**）

> 三种权益相互独立。一个 license 用户想要 50 额度仍需单独订阅；一个买断用户没有桌面、填不满云端，所以**订阅入口只对 license 用户展示**（见下）。

## 商品（App Store Connect，已创建）

| 商品 | 类型 | 产品 ID | 价格 |
|---|---|---|---|
| 完整版买断 | 非消耗型 (Non-Consumable) | `cc.eversay.whatsub.mobile.fullunlock` | ¥18 |
| 云端 Pro·月 | 自动续订订阅 | `whatsub_pro_month` | ¥12/月 |
| 云端 Pro·年 | 自动续订订阅 | `whatsub_pro_year` | ¥88/年 |

订阅组：**whatSub pro**（组 ID `22110396`），月/年同组（互相升降级）。

## Apple 合规约束（设计必须满足）

1. **买断 = 非消耗型 + 必带「恢复购买」**：换机/重装要能恢复，Apple 强制要求。
2. **自管 1 天试用**：StoreKit 免费试用机制只给订阅；买断没有，必须自己计时。**计时放后端、按邮箱账号**（防卸载重装绕过；换新邮箱能重置是已接受的小漏洞）。
3. **硬付费墙过审**（用户坚持 1 天全锁）：最大风险是**审核员第 1 天看不到墙→测不到内购→ Guideline 2.1 打回**。缓解：
   - 提审"审核备注"提供一个**试用已过期的演示账号**（后端把该账号 `trial_started_at` 设为很久以前）→ 审核员登录即见墙 → sandbox 测买断。
   - 另留一个**审核专用强制弹墙开关**（隐藏入口/构建标志），代码里预留，便于被拒后快速调。
4. **反引导（Guideline 3.1.3）**：iOS 内只能走 IAP。网站买的 license **只能"登录后反映"**，**app 内不得出现任何"去网站购买"的链接/按钮**（已把 MeView 那条 Link 改纯文字，归入本项；`feat/me-link-text` 随本项一起上）。
5. **订阅元数据**：提审订阅需**隐私政策 URL + EULA**（可用 Apple 标准 EULA 或网站页）。这是 Phase 3 提审前置，不阻塞 build/sandbox。

## 架构 / 组件

### 后端（`whatsub-license`）— entitlement 权威，核心

**DB（schema 迁移）** — 在用户维度（按 `email`，与现有 license 一致）新增：
- `trial_started_at TIMESTAMP NULL` — 首次认证请求时若为 null 则置为 `now()`。
- `ios_buyout_at TIMESTAMP NULL` — 买断成功时间（非 null = 永久买断）。
- `ios_sub_expires_at TIMESTAMP NULL` — 订阅到期时间（`> now()` = 订阅有效）。
- `ios_sub_product_id TEXT NULL` — 当前订阅商品（月/年）。
- `ios_original_transaction_id TEXT NULL` — Apple `originalTransactionId`，用于把 ASSN 通知映射回账号（通知里没有 email）。

**`db.ts` 新方法**（均 pg-mem 可单测）：
- `ensureTrialStarted(email)` — 若 `trial_started_at` 为 null 则置 `now()`，返回该值。
- `getEntitlements(email) -> { hasLicense, iosBuyout, iosSubActive, trialStartedAt, trialExpiresAt }`（`hasLicense` 复用现有 license 查询；`iosSubActive = ios_sub_expires_at > now()`；`trialExpiresAt = trial_started_at + 24h`）。
- `grantBuyout(email, originalTransactionId)`、`setSubscription(email, expiresAt, productId, originalTransactionId)`、`revokeBuyout(originalTransactionId)`、`expireSubscription(originalTransactionId)`（后两个供 ASSN 退款/过期用，按 `ios_original_transaction_id` 定位账号）。

**`routes/iap.ts`（新）**：
- `POST /api/iap/verify`（session）：客户端用 StoreKit 2 拿到密码学已验证的交易后，把 `{ signedTransactionInfo (JWS), productId }` 发来。后端**用 App Store Server API / 校验 JWS 签名（Apple 根证书）确认交易真实**（防伪造），再按 productId 写 entitlement：
  - `fullunlock` → `grantBuyout`
  - `whatsub_pro_month/year` → `setSubscription`（到期时间取交易里的 `expiresDate`）
  - 记录 `ios_original_transaction_id`。
  - 返回最新 entitlement。
- `POST /api/iap/notifications`（**无 session，Apple 调**）：App Store Server Notifications V2。**先验签**（Apple JWS），按 `notificationType` 更新：`DID_RENEW`/`DID_CHANGE_RENEWAL_STATUS`/`SUBSCRIBED`→更新 `ios_sub_expires_at`；`EXPIRED`→`expireSubscription`；`REFUND`（买断退款）→`revokeBuyout`。按 `originalTransactionId` 定位账号。

**`routes/auth.ts` `/me`**：扩展现有 `/me`（session，`refreshMe()` 已在调）的响应，加 `{ iosBuyout, iosSubActive, trialExpiresAt }`（`hasLicense`/`hasActiveLicense` 已有）。`requireSession` 里顺带 `ensureTrialStarted(email)`（首次记起点）。不新增独立 entitlements 端点。

**`routes/library.ts` 额度切换**：`quotaLimit` 从 `c.get('hasActiveLicense') ? 50 : 3` 改为 **`iosSubActive ? 50 : 3`**。⚠️ **此改动会让现有 license 用户从 50 掉到 3**——所以**它是最后一步（Phase 3），与 iOS 订阅一起上线**，避免 license 用户失去 50 却无处可补。`/import-queue` + `/sync` 两处强制逻辑只换 limit 来源，结构不变（见 library-quota spec）。

**公共语料库 gating**：`routes/corpus.ts` 当前的公共语料库 gating（实现者需先核实现状——是否按 `hasActiveLicense` 限制）扩展为 `hasLicense || iosBuyout || trialActive`。个人语料库（mine）不受影响。

### iOS（`whatsub-mobile`）

**`IAP/StoreManager.swift`（新，StoreKit 2，ObservableObject）**：
- `loadProducts()` 按上述 3 个 ID 取 `Product`。
- `purchase(_:)` → `Transaction.verified` → POST `/api/iap/verify` → 刷新 entitlement。
- 监听 `Transaction.updates`（续费/外部变更）→ 同样上报。
- `restorePurchases()` → `AppStore.sync()` → 重新上报 `currentEntitlements`。
- `currentEntitlements` 作为本地兜底，**后端 `/me` 为权威**。

**`AppState` entitlement**：`refreshMe()` 拉 `/me` 的 `{hasLicense, iosBuyout, iosSubActive, trialExpiresAt}` 存入；计算 `appUnlocked`、`subShouldOffer = hasLicense`。

**`Paywall/PaywallView.swift`（新，全屏阻断）**：当 `!appUnlocked` 时由根视图覆盖呈现，不可划走。内容：whatSub 手写体头 + 卖点（永久解锁全部功能 + 公共语料库）+ **¥18 买断按钮** + **「恢复购买」** + 必要的条款/隐私链接（系统/网页静态页，非购买链接）。**无任何"去网站购买 license"链接**。
- **审核强制弹墙**：`#if DEBUG` 或一个隐藏手势/构建标志强制显示，配合审核备注的预过期演示账号。

**根视图门禁**：登录后 `refreshMe()` → 若 `!appUnlocked` → 盖 `PaywallView`；`appUnlocked` 则正常进三 tab。试用期内（`trialActive`）正常用。

**订阅 UI（仅 license 用户）**：复用 MeView 的「云端同步」卡——`hasLicense` 时显示 `used/limit` + **「升级到 50（订阅）」** → 月 ¥12 / 年 ¥88 选择 + 购买 + 恢复 + 系统「管理订阅」入口。非 license（买断/免费）用户**不展示订阅入口**（他们填不满 50）。
- 现有 `quota` 卡（#145）演化为此卡；纯文字升级说明保留给非 license 用户。

**`feat/me-link-text`**：把 MeView 旧的"去网站购买授权" Link 改纯文字——**并入本项一起 push**。

**错误/边界**：`/api/iap/verify` 失败 → 提示重试，不发放权益（后端权威）；离线 → 用 `currentEntitlements` 本地兜底放行已购用户，但额度仍以后端为准。

### 数据流（买断为例）

```
用户点买断 → StoreKit2 purchase → Transaction.verified(JWS)
  → POST /api/iap/verify {JWS, productId=fullunlock}
  → 后端验签(App Store Server API/Apple根证书) → grantBuyout(email, origTxnId)
  → 返回 {iosBuyout:true} → app 撤下 PaywallView
（退款时 Apple → POST /api/iap/notifications REFUND → revokeBuyout → 下次 /me 变回未解锁 → 墙重现）
```

## Edge cases
- **买断退款**：ASSN `REFUND` → 撤销买断 → 试用已过 → 墙重现（拿回钱就收回权益）。
- **订阅过期**：`ios_sub_expires_at < now()` → 额度回 3；**已同步视频不删**（沿用 library-quota 的 grandfather）。
- **license + 订阅 同时有**：license 解锁 app，订阅给 50，互不冲突。
- **试用期内额度**：试用给 app 访问，但 50 是订阅专属 → 试用期 `cloudQuotaLimit=3`（试用用户无桌面也填不满）。
- **新邮箱重置试用**：已接受的小漏洞，v1 不防。
- **订阅升/降级（月↔年）**：同组自动处理；ASSN 更新到期时间。
- **后端验签失败/Apple 不可达**：`/verify` 返回错误，app 提示重试；不放发权益。

## 测试
- **后端（pg-mem 单测）**：`ensureTrialStarted` 幂等；`getEntitlements` 各组合（试用中/过期、买断、订阅有效/过期、license）；`/iap/verify` 写买断/订阅；ASSN `EXPIRED`/`REFUND` 按 origTxnId 撤权；额度 `iosSubActive?50:3`；`/import-queue`+`/sync` 用新 limit。验签逻辑用 mock。
- **iOS（sandbox，TestFlight 真机）**：买断购买 + 恢复；订阅购买 + 续费（ASSN）+ 取消到期；墙在试用过期后出现、买断后消失；订阅入口只对 license 显示；强制弹墙开关。
- **审核**：备注给预过期演示账号 + sandbox 步骤。

## 时序 / Phasing（注册已完成，无外部前置阻塞 build）

- **Phase 1 — 后端 entitlement 地基**：DB 迁移 + `db.ts` 方法 + `/api/iap/verify` + `/api/iap/notifications`（ASSN）+ `/me` 扩展 + `ensureTrialStarted`。**不动额度逻辑**（仍 `hasActiveLicense?50:3`）。可独立部署 + 单测。
- **Phase 2 — iOS 买断 + 试用门 + 硬墙**：StoreManager + PaywallView + 根视图门禁 + 恢复购买 + 审核开关 + 并入 `feat/me-link-text`。依赖 Phase 1 的 `/me` + `/verify`。
- **Phase 3 — iOS 订阅 + 额度切换**：MeView 订阅 UI（仅 license）+ 月/年购买；**同时**把后端额度切到 `iosSubActive?50:3`。提审订阅前需隐私政策 + EULA URL。

部署生产 + 每次 iOS push（TestFlight，烧 Apple cert 槽）需用户授权。

## Out of scope（deferred）
- 安卓 / 网页端订阅。
- 家庭共享、促销码、推荐试用。
- 退款防滥用之外的反作弊（多邮箱刷试用）。
- 服务端收据的历史对账报表。
- EU DSA 交易者身份（仅当分发欧盟区时；当前可排除欧盟）。
