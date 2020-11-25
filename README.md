# Deque

This package provides `Deque`, a random-access collection similar to `Array` but backed by a growable ring buffer and offering efficient insertion and removal at the front and back.

See `Guide.playground` for more information on usage.

## Adding Deque as a dependency

To use `Deque` in a SwiftPM project, add the following line to the dependencies in your `Package.swift` file:

```swift
.package(url: "https://github.com/lilyball/swift-deque", from: "0.0.2"),
```

Because `Deque` is still pre-1.0, source-stability is only guaranteed within minor versions. If you don't want potentially source-breaking package updates, use this dependency specification instead:

```swift
.package(url: "https://github.com/lilyball/swift-deque", .upToNextMinor(from: "0.0.2")),
```

Finally, include `"Deque"` as a dependency for your target:

```swift
let package = Package(
    // name, etc…
    dependencies: [
        .package(url: "https://github.com/lilyball/swift-deque", .upToNextMinor(from: "0.0.2")),
    ],
    targets: [
        .target(name: "<target name>", dependencies: [
            .product(name: "Deque", package: "swift-deque")
        ]),
        // other targets…
    ]
)
```
