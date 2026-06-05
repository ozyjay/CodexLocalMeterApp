public actor RefreshScheduler<Value: Sendable> {
    private let refresh: @Sendable () async -> Value
    private var runningTask: Task<Value, Never>?
    private var runningTaskID = 0
    private var queuedTask: Task<Value, Never>?
    private var queuedTaskID = 0
    private var nextTaskID = 0

    public init(refresh: @escaping @Sendable () async -> Value) {
        self.refresh = refresh
    }

    public func requestRefresh() async -> Value {
        if let currentTask = runningTask {
            if let queuedTask {
                return await queuedTask.value
            }
            let previousTask = currentTask
            let refresh = refresh
            let task = Task {
                _ = await previousTask.value
                return await refresh()
            }
            nextTaskID += 1
            let taskID = nextTaskID
            runningTask = task
            runningTaskID = taskID
            queuedTask = task
            queuedTaskID = taskID
            let value = await task.value
            if queuedTaskID == taskID {
                queuedTask = nil
            }
            if runningTaskID == taskID {
                runningTask = nil
            }
            return value
        }

        let refresh = refresh
        let task = Task {
            await refresh()
        }
        nextTaskID += 1
        let taskID = nextTaskID
        runningTask = task
        runningTaskID = taskID
        let value = await task.value
        if runningTaskID == taskID {
            runningTask = nil
        }
        return value
    }
}
