use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use futures_util::StreamExt;
use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Player, Source};

use crate::stream_reader::{StreamBuffer, StreamReader};

const PRE_BUFFER_THRESHOLD: usize = 16 * 1024;

pub struct AudioPlayer {
    _handle: MixerDeviceSink,
    player: Arc<Mutex<Player>>,
    position: Arc<Mutex<PlaybackPosition>>,
    total_duration: Arc<Mutex<Option<Duration>>>,
    current_url: Arc<Mutex<Option<String>>>,
    total_bytes: Arc<Mutex<Option<u64>>>,
    active_buffer: Arc<Mutex<Option<StreamBuffer>>>,
    client: reqwest::Client,
}

struct PlaybackPosition {
    start_instant: Option<Instant>,
    accumulated: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayerState {
    Playing,
    Paused,
    Stopped,
    Buffering,
}

impl AudioPlayer {
    pub fn new() -> Result<Self> {
        let handle = DeviceSinkBuilder::open_default_sink()
            .map_err(|e| anyhow::anyhow!("Failed to open default audio sink: {e:?}"))?;

        let player = Player::connect_new(&handle.mixer());

        Ok(Self {
            _handle: handle,
            player: Arc::new(Mutex::new(player)),
            position: Arc::new(Mutex::new(PlaybackPosition::new())),
            total_duration: Arc::new(Mutex::new(None)),
            current_url: Arc::new(Mutex::new(None)),
            total_bytes: Arc::new(Mutex::new(None)),
            active_buffer: Arc::new(Mutex::new(None)),
            client: reqwest::Client::new(),
        })
    }

    pub async fn play_url(&self, url: &str, duration: Option<Duration>) -> Result<()> {
        let response = self
            .client
            .get(url)
            .header("User-Agent", "Mozilla/5.0")
            .send()
            .await
            .context("Failed to request audio stream")?;

        *self.current_url.lock().unwrap() = Some(url.to_string());
        *self.total_bytes.lock().unwrap() = response.content_length();
        *self.total_duration.lock().unwrap() = duration;

        let mut stream = response.bytes_stream();
        let buffer = StreamBuffer::new();

        *self.active_buffer.lock().unwrap() = Some(buffer.clone());

        let mut pos = self.position.lock().unwrap();
        pos.reset();
        pos.start();

        while let Some(chunk_res) = stream.next().await {
            let chunk = chunk_res.context("Failed to receive stream chunk")?;
            buffer.append(&chunk);

            if buffer.current_len() >= PRE_BUFFER_THRESHOLD {
                break;
            }
        }

        let bg_buffer = buffer.clone();
        tokio::spawn(async move {
            while let Some(chunk_res) = stream.next().await {
                match chunk_res {
                    Ok(chunk) => bg_buffer.append(&chunk),
                    Err(e) => {
                        bg_buffer.set_error(e.to_string());
                        return;
                    }
                }
            }
            bg_buffer.finish();
        });

        let reader = BufReader::new(StreamReader::new(buffer));
        let source = Decoder::try_from(reader)
            .map_err(|e| anyhow::anyhow!("Failed to decode audio stream: {e:?}"))?;

        let player = self.player.lock().unwrap();
        player.stop();
        player.append(source);
        player.play();

        Ok(())
    }

    pub fn play_file<P: AsRef<Path>>(&self, path: P) -> Result<()> {
        let path = path.as_ref();
        let file = File::open(path)
            .with_context(|| format!("Failed to open file: {}", path.display()))?;

        let file_len = file.metadata()?.len();
        let reader = BufReader::new(file);

        let source = Decoder::try_from(reader)
            .map_err(|e| anyhow::anyhow!("Failed to decode local file: {e:?}"))?;

        let total_dur = source.total_duration();

        *self.current_url.lock().unwrap() = Some(format!("file://{}", path.display()));
        *self.total_bytes.lock().unwrap() = Some(file_len);
        *self.total_duration.lock().unwrap() = total_dur;

        let mut pos = self.position.lock().unwrap();
        pos.reset();
        pos.start();

        let player = self.player.lock().unwrap();
        player.stop();
        player.append(source);
        player.play();

        Ok(())
    }

    pub async fn seek(&self, target: Duration) -> Result<()> {
        let current = self
            .current_url
            .lock()
            .unwrap()
            .clone()
            .context("No audio track loaded to seek")?;

        {
            let player = self.player.lock().unwrap();
            player.stop();
        }

        if let Some(path_str) = current.strip_prefix("file://") {
            let file = File::open(path_str)
                .with_context(|| format!("Failed to reopen file: {path_str}"))?;
            let reader = BufReader::new(file);

            let source = Decoder::try_from(reader)
                .map_err(|e| anyhow::anyhow!("Failed to decode local file: {e:?}"))?;

            let skipped_source = source.skip_duration(target);

            let player = self.player.lock().unwrap();
            player.append(skipped_source);
            player.play();

            self.position.lock().unwrap().seek(target);
            return Ok(());
        }

        let buffer = self
            .active_buffer
            .lock()
            .unwrap()
            .clone()
            .context("No active stream buffer available for seek")?;

        let reader = BufReader::new(StreamReader::new(buffer));
        let source = Decoder::try_from(reader)
            .map_err(|e| anyhow::anyhow!("Failed to decode stream for seek: {e:?}"))?;

        let skipped_source = source.skip_duration(target);

        let player = self.player.lock().unwrap();
        player.append(skipped_source);
        player.play();

        self.position.lock().unwrap().seek(target);
        Ok(())
    }

    pub fn pause(&self) {
        self.player.lock().unwrap().pause();
        self.position.lock().unwrap().pause();
    }

    pub fn resume(&self) {
        self.player.lock().unwrap().play();
        self.position.lock().unwrap().start();
    }

    pub fn stop(&self) {
        self.player.lock().unwrap().stop();
        self.position.lock().unwrap().reset();
    }

    pub fn get_position(&self) -> Duration {
        let player = self.player.lock().unwrap();
        let elapsed = self.position.lock().unwrap().elapsed();

        if player.empty() {
            let total = *self.total_duration.lock().unwrap();
            total.unwrap_or(elapsed)
        } else {
            elapsed
        }
    }

    pub fn get_duration(&self) -> Option<Duration> {
        *self.total_duration.lock().unwrap()
    }

    pub fn volume(&self) -> f32 {
        self.player.lock().unwrap().volume()
    }

    pub fn set_volume(&self, volume: f32) {
        self.player.lock().unwrap().set_volume(volume);
    }

    pub fn is_paused(&self) -> bool {
        self.player.lock().unwrap().is_paused()
    }

    pub fn is_empty(&self) -> bool {
        self.player.lock().unwrap().empty()
    }

    pub fn state(&self) -> PlayerState {
        let player = self.player.lock().unwrap();
        if player.empty() {
            PlayerState::Stopped
        } else if player.is_paused() {
            PlayerState::Paused
        } else {
            PlayerState::Playing
        }
    }

    pub fn is_finished(&self) -> bool {
        let player = self.player.lock().unwrap();
        let pos = self.position.lock().unwrap().elapsed();

        player.empty() && pos > Duration::ZERO
    }
}

impl PlaybackPosition {
    fn new() -> Self {
        Self {
            start_instant: None,
            accumulated: Duration::ZERO,
        }
    }

    fn reset(&mut self) {
        self.start_instant = None;
        self.accumulated = Duration::ZERO;
    }

    fn start(&mut self) {
        self.start_instant = Some(Instant::now());
    }

    fn pause(&mut self) {
        if let Some(start) = self.start_instant.take() {
            self.accumulated += start.elapsed();
        }
    }

    fn elapsed(&self) -> Duration {
        match self.start_instant {
            Some(start) => self.accumulated + start.elapsed(),
            Option::None => self.accumulated,
        }
    }

    fn seek(&mut self, target: Duration) {
        self.accumulated = target;

        if self.start_instant.is_some() {
            self.start_instant = Some(Instant::now());
        }
    }
}
