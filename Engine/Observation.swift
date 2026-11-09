#if !canImport(Combine)
protocol ObservableObject: AnyObject {}

struct ObservableObjectPublisher {
    func send() {}
}

@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}
#endif
