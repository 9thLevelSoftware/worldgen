//! Godot `JSON.parse` emits floats for every number. Coerce integer DTO fields
//! only when the float is finite with a zero fractional part.

use derelict_core::authoring::GoldenArea;
use serde_json::{json, Map, Value};

pub fn golden_from_json(value: &Value) -> Result<GoldenArea, String> {
    serde_json::from_value(value.clone()).map_err(|e| format!("golden DTO: {e}"))
}

/// Mutates `value` in place: integer fields become JSON integers, optional
/// keys receive struct defaults, deck/rotation ranges are checked.
pub fn coerce_golden_value(value: &mut Value) -> Result<(), String> {
    let obj = value
        .as_object_mut()
        .ok_or_else(|| "golden document must be an object".to_string())?;
    apply_top_defaults(obj);

    if let Some(topo) = obj.get_mut("topology") {
        coerce_topology(topo)?;
    }
    if let Some(props) = obj.get_mut("props") {
        coerce_props(props)?;
    }
    if let Some(vars) = obj.get_mut("room_vars") {
        coerce_room_vars(vars)?;
    }
    if let Some(hazards) = obj.get_mut("hazards") {
        coerce_hazards(hazards)?;
    }
    if let Some(stamp) = obj.get_mut("stamp") {
        if !stamp.is_null() {
            coerce_stamp(stamp)?;
        }
    }
    Ok(())
}

fn apply_top_defaults(obj: &mut Map<String, Value>) {
    fill(
        obj,
        "module_overrides",
        json!({"floors":{},"ceilings":{},"edges":{}}),
    );
    if let Some(Value::Object(ov)) = obj.get_mut("module_overrides") {
        fill(ov, "floors", json!({}));
        fill(ov, "ceilings", json!({}));
        fill(ov, "edges", json!({}));
    }
    fill(obj, "props", json!([]));
    fill(obj, "room_vars", json!({}));
    fill(
        obj,
        "hazards",
        json!({
            "source": "authored",
            "fire_zones": [],
            "breach_zones": [],
            "arc_zones": [],
            "radiation_zones": [],
        }),
    );
    if let Some(Value::Object(h)) = obj.get_mut("hazards") {
        fill(h, "source", json!("authored"));
        fill(h, "fire_zones", json!([]));
        fill(h, "breach_zones", json!([]));
        fill(h, "arc_zones", json!([]));
        fill(h, "radiation_zones", json!([]));
    }
    if let Some(Value::Object(topo)) = obj.get_mut("topology") {
        fill(topo, "rooms", json!([]));
        fill(topo, "portals", json!([]));
        fill(topo, "verticals", json!([]));
    }
}

fn fill(obj: &mut Map<String, Value>, key: &str, default: Value) {
    if !obj.contains_key(key) || obj.get(key).is_some_and(Value::is_null) {
        obj.insert(key.to_string(), default);
    }
}

fn coerce_topology(topo: &mut Value) -> Result<(), String> {
    let obj = topo
        .as_object_mut()
        .ok_or_else(|| "topology must be an object".to_string())?;
    if let Some(rooms) = obj.get_mut("rooms") {
        let arr = expect_array(rooms, "topology.rooms")?;
        for (i, room) in arr.iter_mut().enumerate() {
            coerce_room(room, i)?;
        }
    }
    if let Some(portals) = obj.get_mut("portals") {
        coerce_endpoints(portals, "topology.portals")?;
    }
    if let Some(verticals) = obj.get_mut("verticals") {
        coerce_endpoints(verticals, "topology.verticals")?;
    }
    Ok(())
}

fn coerce_room(room: &mut Value, i: usize) -> Result<(), String> {
    let obj = room
        .as_object_mut()
        .ok_or_else(|| format!("topology.rooms[{i}] must be an object"))?;
    if let Some(v) = obj.get_mut("id") {
        coerce_u16(v, &format!("topology.rooms[{i}].id"))?;
    }
    if let Some(v) = obj.get_mut("deck") {
        coerce_deck(v, &format!("topology.rooms[{i}].deck"))?;
    }
    if let Some(cells) = obj.get_mut("cells") {
        let arr = expect_array(cells, &format!("topology.rooms[{i}].cells"))?;
        for (j, cell) in arr.iter_mut().enumerate() {
            coerce_cell2(cell, &format!("topology.rooms[{i}].cells[{j}]"))?;
        }
    }
    Ok(())
}

fn coerce_endpoints(list: &mut Value, path: &str) -> Result<(), String> {
    let arr = expect_array(list, path)?;
    for (i, item) in arr.iter_mut().enumerate() {
        let obj = item
            .as_object_mut()
            .ok_or_else(|| format!("{path}[{i}] must be an object"))?;
        if let Some(v) = obj.get_mut("from_room") {
            coerce_u16(v, &format!("{path}[{i}].from_room"))?;
        }
        if let Some(v) = obj.get_mut("to_room") {
            coerce_u16(v, &format!("{path}[{i}].to_room"))?;
        }
        if let Some(v) = obj.get_mut("from_cell") {
            coerce_cell3(v, &format!("{path}[{i}].from_cell"))?;
        }
        if let Some(v) = obj.get_mut("to_cell") {
            coerce_cell3(v, &format!("{path}[{i}].to_cell"))?;
        }
    }
    Ok(())
}

fn coerce_props(props: &mut Value) -> Result<(), String> {
    let arr = expect_array(props, "props")?;
    for (i, prop) in arr.iter_mut().enumerate() {
        let obj = prop
            .as_object_mut()
            .ok_or_else(|| format!("props[{i}] must be an object"))?;
        fill(obj, "inventory", json!([]));
        fill(obj, "inventory_mode", json!("empty"));
        fill(obj, "locked", json!(false));
        fill(obj, "visual_id", json!(""));
        fill(obj, "facing", Value::Null);
        fill(obj, "loot_table", Value::Null);
        if let Some(v) = obj.get_mut("id") {
            coerce_u32(v, &format!("props[{i}].id"))?;
        }
        if let Some(v) = obj.get_mut("rotation") {
            coerce_rotation(v, &format!("props[{i}].rotation"))?;
        }
        if let Some(v) = obj.get_mut("cell") {
            coerce_cell3(v, &format!("props[{i}].cell"))?;
        }
        if let Some(inv) = obj.get_mut("inventory") {
            let stacks = expect_array(inv, &format!("props[{i}].inventory"))?;
            for (j, stack) in stacks.iter_mut().enumerate() {
                let s = stack
                    .as_object_mut()
                    .ok_or_else(|| format!("props[{i}].inventory[{j}] must be an object"))?;
                if let Some(v) = s.get_mut("qty") {
                    coerce_u16(v, &format!("props[{i}].inventory[{j}].qty"))?;
                }
            }
        }
    }
    Ok(())
}

fn coerce_room_vars(vars: &mut Value) -> Result<(), String> {
    let obj = vars
        .as_object_mut()
        .ok_or_else(|| "room_vars must be an object".to_string())?;
    let entries: Vec<(String, Value)> = obj.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    obj.clear();
    for (key, mut rec) in entries {
        let new_key = rec_key_as_room_id(&key);
        let rec_obj = rec
            .as_object_mut()
            .ok_or_else(|| format!("room_vars[{new_key}] must be an object"))?;
        fill(rec_obj, "oxygen_bp", json!(0));
        fill(rec_obj, "depressurized", json!(false));
        fill(rec_obj, "vented", json!(false));
        fill(rec_obj, "radiation_bp", json!(0));
        fill(rec_obj, "temperature_c", json!(0));
        fill(rec_obj, "notes", json!(""));
        if let Some(v) = rec_obj.get_mut("oxygen_bp") {
            coerce_u16(v, &format!("room_vars[{new_key}].oxygen_bp"))?;
        }
        if let Some(v) = rec_obj.get_mut("radiation_bp") {
            coerce_u16(v, &format!("room_vars[{new_key}].radiation_bp"))?;
        }
        if let Some(v) = rec_obj.get_mut("temperature_c") {
            coerce_i16(v, &format!("room_vars[{new_key}].temperature_c"))?;
        }
        obj.insert(new_key, rec);
    }
    Ok(())
}

fn rec_key_as_room_id(key: &str) -> String {
    // Godot may stringify a float key as "1.0".
    if let Ok(i) = coerce_i64_value(&Value::String(key.to_string()), "room_vars key") {
        if (0..=i64::from(u16::MAX)).contains(&i) {
            return i.to_string();
        }
    }
    key.to_string()
}

fn coerce_hazards(hazards: &mut Value) -> Result<(), String> {
    let obj = hazards
        .as_object_mut()
        .ok_or_else(|| "hazards must be an object".to_string())?;
    for key in ["fire_zones", "breach_zones", "arc_zones", "radiation_zones"] {
        if let Some(zones) = obj.get_mut(key) {
            coerce_link_zones(zones, &format!("hazards.{key}"))?;
        }
    }
    Ok(())
}

fn coerce_link_zones(zones: &mut Value, path: &str) -> Result<(), String> {
    let arr = expect_array(zones, path)?;
    for (i, zone) in arr.iter_mut().enumerate() {
        let obj = zone
            .as_object_mut()
            .ok_or_else(|| format!("{path}[{i}] must be an object"))?;
        fill(obj, "module_id", json!(""));
        fill(obj, "compartment_id", json!(""));
        fill(obj, "rationale", json!(""));
        if let Some(v) = obj.get_mut("from_cell") {
            coerce_cell3(v, &format!("{path}[{i}].from_cell"))?;
        }
        if let Some(v) = obj.get_mut("to_cell") {
            coerce_cell3(v, &format!("{path}[{i}].to_cell"))?;
        }
    }
    Ok(())
}

fn coerce_stamp(stamp: &mut Value) -> Result<(), String> {
    let obj = stamp
        .as_object_mut()
        .ok_or_else(|| "stamp must be an object".to_string())?;
    if let Some(edges) = obj.get_mut("attach_edges") {
        let arr = expect_array(edges, "stamp.attach_edges")?;
        for (i, edge) in arr.iter_mut().enumerate() {
            let e = edge
                .as_object_mut()
                .ok_or_else(|| format!("stamp.attach_edges[{i}] must be an object"))?;
            if let Some(v) = e.get_mut("cell") {
                coerce_cell3(v, &format!("stamp.attach_edges[{i}].cell"))?;
            }
        }
    }
    Ok(())
}

fn expect_array<'a>(v: &'a mut Value, path: &str) -> Result<&'a mut Vec<Value>, String> {
    v.as_array_mut()
        .ok_or_else(|| format!("{path} must be an array"))
}

fn coerce_cell2(v: &mut Value, path: &str) -> Result<(), String> {
    let arr = expect_array(v, path)?;
    if arr.len() != 2 {
        return Err(format!("{path} must be [x, y]"));
    }
    coerce_i32(&mut arr[0], &format!("{path}.x"))?;
    coerce_i32(&mut arr[1], &format!("{path}.y"))?;
    Ok(())
}

fn coerce_cell3(v: &mut Value, path: &str) -> Result<(), String> {
    let arr = expect_array(v, path)?;
    if arr.len() != 3 {
        return Err(format!("{path} must be [x, y, deck]"));
    }
    coerce_i32(&mut arr[0], &format!("{path}.x"))?;
    coerce_i32(&mut arr[1], &format!("{path}.y"))?;
    coerce_deck(&mut arr[2], &format!("{path}.deck"))?;
    Ok(())
}

fn coerce_u16(v: &mut Value, path: &str) -> Result<(), String> {
    let i = coerce_i64_value(v, path)?;
    if !(0..=i64::from(u16::MAX)).contains(&i) {
        return Err(format!("{path}: {i} out of u16 range"));
    }
    *v = json!(i);
    Ok(())
}

fn coerce_u32(v: &mut Value, path: &str) -> Result<(), String> {
    let i = coerce_i64_value(v, path)?;
    if !(0..=i64::from(u32::MAX)).contains(&i) {
        return Err(format!("{path}: {i} out of u32 range"));
    }
    *v = json!(i);
    Ok(())
}

fn coerce_i32(v: &mut Value, path: &str) -> Result<(), String> {
    let i = coerce_i64_value(v, path)?;
    if !(i64::from(i32::MIN)..=i64::from(i32::MAX)).contains(&i) {
        return Err(format!("{path}: {i} out of i32 range"));
    }
    *v = json!(i);
    Ok(())
}

fn coerce_i16(v: &mut Value, path: &str) -> Result<(), String> {
    let i = coerce_i64_value(v, path)?;
    if !(i64::from(i16::MIN)..=i64::from(i16::MAX)).contains(&i) {
        return Err(format!("{path}: {i} out of i16 range"));
    }
    *v = json!(i);
    Ok(())
}

fn coerce_deck(v: &mut Value, path: &str) -> Result<(), String> {
    let i = coerce_i64_value(v, path)?;
    if !(0..=7).contains(&i) {
        return Err(format!("{path}: deck {i} must be 0..=7"));
    }
    *v = json!(i);
    Ok(())
}

fn coerce_rotation(v: &mut Value, path: &str) -> Result<(), String> {
    let i = coerce_i64_value(v, path)?;
    if !(0..=3).contains(&i) {
        return Err(format!("{path}: rotation {i} must be 0..=3"));
    }
    *v = json!(i);
    Ok(())
}

pub fn coerce_i64_value(v: &Value, path: &str) -> Result<i64, String> {
    match v {
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                return Ok(i);
            }
            if let Some(u) = n.as_u64() {
                return i64::try_from(u).map_err(|_| format!("{path}: {u} out of i64 range"));
            }
            let f = n
                .as_f64()
                .ok_or_else(|| format!("{path}: invalid number"))?;
            if f.is_finite() && f.fract() == 0.0 && f >= i64::MIN as f64 && f <= i64::MAX as f64 {
                return Ok(f as i64);
            }
            Err(format!("{path}: expected integer, got {f}"))
        }
        Value::String(s) => {
            if let Ok(i) = s.parse::<i64>() {
                return Ok(i);
            }
            if let Ok(f) = s.parse::<f64>() {
                if f.is_finite() && f.fract() == 0.0 {
                    return Ok(f as i64);
                }
            }
            Err(format!("{path}: expected integer, got {s:?}"))
        }
        Value::Null => Err(format!("{path}: missing number")),
        other => Err(format!("{path}: expected number, got {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = include_str!("../../derelict_core/assets/golden_areas/airlock_2x2.json");

    fn floatify_ints(v: &mut Value) {
        match v {
            Value::Number(n) if n.as_i64().is_some() || n.as_u64().is_some() => {
                *v = json!(n.as_f64().unwrap());
            }
            Value::Array(a) => a.iter_mut().for_each(floatify_ints),
            Value::Object(m) => m.values_mut().for_each(floatify_ints),
            _ => {}
        }
    }

    #[test]
    fn sample_with_godot_floats_deserializes() {
        let mut value: Value = serde_json::from_str(SAMPLE).unwrap();
        floatify_ints(&mut value);
        assert!(value["topology"]["rooms"][0]["id"].as_f64().is_some());
        coerce_golden_value(&mut value).expect("coerce");
        let golden = golden_from_json(&value).expect("dto");
        assert_eq!(golden.topology.rooms[0].id, 1);
        assert_eq!(golden.topology.rooms[0].deck, 0);
        assert_eq!(
            golden.topology.rooms[0].cells,
            vec![[0, 0], [1, 0], [0, 1], [1, 1]]
        );
        assert_eq!(golden.topology.portals[0].from_cell, [0, 0, 0]);
        assert_eq!(golden.topology.portals[0].to_cell, [-1, 0, 0]);
        assert_eq!(golden.props[0].id, 1);
        assert_eq!(golden.props[0].rotation, 2);
        assert_eq!(golden.props[0].inventory[0].qty, 2);
        assert_eq!(golden.room_vars["1"].oxygen_bp, 8500);
        assert!(!golden.room_vars["1"].depressurized);
    }

    #[test]
    fn non_integer_float_is_error() {
        let mut value = json!({"topology":{"rooms":[{"id": 1.5}]}});
        let err = coerce_golden_value(&mut value).unwrap_err();
        assert!(err.contains("topology.rooms[0].id"), "{err}");
    }

    #[test]
    fn deck_out_of_range_is_error() {
        let mut value = json!({"topology":{"rooms":[{"id": 1.0, "deck": 8.0}]}});
        let err = coerce_golden_value(&mut value).unwrap_err();
        assert!(err.contains("0..=7"), "{err}");
    }

    #[test]
    fn rotation_out_of_range_is_error() {
        let mut value = json!({"props":[{"id": 1.0, "rotation": 4.0, "cell":[0.0, 0.0, 0.0]}]});
        let err = coerce_golden_value(&mut value).unwrap_err();
        assert!(err.contains("rotation"), "{err}");
    }

    #[test]
    fn missing_optional_keys_use_defaults() {
        let mut value = json!({
            "schema_version": "1.0.0",
            "document_kind": "golden_area",
            "id": "draft",
            "display_name": "Draft",
            "scope": "room",
            "kit_id": "ship_structural_v0",
            "cell_size_m": 4.0,
            "deck_height_m": 4.0,
            "entry_room": "",
            "goal_room": "",
            "topology": {
                "rooms": [{"id": 1.0, "stable_id": "r1", "role": "airlock", "deck": 0.0, "cells": [[0.0, 0.0]]}],
                "portals": [],
                "verticals": []
            }
        });
        coerce_golden_value(&mut value).expect("coerce");
        let golden = golden_from_json(&value).expect("dto");
        assert!(golden.props.is_empty());
        assert!(golden.module_overrides.floors.is_empty());
        assert_eq!(golden.hazards.source, "authored");
        assert!(golden.stamp.is_none());
    }

    #[test]
    fn booleans_stay_bool() {
        let mut value = json!({
            "topology": {"portals": [{
                "from_room": 1.0, "to_room": 0.0,
                "from_cell": [0.0, 0.0, 0.0],
                "to_cell": [-1.0, 0.0, 0.0],
                "state": "DOOR",
                "exterior": true
            }]}
        });
        coerce_golden_value(&mut value).unwrap();
        assert_eq!(value["topology"]["portals"][0]["exterior"], json!(true));
    }

    #[test]
    fn integer_valued_float_coerces() {
        assert_eq!(coerce_i64_value(&json!(2.0), "qty").unwrap(), 2);
        assert_eq!(coerce_i64_value(&json!(-1.0), "x").unwrap(), -1);
        assert!(coerce_i64_value(&json!(1.25), "qty").is_err());
        assert!(coerce_i64_value(&json!(f64::NAN), "qty").is_err());
    }

    #[test]
    fn coerced_sample_compiles() {
        use derelict_core::authoring::compile_authored;
        use derelict_core::structural::compile::DefaultModulePicker;
        use derelict_core::structural::validate::{validate, ValidationPolicy};

        let mut value: Value = serde_json::from_str(SAMPLE).unwrap();
        floatify_ints(&mut value);
        coerce_golden_value(&mut value).unwrap();
        let golden = golden_from_json(&value).unwrap();
        let topology = golden.to_topology().unwrap();
        let (plan, stale) =
            compile_authored(&topology, &DefaultModulePicker, &golden.module_overrides);
        assert!(stale.is_empty());
        validate(&plan, &topology, &ValidationPolicy::pre_damage(Vec::new())).expect("valid");
        assert_eq!(plan.occupancy.len(), 4);
    }
}
