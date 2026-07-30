/// A cold, single-pass sequence of translation result batches.
///
/// Each iterator starts an independent operation. An iterator yields at most two elements:
/// cached results followed by fully validated fresh results.
public struct TranslationResults: AsyncSequence, Sendable {
    public typealias Element = [TranslationResult]

    private let operation: TranslationOperation

    init(operation: TranslationOperation) {
        self.operation = operation
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(operation: operation)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private enum State {
            case initial(TranslationOperation)
            case fresh(TranslationOperation, [TranslationOperation.Miss])
            case finished
        }

        private var state: State

        init(operation: TranslationOperation) {
            self.state = .initial(operation)
        }

        public mutating func next() async throws -> [TranslationResult]? {
            let currentState = state
            state = .finished

            switch currentState {
            case .initial(let operation):
                let prepared = try await operation.prepare()
                if !prepared.cachedResults.isEmpty {
                    if !prepared.misses.isEmpty {
                        state = .fresh(operation, prepared.misses)
                    }
                    return prepared.cachedResults
                }
                guard !prepared.misses.isEmpty else { return nil }
                return try await operation.translate(prepared.misses)
            case .fresh(let operation, let misses):
                return try await operation.translate(misses)
            case .finished:
                return nil
            }
        }
    }
}
