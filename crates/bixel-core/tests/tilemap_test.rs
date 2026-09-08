use bixel_core::tilemap::*;

#[test]
fn set_tile_returns_change() {
    let mut layer = TileLayer::new(4, 4);
    assert!(set_tile(&mut layer, 1, 1, 7));
    assert_eq!(get_tile(&layer, 1, 1), 7);
    assert!(!set_tile(&mut layer, 1, 1, 7));
    assert!(set_tile(&mut layer, 1, 1, 8));
}

#[test]
fn out_of_bounds_is_zero_and_unsettable() {
    let mut layer = TileLayer::new(4, 4);
    assert_eq!(get_tile(&layer, -1, 0), 0);
    assert_eq!(get_tile(&layer, 4, 0), 0);
    assert!(!set_tile(&mut layer, 4, 0, 3));
}

#[test]
fn paint_rect_returns_indices() {
    let mut layer = TileLayer::new(4, 4);
    let changed = paint_rect(&mut layer, 0, 0, 1, 1, 5);
    assert_eq!(changed.len(), 4);
    assert_eq!(get_tile(&layer, 0, 0), 5);
    assert_eq!(get_tile(&layer, 1, 1), 5);
    assert_eq!(get_tile(&layer, 2, 2), 0);
}

#[test]
fn flood_fill_connected_region() {
    let mut layer = TileLayer::new(4, 4);
    for x in 0..4 {
        set_tile(&mut layer, x, 0, 1);
    }
    let changed = flood_fill(&mut layer, 0, 0, 9);
    assert_eq!(changed.len(), 4);
    assert_eq!(get_tile(&layer, 3, 0), 9);
    assert_eq!(get_tile(&layer, 0, 1), 0);
}

#[test]
fn line_cells_supercover() {
    let a = Cell { x: 0, y: 0 };
    let b = Cell { x: 3, y: 0 };
    let pts = line_cells(a, b);
    assert_eq!(pts.len(), 4);
    assert_eq!(pts[0], Cell { x: 0, y: 0 });
    assert_eq!(pts[3], Cell { x: 3, y: 0 });
}

#[test]
fn pattern_flip_and_rotate() {
    // 2x2 pattern
    let p = Pattern { w: 2, h: 2, tiles: vec![1, 2, 3, 4] };
    let h = flip_pattern_h(&p);
    assert_eq!(h.tiles, vec![2, 1, 4, 3]);
    let v = flip_pattern_v(&p);
    assert_eq!(v.tiles, vec![3, 4, 1, 2]);
    let cw = rotate_pattern_cw(&p);
    assert_eq!(cw.tiles, vec![3, 1, 4, 2]);
}

#[test]
fn write_region_skips_empty() {
    let mut layer = TileLayer::new(4, 4);
    let p = Pattern { w: 2, h: 2, tiles: vec![0, 5, 0, 6] };
    let changed = write_region(&mut layer, 0, 0, &p, true);
    assert_eq!(changed.len(), 2);
    assert_eq!(get_tile(&layer, 1, 0), 5);
    assert_eq!(get_tile(&layer, 1, 1), 6);
    assert_eq!(get_tile(&layer, 0, 0), 0);
}

#[test]
fn terrain_mask_bits() {
    let layer = TileLayer::new(4, 4);
    // all four neighbours present
    let mask = terrain_mask(1, 1, |x, y| {
        in_layer(&layer, x, y) && (x != 1 || y != 1)
    });
    assert_eq!(mask, 15);
}

#[test]
fn mask_to_index_wraps() {
    assert_eq!(mask_to_index(15, 16), 15);
    assert_eq!(mask_to_index(15, 8), 7);
    assert_eq!(mask_to_index(0, 0), 0);
}

#[test]
fn replace_tiles_matches_set() {
    let mut layer = TileLayer::new(4, 4);
    paint_rect(&mut layer, 0, 0, 3, 0, 1);
    set_tile(&mut layer, 2, 0, 2);
    let changed = replace_tiles(
        &mut layer,
        Rect { x0: 0, y0: 0, x1: 3, y1: 0 },
        &[1, 2],
        9,
    );
    assert_eq!(changed.len(), 4);
    assert_eq!(get_tile(&layer, 0, 0), 9);
}

#[test]
fn minimap_projection_roundtrip() {
    let scale = mini_scale(100, 100, 50, 50, 8);
    let (ox, oy) = mini_origin(100, 100, scale, 50, 50);
    let (mx, my) = map_from_mini(10.0, 10.0, scale, ox, oy);
    let (rx, ry) = mini_from_map(mx, my, scale, ox, oy);
    assert!((rx - 10.0).abs() < 1e-9);
    assert!((ry - 10.0).abs() < 1e-9);
}
