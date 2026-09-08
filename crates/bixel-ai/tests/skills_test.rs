use bixel_ai::image::RgbaImage;
use bixel_ai::skills::{ModelRole, SkillInput, SkillKind, SkillOutput, Skills};

#[test]
fn all_skills_have_metadata() {
    let specs = Skills::specs();
    assert_eq!(specs.len(), 19);
    for spec in &specs {
        assert!(!spec.id.is_empty());
        assert!(!spec.name.is_empty());
        assert!(!spec.description.is_empty());
        assert!(spec.params_schema.is_object());
    }
}

#[test]
fn skill_ids_are_unique_and_roundtrip() {
    let specs = Skills::specs();
    let mut ids: Vec<String> = specs.iter().map(|s| s.id.clone()).collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), specs.len());
    for spec in &specs {
        assert_eq!(SkillKind::from_id(&spec.id).unwrap().to_string(), spec.id);
    }
}

#[test]
fn deterministic_skills_are_local() {
    let compress = Skills::spec(SkillKind::Compress);
    let bg = Skills::spec(SkillKind::RemoveBackground);
    assert_eq!(compress.model, ModelRole::None);
    assert_eq!(bg.model, ModelRole::None);
    for kind in SkillKind::all() {
        if kind.is_deterministic() {
            assert_eq!(Skills::spec(kind).model, ModelRole::None);
        }
    }
}

#[test]
fn model_skills_need_a_model() {
    assert_eq!(Skills::spec(SkillKind::GenerateArt).model, ModelRole::Image);
    assert_eq!(Skills::spec(SkillKind::Spritesheet).model, ModelRole::Image);
    assert_eq!(Skills::spec(SkillKind::NextFrame).model, ModelRole::Image);
    assert_eq!(Skills::spec(SkillKind::PixelImageGen).model, ModelRole::Image);
}

#[test]
fn compress_skill_runs_locally() {
    let mut img = RgbaImage::new(4, 4);
    for y in 0..4 {
        for x in 0..4 {
            img.set_pixel(x, y, [(x * 60) as u8, (y * 60) as u8, 200, 255]);
        }
    }
    let input = SkillInput {
        image: Some(img),
        params: serde_json::json!({ "bits": 2 }),
        ..Default::default()
    };
    let out = Skills::run(None, SkillKind::Compress, input).unwrap();
    assert!(out.image.is_some());
    assert!(out.text.contains("2-bit"));
}

#[test]
fn remove_background_skill_runs_locally() {
    let mut img = RgbaImage::new(4, 4);
    for y in 0..4 {
        for x in 0..4 {
            img.set_pixel(x, y, [0, 255, 0, 255]);
        }
    }
    img.set_pixel(1, 1, [255, 0, 0, 255]);
    let input = SkillInput {
        image: Some(img),
        params: serde_json::json!({ "tolerance": 16 }),
        ..Default::default()
    };
    let out = Skills::run(None, SkillKind::RemoveBackground, input).unwrap();
    assert!(out.image.is_some());
    assert_eq!(out.image.unwrap().pixel(0, 0)[3], 0);
}

#[test]
fn skill_ids_are_stable() {
    assert_eq!(SkillKind::GenerateArt.to_string(), "generate_art");
    assert_eq!(SkillKind::Spritesheet.to_string(), "spritesheet");
    assert_eq!(SkillKind::NextFrame.to_string(), "next_frame");
    assert_eq!(SkillKind::Compress.to_string(), "compress");
    assert_eq!(SkillKind::RemoveBackground.to_string(), "remove_background");
    assert_eq!(SkillKind::PixelImageGen.to_string(), "pixel_image_gen");
    assert_eq!(SkillKind::PixelReduceColors.to_string(), "pixel_reduce_colors");
    assert_eq!(SkillKind::PixelEightDirCharacter.to_string(), "pixel_8dir_character");
}

#[test]
fn reduce_colors_skill_runs_locally() {
    let mut img = RgbaImage::new(4, 4);
    for y in 0..4 {
        for x in 0..4 {
            img.set_pixel(x, y, [(x * 60) as u8, (y * 60) as u8, 200, 255]);
        }
    }
    let input = SkillInput {
        image: Some(img),
        params: serde_json::json!({ "colors": 4 }),
        ..Default::default()
    };
    let out = Skills::run(None, SkillKind::PixelReduceColors, input).unwrap();
    assert!(out.image.is_some());
}

#[test]
fn ui_slice_skill_returns_frames() {
    let mut img = RgbaImage::new(16, 8);
    img.set_pixel(1, 1, [255, 0, 0, 255]);
    img.set_pixel(2, 1, [255, 0, 0, 255]);
    img.set_pixel(10, 5, [0, 255, 0, 255]);
    let input = SkillInput {
        image: Some(img),
        params: serde_json::json!({ "min_area": 1, "dilate": 0, "pad": 0 }),
        ..Default::default()
    };
    let out = Skills::run(None, SkillKind::PixelGameUiGen, input).unwrap();
    assert_eq!(out.frames.len(), 2);
}

#[test]
fn output_to_json_encodes_image() {
    let mut img = RgbaImage::new(2, 2);
    img.set_pixel(0, 0, [255, 0, 0, 255]);
    let out = SkillOutput { image: Some(img), ..Default::default() };
    let json = bixel_ai::skills::skill_output_to_json(&out);
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert!(value["image"].is_string());
}
