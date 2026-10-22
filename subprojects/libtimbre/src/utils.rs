use image::{DynamicImage, GenericImageView, ImageFormat};
use libblur::{
    BlurImage, BlurImageMut, CLTParameters, FastBlurChannels, ThreadingPolicy, gaussian_box_blur,
};
use std::fs;
use std::sync::OnceLock;

use crate::context::Paths;

static HTTP: OnceLock<reqwest::blocking::Client> = OnceLock::new();

fn http_client() -> &'static reqwest::blocking::Client {
    HTTP.get_or_init(|| {
        reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(8))
            .build()
            .expect("http client")
    })
}

pub fn blur_and_cache(image_url: &str, radius: u32) -> Result<String, Box<dyn std::error::Error>> {
    let paths = Paths::discover()?;
    let cache_dir = paths.cache_dir.join("blur_cache");
    fs::create_dir_all(&cache_dir)?;

    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    image_url.hash(&mut hasher);
    radius.hash(&mut hasher);
    let hash = hasher.finish();

    let path = cache_dir.join(format!("{:x}.jpg", hash));

    if path.exists() {
        return Ok(path.to_string_lossy().into_owned());
    }

    let bytes = http_client().get(image_url).send()?.bytes()?.to_vec();
    let img = image::load_from_memory(&bytes)?;
    let (width, height) = img.dimensions();
    let src_bytes = img.to_rgb8().into_raw();
    let mut dst_bytes = vec![0u8; src_bytes.len()];

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

    let out_img =
        image::RgbImage::from_raw(width, height, dst_bytes).ok_or("failed to rebuild image")?;
    DynamicImage::ImageRgb8(out_img).save_with_format(&path, ImageFormat::Jpeg)?;

    Ok(path.to_string_lossy().into_owned())
}
