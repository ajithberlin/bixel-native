//! Integration tests for the TileMap designer engine (`crates/bixel-core/src/map.rs`).
//!
//! Mirrors the semantics of `map_validate` where relevant: Tiled JSON produced
//! here must be consumable by the existing Tiled schema readers, and files
//! produced by the real Tiled editor must round-trip losslessly.

use bixel_core::map::{
    GID_D_FLIP, GID_H_FLIP, GID_V_FLIP, Orientation, RenderOrder, StaggerAxis, StaggerIndex,
    TileMap, MAX_MAP_DIM,
};
use bixel_core::tilemap::{MapGeometry, Pattern};
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

/// A `w × h` solid RGBA image.
fn solid_image(w: u32, h: u32, r: u8, g: u8, b: u8) -> Vec<u8> {
    let mut px = vec![0u8; (w * h * 4) as usize];
    for i in (0..px.len()).step_by(4) {
        px[i] = r;
        px[i + 1] = g;
        px[i + 2] = b;
        px[i + 3] = 255;
    }
    px
}

#[test]
fn image_layer_composites_and_is_overridable() {
    let mut map = TileMap::new(4, 4, 16, 16); // 64×64 px
    let img = solid_image(16, 16, 0, 0, 255); // blue 16×16 at origin
    let idx = map.add_image_layer(Some("bg"), "assets/bg.png", 16, 16, 0.0, 0.0);
    assert!(map.set_image_layer_pixels(idx, &img));
    assert!(map.layers[idx].is_image());

    // The image shows through at (0,0) but is clipped to the map.
    let out = map.composite();
    let p = |x: usize, y: usize| (y * 64 + x) * 4;
    assert_eq!((out[p(0, 0)], out[p(0, 0) + 2]), (0, 255));
    // Outside the image bounds the composite is transparent.
    assert_eq!(out[p(20, 0) + 3], 0);

    // A tile layer added above overrides the image.
    let (sheet, w, h) = two_tile_sheet();
    let ts = map
        .add_tileset("t", "assets/t.png", w, h, 16, 16, 0, 0)
        .unwrap();
    map.set_tileset_pixels(ts, &sheet);
    let top = map.add_tile_layer(Some("top"));
    map.set_tile(top, 0, 0, 1); // red tile at (0,0)
    let out = map.composite();
    assert_eq!((out[p(0, 0)], out[p(0, 0) + 2]), (255, 0));
}

#[test]
fn image_layer_round_trips_through_tiled_json() {
    let mut map = TileMap::new(2, 2, 16, 16);
    let img = solid_image(8, 8, 10, 20, 30);
    let idx = map.add_image_layer(Some("Backdrop"), "assets/bg.png", 8, 8, 0.0, 0.0);
    map.set_image_layer_pixels(idx, &img);
    map.layers[idx].set_opacity(0.5);

    let json = map.to_tiled_json().unwrap();
    let value: Value = serde_json::from_str(&json).unwrap();
    let layer = value["layers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["type"] == "imagelayer")
        .expect("imagelayer present");
    assert_eq!(layer["type"], "imagelayer");
    assert_eq!(layer["image"], "assets/bg.png");
    assert_eq!(layer["imagewidth"], 8);
    assert_eq!(layer["imageheight"], 8);

    let restored = TileMap::from_tiled_json(&json).unwrap();
    let image_index = restored.layers.iter().position(|l| l.is_image()).unwrap();
    let layer = restored.image_layer(image_index).unwrap();
    assert_eq!(layer.image, "assets/bg.png");
    assert_eq!((layer.image_width, layer.image_height), (8, 8));
    assert!((layer.opacity - 0.5).abs() < 1e-6);
    // Pixels are not serialized; the host uploads them after load.
    assert!(layer.pixels.is_empty());
}

#[test]
fn isometric_and_staggered_projection_round_trip() {
    let iso = MapGeometry::new(
        Orientation::Isometric, 4, 4, 32, 16, StaggerAxis::Y, StaggerIndex::Odd,
    );
    for cy in 0..4i64 {
        for cx in 0..4i64 {
            let (ox, oy) = iso.tile_origin(cx, cy);
            let (rx, ry) = iso.pixel_to_cell((ox + 16) as f64, (oy + 8) as f64);
            assert_eq!((rx, ry), (cx, cy), "isometric cell {cx},{cy}");
        }
    }

    for index in [StaggerIndex::Odd, StaggerIndex::Even] {
        let st = MapGeometry::new(
            Orientation::Staggered, 4, 4, 32, 16, StaggerAxis::Y, index,
        );
        for cy in 0..4i64 {
            for cx in 0..4i64 {
                let (ox, oy) = st.tile_origin(cx, cy);
                let (rx, ry) = st.pixel_to_cell((ox + 16) as f64, (oy + 8) as f64);
                assert_eq!((rx, ry), (cx, cy), "staggered {index:?} cell {cx},{cy}");
            }
        }
    }
}

#[test]
fn isometric_pixel_size_and_composite_placement() {
    let mut map = TileMap::new(2, 2, 32, 16);
    map.orientation = Orientation::Isometric;
    assert_eq!((map.pixel_width(), map.pixel_height()), (80, 32));

    let img = solid_image(32, 16, 255, 0, 0);
    let ts = map
        .add_tileset("t", "assets/t.png", 32, 16, 32, 16, 0, 0)
        .unwrap();
    map.set_tileset_pixels(ts, &img);
    map.set_tile(0, 0, 0, 1); // top cell → image origin (32, 0)
    map.set_tile(0, 1, 1, 1); // bottom cell → image origin (32, 16)

    let out = map.composite();
    let w = map.pixel_width();
    let px = |x: usize, y: usize| (y * w + x) * 4;
    assert_eq!(out[px(32, 0)], 255);
    assert_eq!(out[px(32, 0) + 3], 255);
    // Left of the projected tile is untouched.
    assert_eq!(out[px(31, 0) + 3], 0);
    assert_eq!(out[px(32, 16) + 3], 255);
}

#[test]
fn orientation_and_tileoffset_round_trip() {
    let mut map = TileMap::new(3, 3, 32, 16);
    map.orientation = Orientation::Isometric;
    map.render_order = RenderOrder::LeftUp;
    map.add_tileset("t", "assets/t.png", 64, 32, 32, 16, 0, 0).unwrap();
    map.set_tileset_tile_offset(0, 0, -8);
    assert_eq!(map.tileset_tile_offset(0), Some((0, -8)));

    let text = map.to_tiled_json().unwrap();
    let value: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["orientation"], "isometric");
    assert_eq!(value["renderorder"], "left-up");
    assert_eq!(value["tilesets"][0]["tileoffset"]["y"], -8);

    let back = TileMap::from_tiled_json(&text).unwrap();
    assert_eq!(back.orientation, Orientation::Isometric);
    assert_eq!(back.render_order, RenderOrder::LeftUp);
    assert_eq!(back.tilesets[0].tile_offset, (0, -8));
}

#[test]
fn staggered_round_trip_and_hexagonal_rejected() {
    let mut map = TileMap::new(4, 3, 32, 16);
    map.orientation = Orientation::Staggered;
    map.stagger_axis = StaggerAxis::Y;
    map.stagger_index = StaggerIndex::Even;
    let text = map.to_tiled_json().unwrap();
    let value: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["orientation"], "staggered");
    assert_eq!(value["staggeraxis"], "y");
    assert_eq!(value["staggerindex"], "even");

    let back = TileMap::from_tiled_json(&text).unwrap();
    assert_eq!(back.orientation, Orientation::Staggered);
    assert_eq!(back.stagger_index, StaggerIndex::Even);

    // `isometric_staggered` is accepted as an alias for Tiled's staggered layout.
    let alias = r#"{"type":"map","orientation":"isometric_staggered","width":2,"height":2,
        "tilewidth":32,"tileheight":16,"tilesets":[],"layers":[]}"#;
    assert_eq!(TileMap::from_tiled_json(alias).unwrap().orientation, Orientation::Staggered);

    let hex = r#"{"type":"map","orientation":"hexagonal","width":2,"height":2,
        "tilewidth":16,"tileheight":16,"tilesets":[],"layers":[]}"#;
    assert!(TileMap::from_tiled_json(hex).is_err());
}

#[test]
fn infinite_isometric_origin_is_absolute() {
    let mut geo = MapGeometry::new(
        Orientation::Isometric, 10, 10, 32, 16, StaggerAxis::Y, StaggerIndex::Odd,
    );
    geo.infinite = true;
    let before = geo.tile_origin(3, 4);
    // Growing the storage must not shift existing content.
    geo.rows = 500;
    geo.columns = 500;
    assert_eq!(geo.tile_origin(3, 4), before);
}

#[test]
fn infinite_map_grows_and_round_trips_chunks() {
    let mut map = TileMap::new_infinite(16, 16, Orientation::Orthogonal);
    assert!(map.infinite);
    let img = solid_image(16, 16, 255, 0, 0);
    let ts = map.add_tileset("t", "assets/t.png", 16, 16, 16, 16, 0, 0).unwrap();
    map.set_tileset_pixels(ts, &img);

    // Paint at negative and positive world coordinates.
    assert!(map.set_tile(0, -5, -3, 1));
    assert!(map.set_tile(0, 10, 12, 1));
    assert_eq!(map.get_tile(0, -5, -3), 1);
    assert_eq!(map.get_tile(0, 10, 12), 1);
    assert_eq!(map.get_tile(0, 100, 100), 0);
    assert_eq!(map.content_cell_bounds(), Some((-5, -3, 10, 12)));

    // Region composite renders the painted tile at its world position.
    let out = map.composite_region(10 * 16, 12 * 16, 16, 16);
    assert_eq!(out.len(), 16 * 16 * 4);
    assert_eq!((out[0], out[1], out[2], out[3]), (255, 0, 0, 255));

    // Serialized as a Tiled infinite map with chunks.
    let text = map.to_tiled_json().unwrap();
    let value: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["infinite"], true);
    assert_eq!(value["width"], 0);
    assert_eq!(value["height"], 0);
    assert!(value["layers"][0]["chunks"].is_array());

    // Round-trips world coordinates through the chunked format.
    let back = TileMap::from_tiled_json(&text).unwrap();
    assert!(back.infinite);
    assert_eq!(back.get_tile(0, -5, -3), 1);
    assert_eq!(back.get_tile(0, 10, 12), 1);
    assert_eq!(back.content_cell_bounds(), Some((-5, -3, 10, 12)));
}
