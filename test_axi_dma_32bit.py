import os
import random
import shutil
import subprocess
import sys
import re
import csv
import numpy as np

ROOT = r"C:\Users\khnay\Desktop\MMUL\project_1"
SRC  = os.path.join(ROOT, "project_1.srcs", "sources_1", "new")
SIM  = os.path.join(ROOT, "project_1.srcs", "sim_1", "new")
WORK = os.path.join(ROOT, "python", "work_dma32")
BASE32 = os.path.join(os.path.dirname(ROOT), "baseline32")
DMA32 = os.path.join(BASE32, "axi_dma.v")
TB32 = os.path.join(BASE32, "tb_axi_dma.v")
VIVADO_BIN = r"C:\AMDDesignTools\2025.2\Vivado\bin"

MEMWORDS = 4096
BAD = 0x3000                 # accesses >= BAD return SLVERR in the slave model
M32 = 0xFFFFFFFF

RTL_COMMON = ["sram_buf.v", "a_buf.v", "b_buf.v", "c_buf.v"]


def tool(name):
    for cand in (os.path.join(VIVADO_BIN, name + ".bat"),
                 os.path.join(VIVADO_BIN, name + ".exe")):
        if os.path.isfile(cand):
            return cand
    found = shutil.which(name)
    if found:
        return found
    sys.exit(f"{name} not found in {VIVADO_BIN} or on PATH.")


def aligned(addr):
    return addr % 64 == 0


def read_err(addr):      # LOAD_A / LOAD_B fails?
    return (not aligned(addr)) or addr >= BAD


def write_err(addr):     # STORE_C fails?
    return (not aligned(addr)) or addr >= BAD


def gen_vectors():
    os.makedirs(WORK, exist_ok=True)
    rng = random.Random(2026)
    nrng = np.random.default_rng(2026)

    init = [rng.getrandbits(32) for _ in range(MEMWORDS)]

    def al(max_addr):
        return rng.randrange(0, max_addr // 64 + 1) * 64

    def bad_a():
        return BAD + 64 * rng.randrange(0, 61)       # 256 B region stays inside 16 KB

    def bad_c():
        return BAD + 64 * rng.randrange(0, 49)       # 1 KB region stays inside 16 KB

    jobs = []
    for _ in range(10):                              # normal jobs
        jobs.append((al(0x2F00), al(0x2F00), al(0x2C00)))
    jobs.append((al(0x2F00) + 0x20, al(0x2F00), al(0x2C00)))   # A misaligned
    jobs.append((al(0x2F00), al(0x2F00) + 4, al(0x2C00)))      # B misaligned
    jobs.append((al(0x2F00), al(0x2F00), al(0x2C00) + 0x3C))   # C misaligned
    jobs.append((bad_a(), al(0x2F00), al(0x2C00)))             # A read error
    jobs.append((al(0x2F00), bad_a(), al(0x2C00)))             # B read error
    jobs.append((al(0x2F00), al(0x2F00), bad_c()))             # C write error
    jobs.append((al(0x2F00) + 0x20, al(0x2F00), bad_c()))      # mixed
    for _ in range(3):                                         # recovery
        jobs.append((al(0x2F00), al(0x2F00), al(0x2C00)))

    njobs = len(jobs)
    cmat = nrng.integers(-2**31, 2**31, size=(njobs, 256), dtype=np.int64)

    exp_ar = sum((4 if aligned(a) else 0) + (4 if aligned(b) else 0) for a, b, c in jobs)
    exp_aw = sum(16 if aligned(c) else 0 for a, b, c in jobs)

    # golden DRAM after all jobs
    exp = init[:]
    for j, (a, b, c) in enumerate(jobs):
        if not write_err(c):
            for w in range(256):
                exp[c // 4 + w] = int(cmat[j][w]) & M32

    with open(os.path.join(WORK, "dma_dram_init.hex"), "w") as f:
        for v in init:
            f.write(f"{v:08x}\n")
    with open(os.path.join(WORK, "dma_script.hex"), "w") as f:
        f.write(f"{njobs:08x}\n{exp_ar:08x}\n{exp_aw:08x}\n")
        for a, b, c in jobs:
            row = [a, b, c, int(read_err(a)), int(read_err(b)), int(write_err(c)), 0, 0]
            f.write(" ".join(f"{v:08x}" for v in row) + "\n")
    with open(os.path.join(WORK, "dma_cmat.hex"), "w") as f:
        for j in range(njobs):
            for v in cmat[j]:
                f.write(f"{int(v) & M32:08x}\n")

    err_jobs = sum(1 for a, b, c in jobs if read_err(a) or read_err(b) or write_err(c))
    print(f"Generated {njobs} jobs ({err_jobs} with expected errors), "
          f"expect {exp_ar} AR and {exp_aw} AW bursts")
    return exp


def load_final():
    words = []
    with open(os.path.join(WORK, "dma_dram_final.hex")) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//") or line.startswith("@"):
                continue
            for tok in line.split():
                try:
                    words.append(int(tok, 16))
                except ValueError:
                    words.append(-1)          # x/z in the dump
    return words


def run(cmd):
    print(">", " ".join(cmd))
    r = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        sys.exit(f"Command failed: {os.path.basename(cmd[0])}")
    return r.stdout


def main():
    xvlog, xelab, xsim = tool("xvlog"), tool("xelab"), tool("xsim")

    exp = gen_vectors()

    if not os.path.isfile(DMA32):
        sys.exit(f"Missing original 32-bit DMA RTL: {DMA32}")
    if not os.path.isfile(TB32):
        sys.exit(f"Missing instrumented 32-bit testbench: {TB32}")

    # Reuse the project's buffer modules, but compile the saved 32-bit DMA
    # and its own instrumented testbench from the separate baseline folder.
    source_files = [os.path.join(SRC, f) for f in RTL_COMMON]
    source_files += [DMA32, TB32]
    run([xvlog] + source_files)
    run([xelab, "tb_axi_dma", "-s", "dma_snap", "-debug", "typical"])
    out = run([xsim, "dma_snap", "-runall"])
    print(out)

    if "TEST PASSED" not in out:
        sys.exit("RESULT: FAIL (testbench checks)")

    got = load_final()
    if len(got) != MEMWORDS:
        sys.exit(f"RESULT: FAIL (dump has {len(got)} words, expected {MEMWORDS})")
    bad = [i for i in range(MEMWORDS) if got[i] != exp[i]]
    if bad:
        for i in bad[:10]:
            print(f"DRAM mismatch at byte address 0x{i*4:04x}: got {got[i]:08x}, "
                  f"expected {exp[i]:08x}")
        sys.exit(f"RESULT: FAIL ({len(bad)} words differ)")

    print(f"DRAM image matches the Python model ({MEMWORDS} words)")

    # Parse per-command latency emitted by the instrumented 32-bit testbench.
    perf = re.findall(
        r"PERF job=(\d+) op=(LOAD_A|LOAD_B|STORE_C) cycles=(\d+) err=(\d+)",
        out,
    )
    perf_path = os.path.join(WORK, "dma_performance_32bit.csv")
    samples = {"LOAD_A": [], "LOAD_B": [], "STORE_C": []}
    with open(perf_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["job", "operation", "cycles", "error"])
        for job, op, cycles, error in perf:
            cycles, error = int(cycles), int(error)
            writer.writerow([int(job), op, cycles, error])
            if not error and cycles > 0:
                samples[op].append(cycles)

    print("\n========== 32-BIT DMA PERFORMANCE ==========")
    for op, values in samples.items():
        if values:
            print(f"AVG {op}: {sum(values) / len(values):.2f} cycles ({len(values)} successful samples)")
        else:
            print(f"AVG {op}: no successful samples")
    print(f"Saved results to {perf_path}")
    print("RESULT: PASS")


if __name__ == "__main__":
    main()