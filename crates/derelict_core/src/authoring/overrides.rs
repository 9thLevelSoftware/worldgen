//! Apply authored module_id overrides after compile, without re-dressing vertices.

use super::dto::ModuleOverrides;
use crate::structural::compile::{
    compile, edge_set_wrapper_required, emit_socket_bindings, ModulePicker,
};
use crate::structural::plan::{EdgeKind, StructuralPlan, Topology};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StaleClass {
    Floor,
    Ceiling,
    Edge,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StaleOverride {
    pub class: StaleClass,
    pub key: String,
    pub module_id: String,
}

pub fn compile_authored(
    topology: &Topology,
    picker: &dyn ModulePicker,
    overrides: &ModuleOverrides,
) -> (StructuralPlan, Vec<StaleOverride>) {
    let mut plan = compile(topology, picker);
    let stale = apply_module_overrides(&mut plan, overrides);
    (plan, stale)
}

/// Mutates plan in place. Does not call apply_vertex_modules again.
pub fn apply_module_overrides(
    plan: &mut StructuralPlan,
    ov: &ModuleOverrides,
) -> Vec<StaleOverride> {
    let mut stale = Vec::new();

    for (key, module_id) in &ov.floors {
        match plan.occupancy.get_mut(key) {
            Some(occ) => {
                occ.module_id.clone_from(module_id);
                if let Some(floor) = plan
                    .floor_placements
                    .iter_mut()
                    .find(|f| f.cell_key == *key)
                {
                    floor.module_id.clone_from(module_id);
                }
            }
            None => stale.push(StaleOverride {
                class: StaleClass::Floor,
                key: key.clone(),
                module_id: module_id.clone(),
            }),
        }
    }

    for (key, module_id) in &ov.ceilings {
        match plan
            .ceiling_placements
            .iter_mut()
            .find(|c| c.cell_key == *key)
        {
            Some(ceiling) => ceiling.module_id.clone_from(module_id),
            None => stale.push(StaleOverride {
                class: StaleClass::Ceiling,
                key: key.clone(),
                module_id: module_id.clone(),
            }),
        }
    }

    for (key, module_id) in &ov.edges {
        let kind = match plan.edges.get(key).map(|e| e.kind) {
            Some(kind) => kind,
            None => {
                stale.push(StaleOverride {
                    class: StaleClass::Edge,
                    key: key.clone(),
                    module_id: module_id.clone(),
                });
                continue;
            }
        };
        if kind == EdgeKind::Breach {
            plan.edges
                .get_mut(key)
                .expect("edge key was present")
                .module_id
                .clear();
            continue;
        }
        if module_id.is_empty() && kind != EdgeKind::Open {
            plan.errors.push(format!(
                "empty module_id override for materialized {} edge {key}",
                kind.name()
            ));
            continue;
        }
        plan.edges
            .get_mut(key)
            .expect("edge key was present")
            .module_id
            .clone_from(module_id);
    }

    for edge in plan.edges.values_mut() {
        edge_set_wrapper_required(edge);
    }
    plan.placements = plan
        .edges
        .values()
        .filter(|e| e.kind != EdgeKind::Open && e.wrapper_required)
        .cloned()
        .collect();
    emit_socket_bindings(plan);

    stale
}
