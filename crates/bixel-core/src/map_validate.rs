//! Zone map loading and validation (port of `core/maps.py`).
//!
//! The game parses zone JSON by hand, so a map can be perfectly valid Tiled and
//! still be silently wrong in-game. Every rule here mirrors a specific branch of
//! the game's zone loader; valid zone names are parsed out of `zone_id.dart` at
//! runtime rather than duplicated.

use std::path::Path;

use regex::Regex;
use serde::Serialize;
use serde_json::{json, Value};

pub const ZONE_ID_DART: &str = "lib/models/zone_id.dart";
pub const ZONE_MANIFEST_DART: &str = "lib/models/place_zone_manifest.dart";

/// Layer names that assign a role to untyped objects.
const ROLE_LAYERS: [(&str, &str); 6] = [
    ("doors", "door"),
    ("spawns", "spawn"),
    ("boards", "board"),
    ("npcs", "npc"),
    ("rifts", "rift"),
    ("rift", "rift"),
];
/// Object-name prefixes that do the same.
const ROLE_PREFIXES: [(&str, &str); 5] = [
    ("door_", "door"),
    ("spawn_", "spawn"),
    ("board_", "board"),
    ("npc_", "npc"),
    ("rift", "rift"),
];
const KNOWN_TYPES: [&str; 5] = ["door", "spawn", "board", "npc", "rift"];

pub const COLLISION_LAYER: &str = "collisions";
pub const MIN_RIFT_SIZE: f64 = 110.0;

#[derive(Debug, Clone, Serialize)]
pub struct Finding {
    pub level: String,
    pub code: String,
    pub message: String,
    #[serde(default)]
    pub layer: String,
    #[serde(default)]
    pub object: String,
}

impl Finding {
    pub fn new(level: &str, code: &str, message: impl Into<String>, layer: &str, object: &str) -> Self {
        Finding {
            level: level.into(),
            code: code.into(),
            message: message.into(),
            layer: layer.into(),
            object: object.into(),
        }
    }
}

// ------------------------------------------------------------------ zone ids

fn zone_source(root: &Path) -> Option<(Vec<String>, Vec<String>)> {
    let text = std::fs::read_to_string(root.join(ZONE_ID_DART)).ok()?;
    let enum_re = Regex::new(r"enum\s+ZoneId\s*\{(.*?)\}").ok()?;
    let mut names = Vec::new();
    if let Some(caps) = enum_re.captures(&text) {
        for line in caps[1].split(',') {
            let cleaned = Regex::new(r"//.*").map(|r| r.replace_all(line, "")).ok()?;
            let cleaned = cleaned.trim();
            let ident_re = Regex::new(r"^[A-Za-z_][A-Za-z0-9_]*$").ok()?;
            if ident_re.is_match(cleaned) {
                names.push(cleaned.to_string());
            }
        }
    }
    let fn_re = Regex::new(r"ZoneId\?\s+zoneIdFromName\s*\(.*?\)\s*\{(.*?)\n\}").ok()?;
    let case_re = Regex::new(r"case\s+'([^']+)'").ok()?;
    let mut aliases = Vec::new();
    if let Some(fn_caps) = fn_re.captures(&text) {
        for c in case_re.captures_iter(&fn_caps[1]) {
            aliases.push(c[1].to_string());
        }
    }
    Some((names, aliases))
}

/// `(enum names, alias strings)` parsed from `zone_id.dart`.
pub fn zone_names(root: &Path) -> (Vec<String>, Vec<String>) {
    zone_source(root).unwrap_or_default()
}

/// Mirror of `zoneIdFromName`: does this door target reach a real zone?
pub fn resolve_zone(root: &Path, name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    let (names, aliases) = zone_names(root);
    if names.is_empty() {
        // zone_id.dart unreadable — do not raise false alarms.
        return true;
    }
    if aliases.iter().any(|a| a == name) || names.iter().any(|n| n == name) {
        return true;
    }
    let normalized = name.replace(['-', '_'], "").to_lowercase();
    names.iter().any(|c| c.to_lowercase() == normalized)
}

fn zone_maps(root: &Path) -> Option<Vec<(String, String)>> {
    let text = std::fs::read_to_string(root.join(ZONE_MANIFEST_DART)).ok()?;
    let re = Regex::new(r"zoneName:\s*'([^']+)'.*?mapJson:\s*'([^']+)'").ok()?;
    let mut pairs = Vec::new();
    for caps in re.captures_iter(&text) {
        pairs.push((caps[1].to_string(), caps[2].to_string()));
    }
    Some(pairs)
}

pub fn zone_map_path(root: &Path, zone_name: &str, lang: &str) -> String {
    let Some(pairs) = zone_maps(root) else {
        return String::new();
    };
    for (name, map_json) in pairs {
        if name == zone_name {
            return map_json.replace("assets/lang/", &format!("assets/{lang}/"));
        }
    }
    String::new()
}

pub fn canonical_zone(root: &Path, name: &str) -> String {
    let (names, aliases) = zone_names(root);
    if names.iter().any(|n| n == name) {
        return name.to_string();
    }
    if aliases.iter().any(|a| a == name) {
        if let Ok(text) = std::fs::read_to_string(root.join(ZONE_ID_DART)) {
            let start = text.find("zoneIdFromName").unwrap_or(0);
            let tail = &text[start..];
            let re = Regex::new(r"((?:\s*case\s+'[^']+':)+)\s*return\s+ZoneId\.(\w+);").ok();
            if let Some(re) = re {
                for caps in re.captures_iter(tail) {
                    if caps[1].contains(&format!("'{name}'")) {
                        return caps[2].to_string();
                    }
                }
            }
        }
    }
    let normalized = name.replace(['-', '_'], "").to_lowercase();
    for candidate in &names {
        if candidate.to_lowercase() == normalized {
            return candidate.clone();
        }
    }
    String::new()
}

// --------------------------------------------------------------------- model

pub fn object_layers(data: &Value) -> Vec<&Value> {
    data.get("layers")
        .and_then(|v| v.as_array())
        .map(|layers| {
            layers
                .iter()
                .filter(|layer| {
                    layer.is_object()
                        && (layer.get("type").and_then(|t| t.as_str()) == Some("objectgroup")
                            || layer.get("objects").is_some())
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn tile_layers(data: &Value) -> Vec<&Value> {
    data.get("layers")
        .and_then(|v| v.as_array())
        .map(|layers| {
            layers
                .iter()
                .filter(|layer| layer.get("type").and_then(|t| t.as_str()) == Some("tilelayer"))
                .collect()
        })
        .unwrap_or_default()
}

pub fn properties(node: &Value) -> std::collections::HashMap<String, String> {
    let mut result = std::collections::HashMap::new();
    if let Some(props) = node.get("properties").and_then(|v| v.as_array()) {
        for entry in props {
            if let (Some(name), Some(value)) = (entry.get("name"), entry.get("value")) {
                result.insert(name.as_str().unwrap_or("").to_string(), value.to_string());
            }
        }
    }
    result
}

/// The role the zone loader will assign to this object.
pub fn role_of(layer_name: &str, obj: &Value) -> String {
    let explicit = obj
        .get("type")
        .or_else(|| obj.get("class"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim();
    if !explicit.is_empty() {
        return explicit.to_string();
    }
    let lowered = layer_name.to_lowercase();
    let name = obj.get("name").and_then(|v| v.as_str()).unwrap_or("").trim();
    if lowered == "rifts" || lowered == "rift" || name.to_lowercase().starts_with("rift") {
        return "rift".to_string();
    }
    for (prefix, role) in ROLE_PREFIXES {
        if name.starts_with(prefix) {
            return role.to_string();
        }
    }
    ROLE_LAYERS
        .iter()
        .find(|(k, _)| *k == lowered)
        .map(|(_, role)| role.to_string())
        .unwrap_or_default()
}

fn norm_path(parent: &Path, image: &str) -> String {
    let joined = parent.join(image);
    let mut parts: Vec<String> = Vec::new();
    for comp in joined.components() {
        match comp {
            std::path::Component::Normal(c) => parts.push(c.to_string_lossy().into_owned()),
            std::path::Component::ParentDir => {
                if parts.last().map(|p| p != "..").unwrap_or(false) {
                    parts.pop();
                }
            }
            _ => {}
        }
    }
    parts.join("/")
}

/// Repo-relative path of the map's background image, or `""`.
pub fn tileset_image(root: &Path, data: &Value, map_rel: &str) -> String {
    let parent = Path::new(map_rel).parent().unwrap_or(Path::new(""));
    let tilesets = data.get("tilesets").and_then(|v| v.as_array());
    let Some(tilesets) = tilesets else {
        return String::new();
    };
    for ts in tilesets {
        if !ts.is_object() {
            continue;
        }
        let image = ts.get("image").and_then(|v| v.as_str()).unwrap_or("").trim();
        if !image.is_empty() {
            let norm = norm_path(parent, image);
            if norm != "." {
                return norm;
            }
        }
        let source = ts.get("source").and_then(|v| v.as_str()).unwrap_or("").trim();
        if !source.is_empty() && (source.ends_with(".json") || source.ends_with(".tmj")) {
            let ext_rel = norm_path(parent, source);
            if let Ok(ext_file) = crate::paths::safe_resolve(&ext_rel, root) {
                if ext_file.is_file() {
                    if let Ok(text) = std::fs::read_to_string(&ext_file) {
                        if let Ok(ext_data) = serde_json::from_str::<Value>(&text) {
                            if let Some(ext_img) = ext_data.get("image").and_then(|v| v.as_str()) {
                                let ext_img = ext_img.trim();
                                if !ext_img.is_empty() {
                                    let norm = norm_path(&ext_file.parent().unwrap_or(Path::new("")), ext_img);
                                    return norm;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    String::new()
}

pub fn renders_as_full_image(data: &Value) -> bool {
    let Some(tilesets) = data.get("tilesets").and_then(|v| v.as_array()) else {
        return false;
    };
    let Some(first) = tilesets.first() else {
        return false;
    };
    if first.get("tilecount").and_then(|v| v.as_i64()) != Some(1) {
        return false;
    }
    for layer in data.get("layers").and_then(|v| v.as_array()).into_iter().flatten() {
        if layer.get("type").and_then(|t| t.as_str()) == Some("tilelayer") {
            return layer.get("width").and_then(|v| v.as_i64()) == Some(1)
                && layer.get("height").and_then(|v| v.as_i64()) == Some(1)
                && layer.get("data").and_then(|v| v.as_array()).map(|d| d.len() == 1).unwrap_or(false);
        }
    }
    false
}

pub fn is_hidden_by_game(layer: &Value) -> bool {
    let mut render_mode_depth = false;
    if let Some(props) = layer.get("properties").and_then(|v| v.as_array()) {
        for p in props {
            if p.get("name").and_then(|v| v.as_str()) == Some("renderMode")
                && p.get("value").and_then(|v| v.as_str()) == Some("depth")
            {
                render_mode_depth = true;
            }
        }
    }
    render_mode_depth || layer.get("name").and_then(|v| v.as_str()).unwrap_or("").to_lowercase() == "deco"
}

pub fn is_tile_based(data: &Value) -> bool {
    if renders_as_full_image(data) {
        return false;
    }
    !tile_layers(data).is_empty()
}

pub fn tileset_meta(data: &Value, map_rel: &str, root: &Path) -> Option<Value> {
    let tilesets = data.get("tilesets").and_then(|v| v.as_array())?;
    let ts = tilesets.first()?;
    let image = ts.get("image").and_then(|v| v.as_str()).unwrap_or("").trim();
    let image_rel = if !image.is_empty() {
        norm_path(Path::new(map_rel).parent().unwrap_or(Path::new("")), image)
    } else {
        tileset_image(root, data, map_rel)
    };
    let image_rel = if image_rel == "." { String::new() } else { image_rel };
    Some(json!({
        "name": ts.get("name").and_then(|v| v.as_str()).unwrap_or(""),
        "image": image_rel,
        "firstgid": ts.get("firstgid").and_then(|v| v.as_i64()).unwrap_or(1),
        "tilewidth": ts.get("tilewidth").and_then(|v| v.as_i64()).unwrap_or(0),
        "tileheight": ts.get("tileheight").and_then(|v| v.as_i64()).unwrap_or(0),
        "columns": ts.get("columns").and_then(|v| v.as_i64()).unwrap_or(0),
        "tilecount": ts.get("tilecount").and_then(|v| v.as_i64()).unwrap_or(0),
        "imagewidth": ts.get("imagewidth").and_then(|v| v.as_i64()).unwrap_or(0),
        "imageheight": ts.get("imageheight").and_then(|v| v.as_i64()).unwrap_or(0),
    }))
}

pub fn layer_meta(layer: &Value) -> Value {
    let mut base = json!({
        "id": layer.get("id"),
        "name": layer.get("name").and_then(|v| v.as_str()).unwrap_or(""),
        "type": layer.get("type").and_then(|v| v.as_str()).unwrap_or(""),
        "visible": layer.get("visible").and_then(|v| v.as_bool()).unwrap_or(true),
        "opacity": layer.get("opacity").and_then(|v| v.as_f64()).unwrap_or(1.0),
    });
    if layer.get("type").and_then(|t| t.as_str()) == Some("tilelayer") {
        let data = layer.get("data").and_then(|v| v.as_array());
        let tiles = data.map(|d| d.iter().filter(|g| g.as_i64().unwrap_or(0) != 0).count()).unwrap_or(0);
        base["kind"] = json!("tile");
        base["width"] = json!(layer.get("width").and_then(|v| v.as_i64()).unwrap_or(0));
        base["height"] = json!(layer.get("height").and_then(|v| v.as_i64()).unwrap_or(0));
        base["tiles"] = json!(tiles);
        base["hidden_by_game"] = json!(is_hidden_by_game(layer));
    } else {
        base["kind"] = json!("objects");
        base["objects"] = json!(layer.get("objects").and_then(|v| v.as_array()).map(|o| o.len()).unwrap_or(0));
    }
    base
}

// ---------------------------------------------------------------- validation

pub fn validate(data: &Value, map_rel: &str, root: &Path) -> Vec<Finding> {
    let mut findings: Vec<Finding> = Vec::new();
    let mut add = |f: Option<Finding>| {
        if let Some(f) = f {
            findings.push(f);
        }
    };

    let layers = object_layers(data);
    let layer_names: Vec<String> = layers
        .iter()
        .map(|l| l.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string())
        .collect();

    if !layer_names.iter().any(|n| n == COLLISION_LAYER) {
        let near: Vec<&str> = layer_names
            .iter()
            .filter(|n| {
                matches!(
                    n.to_lowercase().replace(' ', "").as_str(),
                    "collisions" | "collision" | "collider" | "colliders"
                )
            })
            .map(|n| n.as_str())
            .collect();
        if let Some(first) = near.first() {
            add(Some(Finding::new(
                "error",
                "collision_layer_name",
                format!(
                    "layer {first:?} is not the collision layer — zone_loader matches the name \
                     {COLLISION_LAYER:?} exactly, so nothing here is solid"
                ),
                first,
                "",
            )));
        } else {
            add(Some(Finding::new(
                "warn",
                "no_collision_layer",
                format!("no {COLLISION_LAYER:?} object layer — this zone has no walls"),
                "",
                "",
            )));
        }
    }

    let mut spawn_names: Vec<String> = Vec::new();
    let mut door_count = 0;

    for layer in &layers {
        let layer_name = layer.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let objects = layer.get("objects").and_then(|v| v.as_array()).cloned().unwrap_or_default();

        if layer_name == COLLISION_LAYER {
            let mut typed = 0;
            for obj in &objects {
                if obj.get("width").and_then(|v| v.as_f64()).unwrap_or(0.0) <= 0.0
                    || obj.get("height").and_then(|v| v.as_f64()).unwrap_or(0.0) <= 0.0
                {
                    add(Some(Finding::new(
                        "error",
                        "collision_zero_size",
                        "collision rect has zero width or height and is skipped by the loader",
                        &layer_name,
                        &label(obj),
                    )));
                }
                if !obj
                    .get("type")
                    .or_else(|| obj.get("class"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .trim()
                    .is_empty()
                {
                    typed += 1;
                }
            }
            if typed > 0 {
                add(Some(Finding::new(
                    "info",
                    "collision_typed",
                    format!("{typed} collision rect(s) carry a type; harmless here, though tile-object-extractor writes them untyped"),
                    &layer_name,
                    "",
                )));
            }
            continue;
        }

        for obj in &objects {
            let where_label = label(obj);
            let role = role_of(&layer_name, obj);
            let name = obj.get("name").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
            let props = properties(obj);

            if role.is_empty() {
                add(Some(Finding::new(
                    "warn",
                    "object_ignored",
                    "no type, no role-carrying layer name and no known name prefix — the loader will ignore this object",
                    &layer_name,
                    &where_label,
                )));
                continue;
            }
            if !KNOWN_TYPES.contains(&role.as_str()) {
                add(Some(Finding::new(
                    "warn",
                    "unknown_type",
                    format!("type {role:?} is not handled by zone_loader and is ignored"),
                    &layer_name,
                    &where_label,
                )));
                continue;
            }

            if role == "door" {
                door_count += 1;
                let target = props
                    .get("targetZone")
                    .or_else(|| props.get("target"))
                    .cloned()
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if target.is_empty() {
                    add(Some(Finding::new(
                        "error",
                        "door_no_target",
                        "door has no targetZone property — the loader treats it as an unfinished placeholder and the door does nothing",
                        &layer_name,
                        &where_label,
                    )));
                } else if !resolve_zone(root, &target) {
                    add(Some(Finding::new(
                        "error",
                        "door_unknown_target",
                        format!("targetZone {target:?} does not resolve to a ZoneId — the door is inert"),
                        &layer_name,
                        &where_label,
                    )));
                } else {
                    add(check_target_spawn(root, &target, &props, map_rel, &layer_name, &where_label));
                }
                if let Some(level) = props.get("requiredLevel") {
                    let int_re = Regex::new(r"^-?\d+$").ok();
                    if let Some(re) = int_re {
                        if !re.is_match(level.trim()) {
                            add(Some(Finding::new(
                                "warn",
                                "door_bad_level",
                                format!("requiredLevel {level:?} is not an integer; the loader falls back to 1"),
                                &layer_name,
                                &where_label,
                            )));
                        }
                    }
                }
            } else if role == "spawn" {
                if name.is_empty() {
                    add(Some(Finding::new(
                        "error",
                        "spawn_unnamed",
                        "spawn has no name — spawns are keyed by name and this one is unreachable",
                        &layer_name,
                        &where_label,
                    )));
                } else {
                    spawn_names.push(name);
                }
            } else if role == "npc" {
                if props.get("npcId").map(|v| v.is_empty()).unwrap_or(true) {
                    add(Some(Finding::new(
                        "warn",
                        "npc_no_id",
                        "npc marker has no npcId property, so no NPC is placed from this object",
                        &layer_name,
                        &where_label,
                    )));
                }
            } else if role == "rift" {
                let width = obj.get("width").and_then(|v| v.as_f64()).unwrap_or(0.0);
                let height = obj.get("height").and_then(|v| v.as_f64()).unwrap_or(0.0);
                if 0.0 < width.min(height) && width.min(height) < MIN_RIFT_SIZE {
                    add(Some(Finding::new(
                        "info",
                        "rift_inflated",
                        format!("rift smaller than {MIN_RIFT_SIZE:.0}px is inflated by the loader; the drawn box is not what players see"),
                        &layer_name,
                        &where_label,
                    )));
                }
            }
        }
    }

    let mut counts = std::collections::HashMap::new();
    for name in &spawn_names {
        *counts.entry(name.clone()).or_insert(0usize) += 1;
    }
    let mut dups: Vec<&String> = counts.iter().filter(|(_, c)| **c > 1).map(|(k, _)| k).collect();
    dups.sort();
    for name in dups {
        add(Some(Finding::new(
            "warn",
            "spawn_duplicate",
            format!("spawn {name:?} is defined more than once; the last one wins"),
            "",
            "",
        )));
    }

    let tilesets = data.get("tilesets").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    if let Some(first) = tilesets.first() {
        let image = first.get("image").and_then(|v| v.as_str()).unwrap_or("");
        if image.contains("..") {
            add(Some(Finding::new(
                "error",
                "tileset_parent_path",
                format!("tileset image {image:?} uses '..'; the JSON and PNG must sit side by side"),
                "",
                "",
            )));
        } else {
            let image_rel = tileset_image(root, data, map_rel);
            if !image_rel.is_empty() && !root.join(&image_rel).exists() {
                add(Some(Finding::new(
                    "error",
                    "tileset_missing",
                    format!("tileset image {image_rel:?} does not exist"),
                    "",
                    "",
                )));
            }
        }
    } else {
        add(Some(Finding::new(
            "warn",
            "no_tileset",
            "map has no tileset, so it has no background image",
            "",
            "",
        )));
    }

    if !tilesets.is_empty() && !renders_as_full_image(data) {
        add(Some(Finding::new(
            "info",
            "not_full_image",
            "this map will not render as a single full-image background (needs a 1x1 tile layer and a tileset with tilecount 1)",
            "",
            "",
        )));
    }

    let _ = door_count;
    findings
}

fn check_target_spawn(
    root: &Path,
    target: &str,
    props: &std::collections::HashMap<String, String>,
    map_rel: &str,
    layer_name: &str,
    where_label: &str,
) -> Option<Finding> {
    let lang = language_of(map_rel);
    if lang.is_empty() {
        return None;
    }
    let zone = canonical_zone(root, target);
    if zone.is_empty() {
        return None;
    }
    let map_path = zone_map_path(root, &zone, &lang);
    if map_path.is_empty() {
        return None;
    }
    let full = root.join(&map_path);
    if !full.exists() {
        return None;
    }
    let Ok(text) = std::fs::read_to_string(&full) else {
        return None;
    };
    let Ok(data) = serde_json::from_str::<Value>(&text) else {
        return None;
    };
    let mut spawns: Vec<String> = Vec::new();
    for layer in object_layers(&data) {
        let ln = layer.get("name").and_then(|v| v.as_str()).unwrap_or("");
        if ln == COLLISION_LAYER {
            continue;
        }
        for obj in layer.get("objects").and_then(|v| v.as_array()).into_iter().flatten() {
            if role_of(ln, obj) == "spawn" {
                let n = obj.get("name").and_then(|v| v.as_str()).unwrap_or("").trim();
                if !n.is_empty() {
                    spawns.push(n.to_string());
                }
            }
        }
    }
    if spawns.is_empty() {
        return None;
    }
    let wanted = props.get("targetSpawn").or_else(|| props.get("spawn")).map(|s| s.as_str()).unwrap_or("default").trim();
    if spawns.iter().any(|s| s == wanted) {
        return None;
    }
    let mut sorted = spawns.clone();
    sorted.sort();
    Some(Finding::new(
        "info",
        "door_missing_spawn",
        format!(
            "targetSpawn {wanted:?} is not defined in {map_path} (it has: {}) — the game falls back to the door-return point, so the named spawn has no effect",
            if sorted.is_empty() { "none".to_string() } else { sorted.join(", ") }
        ),
        layer_name,
        where_label,
    ))
}

fn label(obj: &Value) -> String {
    let name = obj.get("name").and_then(|v| v.as_str()).unwrap_or("").trim();
    if !name.is_empty() {
        name.to_string()
    } else {
        format!("#{}", obj.get("id").and_then(|v| v.as_i64()).map(|i| i.to_string()).unwrap_or_else(|| "?".into()))
    }
}

/// `'ja'` from `'assets/ja/images/tiles/places/konbini.json'`.
pub fn language_of(map_rel: &str) -> String {
    let parts: Vec<&str> = map_rel.split('/').collect();
    if parts.len() > 2 && parts[0] == "assets" {
        parts[1].to_string()
    } else {
        String::new()
    }
}

pub fn summarize(data: &Value) -> Value {
    let mut counts = std::collections::HashMap::<String, usize>::new();
    counts.insert("collisions".to_string(), 0);
    for layer in object_layers(data) {
        let layer_name = layer.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let objects = layer.get("objects").and_then(|v| v.as_array()).cloned().unwrap_or_default();
        if layer_name == COLLISION_LAYER {
            *counts.entry("collisions".into()).or_insert(0) += objects.len();
            continue;
        }
        for obj in &objects {
            let role = role_of(layer_name, obj);
            let role = if role.is_empty() { "ignored".to_string() } else { role };
            *counts.entry(role).or_insert(0) += 1;
        }
    }
    serde_json::to_value(counts).unwrap_or(json!({}))
}

// ------------------------------------------------------------------ creation

pub fn new_document(
    width: i64,
    height: i64,
    tilewidth: i64,
    tileheight: Option<i64>,
    ground_layer: bool,
    collisions_layer: bool,
    objects_layer: bool,
) -> Value {
    let width = width.clamp(1, 1024);
    let height = height.clamp(1, 1024);
    let tilewidth = tilewidth.clamp(1, 256);
    let tileheight = tileheight.unwrap_or(tilewidth).clamp(1, 256);

    let object_group = |layer_id: i64, name: &str| {
        json!({
            "id": layer_id, "name": name, "type": "objectgroup",
            "draworder": "topdown", "objects": [], "opacity": 1,
            "visible": true, "x": 0, "y": 0
        })
    };

    let mut next_id = 1;
    let mut layers: Vec<Value> = Vec::new();
    if ground_layer {
        layers.push(json!({
            "id": next_id, "name": "ground", "type": "tilelayer",
            "width": width, "height": height,
            "data": vec![0i64; (width * height) as usize],
            "opacity": 1, "visible": true, "x": 0, "y": 0,
        }));
        next_id += 1;
    }
    for (name, include) in [("collisions", collisions_layer), ("objects", objects_layer)] {
        if include {
            layers.push(object_group(next_id, name));
            next_id += 1;
        }
    }

    json!({
        "type": "map", "version": "1.10", "orientation": "orthogonal",
        "renderorder": "right-down", "infinite": false,
        "width": width, "height": height,
        "tilewidth": tilewidth, "tileheight": tileheight,
        "nextlayerid": next_id, "nextobjectid": 1,
        "tilesets": [], "layers": layers,
    })
}

/// Resolve a map's tileset image to a workspace-relative path when it exists.
pub fn load_image_rel(root: &Path, data: &Value, map_rel: &str) -> String {
    let rel = tileset_image(root, data, map_rel);
    if !rel.is_empty() && root.join(&rel).exists() {
        rel
    } else {
        String::new()
    }
}
