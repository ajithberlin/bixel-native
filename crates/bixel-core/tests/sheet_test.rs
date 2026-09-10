use bixel_core::document::AsepriteDoc;
use bixel_core::sheet::{SheetPlan, SheetSource};

/// Build a 4x2 sheet of 2x2 cells; each cell is filled with a distinct color.
fn sheet_fixture() -> Vec<u8> {
    let (w, h) = (4usize, 2usize);
    let mut data = vec![0u8; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) * 4;
            data[i] = (x * 60) as u8;
            data[i + 1] = (y * 120) as u8;
            data[i + 2] = 10;
            data[i + 3] = 255;
        }
    }
    data
}

#[test]
fn from_sheet_builds_frames_and_tags() {
    let data = sheet_fixture();
    let manifest = serde_json::json!({
        "size": {"w": 4, "h": 2},
        "cell": {"w": 2, "h": 2},
        "actions": {
            "idle": {"frames": [{"x":0,"y":0,"w":2,"h":2,"duration":100}]},
            "walk": {"frames": [{"x":2,"y":0,"w":2,"h":2,"duration":80},
                                 {"x":0,"y":0,"w":2,"h":2,"duration":80}]}
        }
    });
    let plan = SheetPlan::from_json(&manifest, 4, 2).unwrap();
    assert_eq!(plan.source, SheetSource::Atlas);

    let doc = AsepriteDoc::from_sheet(&data, 4, 2, &plan, "Hero").unwrap();
    assert_eq!((doc.width, doc.height), (2, 2));
    assert_eq!(doc.frames.len(), 3);
    assert_eq!(doc.frames[0].duration_ms, 100);
    assert_eq!(doc.frames[1].duration_ms, 80);
    assert_eq!(doc.layers.len(), 1);
    assert_eq!(doc.layers[0].name, "Hero");
    assert_eq!(doc.tags.len(), 2);
    assert_eq!((doc.tags[0].name.as_str(), doc.tags[0].from, doc.tags[0].to), ("idle", 0, 0));
    assert_eq!((doc.tags[1].name.as_str(), doc.tags[1].from, doc.tags[1].to), ("walk", 1, 2));

    // Frame 1 crops the cell at x=2 (r=120) rather than x=0.
    let px = doc.get_pixel(0, 1, 0, 0);
    assert_eq!(px.r, 120);
}

#[test]
fn bixel_export_round_trips_frame_count() {
    // A 2-frame 2x2 document packed into a 2x1 sheet.
    let mut source = AsepriteDoc::new(2, 2, &[]);
    source.set_pixel(0, 0, 0, 0, bixel_core::color::Rgba::new(255, 0, 0, 255));
    source.add_frame(200);
    source.set_pixel(0, 1, 1, 1, bixel_core::color::Rgba::new(0, 255, 0, 255));
    let (sheet, sw, sh) = source.pack_frames(2).unwrap();

    let manifest = serde_json::json!({
        "frame_width": 2, "frame_height": 2, "columns": 2,
        "frames": [
            {"x":0,"y":0,"width":2,"height":2,"duration_ms":125},
            {"x":2,"y":0,"width":2,"height":2,"duration_ms":200}
        ]
    });
    let plan = SheetPlan::from_json(&manifest, sw as u32, sh as u32).unwrap();
    let restored = AsepriteDoc::from_sheet(&sheet, sw, sh, &plan, "Layer 1").unwrap();
    assert_eq!(restored.frames.len(), 2);
    assert_eq!(restored.frames[1].duration_ms, 200);
    assert_eq!(
        restored.get_pixel(0, 0, 0, 0),
        bixel_core::color::Rgba::new(255, 0, 0, 255)
    );
}

#[test]
fn append_sheet_frames_preserves_canvas_and_offsets_tags() {
    let data = sheet_fixture();
    let plan = SheetPlan::from_json(&serde_json::json!({"cell": {"w": 2, "h": 2}}), 4, 2).unwrap();

    let mut doc = AsepriteDoc::new(2, 2, &[]);
    doc.set_pixel(0, 0, 0, 0, bixel_core::color::Rgba::new(9, 9, 9, 255));
    let report = doc.append_sheet_frames(&data, 4, 2, &plan, "Imported", false).unwrap();
    assert_eq!(report.first_frame, 1);
    assert_eq!(report.frames_added, 2);
    assert_eq!(doc.frames.len(), 3);
    assert_eq!(doc.layers.len(), 2);
    // Original content survives on layer 0.
    assert_eq!(doc.get_pixel(0, 0, 0, 0).r, 9);
}

#[test]
fn append_sheet_frames_replace_clears_prior_frames() {
    let data = sheet_fixture();
    let plan = SheetPlan::from_json(&serde_json::json!({"cell": {"w": 2, "h": 2}}), 4, 2).unwrap();

    let mut doc = AsepriteDoc::new(2, 2, &[]);
    doc.add_frame(125);
    assert_eq!(doc.frames.len(), 2);
    let report = doc.append_sheet_frames(&data, 4, 2, &plan, "Imported", true).unwrap();
    assert_eq!(report.first_frame, 0);
    assert_eq!(doc.frames.len(), 2);
}
