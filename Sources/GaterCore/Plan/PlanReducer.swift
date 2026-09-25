import Foundation

/// Folds events into the plan. Pure and deterministic: replaying the same
/// log always yields the same plan.json, which is what makes the log the
/// single source of truth (spec §4.4).
public enum PlanReducer {
    public static func replay(_ events: [GaterEvent]) -> Plan {
        var plan = Plan()
        for event in events { apply(event, to: &plan) }
        return plan
    }

    /// Applies one event; returns whether the plan changed.
    @discardableResult
    public static func apply(_ event: GaterEvent, to plan: inout Plan) -> Bool {
        let ts = event.ts ?? ""
        switch event.kind {
        case "delegation":
            guard let gater = event.fields["gater"], let type = gater.value(atPath: "type")?.stringValue,
                  let id = gater.value(atPath: "id")?.stringValue else { return false }
            return applyDelegation(type: type, id: id, gater: gater, to: event["to"]?.stringValue,
                                   ts: ts, plan: &plan)

        case "done_note":
            guard let id = event["dish"]?.stringValue else { return false }
            guard let index = plan.dishes.firstIndex(where: { $0.id == id }) else {
                return warn(&plan, "\(ts): GATER-DONE for unknown dish \(id)")
            }
            guard plan.dishes[index].state == .cooking else { return false }
            plan.dishes[index].state = .pass
            plan.dishes[index].updatedAt = ts
            return record(&plan, ts: ts, type: "done", dish: id, summary: "\(id) → pass",
                          reason: event["did"]?.stringValue)

        case "lifecycle":
            guard let id = event["dish"]?.stringValue,
                  let state = event["state"]?.stringValue.flatMap(DishState.init(rawValue:)),
                  let index = plan.dishes.firstIndex(where: { $0.id == id }),
                  plan.dishes[index].state != state else { return false }
            plan.dishes[index].state = state
            plan.dishes[index].updatedAt = ts
            return record(&plan, ts: ts, type: "lifecycle", dish: id, summary: "\(id) → \(state.rawValue)", reason: nil)

        default:
            return false
        }
    }

    private static func applyDelegation(type: String, id: String, gater: JSONValue, to pane: String?,
                                        ts: String, plan: inout Plan) -> Bool {
        let directive = gater.value(atPath: "directive")?.stringValue
        let scope = (gater.value(atPath: "scope")?.arrayValue ?? []).compactMap(\.stringValue)
        let index = plan.dishes.firstIndex { $0.id == id }

        if type == "delegate" {
            guard index == nil else { return warn(&plan, "\(ts): delegate reused existing dish id \(id)") }
            let feature = gater.value(atPath: "feature")?.stringValue ?? "unassigned"
            if !plan.features.contains(feature) { plan.features.append(feature) }
            plan.dishes.append(Dish(id: id, feature: feature, directive: directive ?? "", scope: scope,
                                    pane: pane, state: .cooking, instructions: [], mergedInto: nil,
                                    createdAt: ts, updatedAt: ts))
            return record(&plan, ts: ts, type: type, dish: id,
                          summary: "\(id) delegated (\(feature)) → \(pane ?? "?")", reason: directive)
        }

        guard let i = index else { return warn(&plan, "\(ts): \(type) for unknown dish \(id)") }
        var dish = plan.dishes[i]
        let summary: String

        switch type {
        case "rescope":
            if let directive { dish.directive = directive }
            if !scope.isEmpty { dish.scope = scope }
            summary = "\(id) rescoped"
        case "cancel":
            dish.state = .cancelled
            summary = "\(id) cancelled"
        case "merge":
            guard let targetId = gater.value(atPath: "merge_into")?.stringValue,
                  let t = plan.dishes.firstIndex(where: { $0.id == targetId }), t != i else {
                return warn(&plan, "\(ts): merge of \(id) into a missing dish")
            }
            for path in dish.scope where !plan.dishes[t].scope.contains(path) {
                plan.dishes[t].scope.append(path)
            }
            plan.dishes[t].updatedAt = ts
            dish.state = .merged
            dish.mergedInto = targetId
            summary = "\(id) merged into \(targetId)"
        case "instruct":
            dish.instructions.append(directive ?? "")
            // New instructions for plated work send it back to the stove.
            if dish.state == .pass { dish.state = .cooking }
            summary = "\(id) instructed"
        case "finish":
            dish.state = .finished
            summary = "\(id) finished"
        default:
            return warn(&plan, "\(ts): unknown GATER/1 type \(type)")
        }

        dish.updatedAt = ts
        plan.dishes[i] = dish
        return record(&plan, ts: ts, type: type, dish: id, summary: summary, reason: directive)
    }

    private static func record(_ plan: inout Plan, ts: String, type: String, dish: String,
                               summary: String, reason: String?) -> Bool {
        plan.version += 1
        plan.changes.append(PlanChange(version: plan.version, ts: ts, type: type, dish: dish,
                                       summary: summary, reason: reason))
        return true
    }

    private static func warn(_ plan: inout Plan, _ message: String) -> Bool {
        plan.warnings.append(message)
        return true
    }
}
