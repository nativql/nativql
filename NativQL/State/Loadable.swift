/// Lightweight async-result wrapper used by view models.
enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case error(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}
