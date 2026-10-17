use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{Arc, Condvar, Mutex};

const DEFAULT_BUFFER_CAPACITY: usize = 4 * 1024 * 1024;

pub(crate) struct StreamBufferInner {
    pub(crate) data: Vec<u8>,
    pub(crate) is_finished: bool,
    pub(crate) error: Option<String>,
    pub(crate) cancelled: bool,
}

#[derive(Clone)]
pub struct StreamBuffer {
    pub(crate) inner: Arc<Mutex<StreamBufferInner>>,
    pub(crate) cvar: Arc<Condvar>,
}

impl Default for StreamBuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl StreamBuffer {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(StreamBufferInner {
                data: Vec::with_capacity(DEFAULT_BUFFER_CAPACITY),
                is_finished: false,
                error: None,
                cancelled: false,
            })),
            cvar: Arc::new(Condvar::new()),
        }
    }

    pub fn append(&self, chunk: &[u8]) {
        let mut inner = self.inner.lock().unwrap();
        if inner.cancelled {
            return;
        }
        inner.data.extend_from_slice(chunk);
        self.cvar.notify_all();
    }

    pub fn finish(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.is_finished = true;
        self.cvar.notify_all();
    }

    pub fn set_error(&self, err: String) {
        let mut inner = self.inner.lock().unwrap();
        inner.error = Some(err);
        inner.is_finished = true;
        self.cvar.notify_all();
    }

    pub fn cancel(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.cancelled = true;
        inner.is_finished = true;
        inner.data.clear();
        self.cvar.notify_all();
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.lock().unwrap().cancelled
    }

    pub fn is_finished(&self) -> bool {
        self.inner.lock().unwrap().is_finished
    }

    pub fn current_len(&self) -> usize {
        self.inner.lock().unwrap().data.len()
    }
}

pub struct StreamReader {
    buffer: StreamBuffer,
    cursor: usize,
}

impl StreamReader {
    pub fn new(buffer: StreamBuffer) -> Self {
        Self { buffer, cursor: 0 }
    }
}

impl Read for StreamReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() { return Ok(0); }
        let mut inner = self.buffer.inner.lock().unwrap();
        loop {
            if inner.cancelled { return Ok(0); }
            if let Some(ref err) = inner.error { return Err(io::Error::other(err.clone())); }
            if self.cursor < inner.data.len() {
                let available = inner.data.len() - self.cursor;
                let to_copy = available.min(buf.len());
                buf[..to_copy].copy_from_slice(&inner.data[self.cursor..self.cursor + to_copy]);
                self.cursor += to_copy;

                if self.cursor >= 256 * 1024 {
                    inner.data.drain(..self.cursor);
                    self.cursor = 0;
                }
                return Ok(to_copy);
            }
            if inner.is_finished { return Ok(0); }
            inner = self.buffer.cvar.wait(inner).unwrap();
        }
    }
}

impl Seek for StreamReader {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let mut inner = self.buffer.inner.lock().unwrap();

        let target_pos = match pos {
            SeekFrom::Start(offset) => offset as i64,
            SeekFrom::Current(offset) => self.cursor as i64 + offset,
            SeekFrom::End(offset) => {
                while !inner.is_finished && inner.error.is_none() && !inner.cancelled {
                    inner = self.buffer.cvar.wait(inner).unwrap();
                }
                if let Some(ref err) = inner.error {
                    return Err(io::Error::other(err.clone()));
                }
                inner.data.len() as i64 + offset
            }
        };

        if target_pos < 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Seek before beginning of stream",
            ));
        }

        self.cursor = target_pos as usize;
        Ok(self.cursor as u64)
    }
}
