//! Incremental transcript reader: remembers where it stopped and, on refresh,
//! only reads the bytes appended since then.
//!
//! First read of a large transcript: instead of replaying the whole file, scan
//! backwards for the last line that replaces the whole task list and replay from
//! there (plus at least the last `TAIL_BYTES`, for the latest tool call).

use crate::model::Progress;
use crate::plan::PlanState;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// Files up to this size are replayed whole on the first read.
const WHOLE_FILE_LIMIT: u64 = 4 * 1024 * 1024;
/// Chunk size for the backward scan.
const CHUNK: u64 = 256 * 1024;
/// Always replay at least this much of the end of the file.
const TAIL_BYTES: u64 = 512 * 1024;
/// Stop looking for a task-list reset this far back.
const MAX_BACKWARD_SCAN: u64 = 64 * 1024 * 1024;

#[derive(Debug)]
pub struct TranscriptReader {
    path: PathBuf,
    /// Offset of the first byte not yet consumed.
    offset: u64,
    /// Bytes of an unfinished last line (no trailing newline yet).
    partial: Vec<u8>,
    state: PlanState,
    started: bool,
}

impl TranscriptReader {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            offset: 0,
            partial: Vec::new(),
            state: PlanState::default(),
            started: false,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn progress(&self) -> &Progress {
        &self.state.progress
    }

    /// Reads what was appended since the last call. Returns true if the progress changed.
    /// A file that shrank (rewritten) is read again from a fresh state.
    pub fn refresh(&mut self) -> io::Result<bool> {
        let mut file = File::open(&self.path)?;
        let len = file.metadata()?.len();
        let before = self.state.progress.clone();

        if len < self.offset {
            *self = Self::new(std::mem::take(&mut self.path));
        }
        if !self.started {
            self.offset = start_offset(&mut file, len)?;
            self.started = true;
        }
        if len > self.offset {
            file.seek(SeekFrom::Start(self.offset))?;
            let mut buf = Vec::with_capacity((len - self.offset) as usize);
            file.take(len - self.offset).read_to_end(&mut buf)?;
            self.offset += buf.len() as u64;
            self.consume(&buf);
        }
        Ok(self.state.progress != before)
    }

    fn consume(&mut self, bytes: &[u8]) {
        let mut data = std::mem::take(&mut self.partial);
        data.extend_from_slice(bytes);
        let mut start = 0;
        while let Some(nl) = data[start..].iter().position(|&b| b == b'\n') {
            let line = &data[start..start + nl];
            if let Ok(text) = std::str::from_utf8(line) {
                self.state.apply_line(text);
            }
            start += nl + 1;
        }
        self.partial = data[start..].to_vec();
    }
}

/// Where the first read starts: 0 for small files, otherwise the start of the last
/// task-list reset line (or of the last `TAIL_BYTES`, whichever comes first).
fn start_offset(file: &mut File, len: u64) -> io::Result<u64> {
    if len <= WHOLE_FILE_LIMIT {
        return Ok(0);
    }
    let tail_start = line_start_at_or_after(file, len.saturating_sub(TAIL_BYTES), len)?;
    let mut end = len;
    let mut carry: Vec<u8> = Vec::new(); // start of a line cut by the previous (later) chunk
    // Give up after this much and use the tail only (a task list that old no longer matters).
    let floor = len.saturating_sub(MAX_BACKWARD_SCAN);
    while end > floor {
        let begin = end.saturating_sub(CHUNK);
        let mut chunk = vec![0u8; (end - begin) as usize];
        file.seek(SeekFrom::Start(begin))?;
        file.read_exact(&mut chunk)?;
        chunk.extend_from_slice(&carry);

        // Lines fully inside `chunk` (the first one may be cut unless begin == 0).
        let first_nl = if begin == 0 {
            None
        } else {
            chunk.iter().position(|&b| b == b'\n')
        };
        let body_start = first_nl.map(|p| p + 1).unwrap_or(0);
        let mut line_end = chunk.len();
        // Walk lines backwards.
        let mut pos = chunk.len();
        while pos > body_start {
            let line_begin = chunk[body_start..pos - 1]
                .iter()
                .rposition(|&b| b == b'\n')
                .map(|p| body_start + p + 1)
                .unwrap_or(body_start);
            let line = &chunk[line_begin..line_end];
            if let Ok(text) = std::str::from_utf8(line)
                && PlanState::is_reset_line(text.trim_end_matches(['\n', '\r']))
            {
                return Ok((begin + line_begin as u64).min(tail_start));
            }
            line_end = line_begin;
            pos = line_begin;
        }
        carry = chunk[..body_start].to_vec();
        end = begin;
    }
    Ok(tail_start)
}

/// Offset of the first line that starts at or after `from`.
fn line_start_at_or_after(file: &mut File, from: u64, len: u64) -> io::Result<u64> {
    if from == 0 {
        return Ok(0);
    }
    file.seek(SeekFrom::Start(from - 1))?;
    let mut buf = vec![0u8; (len - from + 1).min(64 * 1024) as usize];
    let n = file.read(&mut buf)?;
    Ok(buf[..n]
        .iter()
        .position(|&b| b == b'\n')
        .map(|p| from + p as u64)
        .unwrap_or(len))
}
