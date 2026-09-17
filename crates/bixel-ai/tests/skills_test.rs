use std::sync::{Arc, Mutex};

use bixel_ai::error::AiError;
use bixel_ai::image::RgbaImage;
use bixel_ai::image_gen::{ImageGenerationOptions, ImageGenerator};
use bixel_ai::skills::{ModelRole, SkillInput, SkillKind, SkillOutput, Skills};

#[derive(Clone, Default)]
struct RecordingGenerator {
    prompt: Arc<Mutex<String>>,
    reference_seen: Arc<Mutex<bool>>,
    options: Arc<Mutex<Vec<ImageGenerationOptions>>>,
}

impl ImageGenerator for RecordingGenerator {
    fn model(&self) -> &str {
        "test-image-backend"
    }

    fn generate_image(
        &self,
        prompt: &str,
        input: Option<&RgbaImage>,
    ) -> Result<RgbaImage, AiError> {
        *self.prompt.lock().unwrap() = prompt.to_string();
        *self.reference_seen.lock().unwrap() = input.is_some();
        Ok(RgbaImage::new(8, 8))
    }

    fn generate_image_with_options(
        &self,
        prompt: &str,
        input: Option<&RgbaImage>,
        options: ImageGenerationOptions,
    ) -> Result<RgbaImage, AiError> {
        self.options.lock().unwrap().push(options);
        self.generate_image(prompt, input)
    }
}

#[test]
fn only_provider_image_skills_remain() {
    // Deterministic/local skills now live as bundled goose SKILL.md packages,
    // so the Rust registry is exactly the provider-backed image skills.
    assert_eq!(Skills::specs().len(), 5);
    for kind in SkillKind::all() {
        assert_eq!(Skills::spec(kind).model, ModelRole::Image);
    }
}

#[test]
fn all_skills_have_metadata() {
    let specs = Skills::specs();
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
fn model_skills_need_a_model() {
    assert_eq!(Skills::spec(SkillKind::ImageGen).model, ModelRole::Image);
    assert_eq!(Skills::spec(SkillKind::GenerateArt).model, ModelRole::Image);
    assert_eq!(Skills::spec(SkillKind::Spritesheet).model, ModelRole::Image);
    assert_eq!(Skills::spec(SkillKind::NextFrame).model, ModelRole::Image);
    assert_eq!(
        Skills::spec(SkillKind::PixelImageGen).model,
        ModelRole::Image
    );
}

#[test]
fn skill_ids_are_stable() {
    assert_eq!(SkillKind::GenerateArt.to_string(), "generate_art");
    assert_eq!(SkillKind::ImageGen.to_string(), "image_gen");
    assert_eq!(SkillKind::Spritesheet.to_string(), "spritesheet");
    assert_eq!(SkillKind::NextFrame.to_string(), "next_frame");
    assert_eq!(SkillKind::PixelImageGen.to_string(), "pixel_image_gen");
}

#[test]
fn removed_local_skills_no_longer_resolve() {
    assert!(SkillKind::from_id("compress").is_none());
    assert!(SkillKind::from_id("remove_background").is_none());
    assert!(SkillKind::from_id("pixel_reduce_colors").is_none());
    assert!(SkillKind::from_id("import_spritesheet").is_none());
}

#[test]
fn image_gen_skill_uses_the_configured_image_backend() {
    let generator = RecordingGenerator::default();
    let prompt = generator.prompt.clone();
    let input = SkillInput {
        prompt: "a red fox in a moonlit forest".into(),
        params: serde_json::json!({"transparent": false}),
        ..Default::default()
    };
    let output = Skills::run(Some(&generator), SkillKind::ImageGen, input).unwrap();
    assert!(output.image.is_some());
    assert!(prompt
        .lock()
        .unwrap()
        .contains("a red fox in a moonlit forest"));
    assert!(!*generator.reference_seen.lock().unwrap());
}

#[test]
fn transparent_image_skill_requests_an_alpha_capable_background() {
    let generator = RecordingGenerator::default();
    let input = SkillInput {
        prompt: "a red fox sprite with no background".into(),
        params: serde_json::json!({"transparent": true}),
        ..Default::default()
    };

    Skills::run(Some(&generator), SkillKind::PixelImageGen, input).unwrap();

    assert_eq!(
        generator.options.lock().unwrap().as_slice(),
        &[ImageGenerationOptions {
            transparent_background: true
        }]
    );
}

#[test]
fn general_image_skill_infers_transparency_from_a_no_background_prompt() {
    let generator = RecordingGenerator::default();
    let input = SkillInput {
        prompt: "create an isolated icon with no background".into(),
        params: serde_json::json!({}),
        ..Default::default()
    };

    Skills::run(Some(&generator), SkillKind::ImageGen, input).unwrap();

    assert_eq!(
        generator.options.lock().unwrap().as_slice(),
        &[ImageGenerationOptions {
            transparent_background: true
        }]
    );
}

#[test]
fn next_frame_conditions_on_source_and_matches_its_size() {
    let generator = RecordingGenerator::default();
    let prompt = generator.prompt.clone();
    let mut current = RgbaImage::new(4, 6);
    current.set_pixel(1, 1, [200, 30, 30, 255]);
    let input = SkillInput {
        image: Some(current),
        params: serde_json::json!({ "action": "swing the sword" }),
        ..Default::default()
    };
    let output = Skills::run(Some(&generator), SkillKind::NextFrame, input).unwrap();
    assert!(
        *generator.reference_seen.lock().unwrap(),
        "must send the current frame as the edit reference"
    );
    let text = prompt.lock().unwrap().clone();
    assert!(text.contains("swing the sword"));
    assert!(text.contains("NEXT frame"));
    // The stub returns 8x8, so this also proves the output is fitted back to the source frame.
    let image = output.image.unwrap();
    assert_eq!((image.width, image.height), (4, 6));
}

#[test]
fn next_frame_prompt_can_opt_opaque_source_into_transparency() {
    let generator = RecordingGenerator::default();
    let input = SkillInput {
        prompt: "continue the walk with no background".into(),
        image: Some(RgbaImage::from_rgba(8, 8, vec![255; 8 * 8 * 4])),
        params: serde_json::json!({}),
        ..Default::default()
    };

    Skills::run(Some(&generator), SkillKind::NextFrame, input).unwrap();

    assert_eq!(
        generator.options.lock().unwrap().as_slice(),
        &[ImageGenerationOptions {
            transparent_background: true
        }]
    );
}

#[test]
fn output_to_json_encodes_image() {
    let mut img = RgbaImage::new(2, 2);
    img.set_pixel(0, 0, [255, 0, 0, 255]);
    let out = SkillOutput {
        image: Some(img),
        ..Default::default()
    };
    let json = bixel_ai::skills::skill_output_to_json(&out);
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert!(value["image"].is_string());
}
