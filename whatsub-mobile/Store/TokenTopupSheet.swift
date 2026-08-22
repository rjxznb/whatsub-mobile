import SwiftUI
import StoreKit

struct TokenTopupSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tokenTopups: TokenTopupStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let wallet = tokenTopups.wallet {
                    Section("当前额度") {
                        LabeledContent("本月已用", value: "\(short(wallet.monthlyUsed))/\(short(wallet.monthlyLimit))")
                        LabeledContent("充值余额", value: "\(short(wallet.topupBalance)) tokens")
                        if wallet.topupFrozen {
                            Text("充值余额已冻结。恢复 Pro 后会自动继续可用。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if appState.effectiveLlmEntitlements?.tokenTopups == true {
                    Section("购买 Token 加量包") {
                        if tokenTopups.catalog.isEmpty {
                            Text("加量包暂未开放")
                                .foregroundStyle(.secondary)
                        } else if tokenTopups.products.isEmpty {
                            Text("商品正在加载，请稍后重试")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(tokenTopups.products, id: \.id) { product in
                                Button {
                                    Task { _ = await tokenTopups.purchase(product: product) }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(label(for: product.id))
                                                .foregroundStyle(.primary)
                                            Text("\(short(tokens(for: product.id))) tokens")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(product.displayPrice)
                                            .fontWeight(.semibold)
                                    }
                                }
                                .disabled(tokenTopups.purchaseInProgress)
                            }
                        }
                    }
                }

                if !tokenTopups.history.isEmpty {
                    Section("最近充值") {
                        ForEach(tokenTopups.history.prefix(50)) { transaction in
                            HStack {
                                Text(label(for: transaction.productId ?? ""))
                                Spacer()
                                Text("+\(short(transaction.tokenDelta))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let error = tokenTopups.lastError {
                    Section { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Token 加量包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .task {
            if let token = appState.session?.sessionToken {
                tokenTopups.installWallet(try? await WhatsubAPI.shared.tokenWallet(token: token))
            }
        }
    }

    private func tokens(for id: String) -> Int {
        tokenTopups.catalog.first(where: { $0.id == id })?.tokens ?? 0
    }

    private func label(for id: String) -> String {
        switch id {
        case "whatsub_token_1m": return "小额加量包"
        case "whatsub_token_5m": return "标准加量包"
        case "whatsub_token_15m": return "重度加量包"
        default: return "Token 加量包"
        }
    }

    private func short(_ value: Int) -> String {
        if value >= 1_000_000 { return "\(value / 1_000_000)M" }
        if value >= 1_000 { return "\(value / 1_000)K" }
        return "\(value)"
    }
}
