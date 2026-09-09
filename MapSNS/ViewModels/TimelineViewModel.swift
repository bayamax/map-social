import Foundation
import Combine
import MapKit

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published private(set) var posts: [Post] = []
    @Published var selectedPost: Post?
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )
    
    private var cancellables = Set<AnyCancellable>()
    
    /// 投稿の表示時間（時間）
    private let displayWindowHours: Double = 72

    var postsWithLocation: [Post] {
        // 位置情報付きかつブロック対象外、表示時間以内
        let now = Date()
        let result = posts.filter { post in
            guard let _ = post.location else { return false }
            if AuthManager.shared.blockedUserIDs.contains(post.user.id) { return false }
            return now.timeIntervalSince(post.createdAt) <= displayWindowHours * 60 * 60
        }
#if DEBUG
        // --- 詳細デバッグログ ---
        print("[TimelineViewModel] postsWithLocation debug --- 全投稿: \(posts.count) 件, location付き: \(posts.filter { $0.location != nil }.count) 件, フィルタ後: \(result.count) 件")
        for p in posts {
            if p.location != nil {
                let blocked = AuthManager.shared.blockedUserIDs.contains(p.user.id)
                let age = now.timeIntervalSince(p.createdAt) / 3600.0
                let include = !blocked && age <= displayWindowHours
                print("  id=\(p.id) user=\(p.user.username) blocked=\(blocked) age(h)=\(String(format: "%.1f", age)) -> include=\(include)")
            }
        }
        print("[TimelineViewModel] --- end debug")
#endif
        return result
    }
    
    func fetchPosts() {
        APIService.shared.fetchTimeline()
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    if let decErr = error as? DecodingError {
                        print("DecodingError: \(decErr)")
                    }
                    print("Failed to fetch timeline: \(error.localizedDescription)")
                }
            }, receiveValue: { [weak self] posts in
                self?.posts = posts
                print("取得件数: \(posts.count)")
                let locCount = posts.filter { $0.location != nil }.count
                print("location 付き件数: \(locCount)")
                // 位置更新は MapTimelineView で現在地に合わせて行うためここではリージョンを変更しない
            })
            .store(in: &cancellables)
    }

    /// - Parameter completion: 失敗理由を呼び出し側に返す。nil なら成功。
    ///   以前は失敗しても黙って閉じていたので「投稿したのに出てこない」状態になっていた。
    func createPost(content: String, location: CLLocation?, imageData: Data? = nil,
                    completion: ((String?) -> Void)? = nil) {
        APIService.shared.createPost(content: content, location: location, imageData: imageData)
            .sink(receiveCompletion: { result in
                if case .failure(let error) = result {
                    print("Post creation failed: \(error.localizedDescription)")
                    let message = (error as? APIService.APIServiceError)?.message ?? error.localizedDescription
                    completion?(message)
                }
            }, receiveValue: { [weak self] post in
                self?.posts.insert(post, at: 0)
                completion?(nil)
            })
            .store(in: &cancellables)
    }

    // 返信作成
    func reply(to parent: Post, content: String) {
        APIService.shared.createPost(content: content, location: nil, parentPostID: parent.id)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    print("Reply failed: \(error.localizedDescription)")
                }
            }, receiveValue: { [weak self] reply in
                // 親投稿直後に挿入
                if let idx = self?.posts.firstIndex(where: { $0.id == parent.id }) {
                    self?.posts.insert(reply, at: idx + 1)
                } else {
                    self?.posts.insert(reply, at: 0)
                }
            })
            .store(in: &cancellables)
    }

    // 投稿通報
    func report(post: Post, reason: String?) {
        APIService.shared.reportPost(postID: post.id, reason: reason)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion {
                    print("Report failed: \(err.localizedDescription)")
                }
            }, receiveValue: { _ in
                print("報告完了")
            })
            .store(in: &cancellables)
    }
} 