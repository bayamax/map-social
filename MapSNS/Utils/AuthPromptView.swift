import SwiftUI

/// 書き込み操作の直前に出す登録プロンプト。
///
/// 設計意図: ゲストは「投稿ボタンを押した瞬間」ではなく「送信しようとした瞬間」に
/// ここへ来る。呼び出し側は入力内容を保持したままこれを出し、ログイン成功後に
/// 元の操作を自動で続行する（書いたものを捨てさせない）。
struct AuthPromptView: View {
    /// その操作を終えると何が起きるかを一言で伝える文言。
    /// String だと Text が辞書を引かないので LocalizedStringKey で受ける。
    let message: LocalizedStringKey

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthManager.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.green)
                Text("あと少しで書き込めます")
                    .font(.title3)
                    .fontWeight(.bold)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.horizontal, 28)
            .padding(.bottom, 4)

            LoginView(showsTitle: false)
        }
        .onChange(of: auth.isLoggedIn) { loggedIn in
            // ログイン/新規登録が成功したら閉じる。続きの処理は呼び出し側が再開する。
            if loggedIn { dismiss() }
        }
    }
}
