import Foundation

/// 同時に1つだけ動く非同期の処理。やり直すときは前のものを止め、止まり切ってから次を始める。
/// 止めても `await` の後ろの処理は最後まで走るので、待たずに次を始めると同じ状態を2つが書き換える（PR #10 のクラッシュ）
final class SerialTask {
    private var task: Task<Void, Never>?

    var hasStarted: Bool { task != nil }

    func restart(_ body: @escaping @MainActor () async -> Void) {
        let previous = task
        previous?.cancel()
        task = Task {
            await previous?.value
            await body()
        }
    }

    /// いまの処理が終わるまで待つ
    func wait() async { await task?.value }
}
