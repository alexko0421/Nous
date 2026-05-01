import Foundation
import Observation

@MainActor
@Observable
final class BeadsAgentWorkViewModel {
    var snapshot: BeadsAgentWorkSnapshot = .empty
    var isLoading = false
    var errorMessage: String?
    var hasLoaded = false

    private let service: BeadsAgentWorkService

    init(service: BeadsAgentWorkService = BeadsAgentWorkService()) {
        self.service = service
    }

    func refresh() {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        let service = service
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try service.loadSnapshot() }

            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }

                self.finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        isLoading = false
        hasLoaded = true
    }
}
