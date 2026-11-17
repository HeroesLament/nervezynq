# STATE DUMP — end of the readback-instrument session

> Raw session log: records what was believed at the time. Where it disagrees
> with `nerves_system_libresdr/README.md`, its `docs/`, or `nervezynq/AGENTS.md`,
> those win.


Everything below is measured or implemented, not planned. Planned work is at
the bottom, clearly separated.

## Board access

**Use the USB link. It is the only path that does not depend on the WAN.**

    board        172.31.248.125     (usb0)
    workstation  172.31.248.126     (usb0)
    file server  http://172.31.248.126:8101
                 serving ~/src/ehdl/designs/libresdr_radio/taps/serve

The LAN address changes every boot (observed .57, .60, .58 in one evening) and
vanished entirely when the workstation moved to a mobile hotspot. The USB
gadget link is point-to-point, needs no router, and survived that transition.
`ssh 172.31.248.125` drops straight into IEx.

There is no console. The PS UART is not wired to any FT4232H channel --
verified by writing bytes into the UART0 TX FIFO over JTAG and seeing nothing.
**Never modify the boot path.** A bad boot is unrecoverable without reflashing.

## The instrument, and what it is now known to do

### Files

    nervezynq/scripts/silicon_sweep.exs   canonical harness
    nervezynq/scripts/rb_check.exs        standalone readback probe
    <serve>/pl_load.exs                   bracketed PL loader
    <serve>/mirror.exs                    mirror-census batch
    <serve>/confine.exs                   confinement batch

`<serve>` copies are what the board fetches; `nervezynq/scripts/` is canonical.
Keep them in sync -- there is no git in this tree, so a drift is silent.

### Bootstrap, in order, on a fresh boot

    :inets.start()
    fetch silicon_sweep.exs, rb_check.exs, pl_load.exs -> /data
    Code.compile_file/1 on each
    SiliconSweep.Devcfg.start_link()      # NOT started by the app
    SiliconSweep.DmaBuf.start_link()      # NOT started by the app
    PlLoad.load("/data/mmcm_zinv.bin")    # THE PL IS EMPTY AT BOOT

`SiliconSweep.probe/0` reports every prerequisite by name and is the gate.

### The PL is NOT configured at boot

`PlLoad.preflight/0` reports `pcfg_done: false` on every fresh boot, confirmed
three times. The bitstream was removed from the SD boot partition to fix a
U-Boot hang and nothing replaced it. A readback against an unconfigured PL
returns a clean stream of zeros that completes without error and looks exactly
like a broken instrument. It cost most of an hour. Gate on
`PlLoad.pcfg_done?/0` -- PS-side, cannot hang.

### Readback API and its invariants

    words_for(n)       (n + 1) * 101      what the DMA collects
    engine_words(n)    == words_for(n)    what the command stream requests
    request_frames(n)  n + 2              frames to ASK for to get n aligned
    align/1            measured per read, returns %{lead:, offset:, confident:}
    to_frames/1        {:ok, frames, align} | {:error, {:unaligned, a}}
    split/2            split at a KNOWN offset -- callers that measured one
    readback_tile/1    public; asks for request_frames(tile.frames), trims back
    write_frames/2     public; MUST build payload via write_payload/1

**Symmetric lengths.** `engine_words == words_for` is deliberate. Both
asymmetric variants stalled the engine and cost a power cycle each:

    DMA 3232 / engine 3131    inverted the rule outright
    DMA 3232 / engine 3333    stalled on the SECOND read after a load, having
                              succeeded on the first

The second is the informative one: **the engine's output is not governed by
the type-2 count alone.** The asymmetric-lengths trick recorded earlier in this
file holds for short register-style reads where the collect count is far below
the production count. It does not generalise to one frame below.

**The lead is not a constant.** Measured lead 14 on one boot, 0 on the next
two, same board, same bitstream, same code, with the 209-assertion set
confirming each independently. Stable within a boot, which is what makes it
dangerous. Measure every read; never hardcode. Full detail in SILICON_MAP.md
section 22.

## Results, all reproduced through the harness path

    prjxray zynq7 CMT segbits          209 assertions, 0 disagreements
    census                             3136 / 3136 candidate positions
    mirror census                      3136 / 3136 proven BIDIRECTIONAL
    confinement                        36 frames compared, 0 collateral changes
    stability                          9 consecutive reads, no stall, queue idle

### The three-state round trip

    pristine      209 agree,   0 disagree
    all ones      206 agree,   3 disagree     (the 3 must-be-0 flip)
    all zeros       3 agree, 206 disagree     (the 206 must-be-1 flip)

The set contains 206 must-be-1 and 3 must-be-0. Both outcomes were predicted
before running and both came out to the bit. This exercises the write path,
the read path and prjxray's database simultaneously; a displaced reader, a
misdirected writer or a wrong database each fail it visibly and differently.

### Confinement is what licenses poke-and-observe

Ones into minors 28/29 words 0..48, then 36 frames compared word for word:
98 changed, all intended, **zero collateral**. Nothing moved in words 49..100
(shared with `HCLK_CMT_L` at offset 45 and `INT_L` at offset 48, whose windows
overlap this tile) and nothing moved in minors 30..35. A behaviour change after
a poke can therefore be attributed to the poked bits.

## Defects found and fixed this session

  * **`write_frames/2` omitted the pipeline pad frame.** Built its payload with
    `List.flatten/1` while `write_sequence/2` declares an FDRI packet of
    `(n+1)*101`. The engine sat mid-packet, consumed DESYNC as frame data, and
    the NEXT readback stalled -- so it presents as a broken reader. `:census`
    was immune because `write_all_ones/2` already used `write_payload/1`;
    `poke_load_test/4` was not, so the whole `:functional` strategy would have
    hit this on its first poke. Fixed and confirmed on silicon.
  * **`PL.enable_ps_pl_interfaces/0` reverted.** Dead code from a disproven
    theory, broken under `CONFIG_STRICT_DEVMEM`, and its raise sat between
    `Fabric.invalidate/0` and `Fabric.authorise/0`, stranding the fabric gated
    off.

## Hazards, each of which has cost at least one power cycle

  * A DMA that collects more than the engine produces stalls it. Recovery is a
    POWER CYCLE -- a reboot does not clear it and may not boot.
  * Never write CTRL/STAT to 0 to "power cycle the debug domain" over JTAG. It
    drops CDBGPWRUP and recovery gets strictly harder.
  * `mdw phys` on a `cortex_a` target executes loads on the core and wedges the
    board. Use a `mem_ap` target.
  * One PL AXI probe per power cycle. After a failed probe the AHB-AP holds the
    stall; the DP is clean (`CTRL/STAT 0xf0000000`, no sticky bits) and
    `DAPABORT` cannot reach it. The board survives, unlike the Elixir path.

## Operational notes on the tooling

  * **`mix nerves.discover.first -q` does NOT leave only the IP on stdout.**
    Mix's own environment banner and compile output precede it. Take the last
    line; `$(mix nerves.discover.first --quiet)` is broken on any run where mix
    has something to say, which includes the first run in a session.
  * **`wait_for_channel` is capped at ~60s** by the MCP layer whatever timeout
    is passed. Let the shell own the deadline and write results to a file; the
    channel is only a wake-up, and its signal is edge-triggered so it can be
    missed. Read the file, do not re-wait.
  * A board-reachability test cannot distinguish "board rebooted" from "my
    network went away". Key reboot detection on BEAM uptime, not on ping.

## Open questions

  * **What does the readback lead depend on?** Untested candidates: FCLK,
    engine state at load time, DESYNC history of the previous stream.
  * **Fabric AXI is still dead** and unexplained. Everything except the
    firmware build has been eliminated by measurement; the working image was
    destroyed by a `fwup -t complete` and there is no git history to rebuild it.
  * **GCAPTURE yields nothing.** 8 frame ranges, full tile, FASM-derived
    columns, explicit RCRC/GRESTORE/START, 1024 clocks -- all zero. Any plan
    that measures dynamic state via capture-and-readback is void on this setup.

## Next, in the order I would do it

  1. **Falsify the DRP premise before building anything.** The whole
     DRP-differential approach assumes MMCM DRP registers and CMT configuration
     bits are the same storage. If the DRP file is separate storage initialised
     at load, DRP writes will not appear in readback and the approach is void.
     Minimal harness, ONE DRP write to one known field, one readback. Cheapest
     test of the most expensive assumption.
  2. **EMIO GPIO as the AXI-free bridge.** PS GPIO banks 2/3 route into the
     fabric from the controller at `0xE000A000` -- a PS peripheral like SLCR
     and devcfg, with no M_AXI_GP0 involvement. Bit-bang DRP from Elixir.
  3. **Read the observables back over EMIO GPIO INPUTS, not GCAPTURE.** Route
     `LOCKED` and the high bits of a free-running counter clocked by the MMCM
     output to EMIO inputs. Two reads a known interval apart give frequency.
     This replaces the dead capture path and resurrects a general functional
     oracle, which is worth more than the CMT work on its own.
  4. Desk gap analysis: diff prjxray's zynq7 CMT segbits against the full
     attribute inventory to get a finite target list. No board needed.
  5. Deferred: static-only attributes by bit-flipping; census extension to
     other tile types.

Cite XAPP888 for the lock/filter table words rather than claiming independent
derivation -- silicon only ever shows one row at a time, and the provenance
matters.
