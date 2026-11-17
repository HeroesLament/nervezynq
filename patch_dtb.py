#!/usr/bin/env python3
"""
patch_dtb.py -- inject the PCAP readback reserved-memory node into the built DTB.

OBSOLETE (2026-09-28). Do not use. The system now builds from source and
nerves_system_libresdr/post-createfs.sh compiles zynq-libresdr.dtb from dts/ on
every system build, so the DTS is the single source of truth (it already
carries this node). Patching the artifact DTB by hand would be overwritten by
the next system build. Kept only for the history below.

## Why this exists instead of just editing the DTS

`nerves_system_libresdr` resolves to a PREBUILT PORTABLE ARTIFACT at
~/.nerves/artifacts/nerves_system_libresdr-portable-0.1.0. The DTS in the source
tree is compiled by buildroot's linux package, which is not in this build path at
all -- so editing dts/xilinx/zynq-libresdr.dts changes nothing about the firmware
`mix firmware` produces. That was verified rather than assumed: after a clean
`mix firmware`, the DTB inside the .fw contained ZERO occurrences of the new
node.

That mattered. Had it gone unnoticed, the reservation would not exist, 0x3FC00000
would be ordinary kernel-managed RAM, and the first readback would have DMA'd
4 MB of frame data straight over it.

Rebuilding the system from source means a full buildroot run in Docker. This is
the surgical alternative: decompile the artifact's DTB, add the node, recompile.
No kernel headers needed, because a decompiled DTB has every #include already
resolved.

A round-trip was checked first -- decompile, recompile, decompile, diff -- and is
byte-identical at 11200 bytes, so dtc is not silently reshaping anything.

The source DTS keeps the same node so a future from-source system build produces
the same result. This script is the bridge until then, not a replacement for it.
"""
import subprocess, sys, os, re

ART = os.path.expanduser("~/.nerves/artifacts/nerves_system_libresdr-portable-0.1.0/images")
DTB = os.path.join(ART, "zynq-libresdr.dtb")
BACKUP = DTB + ".orig"

NODE = '''
\treserved-memory {
\t\t#address-cells = <0x01>;
\t\t#size-cells = <0x01>;
\t\tranges;

\t\tpcap-readback@3fc00000 {
\t\t\treg = <0x3fc00000 0x400000>;
\t\t\tno-map;
\t\t};
\t};
'''

def run(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(a)}\n{r.stderr}")
    return r.stdout

def main():
    if not os.path.exists(DTB):
        sys.exit(f"no DTB at {DTB}")

    if not os.path.exists(BACKUP):
        run("cp", DTB, BACKUP)
        print(f"backed up -> {BACKUP}")

    # Always start from the pristine backup so re-running is idempotent and
    # never stacks two copies of the node.
    run("dtc", "-I", "dtb", "-O", "dts", "-o", "/tmp/p.dts", BACKUP)
    dts = open("/tmp/p.dts").read()

    if "pcap-readback" in dts:
        sys.exit("node already present in the PRISTINE dtb -- refusing, this is unexpected")

    # Anchor on memory@0's closing brace: the reservation is a sibling of the
    # memory node and must be at the root, not nested in whatever precedes it.
    m = re.search(r'(\tmemory@0 \{\n(?:[^\n]*\n)*?\t\};\n)', dts)
    if not m:
        sys.exit("could not locate memory@0 -- refusing to guess an insertion point")

    dts = dts[:m.end(1)] + NODE + dts[m.end(1):]
    open("/tmp/p.dts", "w").write(dts)

    run("dtc", "-I", "dts", "-O", "dtb", "-o", "/tmp/p.dtb", "/tmp/p.dts")

    # Verify by DECOMPILING the result, not by trusting the write.
    back = run("dtc", "-I", "dtb", "-O", "dts", "/tmp/p.dtb")
    if "pcap-readback@3fc00000" not in back:
        sys.exit("node absent after recompile -- refusing to install")
    if "0x3fc00000 0x400000" not in back:
        sys.exit("reg property wrong after recompile -- refusing to install")

    run("cp", "/tmp/p.dtb", DTB)
    print(f"installed patched DTB -> {DTB}")
    print(f"  size {os.path.getsize(DTB)} bytes (was {os.path.getsize(BACKUP)})")
    print("  restore with: cp %s %s" % (BACKUP, DTB))

if __name__ == "__main__":
    main()
