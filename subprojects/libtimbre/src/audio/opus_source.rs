use std::io::{self, Read, Seek, SeekFrom};
use std::num::{NonZeroU16, NonZeroU32};
use std::path::Path;
use std::time::Duration;

use rodio::Source;
use symphonia::core::codecs::CODEC_TYPE_NULL;
use symphonia::core::formats::{FormatOptions, FormatReader, Packet};
use symphonia::core::io::{MediaSource, MediaSourceStream};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use crate::stream_reader::StreamBuffer;

pub struct StreamingMediaSource {
    buffer: StreamBuffer,
    cursor: u64,
}

impl StreamingMediaSource {
    pub fn new(buffer: StreamBuffer) -> Self {
        Self { buffer, cursor: 0 }
    }

    fn wait_until(&self, position: u64) -> io::Result<()> {
        let mut inner = self.buffer.inner.lock().unwrap();
        while (inner.data.len() as u64) < position {
            if let Some(err) = &inner.error {
                return Err(io::Error::other(err.clone()));
            }
            if inner.cancelled {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "stream cancelled"));
            }
            if inner.is_finished {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "stream ended before position",
                ));
            }
            inner = self.buffer.cvar.wait(inner).unwrap();
        }
        Ok(())
    }
}

impl Read for StreamingMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let mut inner = self.buffer.inner.lock().unwrap();
        loop {
            if inner.cancelled {
                return Ok(0);
            }
            if let Some(err) = &inner.error {
                return Err(io::Error::other(err.clone()));
            }
            let cursor = self.cursor as usize;
            if cursor < inner.data.len() {
                let available = inner.data.len() - cursor;
                let to_copy = available.min(buf.len());
                buf[..to_copy].copy_from_slice(&inner.data[cursor..cursor + to_copy]);
                self.cursor += to_copy as u64;
                return Ok(to_copy);
            }
            if inner.is_finished {
                return Ok(0);
            }
            inner = self.buffer.cvar.wait(inner).unwrap();
        }
    }
}

impl Seek for StreamingMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        match pos {
            SeekFrom::Start(n) => {
                self.wait_until(n)?;
                self.cursor = n;
                Ok(n)
            }
            SeekFrom::Current(delta) => {
                let target = (self.cursor as i64)
                    .checked_add(delta)
                    .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "seek overflow"))?;
                if target < 0 {
                    return Err(io::Error::new(io::ErrorKind::InvalidInput, "seek before start"));
                }
                let target = target as u64;
                self.wait_until(target)?;
                self.cursor = target;
                Ok(target)
            }
            SeekFrom::End(_) => Err(io::Error::new(
                io::ErrorKind::Other,
                "seek from end not supported on a streaming source",
            )),
        }
    }
}

impl MediaSource for StreamingMediaSource {
    fn is_seekable(&self) -> bool {
        false
    }
    fn byte_len(&self) -> Option<u64> {
        None
    }
}

pub struct OpusSource {
    format: Box<dyn FormatReader>,
    track_id: u32,
    decoder: opus::Decoder,
    pcm: Vec<f32>,
    pcm_cursor: usize,
    pcm_len: usize,
    channels: NonZeroU16,
    sample_rate: NonZeroU32,
    total_duration: Option<Duration>,
    pre_skip: usize,
    packets_seen: u64,
    pending_packet: Option<Packet>,
}

impl OpusSource {
    pub fn from_stream(buffer: StreamBuffer) -> Result<Self, String> {
        Self::build(Box::new(StreamingMediaSource::new(buffer)))
    }

    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, String> {
        Self::build(Box::new(std::io::Cursor::new(bytes)))
    }

    pub fn from_file(path: &Path) -> Result<Self, String> {
        let file = std::fs::File::open(path).map_err(|e| format!("open: {e}"))?;
        Self::build(Box::new(file))
    }

    pub fn from_source(source: Box<dyn MediaSource>) -> Result<Self, String> {
        Self::build(source)
    }

    pub fn try_seek_to(&mut self, target: Duration) -> Result<Duration, String> {
        use symphonia::core::formats::{SeekMode, SeekTo};
        use symphonia::core::units::Time as SymTime;

        let to = SeekTo::Time {
            time: SymTime {
                seconds: target.as_secs(),
                frac: target.subsec_nanos() as f64 / 1_000_000_000.0,
            },
            track_id: Some(self.track_id),
        };
        self.format
            .seek(SeekMode::Accurate, to)
            .map_err(|e| format!("demuxer seek: {e}"))?;

        let opus_channels = if self.channels.get() == 1 {
            opus::Channels::Mono
        } else {
            opus::Channels::Stereo
        };
        self.decoder = opus::Decoder::new(self.sample_rate.get(), opus_channels)
            .map_err(|e| format!("opus decoder reset: {e}"))?;
        self.pcm_cursor = 0;
        self.pcm_len = 0;
        self.packets_seen = 0;
        self.pre_skip = 0;

        let landed = match self.format.next_packet() {
            Ok(packet) => {
                let ts = packet.ts();
                let landed = self
                    .format
                    .tracks()
                    .iter()
                    .find(|t| t.id == self.track_id)
                    .and_then(|t| t.codec_params.time_base)
                    .map(|tb| {
                        let t = tb.calc_time(ts);
                        Duration::from_secs_f64(t.seconds as f64 + t.frac)
                    })
                    .unwrap_or(target);
                self.pending_packet = Some(packet);
                landed
            }
            Err(err) => {
                tracing::debug!(%err, "opus: no packet after seek, using target");
                target
            }
        };

        tracing::debug!(
            requested_ms = target.as_millis() as u64,
            landed_ms = landed.as_millis() as u64,
            drift_ms = landed.as_millis() as i64 - target.as_millis() as i64,
            "opus: demuxer seek landed"
        );

        Ok(landed)
    }

    pub fn landed_time(&mut self) -> Option<Duration> {
        if self.pending_packet.is_none() {
            if let Ok(p) = self.format.next_packet() {
                self.pending_packet = Some(p);
            }
        }
        let packet = self.pending_packet.as_ref()?;
        let ts = packet.ts();
        self.format
            .tracks()
            .iter()
            .find(|t| t.id == self.track_id)
            .and_then(|t| t.codec_params.time_base)
            .map(|tb| {
                let t = tb.calc_time(ts);
                Duration::from_secs_f64(t.seconds as f64 + t.frac)
            })
    }

    fn build(reader: Box<dyn MediaSource>) -> Result<Self, String> {
        let mss = MediaSourceStream::new(reader, Default::default());
        let mut hint = Hint::new();
        hint.with_extension("webm");

        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
            .map_err(|e| format!("probe: {e}"))?;
        let format = probed.format;

        let track = format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or_else(|| "no decodable track".to_owned())?;

        let track_id = track.id;
        let sample_rate_u32 = track.codec_params.sample_rate.unwrap_or(48_000);
        let channels_u16 = track.codec_params.channels.map(|c| c.count() as u16).unwrap_or(2);

        let sample_rate = NonZeroU32::new(sample_rate_u32)
            .ok_or_else(|| "invalid sample rate".to_owned())?;
        let channels = NonZeroU16::new(channels_u16)
            .ok_or_else(|| "invalid channel count".to_owned())?;

        let total_duration = track
            .codec_params
            .n_frames
            .map(Duration::from_millis)
            .filter(|d| d.as_secs() >= 30);

        let opus_channels = if channels_u16 == 1 {
            opus::Channels::Mono
        } else {
            opus::Channels::Stereo
        };
        let decoder = opus::Decoder::new(sample_rate_u32, opus_channels)
            .map_err(|e| format!("opus decoder: {e}"))?;

        Ok(Self {
            format,
            track_id,
            decoder,
            pcm: vec![0.0f32; 5760 * 2],
            pcm_cursor: 0,
            pcm_len: 0,
            channels,
            sample_rate,
            total_duration,
            pre_skip: 0,
            packets_seen: 0,
            pending_packet: None,
        })
    }

    fn refill(&mut self) -> bool {
        loop {
            let packet = if let Some(p) = self.pending_packet.take() {
                p
            } else {
                match self.format.next_packet() {
                    Ok(p) => p,
                    Err(e) => {
                        tracing::debug!(
                            packets_seen = self.packets_seen,
                            %e,
                            "opus: demuxer stopped"
                        );
                        return false;
                    }
                }
            };
            if packet.track_id() != self.track_id {
                continue;
            }
            match self.decoder.decode_float(&packet.data, &mut self.pcm, false) {
                Ok(samples_per_channel) => {
                    self.packets_seen += 1;
                    let channels = self.channels.get() as usize;
                    let skip_per_ch = self.pre_skip.min(samples_per_channel);
                    self.pre_skip -= skip_per_ch;
                    self.pcm_cursor = skip_per_ch * channels;
                    self.pcm_len = samples_per_channel * channels;
                    return self.pcm_len > self.pcm_cursor;
                }
                Err(_) => continue,
            }
        }
    }
}

impl Iterator for OpusSource {
    type Item = f32;

    fn next(&mut self) -> Option<f32> {
        loop {
            if self.pcm_cursor < self.pcm_len {
                let sample = self.pcm[self.pcm_cursor];
                self.pcm_cursor += 1;
                return Some(sample);
            }
            if !self.refill() {
                return None;
            }
        }
    }
}

impl Source for OpusSource {
    fn current_span_len(&self) -> Option<usize> {
        None
    }
    fn channels(&self) -> NonZeroU16 {
        self.channels
    }
    fn sample_rate(&self) -> NonZeroU32 {
        self.sample_rate
    }
    fn total_duration(&self) -> Option<Duration> {
        self.total_duration
    }
}

pub struct Mp4SparseSource {
    header: Vec<u8>,
    window: Vec<u8>,
    window_start: u64,
    tail_buffer: StreamBuffer,
    tail_start: u64,
    cursor: u64,
    total_len: Option<u64>,
}

impl Mp4SparseSource {
    pub fn new(
        header: Vec<u8>,
        window: Vec<u8>,
        window_start: u64,
        tail_buffer: StreamBuffer,
        total_len: Option<u64>,
    ) -> Self {
        let tail_start = window_start + window.len() as u64;
        Self {
            header,
            window,
            window_start,
            tail_buffer,
            tail_start,
            cursor: 0,
            total_len,
        }
    }
}

impl Read for Mp4SparseSource {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let pos = self.cursor;
        let hlen = self.header.len() as u64;
        let wend = self.window_start + self.window.len() as u64;

        if pos < hlen {
            let end = hlen.min(pos + buf.len() as u64);
            let n = (end - pos) as usize;
            buf[..n].copy_from_slice(&self.header[pos as usize..end as usize]);
            self.cursor += n as u64;
            return Ok(n);
        }
        if pos >= self.window_start && pos < wend {
            let off = (pos - self.window_start) as usize;
            let available = self.window.len() - off;
            let n = available.min(buf.len());
            buf[..n].copy_from_slice(&self.window[off..off + n]);
            self.cursor += n as u64;
            return Ok(n);
        }
        if pos < self.window_start {
            let end = self.window_start.min(pos + buf.len() as u64);
            let n = (end - pos) as usize;
            buf[..n].fill(0);
            self.cursor += n as u64;
            return Ok(n);
        }

        let tpos = (pos - self.tail_start) as usize;
        let mut inner = self.tail_buffer.inner.lock().unwrap();
        loop {
            if inner.cancelled {
                return Ok(0);
            }
            if let Some(ref err) = inner.error {
                return Err(io::Error::other(err.clone()));
            }
            if tpos < inner.data.len() {
                let available = inner.data.len() - tpos;
                let n = available.min(buf.len());
                buf[..n].copy_from_slice(&inner.data[tpos..tpos + n]);
                drop(inner);
                self.cursor += n as u64;
                return Ok(n);
            }
            if inner.is_finished {
                return Ok(0);
            }
            inner = self.tail_buffer.cvar.wait(inner).unwrap();
        }
    }
}

impl Seek for Mp4SparseSource {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let target = match pos {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::Current(delta) => (self.cursor as i64)
                .checked_add(delta)
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "seek overflow"))?,
            SeekFrom::End(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "seek from end not supported on a sparse source",
                ));
            }
        };
        if target < 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "seek before start"));
        }
        self.cursor = target as u64;
        Ok(self.cursor)
    }
}

impl MediaSource for Mp4SparseSource {
    fn is_seekable(&self) -> bool {
        true
    }
    fn byte_len(&self) -> Option<u64> {
        self.total_len
    }
}
