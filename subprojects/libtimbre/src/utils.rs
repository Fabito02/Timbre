use image::{DynamicImage, GenericImageView, ImageFormat};
use libblur::{
    BlurImage, BlurImageMut, CLTParameters, FastBlurChannels, ThreadingPolicy, gaussian_box_blur,
};
use std::fs;
use std::time::Instant;

use crate::context::Paths;

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
    let hash = hasher.finish();

    let path = cache_dir.join(format!("{:x}.jpg", hash));
    if path.exists() {
        return Ok(path.to_string_lossy().into_owned());
    }

    let bytes = fs::read(image_path)?;
    let img = image::load_from_memory(&bytes)?;

    let (w, h) = img.dimensions();
    let side = w.min(h);
    let img = img.crop_imm((w - side) / 2, (h - side) / 2, side, side);

    let target_size = 1024;
    let img = img.resize_exact(
        target_size,
        target_size,
        image::imageops::FilterType::Triangle,
    );

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

    let out_img =
        image::RgbImage::from_raw(width, height, dst_bytes).ok_or("failed to rebuild image")?;
    DynamicImage::ImageRgb8(out_img).save_with_format(&path, ImageFormat::Jpeg)?;

    Ok(path.to_string_lossy().into_owned())
}
