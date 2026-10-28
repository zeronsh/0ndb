//! Versioned binary encoding. Every payload starts with a one-byte format
//! tag so stored data and wire messages can evolve independently.

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::history::History;
use crate::op::Batch;

pub const BATCH_FORMAT: u8 = 1;
pub const SNAPSHOT_FORMAT: u8 = 1;

#[derive(Debug, thiserror::Error)]
pub enum CodecError {
    #[error("empty payload")]
    Empty,
    #[error("unsupported format {found} (expected {expected})")]
    Format { found: u8, expected: u8 },
    #[error(transparent)]
    Postcard(#[from] postcard::Error),
}

pub fn encode<T: Serialize>(format: u8, value: &T) -> Vec<u8> {
    let mut out = vec![format];
    out.extend(postcard::to_stdvec(value).expect("in-memory serialization cannot fail"));
    out
}

pub fn decode<T: DeserializeOwned>(format: u8, bytes: &[u8]) -> Result<T, CodecError> {
    let (&found, rest) = bytes.split_first().ok_or(CodecError::Empty)?;
    if found != format {
        return Err(CodecError::Format { found, expected: format });
    }
    Ok(postcard::from_bytes(rest)?)
}

pub fn encode_batch(batch: &Batch) -> Vec<u8> {
    encode(BATCH_FORMAT, batch)
}

pub fn decode_batch(bytes: &[u8]) -> Result<Batch, CodecError> {
    decode(BATCH_FORMAT, bytes)
}

pub fn encode_snapshot(history: &History) -> Vec<u8> {
    encode(SNAPSHOT_FORMAT, history)
}

pub fn decode_snapshot(bytes: &[u8]) -> Result<History, CodecError> {
    decode(SNAPSHOT_FORMAT, bytes)
}
