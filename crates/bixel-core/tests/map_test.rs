//! Integration tests for the TileMap designer engine (`crates/bixel-core/src/map.rs`).
//!
//! Mirrors the semantics of `map_validate` where relevant: Tiled JSON produced
//! here must be consumable by the existing Tiled schema readers, and files
//! produced by the real Tiled editor must round-trip losslessly.

use bixel_core::map::{
    GID_D_FLIP, GID_H_FLIP, GID_V_FLIP, TileMap, MAX_MAP_DIM,
};
use bixel_core::tilemap::Pattern;
use serde_json::Value;

/// 32×32 two-tile RGBA sheet: tile 0 solid red, tile 1 solid green.
fn two_tile_sheet() -> (Vec<u8>, u32, u32) {
    let (w, h) = (32u32, 32u32);
    let mut px = vec![0u8; (w * h * 4) as usize];
    for y in 0..16 {
        for x in 0..16 {
            let i = ((y * w + x) * 4) as usize;
            px[i] = 255; // red tile (local 0)
            px[i + 3] = 255;
        }
        for x in 16..32 {
            let i = ((y * w + x) * 4) as usize;
            px[i + 1] = 255; // green tile (local 1)
            px[i + 3] = 255;
        }
    }
    for y in 16..32 {
        for x in 0..16 {
            let i = ((y * w + x) * 4) as usize;
            px[i] = 255;
            px[i + 3] = 255;
        }
        for x in 16..32 {
            let i = ((y * w + x) * 4) as usize;
            px[i + 1] = 255;
            px[i + 3] = 255;
        }
    }
    (px, w, h)
}

fn map_with_sheet() -> TileMap {
    let mut map = TileMap::new(4, 4, 16, 16);
    let (px, w, h) = two_tile_sheet();
    let idx = map
        .add_tileset("tiles", "assets/tiles.png", w, h, 16, 16, 0, 0)
        .unwrap();
    map.set_tileset_pixels(idx, &px);
    map
}

#[test]
fn slice_math_synthetic() {
    assert_eq!(TileMap::slice_tileset_math(128, 128, 16, 16, 0, 0), (8, 64));
    assert_eq!(TileMap::slice_tileset_math(128, 128, 16, 16, 4, 4), (6, 36));
    assert_eq!(TileMap::slice_tileset_math(16, 8, 16, 16, 0, 0), (0, 0));
    // A single-tile "full image" tileset used by the game's background maps.
    assert_eq!(TileMap::slice_tileset_math(64, 64, 64, 64, 0, 0), (1, 1));
}

#[test]
fn gid_flag_encode_decode() {
    let mut map = map_with_sheet();
    let encoded = TileMap::encode_gid(1, 1, GID_H_FLIP | GID_V_FLIP | GID_D_FLIP);
    assert_eq!(TileMap::gid_flags(encoded), GID_H_FLIP | GID_V_FLIP | GID_D_FLIP);
    assert_eq!(encoded & 0x1fff_ffff, 2);
    let (ts, local, flags) = map.gid_lookup(encoded).unwrap();
    assert_eq!((ts, local, flags), (0, 1, GID_H_FLIP | GID_V_FLIP | GID_D_FLIP));
}

#[test]
fn stamp_and_region_copy_paste() {
    let mut map = map_with_sheet();
    // Stamp a 2×2 pattern: gid 1 (red) on the left, gid 2 (green) on the right.
    let pattern = Pattern {
        w: 2,
        h: 2,
        tiles: vec![1, 2, 2, 1],
    };
    let changed = map.stamp(0, 1, 1, &pattern, true);
    assert_eq!(changed, 4);
    assert_eq!(map.get_tile(0, 1, 1), 1);
    assert_eq!(map.get_tile(0, 2, 1), 2);
    assert_eq!(map.get_tile(0, 2, 2), 1);

    // Copy the region and paste it into a second layer.
    let second = map.add_tile_layer(Some("Copy"));
    let copied = map.read_region(0, 1, 1, 2, 2);
    assert_eq!((copied.w, copied.h), (2, 2));
    map.stamp(second, 0, 0, &copied, true);
    assert_eq!(map.get_tile(second, 0, 0), 1);
    assert_eq!(map.get_tile(second, 1, 1), 1);
    assert_eq!(map.get_tile(second, 1, 0), 2);
}

#[test]
fn undo_redo_round_trip() {
    let mut map = map_with_sheet();
    map.snapshot();
    map.set_tile(0, 0, 0, 1);
    assert!(map.can_undo());
    assert_eq!(map.get_tile(0, 0, 0), 1);
    map.undo();
    assert_eq!(map.get_tile(0, 0, 0), 0);
    assert!(map.can_redo());
    map.redo();
    assert_eq!(map.get_tile(0, 0, 0), 1);
}

#[test]
fn composite_pixel_correctness() {
    let mut map = map_with_sheet();
    map.set_tile(0, 0, 0, 1); // red at top-left cell
    map.set_tile(0, 1, 1, TileMap::encode_gid(1, 1, 0)); // green at (1,1)
    let out = map.composite();
    assert_eq!(out.len(), 4 * 4 * 16 * 16 * 4);

    let px = |x: usize, y: usize| -> (u8, u8, u8, u8) {
        let i = (y * 64 + x) * 4;
        (out[i], out[i + 1], out[i + 2], out[i + 3])
    };
    assert_eq!(px(0, 0), (255, 0, 0, 255));
    assert_eq!(px(15, 15), (255, 0, 0, 255));
    // Green tile stamped at map cell (1,1) → pixels (16…31, 16…31).
    assert_eq!(px(17, 17), (0, 255, 0, 255));
    assert_eq!(px(31, 31), (0, 255, 0, 255));
    // Empty cells stay fully transparent.
    assert_eq!(px(48, 0).3, 0);
    assert_eq!(px(0, 48).3, 0);
    assert_eq!(px(48, 48).3, 0);
}

#[test]
fn composite_respects_layer_visibility_and_flags() {
    let mut map = map_with_sheet();
    map.set_tile(0, 0, 0, 1);
    // Layer 2 paints an overlapping H-flipped green tile on a DIFFERENT cell so
    // the underlying red cell can be observed when the layer is hidden.
    let l2 = map.add_tile_layer(Some("Over"));
    map.set_tile(l2, 1, 0, TileMap::encode_gid(1, 1, GID_H_FLIP));
    let base = map.composite();
    let count_red = base
        .chunks_exact(4)
        .filter(|px| px[0] == 255 && px[1] == 0 && px[2] == 0 && px[3] == 255)
        .count();
    assert!(count_red > 0);

    map.snapshot();
    if let Some(layer) = map.layers.get_mut(l2) {
        layer.set_visible(false);
    }
    // Layer 2 hidden: the green tile is gone, the red cell is untouched.
    let hidden = map.composite();
    let i = 0;
    assert_eq!((hidden[i], hidden[i + 1], hidden[i + 2], hidden[i + 3]), (255, 0, 0, 255));
    map.undo();
    let restored = map.composite();
    assert!(restored
        .chunks_exact(4)
        .any(|px| px[0] == 0 && px[1] == 255 && px[2] == 0 && px[3] == 255));
}

#[test]
fn csv_output_matches_data() {
    let mut map = map_with_sheet();
    map.set_tile(0, 0, 0, 1);
    map.set_tile(0, 3, 3, 2);
    let csv = map.layer_to_csv(0);
    let lines: Vec<&str> = csv.lines().collect();
    assert_eq!(lines.len(), 4);
    assert_eq!(lines[0], "1,0,0,0");
    assert_eq!(lines[3], "0,0,0,2");
}

#[test]
fn json_round_trip_through_map_validate() {
    let mut map = map_with_sheet();
    map.set_tile(0, 0, 0, 1);
    map.set_tile(0, 2, 2, 2);
    map.add_object_layer(Some("collisions"));
    // Object layers parse in phase 1 even though editing lands later.
    let text = map.to_tiled_json().unwrap();

    let reparsed = TileMap::from_tiled_json(&text).unwrap();
    assert_eq!((reparsed.width, reparsed.height), (4, 4));
    assert_eq!(reparsed.tilesets.len(), 1);
    assert_eq!(reparsed.tilesets[0].first_gid, 1);
    assert_eq!(reparsed.get_tile(0, 0, 0), 1);
    assert_eq!(reparsed.get_tile(0, 2, 2), 2);
    assert_eq!(reparsed.layers.len(), 2);

    // The schema the game's continuity tooling already reads must accept our output.
    let value: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(bixel_core::map_validate::tile_layers(&value).len(), 1);
    let meta = bixel_core::map_validate::tileset_meta(&value, "assets/maps/m.json", std::path::Path::new("/tmp"))
        .expect("tileset_meta must resolve the embedded tileset");
    assert_eq!(meta["name"], "tiles");
    assert_eq!(meta["firstgid"], 1);
    assert_eq!(meta["columns"], 2);
}

#[test]
fn json_round_trip_preserves_unknown_fields() {
    let json = r##"{
        "type": "map",
        "version": "1.10",
        "orientation": "orthogonal",
        "renderorder": "right-down",
        "infinite": false,
        "width": 3,
        "height": 2,
        "tilewidth": 16,
        "tileheight": 16,
        "nextlayerid": 4,
        "nextobjectid": 7,
        "compressionlevel": -1,
        "backgroundColor": "#33223333",
        "tilesets": [
            {
                "firstgid": 1,
                "name": "terrain",
                "image": "../tiles.png",
                "imagewidth": 48,
                "imageheight": 16,
                "tilewidth": 16,
                "tileheight": 16,
                "columns": 3,
                "tilecount": 3,
                "tileoffset": {"x": 0, "y": 4}
            }
        ],
        "layers": [
            {
                "id": 1,
                "name": "ground",
                "type": "tilelayer",
                "width": 3,
                "height": 2,
                "x": 0,
                "y": 0,
                "visible": true,
                "opacity": 1,
                "startx": 1,
                "data": [1, 2, 3, 0, 1, 2]
            },
            {
                "id": 2,
                "name": "objects",
                "type": "objectgroup",
                "draworder": "topdown",
                "visible": true,
                "opacity": 1,
                "objects": [
                    {"id": 5, "name": "door_a", "type": "door", "x": 16, "y": 0, "width": 16, "height": 32,
                     "rotation": 90, "properties": [{"name": "target", "type": "string", "value": "shop"}]}
                ]
            }
        ]
    }"##;
    let map = TileMap::from_tiled_json(json).expect("parse a real-Tiled-style file");
    assert_eq!(map.next_object_id, 7);
    // Custom/unknown map keys round-trip.
    let text = map.to_tiled_json().unwrap();
    let value: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["backgroundColor"], "#33223333");
    assert_eq!(value["compressionlevel"], -1);
    assert!(value["tilesets"][0]["tileoffset"].is_object());
    // Layer-level unknown fields survive.
    assert_eq!(value["layers"][0]["startx"], 1);
    // Object properties survive.
    assert_eq!(value["layers"][1]["objects"][0]["properties"][0]["value"], "shop");
    assert_eq!(value["layers"][1]["objects"][0]["rotation"], 90);
    // Tile data matches.
    assert_eq!(value["layers"][0]["data"][0], 1);
    assert_eq!(map.get_tile(0, 2, 1), 2);
}

#[test]
fn csv_string_data_loading() {
    let json = r#"{
        "type": "map", "version": "1.10", "orientation": "orthogonal",
        "infinite": false, "width": 2, "height": 2,
        "tilewidth": 16, "tileheight": 16,
        "nextlayerid": 2, "nextobjectid": 1,
        "tilesets": [],
        "layers": [{
            "id": 1, "name": "ground", "type": "tilelayer",
            "width": 2, "height": 2, "visible": true, "opacity": 1,
            "data": "1,2,\n3,4,\n"
        }]
    }"#;
    let map = TileMap::from_tiled_json(json).unwrap();
    assert_eq!(map.get_tile(0, 0, 0), 1);
    assert_eq!(map.get_tile(0, 1, 0), 2);
    assert_eq!(map.get_tile(0, 0, 1), 3);
    assert_eq!(map.get_tile(0, 1, 1), 4);
}

#[test]
fn resize_regrids_all_layers() {
    let mut map = map_with_sheet();
    map.set_tile(0, 3, 3, 1);
    let l2 = map.add_tile_layer(None);
    map.set_tile(l2, 1, 1, 2);
    map.resize(6, 5);
    assert_eq!((map.width, map.height), (6, 5));
    assert_eq!(map.get_tile(0, 3, 3), 1); // preserved anchor
    assert_eq!(map.get_tile(l2, 1, 1), 2);
    assert_eq!(map.get_tile(0, 5, 4), 0); // freshly extended
    map.resize(2, 2);
    assert_eq!((map.width, map.height), (2, 2));
    assert_eq!(map.get_tile(0, 0, 0), 0); // cropped region is gone
}

#[test]
fn object_editing_lifecycle() {
    let mut map = map_with_sheet();
    let layer = map.add_object_layer(Some("collisions"));
    let id = map.add_object(layer, "wall", "rect", 16.0, 32.0, 16.0, 16.0).unwrap();
    let _ = map.add_object(layer, "", "point", 4.0, 4.0, 0.0, 0.0).unwrap();
    assert_eq!(map.object_layer(layer).unwrap().objects.len(), 2);

    assert!(map.set_object(layer, id, "door_a", "door", 10.0, 20.0, 32.0, 48.0));
    let objs = map.object_layer(layer).unwrap();
    let door = objs.objects.iter().find(|o| o.id == id).unwrap();
    assert_eq!(door.name, "door_a");
    assert_eq!((door.x, door.y, door.width, door.height), (10.0, 20.0, 32.0, 48.0));

    assert!(map.remove_object(layer, id));
    assert_eq!(map.object_layer(layer).unwrap().objects.len(), 1);

    // Objects survive a JSON round trip.
    map.add_object(layer, "tree", "deco", 0.0, 0.0, 16.0, 16.0);
    let text = map.to_tiled_json().unwrap();
    let back = TileMap::from_tiled_json(&text).unwrap();
    let obj_layer = back.layers.iter().position(|l| l.is_objects()).unwrap();
    assert_eq!(back.object_layer(obj_layer).unwrap().objects.len(), 2);
}

#[test]
fn properties_on_nodes_round_trip() {
    let mut map = map_with_sheet();
    map.set_properties(
        0,
        None,
        None,
        vec![bixel_core::map::Property::new("theme", serde_json::json!("forest"))],
    );
    let l2 = map.add_tile_layer(None);
    map.set_properties(
        1,
        Some(l2),
        None,
        vec![bixel_core::map::Property::new("renderMode", serde_json::json!("depth"))],
    );
    assert_eq!(map.layer_properties(l2).unwrap()[0].name, "renderMode");

    let text = map.to_tiled_json().unwrap();
    let value: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["properties"][0]["value"], "forest");
    assert_eq!(value["layers"][1]["properties"][0]["name"], "renderMode");
}

#[test]
fn autotile_slot_paint_resolves_edges() {
    let mut map = map_with_sheet();
    // Assign the four cardinal-blend slots using the two known tiles plus the
    // red tile for every full-mask variant.
    let idx = 0;
    map.set_autotile(idx, 0, Some(0));
    map.set_autotile(idx, 15, Some(0));
    map.set_autotile(idx, 1, Some(1));
    map.set_autotile(idx, 2, Some(1));
    map.set_autotile(idx, 4, Some(1));
    map.set_autotile(idx, 8, Some(1));
    assert_eq!(map.autotile_slots(idx).len(), 16);

    // Paint a 2×2 ground block of the red tile then autotile it.
    for (dy, dx) in [(0usize, 0usize), (0, 1), (1, 0), (1, 1)] {
        map.set_tile(0, dx as isize, dy as isize, 1);
    }
    let changed = map.autotile(0, idx, 0, 0, 2, 2);
    assert!(changed >= 0);
    // Top-left cell (0,0) has ground only to the east and south → mask = E|S = 6.
    // With slots 1/2/4/8 mapping to tile 2 (green), mask 6 has no slot → stays 1.
    // This mainly guards that autotile ran without panicking; flip-flags kept.
    assert_eq!(map.get_tile(0, 0, 0) & 0x1fff_ffff, 1);
}

#[test]
fn wand_mask_finds_same_tile_region() {
    let mut map = map_with_sheet();
    for (x, y) in [(0, 0), (1, 0), (0, 1)] {
        map.set_tile(0, x, y, 1);
    }
    map.set_tile(0, 2, 0, 2);
    let mut mask = vec![0u8; 4 * 4];
    let count = map.wand_mask(0, 0, 0, &mut mask);
    assert_eq!(count, 3);
    assert_eq!(mask[0], 1);
    assert_eq!(mask[1], 1);
    assert_eq!(mask[4], 1);
    assert_eq!(mask[2], 0);
}

#[test]
fn removing_tileset_remaps_later_gids() {
    let mut map = map_with_sheet(); // tileset 0: 4 tiles (2x2), first_gid = 1
    let (px, w, h) = two_tile_sheet();
    map.add_tileset("b", "assets/b.png", w, h, 16, 16, 0, 0).unwrap(); // tileset 1: first_gid = 5
    map.set_tileset_pixels(1, &px);

    // Cell 0 references tileset 1 local 1 (gid 6) with an H flip.
    map.set_tile(0, 0, 0, TileMap::encode_gid(1, 5, GID_H_FLIP));
    // Cell 1 references tileset 0 local 0 (gid 1).
    map.set_tile(0, 1, 0, 1);
    assert_eq!(map.gid_lookup(map.get_tile(0, 0, 0)).unwrap(), (1, 1, GID_H_FLIP));

    // Removing the first tileset must shift the later tileset down and keep
    // its cells pointing at the same artwork (including flip flags).
    assert!(map.remove_tileset(0));
    assert_eq!(map.tilesets.len(), 1);
    assert_eq!(map.tilesets[0].first_gid, 1);
    let remapped = map.get_tile(0, 0, 0);
    assert_eq!(map.gid_lookup(remapped).unwrap(), (0, 1, GID_H_FLIP));
    // The removed tileset's cells are cleared.
    assert_eq!(map.get_tile(0, 1, 0), 0);
}

#[test]
fn oversized_dimensions_are_rejected_on_load() {
    let json = format!(
        r#"{{"type":"map","version":"1.10","orientation":"orthogonal","infinite":false,
        "width":{}, "height":2,"tilewidth":16,"tileheight":16,"nextlayerid":1,"nextobjectid":1,
        "tilesets":[],"layers":[]}}"#,
        MAX_MAP_DIM + 1
    );
    assert!(TileMap::from_tiled_json(&json).is_err());
}
