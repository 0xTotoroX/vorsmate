// [INPUT]: Apple Translation 框架（macOS 15+）、SwiftUI 宿主视图与本地翻译协议。
// [OUTPUT]: macOS 系统离线批量翻译协调器（按请求队列调度与精确取消）、隐藏 SwiftUI 宿主与离线预览替身。
// [POS]: VorsmateSystem 与界面层之间的 Apple 系统翻译桥接；在 macOS 14 下安全回退并提示升级或切换接口。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import SwiftUI
import VorsmateSystem

#if canImport(Translation)
    import Translation
#endif

@MainActor
protocol LocalSystemTranslator: AnyObject {
    func translateBatch(_ texts: [String], sourceCode: String, targetCode: String) async throws -> [String]
}

@MainActor
final class AppleSystemTranslationCoordinator: ObservableObject, LocalSystemTranslator {
    private final class PendingJob {
        let id: UUID
        let texts: [String]
        let sourceCode: String
        let targetCode: String
        var claimed = false
        private var continuation: CheckedContinuation<[String], any Error>?

        init(
            id: UUID,
            texts: [String],
            sourceCode: String,
            targetCode: String,
            continuation: CheckedContinuation<[String], any Error>
        ) {
            self.id = id
            self.texts = texts
            self.sourceCode = sourceCode
            self.targetCode = targetCode
            self.continuation = continuation
        }

        func finish(_ result: Result<[String], any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    @Published fileprivate var configBox: Any?
    private var activeJob: PendingJob?
    private var pendingQueue: [PendingJob] = []
    private var cancelledJobIDs: Set<UUID> = []

    func translateBatch(_ texts: [String], sourceCode: String, targetCode: String) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        #if canImport(Translation)
            guard #available(macOS 15.0, *) else {
                throw TranslationServiceError.unsupportedOS
            }

            let sourceLang = Locale.Language(identifier: sourceCode)
            let targetLang = Locale.Language(identifier: targetCode)
            let availability = LanguageAvailability()
            let status = await availability.status(from: sourceLang, to: targetLang)
            if status == .unsupported {
                throw TranslationServiceError.languageUnsupported("\(sourceCode) → \(targetCode)")
            }
            try Task.checkCancellation()

            let jobID = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled || self.cancelledJobIDs.remove(jobID) != nil {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let job = PendingJob(
                        id: jobID,
                        texts: texts,
                        sourceCode: sourceCode,
                        targetCode: targetCode,
                        continuation: continuation)
                    if self.activeJob == nil {
                        self.activeJob = job
                        self.scheduleConfiguration(for: job)
                    } else {
                        self.pendingQueue.append(job)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelJob(id: jobID)
                }
            }
        #else
            throw TranslationServiceError.unsupportedOS
        #endif
    }

    func cancelAll() {
        let active = activeJob
        activeJob = nil
        let queued = pendingQueue
        pendingQueue.removeAll()
        cancelledJobIDs.removeAll()
        configBox = nil
        active?.finish(.failure(CancellationError()))
        for job in queued {
            job.finish(.failure(CancellationError()))
        }
    }

    private func cancelJob(id: UUID) {
        if let active = activeJob, active.id == id {
            activeJob = nil
            active.finish(.failure(CancellationError()))
            startNextQueuedJobIfNeeded()
            return
        }
        if let idx = pendingQueue.firstIndex(where: { $0.id == id }) {
            let removed = pendingQueue.remove(at: idx)
            removed.finish(.failure(CancellationError()))
            return
        }
        cancelledJobIDs.insert(id)
    }

    private func startNextQueuedJobIfNeeded() {
        guard activeJob == nil, !pendingQueue.isEmpty else { return }
        let next = pendingQueue.removeFirst()
        activeJob = next
        #if canImport(Translation)
            if #available(macOS 15.0, *) {
                scheduleConfiguration(for: next)
            }
        #endif
    }

    #if canImport(Translation)
        @available(macOS 15.0, *)
        private func scheduleConfiguration(for job: PendingJob) {
            let sourceLang = Locale.Language(identifier: job.sourceCode)
            let targetLang = Locale.Language(identifier: job.targetCode)
            if var existing = configBox as? TranslationSession.Configuration,
                existing.source == sourceLang,
                existing.target == targetLang
            {
                existing.invalidate()
                configBox = existing
            } else {
                configBox = TranslationSession.Configuration(source: sourceLang, target: targetLang)
            }
        }

        @available(macOS 15.0, *)
        fileprivate var macOS15Config: TranslationSession.Configuration? {
            configBox as? TranslationSession.Configuration
        }

        fileprivate func claimPendingJob() -> (id: UUID, texts: [String])? {
            guard let job = activeJob, !job.claimed else { return nil }
            job.claimed = true
            return (job.id, job.texts)
        }

        fileprivate func finishPendingJob(id: UUID, result: Result<[String], any Error>) {
            guard let job = activeJob, job.id == id else { return }
            activeJob = nil
            job.finish(result)
            startNextQueuedJobIfNeeded()
        }
    #endif
}

struct AppleTranslationHostView: View {
    @ObservedObject var coordinator: AppleSystemTranslationCoordinator

    var body: some View {
        hostContent
            .onDisappear { coordinator.cancelAll() }
    }

    @ViewBuilder
    private var hostContent: some View {
        #if canImport(Translation)
            if #available(macOS 15.0, *) {
                Color.clear
                    .frame(width: 0, height: 0)
                    .translationTask(
                        coordinator.macOS15Config,
                        action: Self.makeAction(coordinator: coordinator))
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        #else
            Color.clear.frame(width: 0, height: 0)
        #endif
    }

    #if canImport(Translation)
        @available(macOS 15.0, *)
        private nonisolated static func makeAction(
            coordinator: AppleSystemTranslationCoordinator
        ) -> @Sendable (TranslationSession) async -> Void {
            { session in
                guard let job = await coordinator.claimPendingJob() else { return }
                do {
                    let requests = job.texts.enumerated().map { index, text in
                        TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
                    }
                    let responses = try await session.translations(from: requests)
                    var byIndex: [Int: String] = [:]
                    for response in responses {
                        if let key = response.clientIdentifier, let idx = Int(key) {
                            byIndex[idx] = response.targetText
                        }
                    }
                    let ordered = job.texts.indices.map { idx in
                        byIndex[idx] ?? responses[safe: idx]?.targetText ?? ""
                    }
                    await coordinator.finishPendingJob(id: job.id, result: .success(ordered))
                } catch let error as TranslationServiceError {
                    await coordinator.finishPendingJob(id: job.id, result: .failure(error))
                } catch is CancellationError {
                    await coordinator.finishPendingJob(id: job.id, result: .failure(CancellationError()))
                } catch {
                    await coordinator.finishPendingJob(
                        id: job.id,
                        result: .failure(TranslationServiceError.networkFailure(error.localizedDescription)))
                }
            }
        }
    #endif
}

@MainActor
final class PreviewSystemTranslator: LocalSystemTranslator {
    func translateBatch(_ texts: [String], sourceCode: String, targetCode: String) async throws -> [String] {
        texts.map { text in
            switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "+ New Conversation": "+ 新对话"
            case "Automations": "自动化"
            case "Customizations": "自定义设置"
            case "Vorsmate supports offline macOS translation.": "Vorsmate 支持 macOS 离线翻译。"
            default:
                targetCode == "en" ? "[EN] \(text)" : "[译] \(text)"
            }
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
