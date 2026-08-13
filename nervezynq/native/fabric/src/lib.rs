//! Memory-mapped access to a physical aperture — on the LibreSDR, the Zynq PL
//! at `0x4000_0000`.
//!
//! # Why mmap and not read/write
//!
//! `pread` on `/dev/mem` does not work for this. ARM's `valid_phys_addr_range()`
//! caps the read/write path to physical RAM, so a `pread` at `0x4000_0000`
//! returns `EFAULT` — the PL aperture is not RAM. `mmap` carries no such check.
//! That is the whole reason this crate exists rather than the driver just
//! opening a file from Elixir.
//!
//! # Why O_SYNC
//!
//! Opening `/dev/mem` with `O_SYNC` is what makes the kernel map the range as
//! uncached device memory rather than normal memory. Without it the mapping is
//! cacheable: writes sit in the cache instead of reaching the fabric, reads are
//! answered from a line that was filled once, and a register file appears to
//! work exactly until it doesn't. On ARM an uncached Device mapping is also
//! strongly ordered, which is what makes a write-then-read of the same register
//! mean what it says.
//!
//! # Ordering
//!
//! There are no barriers here, deliberately. `read_volatile` and
//! `write_volatile` are guaranteed not to be elided, duplicated or reordered
//! with respect to *other volatile operations*, and every access in this crate
//! is volatile — so the ordering a barrier would buy is already guaranteed.
//!
//! An earlier version put a `compiler_fence(SeqCst)` after each access. It was
//! cargo cult: there was nothing non-volatile for it to order against, and
//! `compiler_fence` emits no instruction, so it constrained only a compiler
//! that was already constrained.
//!
//! A barrier becomes necessary when volatile MMIO is mixed with *non*-volatile
//! memory — writing a descriptor into normal cacheable RAM and then poking a
//! doorbell over MMIO, say. That needs ordering `volatile` does not provide,
//! and on ARM it needs `fence()` (which lowers to `DMB`), not
//! `compiler_fence()`. When a DMA path exists, revisit this.
//!
//! # Safety model
//!
//! All `unsafe` in this crate is in this file, and it is all in service of two
//! facts the compiler cannot check:
//!
//! - the mapping is valid for `len` bytes from `base` (established once, in
//!   `map`, and torn down in `Drop`)
//! - every access is bounds- and alignment-checked before it is issued
//!
//! What this crate CANNOT protect against: a read into an aperture no slave
//! answers. The Zynq AXI interconnect has no timeout, so that hangs the CPU
//! outright — not a fault, not a signal, nothing a process boundary or a
//! language can catch. Confirming the PL is configured before mapping is the
//! caller's job, and on this system it is done in Elixir.

use std::fs::OpenOptions;
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::AsRawFd;
use std::ptr;

/// A mapped physical window.
pub struct Fabric {
    base: *mut u8,
    phys: u64,
    len: usize,
}

// SAFETY: `*mut u8` is not `Send` only because the compiler cannot know what it
// points at. Here it is an address returned by `mmap`, owned exclusively by
// this `Fabric` and unmapped only by its `Drop`, with no thread affinity of any
// kind — the mapping belongs to the process, not to the thread that created it.
// Moving the struct between threads therefore hands over sole ownership of a
// region no other `Fabric` refers to.
//
// `Sync` is deliberately NOT implemented. `write32` takes `&self`, so a `Sync`
// impl would let two threads issue overlapping MMIO writes through shared
// references. That is not a Rust aliasing violation — the pointer does not
// derive from a reference to the mapped bytes — but it is a hardware race, and
// nothing in this type would prevent it.
unsafe impl Send for Fabric {}

impl Fabric {
    /// Map `len` bytes of physical memory starting at `phys`.
    ///
    /// `phys` must be page-aligned and `len` a multiple of the page size.
    pub fn map(phys: u64, len: usize) -> io::Result<Self> {
        let page = page_size();

        if phys % page as u64 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("base {phys:#x} is not page-aligned ({page} bytes)"),
            ));
        }

        if len == 0 || len % page != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("length {len} is not a non-zero multiple of the page size ({page})"),
            ));
        }

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_SYNC)
            .open("/dev/mem")?;

        // SAFETY: fd is open and valid for the duration of the call; a null
        // hint lets the kernel choose the address; len is page-aligned.
        let addr = unsafe {
            libc::mmap(
                ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                file.as_raw_fd(),
                phys as libc::off_t,
            )
        };

        if addr == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }

        // The mapping outlives the fd — closing the file here is deliberate and
        // correct, mmap holds its own reference to the underlying object.
        drop(file);

        Ok(Fabric {
            base: addr as *mut u8,
            phys,
            len,
        })
    }

    pub fn phys(&self) -> u64 {
        self.phys
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Read one 32-bit word at `offset` bytes from the base of the mapping.
    pub fn read32(&self, offset: usize) -> io::Result<u32> {
        let p = self.word_ptr(offset)?;

        // SAFETY: `p` came from `word_ptr`, which returns `Ok` only when
        // `offset % 4 == 0` and `offset + 4 <= self.len`. `self.base` is the
        // address returned by a successful `mmap` of `self.len` bytes and
        // stays live for the lifetime of `self` — only `Drop` unmaps it, and
        // `&self` here borrows the mapping alive. So `p` is valid for a 4-byte
        // read and correctly aligned for `u32`. Every bit pattern is a valid
        // `u32`, so no initialisation invariant applies.
        Ok(unsafe { ptr::read_volatile(p) })
    }

    /// Write one 32-bit word at `offset` bytes from the base of the mapping.
    ///
    /// Takes `&self` because the pointer is derived from `mmap`, not from a
    /// Rust reference to the mapped bytes, so writing through it does not
    /// violate any aliasing rule. Note that this means two holders of a
    /// `&Fabric` may both write; `Fabric` is `Send` but deliberately not
    /// `Sync`, and serialisation is enforced by the GenServer that owns the
    /// port, not by this type.
    pub fn write32(&self, offset: usize, value: u32) -> io::Result<()> {
        let p = self.word_ptr(offset)?;

        // SAFETY: as in `read32` — `word_ptr` has established alignment and
        // that the whole 4-byte access lies inside a mapping that outlives
        // this call. `u32` has no invalid bit patterns to write.
        unsafe { ptr::write_volatile(p, value) };
        Ok(())
    }

    /// Read `count` consecutive words starting at `offset`.
    pub fn read_block(&self, offset: usize, count: usize) -> io::Result<Vec<u32>> {
        // Check the whole span before issuing any access, so a partially
        // out-of-range request reads nothing at all rather than half of it.
        self.check_span(offset, count)?;

        let mut out = Vec::with_capacity(count);
        for i in 0..count {
            out.push(self.read32(offset + i * 4)?);
        }
        Ok(out)
    }

    /// Read the SAME word `count` times, returning every value.
    ///
    /// Not a mistake, and not the same as `read_block`. A register that sits in
    /// front of an auto-advancing buffer -- a FIFO or a capture memory whose
    /// read pointer steps on each access -- returns a DIFFERENT value on each
    /// read of one address. `read_block` walks addresses and would step off the
    /// end of the window; this walks time.
    ///
    /// Why it exists: on this platform a bus read costs ~1.06 us but a
    /// userspace round trip costs ~215 us. Pulling N words in one call turns a
    /// 200x overhead into a rounding error, and is the difference between
    /// reading a whole capture buffer in 17 ms and in 3.5 seconds.
    pub fn read_repeat(&self, offset: usize, count: usize) -> io::Result<Vec<u32>> {
        // One word, checked once: every access is to the same address.
        self.check_span(offset, 1)?;

        let mut out = Vec::with_capacity(count);
        for _ in 0..count {
            out.push(self.read32(offset)?);
        }
        Ok(out)
    }

    /// Write `values` to consecutive words starting at `offset`.
    pub fn write_block(&self, offset: usize, values: &[u32]) -> io::Result<()> {
        self.check_span(offset, values.len())?;

        for (i, v) in values.iter().enumerate() {
            self.write32(offset + i * 4, *v)?;
        }
        Ok(())
    }

    fn word_ptr(&self, offset: usize) -> io::Result<*mut u32> {
        if offset % 4 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("offset {offset:#x} is not 4-byte aligned"),
            ));
        }

        // offset + 4 cannot overflow in practice, but say so rather than rely
        // on it: an attacker-controlled offset near usize::MAX would otherwise
        // wrap past the bounds check.
        match offset.checked_add(4) {
            Some(end) if end <= self.len => {
                // SAFETY: end <= len, so base + offset is inside the mapping.
                Ok(unsafe { self.base.add(offset) } as *mut u32)
            }
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "offset {:#x} is outside the {:#x}-byte window at {:#x}",
                    offset, self.len, self.phys
                ),
            )),
        }
    }

    fn check_span(&self, offset: usize, count: usize) -> io::Result<()> {
        let bytes = count
            .checked_mul(4)
            .and_then(|b| offset.checked_add(b))
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "span overflows an address")
            })?;

        if offset % 4 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("offset {offset:#x} is not 4-byte aligned"),
            ));
        }

        if bytes > self.len {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "span {:#x}..{:#x} is outside the {:#x}-byte window at {:#x}",
                    offset, bytes, self.len, self.phys
                ),
            ));
        }

        Ok(())
    }
}

impl Drop for Fabric {
    fn drop(&mut self) {
        // SAFETY: base/len are exactly what mmap returned and have not moved.
        unsafe {
            libc::munmap(self.base as *mut libc::c_void, self.len);
        }
    }
}

fn page_size() -> usize {
    // SAFETY: sysconf with a valid name is always safe.
    let n = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if n > 0 {
        n as usize
    } else {
        4096
    }
}
