/// A screen has exactly one loading outcome at a time.
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
