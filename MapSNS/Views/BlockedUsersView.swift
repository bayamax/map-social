import SwiftUI

struct BlockedUsersView: View {
    @ObservedObject private var auth = AuthManager.shared

    var body: some View {
        List {
            if auth.blockedUserIDs.isEmpty {
                Text("ブロック中のユーザーはいません")
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(auth.blockedUserIDs), id: \.self) { uid in
                    HStack {
                        Text("ユーザーID: \(uid)")
                        Spacer()
                        Button("解除", role: .destructive) {
                            auth.unblock(userID: uid)
                        }
                    }
                }
            }
        }
        .navigationTitle("ブロック一覧")
        .onAppear {
            // 最新状態を取得
            if auth.isLoggedIn {
                auth.refreshBlockedList()
            }
        }
    }
}

#Preview {
    NavigationStack {
        BlockedUsersView()
    }
} 