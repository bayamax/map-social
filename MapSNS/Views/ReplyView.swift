import SwiftUI

struct ReplyView: View {
    let parent: Post
    @ObservedObject var viewModel: TimelineViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var isPosting = false

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
        }
    }

    private func submit() {
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