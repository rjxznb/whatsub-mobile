import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryListItem] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var loadedOnce = false

    func load(token: String) async {
        loading = true
        errorMessage = nil
        do {
            entries = try await WhatsubAPI.shared.listLibrary(token: token)
        } catch APIError.unauthorized {
            errorMessage = "登录已过期，请到「我的」重新登录"
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "加载失败，请下拉重试"
        }
        loading = false
        loadedOnce = true
    }
}
