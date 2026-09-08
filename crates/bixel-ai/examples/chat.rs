use bixel_ai::{AiSettings, Engine};

fn main() {
    let settings = AiSettings::from_env_file();
    println!("image model: {}", settings.image_model);
    let engine = match Engine::new(settings) {
        Ok(e) => e,
        Err(e) => { println!("ENGINE ERROR: {e}"); return; }
    };

    println!("--- generating image (this can take ~30s) ---");
    match engine.generate_image("a tiny red pixel-art heart on white background", None) {
        Ok(img) => println!("IMAGE OK: {}x{}", img.width, img.height),
        Err(e) => {
            println!("IMAGE ERROR: {e}");
            match engine.generate_image_raw("a tiny red pixel-art heart on white background", None) {
                Ok(raw) => println!("RAW MODEL OUTPUT:\n{}", &raw[..raw.len().min(600)]),
                Err(e2) => println!("RAW ERROR: {e2}"),
            }
        }
    }
}
