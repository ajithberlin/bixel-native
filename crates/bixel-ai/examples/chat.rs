use bixel_ai::image_gen::ImageGen;
use bixel_ai::AiSettings;

fn main() {
    let settings = AiSettings::from_env_file();
    println!("image model: {}", settings.image_model);
    let gen = ImageGen::new(&settings.base_url, &settings.api_key, &settings.image_model);
    match gen.generate_image("a tiny red pixel-art heart on white background", None) {
        Ok(img) => println!("IMAGE OK: {}x{}", img.width, img.height),
        Err(e) => println!("IMAGE ERROR: {e}"),
    }
}
