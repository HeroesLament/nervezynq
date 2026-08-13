# NzScope — waterfall GUI for the Nervezynq SDR

wx_mvu desktop app: live FFT spectrum + scrolling waterfall for the
LibreSDR running the V1 snapshot driver (`Nervezynq.SDR`, `sdr.exs`).

```
┌──────────────────────────────────────────────────────┐
│ Board: [192.168.217.58   ] [Connect]                 │
│ Freq (MHz): [2412.0] [Tune] [−1 MHz][+1 MHz] Gain:[40]│
│ dB floor/ceil: [-100][0]  [Pause] [Clear]            │
│ LO 2.412 GHz | 8.0 Msps | gain 40 dB | 18.4 rows/s   │
│ ─────────────── spectrum trace ────────────────────  │
│ ─────────────── waterfall (turbo) ─────────────────  │
└──────────────────────────────────────────────────────┘
```

## Architecture

```
board (Nerves)                          Mac (this app)
──────────────                          ──────────────
Nervezynq.SDR.rx_binary(1020)           NzScope.Link ──FFT──▶ GLCanvas
        │                                    ▲   │              :spectrum
Nervezynq.WFTap ──{packet,4} TCP:7355────────┘   └───────────▶ :waterfall
  (scripts/wf_tap.exs, hot-loaded)               scene gets meta/stats only
```

* Transport is plain TCP with `{:packet, 4}` framing and
  `term_to_binary` payloads — both ends are BEAM. IQ is shipped raw
  (s16le interleaved): one 1020-pair snapshot is ~4 KB; at 20 rows/s
  that's 80 KB/s, three orders of magnitude below what usb0 does.
  (Opus/Membrane was considered and rejected: Opus is a lossy
  psychoacoustic codec — it would fabricate spectrum. Nothing here needs
  compressing.)
* The FFT is pure Elixir (`NzScope.FFT`): Hann window, radix-2 complex
  FFT, dB, fftshift (DC centered). ~1–3 ms per 1024-point row. When V2
  `stream_rx/2` raises row rates 100×, replace this module with a NIF —
  minutemodem's `ui_dsp` is the template.
* Hot data never touches the MVU scene: `Link` sends bins straight to
  the canvases (`WxMVU.GLCanvas.send_data/2`), the scene hears meta at
  human rate.
* `NzScope.Canvas.Waterfall` is minutemodem's proven `Spectrogram`
  adapted for complex spectra (full-width rows, runtime dB range,
  `:turbo` colormap).

## Running against the board

Board side (IEx over ssh, after the usual bootstrap; `wf_tap.exs` is
served next to `sdr.exs`):

```elixir
Code.compile_file("/data/sdr.exs")
Code.compile_file("/data/wf_tap.exs")
{:ok, _} = Nervezynq.SDR.open()      # 2.412 GHz, 8 Msps, 40 dB
Nervezynq.WFTap.start()              # TCP :7355, ~20 rows/s
```

Host side:

```sh
cd ~/src/nervezynq/scope
mix deps.get
iex -S mix
```

Enter the board IP (usb0 `172.31.248.125`, or whatever `.board-ip`
says), Connect. Tune/gain/pause round-trip through the tap into
`Nervezynq.SDR.set_frequency/1` etc.

## Running without the board

```elixir
iex> NzScope.Sim.start()             # protocol-identical fake board
iex> # then Connect to 127.0.0.1 in the GUI
```

The sim honours retune/gain — the carrier sits at 2 412.5 MHz RF, so
tuning ±1 MHz moves the line across the display like the real thing.

## What to expect from V1 signals (by design, see SDR_V1.md)

* Rows are snapshot captures: gapless within 1020 pairs, dead time
  between rows. Row rate ≈ capture-loop rate, **not** fs/N.
* A DC spike at center — the untranscribed DC-offset cal. Real.
* Absolute dB is not lab-grade until the cal work lands. 0 dBFS is
  calibrated to a full-scale 12-bit tone, nothing more.

## Protocol (wf_tap.exs header is authoritative)

Board → host: `{:hello, meta}`, `{:iq, meta, iq_bin}`, `{:status, map}`,
`{:error, term}`. Host → board: `{:retune, hz}`, `{:gain, db}`,
`{:pause, bool}`, `{:nsamples, n}`, `{:interval, ms}`, `:status`.
