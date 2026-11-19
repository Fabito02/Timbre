use image::{GenericImageView, ImageEncoder};
use image::codecs::webp::WebPEncoder;
use libblur::{
    BlurImage, BlurImageMut, CLTParameters, FastBlurChannels, ThreadingPolicy, gaussian_box_blur,
};
use std::fs;
use std::time::Instant;

use crate::context::Paths;

const TARGET_SIZE: u32 = 1024;

pub fn blur_and_cache_from_file(
    image_path: &str,
    radius: u32,
) -> Result<String, Box<dyn std::error::Error>> {
    let paths = Paths::discover()?;
    let cache_dir = paths.cache_dir.join("blur_cache");
    fs::create_dir_all(&cache_dir)?;

    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    image_path.hash(&mut hasher);
    radius.hash(&mut hasher);
    hasher.write_u8(9);
    let hash = hasher.finish();

    let path = cache_dir.join(format!("{:x}.webp", hash));
    if path.exists() {
        return Ok(path.to_string_lossy().into_owned());
    }

    let bytes = fs::read(image_path)?;
    let img = image::load_from_memory(&bytes)?;

    let (w, h) = img.dimensions();
    let side = w.min(h);
    let img = img.crop_imm((w - side) / 2, (h - side) / 2, side, side);

    let img = img.resize_exact(TARGET_SIZE, TARGET_SIZE, image::imageops::FilterType::Lanczos3);

    let (width, height) = img.dimensions();
    let src_bytes = img.to_rgb8().into_raw();
    let mut dst_bytes = vec![0u8; src_bytes.len()];

    let blur_start = Instant::now();
    {
        let src_image = BlurImage::borrow(&src_bytes, width, height, FastBlurChannels::Channels3);
        let mut dst_image =
            BlurImageMut::borrow(&mut dst_bytes, width, height, FastBlurChannels::Channels3);

        gaussian_box_blur(
            &src_image,
            &mut dst_image,
            CLTParameters::new(radius as f32),
            ThreadingPolicy::Adaptive,
        )?;
    }
    tracing::debug!(
        blur_ms = blur_start.elapsed().as_millis() as u64,
        width,
        height,
        "blur_and_cache: blurred from file"
    );

    let mut out_img =
        image::RgbImage::from_raw(width, height, dst_bytes).ok_or("failed to rebuild image")?;

    let mut rng_state = hash as u32;
    for px in out_img.pixels_mut() {
        for c in px.0.iter_mut() {
            rng_state ^= rng_state << 13;
            rng_state ^= rng_state >> 17;
            rng_state ^= rng_state << 5;
            let dither = (rng_state % 3) as i16 - 1;

            *c = (*c as i16 + dither).clamp(0, 255) as u8;
        }
    }

    let file = fs::File::create(&path)?;
    let mut writer = std::io::BufWriter::new(file);
    let encoder = WebPEncoder::new_lossless(&mut writer);
    encoder.write_image(
        out_img.as_raw(),
        out_img.width(),
        out_img.height(),
        image::ExtendedColorType::Rgb8,
    )?;

    Ok(path.to_string_lossy().into_owned())
}
