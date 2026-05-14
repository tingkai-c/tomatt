import SwiftState

typealias TBStateMachine = StateMachine<TBStateMachineStates, TBStateMachineEvents>

enum TBStateMachineEvents: EventType {
    case startStop, timerFired, skipEvent, pauseResume
    case restoreWork, restoreRest, restoreWorkPaused, restoreRestPaused
}

enum TBStateMachineStates: StateType, Codable {
    case idle, work, rest, workPaused, restPaused
}
