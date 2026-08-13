//! `devcfg_load` — reconfigure the PL from userspace by driving the Zynq-7000
//! Device Configuration Interface (DevC / PCAP) directly.
//!
//! Usage: `devcfg_load <bitstream.bin>`, where the file is a byte-swapped
//! `.bin` (see `Hw.Xilinx.Bit2Bin`), not a `.bit`.
//!
//! ## Why this exists
//!
//! This kernel offers no way to reconfigure the PL from userspace. Checked,
//! one at a time:
//!
//!   * no `/dev/xdevcfg` — the legacy character interface is gone
//!   * no `firmware`/`flags` attributes on `/sys/class/fpga_manager/fpga0`
//!   * no configfs device-tree overlays — `CONFIG_OF_CONFIGFS` is an
//!     out-of-tree Xilinx patch that mainline rejected
//!   * `/fpga-full` carries no `firmware-name`, and `of-fpga-region` only
//!     programs on overlay *apply*, never on probe, so unbind/rebind does
//!     nothing
//!
//! `CONFIG_OF_OVERLAY=y` is set, so the machinery is present — there is simply
//! no userspace trigger for it short of a kernel module. Meanwhile the DevC
//! block sits at `0xF800_7000` and can be driven from `/dev/mem`, which is the
//! same move `fabric_port` already makes for the AXI aperture.
//!
//! Without this, every bitstream iteration costs a write to the boot partition
//! and a reboot — around 50 seconds, and a corrupt bitstream can stop the board
//! booting at all. With it, a reload is a couple of seconds and never touches
//! `/mnt/boot`.
//!
//! ## Provenance
//!
//! Every register offset, bit position and step of the sequence below is
//! transcribed from the mainline Linux driver `drivers/fpga/zynq-fpga.c` —
//! `zynq_fpga_ops_write_init`, `zynq_step_dma` and
//! `zynq_fpga_ops_write_complete`. It is not reconstructed from the TRM, and
//! not from memory. Several values are genuinely counter-intuitive and would
//! have been wrong if guessed: `PCAP_PR` is bit 27 (not 29), `PCAP_MODE` is
//! bit 26 (not 28), `PCFG_DONE` is bit 2 of INT_STS (not bit 12 — that is
//! `D_P_DONE`), and the low bit of the DMA source address is not an address
//! bit at all but a "last transfer" marker.
//!
//! ## Why chunked DMA
//!
//! PCAP is DMA-only and takes physical addresses. Userspace has no access to
//! CMA and the device tree declares no `reserved-memory`, so there is no large
//! physically-contiguous buffer to be had. There does not need to be: the
//! configuration port is a stream, so a bitstream can be pushed as a series of
//! transfers that the config engine concatenates. We `mlock` an ordinary
//! anonymous mapping, resolve its physical pages through `/proc/self/pagemap`,
//! coalesce them into contiguous runs, and issue one transfer per run. A run
//! is usually many pages; worst case it is one page and we do ~1000 transfers,
//! which is still well under a second.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

// --- SLCR (System Level Control Registers) ---------------------------------
//
// `off_t` is a signed 32-bit type on armv7, and 0xF800_0000 does not fit in it.
// That is not a lint to silence: glibc's 32-bit `mmap` forwards to `mmap2` as
// `offset >> 12`, and an arithmetic shift of a negative value maps a different
// page entirely. `mmap64` takes a 64-bit offset and is the correct call for any
// physical address above 2 GiB -- which every Zynq peripheral is.
const SLCR_BASE: libc::off64_t = 0xF800_0000;
const MAP_LEN: usize = 0x8000; // covers SLCR at +0 and DevC at +0x7000

const SLCR_LOCK: usize = 0x004;
const SLCR_UNLOCK: usize = 0x008;
const SLCR_PCAP_CLK_CTRL: usize = 0x18C;
const SLCR_FPGA_RST_CTRL: usize = 0x240;
const SLCR_LVL_SHFTR_EN: usize = 0x900;

const SLCR_UNLOCK_KEY: u32 = 0xDF0D_767B;
const SLCR_LOCK_KEY: u32 = 0x0000_767B;

const LVL_SHFTR_DISABLE_ALL: u32 = 0x0;
const LVL_SHFTR_ENABLE_PS_TO_PL: u32 = 0xA;
const LVL_SHFTR_ENABLE_PL_TO_PS: u32 = 0xF;
const FPGA_RST_ALL: u32 = 0xF;
const FPGA_RST_NONE: u32 = 0x0;

// --- DevC ------------------------------------------------------------------
const DEVC: usize = 0x7000;

const CTRL_OFFSET: usize = DEVC + 0x00;
const LOCK_OFFSET: usize = DEVC + 0x04;
const INT_STS_OFFSET: usize = DEVC + 0x0C;
const INT_MASK_OFFSET: usize = DEVC + 0x10;
const STATUS_OFFSET: usize = DEVC + 0x14;
const DMA_SRC_ADDR_OFFSET: usize = DEVC + 0x18;
const DMA_DST_ADDR_OFFSET: usize = DEVC + 0x1C;
const DMA_SRC_LEN_OFFSET: usize = DEVC + 0x20;
const DMA_DEST_LEN_OFFSET: usize = DEVC + 0x24;
const UNLOCK_OFFSET: usize = DEVC + 0x34;
const MCTRL_OFFSET: usize = DEVC + 0x80;

const CTRL_PCFG_PROG_B: u32 = 1 << 30;
const CTRL_PCAP_PR: u32 = 1 << 27;
const CTRL_PCAP_MODE: u32 = 1 << 26;

const MCTRL_PCAP_LPBK: u32 = 1 << 4;

const STATUS_DMA_Q_F: u32 = 1 << 31;
const STATUS_DMA_Q_E: u32 = 1 << 30;
const STATUS_PCFG_INIT: u32 = 1 << 4;

const IXR_D_P_DONE: u32 = 1 << 12;
const IXR_PCFG_DONE: u32 = 1 << 2;
const IXR_ERROR_FLAGS: u32 = 0x00F0_C860;
const IXR_ALL: u32 = 0xF8F7_F87F;

const DEVC_UNLOCK_KEY: u32 = 0x757B_DF0D;
const DMA_INVALID_ADDRESS: u32 = 0xFFFF_FFFF;
const DMA_SRC_LAST_TRANSFER: u32 = 1;

struct Regs(*mut u8);

impl Regs {
    unsafe fn r(&self, off: usize) -> u32 {
        std::ptr::read_volatile(self.0.add(off) as *const u32)
    }
    unsafe fn w(&self, off: usize, v: u32) {
        std::ptr::write_volatile(self.0.add(off) as *mut u32, v)
    }
}

fn poll<F: Fn() -> bool>(what: &str, f: F) -> Result<(), String> {
    // The kernel uses 20us x 2_500_000. That is generous to the point of being
    // a hang; a tenth of a second is already three orders of magnitude beyond
    // what any of these transitions take.
    for _ in 0..100_000 {
        if f() {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_micros(1));
    }
    Err(format!("timeout waiting for {}", what))
}

/// Physical address of a userspace page, via `/proc/self/pagemap`.
///
/// Requires CAP_SYS_ADMIN to see the PFN at all — since Linux 4.0 an
/// unprivileged reader gets zeros rather than an error, which would look like
/// "every page is at physical address 0" and DMA the wrong memory into the
/// config port. So a zero PFN is treated as fatal, not as an address.
fn phys_of(pagemap: &mut File, vaddr: usize, page_size: usize) -> Result<u64, String> {
    let index = (vaddr / page_size) as u64;
    pagemap
        .seek(SeekFrom::Start(index * 8))
        .map_err(|e| format!("pagemap seek: {}", e))?;
    let mut buf = [0u8; 8];
    pagemap
        .read_exact(&mut buf)
        .map_err(|e| format!("pagemap read: {}", e))?;
    let entry = u64::from_ne_bytes(buf);

    if entry & (1 << 63) == 0 {
        return Err("page not present after mlock - refusing to DMA".into());
    }
    let pfn = entry & ((1u64 << 55) - 1);
    if pfn == 0 {
        return Err("pagemap returned PFN 0 - not running with CAP_SYS_ADMIN?".into());
    }
    Ok(pfn * page_size as u64)
}

fn main() {
    let path = match std::env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("usage: devcfg_load <bitstream.bin>");
            std::process::exit(2);
        }
    };

    match run(&path) {
        Ok(ms) => {
            println!("ok {} ms", ms);
        }
        Err(e) => {
            eprintln!("devcfg_load: {}", e);
            std::process::exit(1);
        }
    }
}

fn run(path: &str) -> Result<u128, String> {
    let started = std::time::Instant::now();

    let mut data = std::fs::read(path).map_err(|e| format!("{}: {}", path, e))?;

    // Transcribed from zynq_fpga_has_sync(). A .bit that was never byte-swapped
    // has AA 99 55 66 here and will be accepted by nothing downstream; catching
    // it now turns a silent dead PL into an error message.
    if !data.windows(4).any(|w| w == [0x66, 0x55, 0x99, 0xAA]) {
        return Err("no byte-swapped sync word 66 55 99 AA - is this a .bit rather than a .bin?".into());
    }

    // The DMA moves whole words.
    while data.len() % 4 != 0 {
        data.push(0);
    }

    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as usize;
    let buf_len = (data.len() + page_size - 1) / page_size * page_size;

    // --- staging buffer ----------------------------------------------------
    let buf = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            buf_len,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_POPULATE,
            -1,
            0,
        )
    };
    if buf == libc::MAP_FAILED {
        return Err(format!("mmap staging buffer: {}", std::io::Error::last_os_error()));
    }
    let buf = buf as *mut u8;

    // mlock pins the pages so their physical addresses cannot change between
    // us reading pagemap and the DMA engine dereferencing them.
    if unsafe { libc::mlock(buf as *const libc::c_void, buf_len) } != 0 {
        return Err(format!("mlock: {}", std::io::Error::last_os_error()));
    }
    unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), buf, data.len()) };

    // --- cache eviction probe ---------------------------------------------
    //
    // DIAGNOSTIC, NOT A FIX. The bitstream has just been written by ordinary
    // CPU stores, so it is sitting in dirty L1/L2 lines. The DevC DMA reads DDR
    // from behind the L2 and does not snoop -- which is why the kernel driver
    // calls dma_map_sgtable(DMA_TO_DEVICE) before programming, purely to clean
    // the caches.
    //
    // Userspace on Cortex-A9 cannot issue clean-to-PoC: those operations are
    // PL1-only, and ARM's cacheflush syscall only reaches PoU, which does not
    // get past L2. So this walks a scratch buffer several times the size of the
    // 512 KB L2, forcing capacity evictions that write our dirty lines back to
    // DDR as a side effect.
    //
    // This is exactly the kind of "probably works" that does not belong in this
    // codebase, and it is here only to decide whether cache coherency is really
    // the cause of the PCFG_DONE timeout. If it is, the real fix is a buffer
    // that was never cached: a `reserved-memory` node with `no-map`, mapped
    // uncached through /dev/mem. Delete this once that lands.
    if std::env::var("DEVCFG_NO_CACHE_PROBE").is_err() {
        let scratch_len = 4 * 1024 * 1024;
        let scratch = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                scratch_len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                -1,
                0,
            )
        };
        if scratch != libc::MAP_FAILED {
            let s = scratch as *mut u8;
            for pass in 0..2u8 {
                let mut i = 0usize;
                while i < scratch_len {
                    unsafe { std::ptr::write_volatile(s.add(i), pass) };
                    i += 32; // one write per cache line
                }
            }
            unsafe { libc::munmap(scratch, scratch_len) };
        }
    }

    // --- physical runs -----------------------------------------------------
    let mut pagemap = File::open("/proc/self/pagemap")
        .map_err(|e| format!("/proc/self/pagemap: {}", e))?;

    let mut runs: Vec<(u32, u32)> = Vec::new(); // (phys addr, byte length)
    let mut remaining = data.len();
    let mut off = 0usize;
    while remaining > 0 {
        let phys = phys_of(&mut pagemap, buf as usize + off, page_size)?;
        let this = remaining.min(page_size);
        match runs.last_mut() {
            Some((addr, len)) if (*addr as u64 + *len as u64) == phys => {
                *len += this as u32;
            }
            _ => runs.push((phys as u32, this as u32)),
        }
        off += this;
        remaining -= this;
    }

    // --- map SLCR + DevC ---------------------------------------------------
    let mem = unsafe {
        libc::open(b"/dev/mem\0".as_ptr() as *const libc::c_char, libc::O_RDWR | libc::O_SYNC)
    };
    if mem < 0 {
        return Err(format!("/dev/mem: {}", std::io::Error::last_os_error()));
    }
    let map = unsafe {
        libc::mmap64(
            std::ptr::null_mut(),
            MAP_LEN,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            mem,
            SLCR_BASE,
        )
    };
    if map == libc::MAP_FAILED {
        return Err(format!("mmap SLCR/DevC: {}", std::io::Error::last_os_error()));
    }
    let r = Regs(map as *mut u8);

    unsafe {
        // SLCR is write-protected out of reset.
        r.w(SLCR_UNLOCK, SLCR_UNLOCK_KEY);

        // The kernel driver takes the PCAP clock through the common clock
        // framework around each operation. With the driver idle that clock may
        // be gated, and every DevC register would read back as garbage. Enable
        // it explicitly rather than depending on who ran last.
        let clk = r.r(SLCR_PCAP_CLK_CTRL);
        r.w(SLCR_PCAP_CLK_CTRL, clk | 1);

        r.w(UNLOCK_OFFSET, DEVC_UNLOCK_KEY);

        // Quiesce the PS-PL boundary before the fabric disappears underneath
        // it. Order matters: resets asserted first, then shifters down, then
        // only the PS-to-PL direction back up.
        r.w(SLCR_FPGA_RST_CTRL, FPGA_RST_ALL);
        r.w(SLCR_LVL_SHFTR_EN, LVL_SHFTR_DISABLE_ALL);
        r.w(SLCR_LVL_SHFTR_EN, LVL_SHFTR_ENABLE_PS_TO_PL);

        // Rising edge on PCFG_INIT. PCFG_PROG_B is active low and PCFG_INIT
        // follows it, so each step has to be observed rather than assumed --
        // UG585 v1.10 p211, and zynq_fpga_ops_write_init does exactly this.
        let ctrl = r.r(CTRL_OFFSET);
        r.w(CTRL_OFFSET, ctrl | CTRL_PCFG_PROG_B);
        poll("PCFG_INIT high", || r.r(STATUS_OFFSET) & STATUS_PCFG_INIT != 0)?;

        let ctrl = r.r(CTRL_OFFSET);
        r.w(CTRL_OFFSET, ctrl & !CTRL_PCFG_PROG_B);
        poll("PCFG_INIT low", || r.r(STATUS_OFFSET) & STATUS_PCFG_INIT == 0)?;

        let ctrl = r.r(CTRL_OFFSET);
        r.w(CTRL_OFFSET, ctrl | CTRL_PCFG_PROG_B);
        poll("PCFG_INIT high again", || r.r(STATUS_OFFSET) & STATUS_PCFG_INIT != 0)?;

        // Select PCAP, full (non-partial) configuration, CPU in user mode.
        let ctrl = r.r(CTRL_OFFSET);
        r.w(CTRL_OFFSET, ctrl | CTRL_PCAP_PR | CTRL_PCAP_MODE);

        let status = r.r(STATUS_OFFSET);
        if status & STATUS_DMA_Q_F != 0 || status & STATUS_DMA_Q_E == 0 {
            return Err(format!("DMA command queue not idle (STATUS 0x{:08X})", status));
        }

        // Internal loopback would swallow the bitstream instead of configuring.
        let mctrl = r.r(MCTRL_OFFSET);
        r.w(MCTRL_OFFSET, mctrl & !MCTRL_PCAP_LPBK);

        r.w(INT_MASK_OFFSET, 0xFFFF_FFFF); // poll rather than interrupt
        r.w(INT_STS_OFFSET, IXR_ALL); // clear stale status

        // --- push the bitstream -------------------------------------------
        let last = runs.len() - 1;
        for (i, (addr, len)) in runs.iter().enumerate() {
            poll("DMA queue space", || r.r(STATUS_OFFSET) & STATUS_DMA_Q_F == 0)?;

            let src = if i == last { addr | DMA_SRC_LAST_TRANSFER } else { *addr };
            r.w(DMA_SRC_ADDR_OFFSET, src);
            r.w(DMA_DST_ADDR_OFFSET, DMA_INVALID_ADDRESS);
            r.w(DMA_SRC_LEN_OFFSET, len / 4);
            r.w(DMA_DEST_LEN_OFFSET, 0);
        }

        poll("DMA and PCAP done", || {
            let s = r.r(INT_STS_OFFSET);
            s & (IXR_D_P_DONE | IXR_ERROR_FLAGS) != 0
        })?;

        let sts = r.r(INT_STS_OFFSET);
        if sts & IXR_ERROR_FLAGS != 0 {
            return Err(format!(
                "DMA reported error: INT_STS 0x{:08X} CTRL 0x{:08X} STATUS 0x{:08X}",
                sts,
                r.r(CTRL_OFFSET),
                r.r(STATUS_OFFSET)
            ));
        }

        if poll("PCFG_DONE", || r.r(INT_STS_OFFSET) & IXR_PCFG_DONE != 0).is_err() {
            // Report what the hardware thinks rather than just "timeout". The
            // interesting distinction is whether the DMA moved the bytes
            // (D_P_DONE set, no error flags) but the configuration engine
            // rejected them -- which is what a cache-coherency problem looks
            // like, since the DMA faithfully transfers whatever is in RAM while
            // the bitstream is still sitting in dirty CPU cache lines.
            return Err(format!(
                "timeout waiting for PCFG_DONE: INT_STS 0x{:08X} STATUS 0x{:08X} \
                 CTRL 0x{:08X} MCTRL 0x{:08X} ({} runs, {} bytes, first run 0x{:08X}+{})",
                r.r(INT_STS_OFFSET),
                r.r(STATUS_OFFSET),
                r.r(CTRL_OFFSET),
                r.r(MCTRL_OFFSET),
                runs.len(),
                data.len(),
                runs[0].0,
                runs[0].1
            ));
        }

        // Hand PR control back to the ICAP.
        let ctrl = r.r(CTRL_OFFSET);
        r.w(CTRL_OFFSET, ctrl & !CTRL_PCAP_PR);

        // Bring the boundary back up in the reverse order.
        r.w(SLCR_LVL_SHFTR_EN, LVL_SHFTR_ENABLE_PL_TO_PS);
        r.w(SLCR_FPGA_RST_CTRL, FPGA_RST_NONE);

        let _ = r.r(LOCK_OFFSET);
        r.w(SLCR_LOCK, SLCR_LOCK_KEY);

        libc::munmap(map, MAP_LEN);
        libc::munlock(buf as *const libc::c_void, buf_len);
        libc::munmap(buf as *mut libc::c_void, buf_len);
        libc::close(mem);
    }

    Ok(started.elapsed().as_millis())
}
