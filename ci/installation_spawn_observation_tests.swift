// Compiled with the exact app helper and its imported plain C wire struct.
// Fixtures supply only observation values; no command or IPC is executed.
enum ObservationTestFailure: Error {
    case assertion(String)
}

func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw ObservationTestFailure.assertion(reason) }
}

final class ObservationThreadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func set(_ value: String) {
        lock.lock()
        text = value
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

let arguments = CommandLine.arguments
try require(arguments.count == 3, "Expected case and mock library path")
let mode = arguments[1]
var mockHandle: UnsafeMutableRawPointer?
if mode != "missing-api" {
    mockHandle = dlopen(arguments[2], RTLD_NOW | RTLD_GLOBAL)
    try require(mockHandle != nil, "Could not load ordinary observation mock")
}

try require(MemoryLayout<jbclient_persona_diagnostic_v1>.size == 56, "C struct size differs")
try require(MemoryLayout<jbclient_persona_diagnostic_v1>.alignment == 8, "C struct alignment differs")
errno = EBUSY
let observation = InstallationSpawnObservation()
try require(errno == EBUSY, "Symbol resolution changed errno")
var cases: [[String: Any]] = []
if mode == "missing-api" || mode == "missing-clear" || mode == "missing-copy" {
    errno = EBUSY
    observation.clearBeforeSpawn()
    try require(errno == EBUSY, "Missing API clear changed errno")
    let text = observation.copyFailureDescription()
    try require(errno == EBUSY, "Missing API diagnostic formatting changed errno")
    try require(text.contains("unavailable (optional observation API missing)"), "Missing API was interpreted as a failure stage")
    try require(!text.contains("entitlement"), "Missing API guessed a privilege failure")
    cases.append(["case": mode, "description": text])
} else {
    typealias Configure = @convention(c) (Int32) -> Void
    guard let symbol = dlsym(mockHandle, "sileo_test_diagnostic_fixture") else {
        throw ObservationTestFailure.assertion("Missing mock setter")
    }
    let configure = unsafeBitCast(symbol, to: Configure.self)
    let expected: [Int32: [String]] = [
        0: ["no observation recorded"],
        1: ["stage=reply-result", "original_result=-1", "server_stage=entitlement-denied"],
        2: ["stage=ipc-returned-error", "ipc_status=5", "original_result=unavailable", "server_stage=unavailable"],
        3: ["stage=pipe-unavailable", "ipc_status_valid=0", "ipc_status=unavailable"],
        4: ["stage=reply-missing"],
        5: ["stage=reply-type-invalid"],
        6: ["stage=result-invalid", "original_result=unavailable"],
        7: ["server_stage=unsupported"],
        8: ["unsupported observation ABI"],
        9: ["unsupported observation ABI"],
        10: ["unsupported observation flags"],
        11: ["unavailable (observation copy failed)"],
        12: ["server_stage=unknown"],
        13: ["server_stage_valid=0", "server_stage=unavailable"],
        14: ["original_result=9223372036854775807"],
        15: ["original_result=-9223372036854775808"],
        16: ["stage=ipc-not-called", "ipc_status_valid=0", "ipc_status=unavailable"],
        17: ["unavailable (observation copy failed)"],
        18: ["no observation recorded"],
        19: ["server_stage=child-not-found"],
        20: ["server_stage=child-path-failed"],
        21: ["server_stage=existing-helper-failed"],
        22: ["server_stage=completed"]
    ]
    for kind in expected.keys.sorted() {
        errno = EBUSY
        observation.clearBeforeSpawn()
        try require(errno == EBUSY, "Clear changed errno in case \(kind)")
        configure(kind)
        errno = EBUSY
        let text = observation.copyFailureDescription()
        try require(errno == EBUSY, "Observation copy or formatting changed errno in case \(kind)")
        for token in expected[kind]! {
            try require(text.contains(token), "Case \(kind) missing \(token): \(text)")
        }
        if kind == 2 || kind == 3 || kind == 13 || kind == 18 {
            try require(!text.contains("entitlement-denied"), "Unobserved stage interpreted as entitlement denial")
        }
        try require(!text.contains("pid") && !text.contains("/var/") && !text.contains("uid="), "Observation printed process or credential details")
        cases.append(["case": Int(kind), "description": text])
    }

    configure(1)
    observation.clearBeforeSpawn()
    try require(observation.copyFailureDescription().contains("no observation recorded"), "Clear left a stale request")
    configure(1)
    let semaphore = DispatchSemaphore(value: 0)
    let otherThreadResult = ObservationThreadResult()
    let thread = Thread {
        let other = InstallationSpawnObservation()
        let text = other.copyFailureDescription()
        otherThreadResult.set(text)
        semaphore.signal()
    }
    thread.start()
    try require(semaphore.wait(timeout: .now() + 5) == .success, "Thread-local mock did not finish")
    let isolatedText = otherThreadResult.get()
    try require(isolatedText.contains("no observation recorded"), "Observation leaked across threads")
    try require(observation.copyFailureDescription().contains("original_result=-1"), "Other thread disturbed original request")
    cases.append(["case": "clear and thread isolation", "status": "passed"])
}

let data = try JSONSerialization.data(withJSONObject: ["status": "passed", "mode": mode, "cases": cases], options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
