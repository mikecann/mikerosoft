import Foundation
import TandemCore

/// Builds the inspector's edit batches. Each control commits one
/// `updateClip`, `updateEffect` or `updateMedia` batch when it's released.
enum InspectorEdits {
    static func video(_ clipID: String, _ fields: [String: JSONValue], label: String) -> EditBatch {
        EditBatch(label: label, commands: [.updateClip(clipID: clipID, patch: .object(["video": .object(fields)]))])
    }

    static func audio(_ clipIDs: [String], _ fields: [String: JSONValue], label: String) -> EditBatch? {
        guard !clipIDs.isEmpty else { return nil }
        return EditBatch(label: label, commands: clipIDs.map { .updateClip(clipID: $0, patch: .object(["audio": .object(fields)])) })
    }

    /// Transform fields as a patch. Changing the transform by hand clears
    /// the layout preset name, since it no longer describes the clip.
    static func transform(_ clipID: String, _ transform: Transform, label: String) -> EditBatch {
        video(clipID, [
            "transform": .object([
                "scale": .number(transform.scale),
                "rotation": .number(transform.rotation),
                "position": .object(["x": .number(transform.position.x), "y": .number(transform.position.y)])
            ]),
            "layoutPreset": .null
        ], label: label)
    }

    static func crop(_ clipID: String, _ crop: Crop) -> EditBatch {
        video(clipID, ["crop": .object([
            "left": .number(crop.left), "top": .number(crop.top), "right": .number(crop.right), "bottom": .number(crop.bottom)
        ])], label: "Crop")
    }

    static func effectParam(_ clipID: String, effectID: String, key: String, value: ParamValue, label: String) -> EditBatch {
        EditBatch(label: label, commands: [.updateEffect(clipID: clipID, effectID: effectID, patch: .object(["params": .object([key: value.json])]))])
    }

    static func effectEnabled(_ clipID: String, effectID: String, enabled: Bool, name: String) -> EditBatch {
        EditBatch(label: enabled ? "Turn on \(name.lowercased())" : "Turn off \(name.lowercased())", commands: [
            .updateEffect(clipID: clipID, effectID: effectID, patch: .object(["enabled": .bool(enabled)]))
        ])
    }

    /// Sets the drop shadow's opacity, adding Filmora's default shadow if
    /// the clip has none.
    static func shadowOpacity(_ clip: Clip, percent: Double, newID: String = IDs.make("fx")) -> EditBatch {
        if let shadow = clip.video?.effects.first(where: { $0.type == "dropShadow" }) {
            return effectParam(clip.id, effectID: shadow.id, key: "opacity", value: .number(percent), label: "Shadow")
        }
        var effect = LayoutPreset.pipShadow(id: newID)
        effect.params["opacity"] = .number(percent)
        return EditBatch(label: "Add shadow", commands: [.addEffect(clipID: clip.id, effect: effect)])
    }

    /// Replaces a file's look (the grade every clip of it gets).
    static func look(_ mediaID: String, _ effects: [Effect], label: String) -> EditBatch? {
        guard let value = try? JSONValue.from(effects) else { return nil }
        return EditBatch(label: label, commands: [.updateMedia(mediaID: mediaID, patch: .object(["look": value]))])
    }

    /// The same look with one parameter changed.
    static func lookParam(_ item: MediaItem, effectID: String, key: String, value: ParamValue, label: String) -> EditBatch? {
        var effects = item.look
        guard let index = effects.firstIndex(where: { $0.id == effectID }) else { return nil }
        effects[index].params[key] = value
        return look(item.id, effects, label: label)
    }
}

extension ParamValue {
    /// The JSON a merge patch needs for this value.
    var json: JSONValue {
        switch self {
        case .number(let v): return .number(v)
        case .bool(let v): return .bool(v)
        case .string(let v): return .string(v)
        case .point(let p): return .object(["x": .number(p.x), "y": .number(p.y)])
        case .color(let c): return .object(["r": .number(c.r), "g": .number(c.g), "b": .number(c.b), "a": .number(c.a)])
        }
    }
}
