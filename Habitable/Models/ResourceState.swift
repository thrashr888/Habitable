//
//  ResourceState.swift
//  Habitable
//
//  Created by Paul Thrasher on 4/28/21.
//

import Collections
import Foundation

enum States: String {
    case NoOp = "noop"
    case Applied = "applied"
    case Applying = "applying"
    case ApplyErrored = "apply failed"
    case Created = "created"
    case Creating = "creating"
    case CreateErrored = "create failed"
    case Deleted = "deleted"
    case Deleting = "deleting"
    case DeleteErrored = "delete failed"
    case Provisioned = "provisioned"
    case Provisioning = "provisioning"
    case ProvisionErrored = "provisioning failed"
    case Refreshed = "refreshed"
    case Replaced = "replaced"
    case Updated = "updated"
    case Updating = "updating"
    case UpdateErrored = "update failed"
}

let actionToState: OrderedDictionary<ChangeActions, States> = [
    ChangeActions.NoOp: States.NoOp,
    ChangeActions.Create: States.Created,
    ChangeActions.Read: States.Refreshed,
    ChangeActions.Update: States.Updated,
    ChangeActions.Replace: States.Replaced,
    ChangeActions.Delete: States.Deleted,
]

let applyStartActionToState: OrderedDictionary<ChangeActions, States> = [
    ChangeActions.Create: States.Creating,
    ChangeActions.Update: States.Updating,
    ChangeActions.Delete: States.Deleting,
]

let applyCompleteActionToState: OrderedDictionary<ChangeActions, States> = [
    ChangeActions.Create: States.Created,
    ChangeActions.Update: States.Updated,
    ChangeActions.Delete: States.Deleted,
]

let applyErroredActionToState: OrderedDictionary<ChangeActions, States> = [
    ChangeActions.Create: States.CreateErrored,
    ChangeActions.Update: States.UpdateErrored,
    ChangeActions.Delete: States.DeleteErrored,
]

struct Provisioner {
    var provisioner: String
    var output: [String] = []
    var state: States
    var done = false
}

struct Stage {
    var id = UUID()
    var state: States
    var identifier: String?
    var elapsed: String?
    var provisioners: [Provisioner] = []
    var done = false
    var errored = false
}

struct StageUpdate {
    var state: States?
    var identifier: String?
    var elapsed: String?
    var provisioners: [Provisioner]?
    var done: Bool?
    var errored: Bool?
}

class ResourceState {
    var id = UUID()
    var address: String
    var resource: Resource
    var action: ChangeActions = .NoOp
    var targetState: States = .NoOp
    var stages: [Stage] = []

    init(_ jsonLog: PlannedChangeSummary) {
        address = jsonLog.address
        resource = jsonLog.resource
        action = jsonLog.action

        if let state = actionToState[jsonLog.action] {
            targetState = state
        }
    }

    func update(_ hook: HookMessage) {
        resource = hook.resource

        switch hook.type {
        case MessageTypes.ApplyStart:
            guard let state = applyStartActionToState[hook.action] else { break }
            stages.append(Stage(
                state: state,
                identifier: identifierFromHook(hook),
                elapsed: "0"
            ))

        case MessageTypes.ApplyProgress:
            updateLatestStage(StageUpdate(
                elapsed: hook.elapsed_seconds
            ))

        case MessageTypes.ApplyComplete:
            var state = States.Applied
            if let found = applyStartActionToState[hook.action] {
                state = found
            }
            updateLatestStage(StageUpdate(
                state: state,
                identifier: identifierFromHook(hook),
                elapsed: hook.elapsed_seconds,
                done: true
            ))

        case MessageTypes.ApplyErrored:
            var state = States.ApplyErrored
            if let found = applyStartActionToState[hook.action] {
                state = found
            }
            updateLatestStage(StageUpdate(
                state: state,
                elapsed: hook.elapsed_seconds,
                done: true,
                errored: true
            ))

        default:
            print("\(hook.type) unsupported")
        }
    }

    private func identifierFromHook(_ hook: HookMessage) -> String? {
        guard let id_key = hook.id_key, let id_value = hook.id_value else { return nil }
        return "\(id_key)=\(id_value)"
    }

    private func updateLatestStage(_ attrs: StageUpdate) {
        guard stages.indices.contains(stages.count - 1) else {
            return
        }
        var stage = stages[stages.count - 1]

        // Special case for identifier: only update if not already present. This
        // ensures that we don't delete the identifier after destroying a resource.
        if stage.identifier == nil, attrs.identifier != nil {
            stage.identifier = attrs.identifier
        }

        if let state = attrs.state {
            stage.state = state
        }
        if let elapsed = attrs.elapsed {
            stage.elapsed = elapsed
        }
        if let done = attrs.done {
            stage.done = done
        }
        if let errored = attrs.errored {
            stage.errored = errored
        }
    }
}
