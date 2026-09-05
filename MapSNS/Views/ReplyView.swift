import SwiftUI

struct ReplyView: View {
    let parent: Post
    @ObservedObject var viewModel: TimelineViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var isPosting = false

    // ゲスト返信: 書き終えて「送信」を押した時点で初めて登録を促す。
    @ObservedObject private var auth = AuthManager.shared
    @State private var isShowingAuth = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("返信先: \(parent.user.username)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(parent.content)
                    .font(.callout)
                    .lineLimit(2)
                    .padding(6)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)

                TextEditor(text: $content)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

                Spacer()
            }
            .padding()
            .navigationTitle("返信")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("送信") {
                        submit()
                    }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPosting)
                }
            }
            .sheet(isPresented: $isShowingAuth) {
                AuthPromptView(message: "登録すると、いま書いた返信がそのまま送信されます。")
            }
            .onChange(of: auth.isLoggedIn) { loggedIn in
                if loggedIn && isShowingAuth {
                    isShowingAuth = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        submit()
                    }
                }
            }
        }
    }

    private func submit() {
        // ゲストはここで登録へ。content は保持されるので、登録成功後に自動で続行する。
        guard auth.isLoggedIn else {
            isShowingAuth = true
            return
        }
        isPosting = true
        viewModel.reply(to: parent, content: content)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            isPosting = false
            dismiss()
        }
    }
}

#Preview {
    ReplyView(parent: Post(id: 1, user: UserBrief(id: 1, username: "demo", profileImageURL: nil, bio: nil, snsType: nil), content: "Hello", createdAt: Date(), location: nil), viewModel: TimelineViewModel())
} 