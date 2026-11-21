use image::{GenericImageView, ImageEncoder, codecs::webp::WebPEncoder};
use libblur::{
    BlurImage, BlurImageMut, CLTParameters, FastBlurChannels, ThreadingPolicy, gaussian_box_blur,
};
use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::time::Instant;

use crate::context::Paths;

const TARGET_SIZE: u32 = 640;
const SATURATION_BOOST: f32 = 1.22;
const CACHE_VERSION: u8 = 16;

fn boost_saturation_rgb(rgb: &mut [u8], boost: f32) {
    for px in rgb.chunks_exact_mut(3) {
        let r = px[0] as f32 / 255.0;
        let g = px[1] as f32 / 255.0;
        let b = px[2] as f32 / 255.0;

        let max = r.max(g).max(b);
        let min = r.min(g).min(b);
        let delta = max - min;

        if delta > 0.0001 {
            let l = (max + min) * 0.5;
            let s = if l < 0.0001 || l > 0.9999 {
                0.0
            } else {
                delta / (1.0 - (2.0 * l - 1.0).abs())
            };
            let new_s = (s * boost).clamp(0.0, 1.0);

            let mut h = if (max - r).abs() < 0.0001 {
                ((g - b) / delta) % 6.0
            } else if (max - g).abs() < 0.0001 {
                (b - r) / delta + 2.0
            } else {
                (r - g) / delta + 4.0
            };
            if h < 0.0 {
                h += 6.0;
            }

            let c = (1.0 - (2.0 * l - 1.0).abs()) * new_s;
            let x = c * (1.0 - ((h % 2.0) - 1.0).abs());
            let m = l - c * 0.5;

            let (nr, ng, nb) = if h < 1.0 {
                (c, x, 0.0)
            } else if h < 2.0 {
                (x, c, 0.0)
            } else if h < 3.0 {
                (0.0, c, x)
            } else if h < 4.0 {
                (0.0, x, c)
            } else if h < 5.0 {
                (x, 0.0, c)
            } else {
                (c, 0.0, x)
            };

            px[0] = ((nr + m) * 255.0).round().clamp(0.0, 255.0) as u8;
            px[1] = ((ng + m) * 255.0).round().clamp(0.0, 255.0) as u8;
            px[2] = ((nb + m) * 255.0).round().clamp(0.0, 255.0) as u8;
        }
    }
}

pub fn blur_and_cache_from_file(
    image_path: &str,
    radius: u32,
) -> Result<String, Box<dyn std::error::Error>> {
    let paths = Paths::discover()?;
    let cache_dir = paths.cache_dir.join("blur_cache");
    fs::create_dir_all(&cache_dir)?;

    let mut hasher = DefaultHasher::new();
    image_path.hash(&mut hasher);
    radius.hash(&mut hasher);
    TARGET_SIZE.hash(&mut hasher);
    hasher.write_u8(CACHE_VERSION);
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

    let img = img.resize_exact(
        TARGET_SIZE,
        TARGET_SIZE,
        image::imageops::FilterType::Lanczos3,
    );

    let (width, height) = img.dimensions();
    let mut src_bytes = img.to_rgb8().into_raw();
    boost_saturation_rgb(&mut src_bytes, SATURATION_BOOST);
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

    let file = fs::File::create(&path)?;
    let mut writer = std::io::BufWriter::new(file);
    let encoder = WebPEncoder::new_lossless(&mut writer);
    encoder.write_image(
        &dst_bytes,
        width,
        height,
        image::ExtendedColorType::Rgb8,
    )?;

    Ok(path.to_string_lossy().into_owned())
}
