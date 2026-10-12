#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
import Foundation

/// Lets a user-started download batch continue for a while after the app is
/// backgrounded, using BGContinuedProcessingTask (iOS 26+). The system shows
/// progress in a Live Activity, may cancel the task at any time (the person or
/// resource pressure), and cancels it when the app is swiped away. There is no
/// unlimited background transfer: on expiry the queue is suspended, the partial
/// file is kept, and the transfer resumes (after verification) in the foreground.
@MainActor
public final class BackgroundTransferCoordinator {
	public static var identifierPrefix: String { (Bundle.main.bundleIdentifier ?? "app") + ".transfer" }

	private struct TaskBox: @unchecked Sendable { let task: BGContinuedProcessingTask }

	private weak var queue: TransferQueue?
	private var active: BGContinuedProcessingTask?
	private var monitor: Task<Void, Never>?
	private let logger: FujiLogger
	public private(set) var lastSubmitError: String?

	public init(queue: TransferQueue, logger: FujiLogger = .shared) {
		self.queue = queue
		self.logger = logger
	}

	/// Must be called during app launch (before the first submit).
	public func register() {
		let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: "\(Self.identifierPrefix).*", using: .main) { [weak self] task in
			guard let task = task as? BGContinuedProcessingTask else {
				task.setTaskCompleted(success: false)
				return
			}
			let box = TaskBox(task: task)
			MainActor.assumeIsolated {
				if let self { self.attach(box.task) } else { box.task.setTaskCompleted(success: false) }
			}
		}
		if !ok { logger.warning("background", "后台任务处理器注册失败（检查 Info.plist BGTaskSchedulerPermittedIdentifiers）") }
	}

	/// Submit from the user's tap that starts downloads.
	public func beginIfNeeded(itemCount: Int) {
		guard active == nil else { return }
		let request = BGContinuedProcessingTaskRequest(identifier: "\(Self.identifierPrefix).\(UUID().uuidString)",
													   title: "正在从相机导入",
													   subtitle: "\(itemCount) 个文件")
		request.strategy = .fail
		do {
			try BGTaskScheduler.shared.submit(request)
			lastSubmitError = nil
		} catch {
			// Not fatal: transfers continue while the app is in the foreground.
			lastSubmitError = error.localizedDescription
			logger.info("background", "未能提交后台继续任务：\(error.localizedDescription)")
		}
	}

	private func attach(_ task: BGContinuedProcessingTask) {
		active = task
		let box = TaskBox(task: task)
		task.expirationHandler = { [weak self] in
			Task { @MainActor in
				self?.queue?.suspend(reason: "系统结束了后台传输，回到 App 后会校验并继续")
				self?.finish(box.task, success: false)
			}
		}
		monitor?.cancel()
		monitor = Task { [weak self] in
			while !Task.isCancelled {
				guard let self, let queue = self.queue else { return }
				let (done, total) = queue.aggregateProgress
				// Progress is reported in KiB so the counts fit comfortably in Int64.
				box.task.progress.totalUnitCount = Int64(max(1, total / 1024))
				box.task.progress.completedUnitCount = Int64(done / 1024)
				let remaining = queue.pendingCount
				box.task.updateTitle("正在从相机导入", subtitle: remaining > 0 ? "剩余 \(remaining) 个文件" : "即将完成")
				let waiting = queue.items.contains { $0.state == .waitingForConnection }
				if remaining == 0 || (!queue.isProcessing && waiting) {
					// Done, or the camera connection is gone: no reason to keep running.
					let failed = queue.items.contains { $0.state == .failed || $0.state == .waitingForConnection }
					self.finish(box.task, success: !failed)
					return
				}
				try? await Task.sleep(for: .milliseconds(500))
			}
		}
	}

	private func finish(_ task: BGContinuedProcessingTask, success: Bool) {
		guard active === task else { return }
		monitor?.cancel()
		monitor = nil
		active = nil
		task.setTaskCompleted(success: success)
	}
}
#endif
