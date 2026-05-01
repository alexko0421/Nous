import Foundation
import Observation

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
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            snapshot = try service.loadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
