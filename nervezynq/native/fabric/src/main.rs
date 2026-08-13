//! `fabric_port` — the Erlang port frontend to [`fabric::Fabric`].
//!
//! Usage: `fabric_port <base> <len>`, e.g. `fabric_port 0x40000000 4096`.
//!
//! Speaks the BEAM's `{:packet, 4}` framing on stdin/stdout: every message,
//! both directions, is a 4-byte big-endian length followed by that many bytes.
//! The VM adds and strips those headers itself, so the Elixir side never sees
//! them.
//!
//! ## Requests
//!
//! | Op   | Name        | Payload                             |
//! |------|-------------|-------------------------------------|
//! | 0x01 | READ32      | `u32 offset`                        |
//! | 0x02 | WRITE32     | `u32 offset, u32 value`             |
//! | 0x03 | READ_BLOCK  | `u32 offset, u16 count`             |
//! | 0x04 | WRITE_BLOCK | `u32 offset, u16 count, u32×count`  |
//! | 0x05 | INFO        | —                                   |
//! | 0x06 | READ_REPEAT | `u32 offset, u16 count`             |
//!
//! ## Responses
//!
//! `0x00` followed by the reply payload, or `0x01` followed by a UTF-8 error
//! message. Everything is big-endian.
//!
//! An out-of-range or misaligned request is an error RESPONSE, not an exit: a
//! typo at the IEx prompt should come back as `{:error, reason}`, not take the
//! port down and lose the mapping. The process only exits on stdin EOF (the VM
//! closed the port) or on a protocol violation it cannot resynchronise from.

use std::io::{self, Read, Write};
use std::process::ExitCode;

use fabric::Fabric;

const OP_READ32: u8 = 0x01;
const OP_WRITE32: u8 = 0x02;
const OP_READ_BLOCK: u8 = 0x03;
const OP_WRITE_BLOCK: u8 = 0x04;
const OP_INFO: u8 = 0x05;
const OP_READ_REPEAT: u8 = 0x06;

const RESP_OK: u8 = 0x00;
const RESP_ERR: u8 = 0x01;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();

    if args.len() != 3 {
        eprintln!("usage: {} <base> <len>", args[0]);
        return ExitCode::from(64);
    }

    let base = match parse_int(&args[1]) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("bad base {:?}: {e}", args[1]);
            return ExitCode::from(64);
        }
    };

    let len = match parse_int(&args[2]) {
        Ok(v) => v as usize,
        Err(e) => {
            eprintln!("bad length {:?}: {e}", args[2]);
            return ExitCode::from(64);
        }
    };

    let fabric = match Fabric::map(base, len) {
        Ok(f) => f,
        Err(e) => {
            // Exit rather than serve: without a mapping there is nothing this
            // process can usefully do, and the supervisor should see it fail
            // immediately instead of on the first request.
            eprintln!("mmap {base:#x}+{len:#x} failed: {e}");
            return ExitCode::from(69);
        }
    };

    match serve(&fabric) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("port loop failed: {e}");
            ExitCode::from(70)
        }
    }
}

fn serve(fabric: &Fabric) -> io::Result<()> {
    let mut stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();

    loop {
        let request = match read_frame(&mut stdin)? {
            Some(r) => r,
            None => return Ok(()), // EOF: the VM closed the port.
        };

        let response = match dispatch(fabric, &request) {
            Ok(payload) => {
                let mut r = Vec::with_capacity(payload.len() + 1);
                r.push(RESP_OK);
                r.extend_from_slice(&payload);
                r
            }
            Err(message) => {
                let mut r = Vec::with_capacity(message.len() + 1);
                r.push(RESP_ERR);
                r.extend_from_slice(message.as_bytes());
                r
            }
        };

        write_frame(&mut stdout, &response)?;
        stdout.flush()?;
    }
}

fn dispatch(fabric: &Fabric, req: &[u8]) -> Result<Vec<u8>, String> {
    let (&op, rest) = req.split_first().ok_or("empty request")?;

    match op {
        OP_READ32 => {
            expect_len(rest, 4)?;
            let offset = take_u32(rest, 0)? as usize;
            let value = fabric.read32(offset).map_err(|e| e.to_string())?;
            Ok(value.to_be_bytes().to_vec())
        }

        OP_WRITE32 => {
            expect_len(rest, 8)?;
            let offset = take_u32(rest, 0)? as usize;
            let value = take_u32(rest, 4)?;
            fabric.write32(offset, value).map_err(|e| e.to_string())?;
            Ok(Vec::new())
        }

        OP_READ_REPEAT => {
            expect_len(rest, 6)?;
            let offset = take_u32(rest, 0)? as usize;
            let count = take_u16(rest, 4)? as usize;
            let words = fabric
                .read_repeat(offset, count)
                .map_err(|e| e.to_string())?;

            let mut out = Vec::with_capacity(words.len() * 4);
            for w in words {
                out.extend_from_slice(&w.to_be_bytes());
            }
            Ok(out)
        }

        OP_READ_BLOCK => {
            expect_len(rest, 6)?;
            let offset = take_u32(rest, 0)? as usize;
            let count = take_u16(rest, 4)? as usize;
            let words = fabric
                .read_block(offset, count)
                .map_err(|e| e.to_string())?;

            let mut out = Vec::with_capacity(words.len() * 4);
            for w in words {
                out.extend_from_slice(&w.to_be_bytes());
            }
            Ok(out)
        }

        OP_WRITE_BLOCK => {
            let offset = take_u32(rest, 0)? as usize;
            let count = take_u16(rest, 4)? as usize;
            expect_len(rest, 6 + count * 4)?;

            let mut words = Vec::with_capacity(count);
            for i in 0..count {
                words.push(take_u32(rest, 6 + i * 4)?);
            }

            fabric
                .write_block(offset, &words)
                .map_err(|e| e.to_string())?;
            Ok(Vec::new())
        }

        OP_INFO => {
            expect_len(rest, 0)?;
            let mut out = Vec::with_capacity(12);
            out.extend_from_slice(&fabric.phys().to_be_bytes());
            out.extend_from_slice(&(fabric.len() as u32).to_be_bytes());
            Ok(out)
        }

        other => Err(format!("unknown opcode {other:#04x}")),
    }
}

// --- framing ---------------------------------------------------------------

fn read_frame(r: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; 4];

    match r.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }

    let len = u32::from_be_bytes(header) as usize;
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)?;
    Ok(Some(body))
}

fn write_frame(w: &mut impl Write, body: &[u8]) -> io::Result<()> {
    w.write_all(&(body.len() as u32).to_be_bytes())?;
    w.write_all(body)
}

// --- payload decoding ------------------------------------------------------

fn expect_len(rest: &[u8], want: usize) -> Result<(), String> {
    if rest.len() == want {
        Ok(())
    } else {
        Err(format!(
            "payload is {} bytes, expected {want}",
            rest.len()
        ))
    }
}

fn take_u32(buf: &[u8], at: usize) -> Result<u32, String> {
    buf.get(at..at + 4)
        .map(|s| u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
        .ok_or_else(|| format!("truncated u32 at byte {at}"))
}

fn take_u16(buf: &[u8], at: usize) -> Result<u16, String> {
    buf.get(at..at + 2)
        .map(|s| u16::from_be_bytes([s[0], s[1]]))
        .ok_or_else(|| format!("truncated u16 at byte {at}"))
}

fn parse_int(s: &str) -> Result<u64, std::num::ParseIntError> {
    match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        Some(hex) => u64::from_str_radix(hex, 16),
        None => s.parse(),
    }
}
