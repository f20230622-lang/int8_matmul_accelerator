import os
import random
import shutil
import subprocess
import sys
import re
import csv

import numpy as np

ROOT = r"C:\Users\khnay\Desktop\MMUL\project_1"
SRC = os.path.join(ROOT, "project_1.srcs", "sources_1", "new")
SIM = os.path.join(ROOT, "project_1.srcs", "sim_1", "new")
WORK = os.path.join(ROOT, "python", "work_dma")
VIVADO_BIN = r"C:\AMDDesignTools\2025.2\Vivado\bin"

MEMWORDS = 4096
BAD = 0x3000
M32 = 0xFFFFFFFF

# 64-bit AXI4:
# Reads: 16 beats/burst = 128 bytes.
# C writeback: 32 beats/burst = 256 bytes.
READ_BURST_BYTES = 16 * 8
WRITE_BURST_BYTES = 32 * 8

READ_BURSTS = 256 // READ_BURST_BYTES
WRITE_BURSTS = 1024 // WRITE_BURST_BYTES

RTL = [
    "sram_buf.v",
    "a_buf.v",
    "b_buf.v",
    "c_buf.v",
    "axi_dma.v",
]

SIM_FILES = [
    "axi_mem_model.v",
    "tb_axi_dma.v",
]


def tool(name):
    for candidate in (
        os.path.join(VIVADO_BIN, name + ".bat"),
        os.path.join(VIVADO_BIN, name + ".exe"),
    ):
        if os.path.isfile(candidate):
            return candidate

    found = shutil.which(name)
    if found:
        return found

    sys.exit(f"{name} not found in {VIVADO_BIN} or on PATH.")


def aligned(addr):
    return addr % 128 == 0


def read_err(addr):
    return (not aligned(addr)) or addr >= BAD


def write_err(addr):
    return (not aligned(addr)) or addr >= BAD


def gen_vectors():
    os.makedirs(WORK, exist_ok=True)

    rng = random.Random(2026)
    nrng = np.random.default_rng(2026)

    init = [rng.getrandbits(32) for _ in range(MEMWORDS)]

    def al(max_addr):
        return rng.randrange(0, max_addr // 128 + 1) * 128

    def bad_a():
        return BAD + 128 * rng.randrange(0, 31)

    def bad_c():
        return BAD + 128 * rng.randrange(0, 25)

    jobs = []

    for _ in range(10):
        jobs.append((al(0x2F00), al(0x2F00), al(0x2C00)))

    # Misaligned-address cases.
    jobs.append((al(0x2F00) + 0x20, al(0x2F00), al(0x2C00)))
    jobs.append((al(0x2F00), al(0x2F00) + 4, al(0x2C00)))
    jobs.append((al(0x2F00), al(0x2F00), al(0x2C00) + 0x3C))

    # Addresses outside the valid memory region.
    jobs.append((bad_a(), al(0x2F00), al(0x2C00)))
    jobs.append((al(0x2F00), bad_a(), al(0x2C00)))
    jobs.append((al(0x2F00), al(0x2F00), bad_c()))
    jobs.append((al(0x2F00) + 0x20, al(0x2F00), bad_c()))

    for _ in range(3):
        jobs.append((al(0x2F00), al(0x2F00), al(0x2C00)))

    njobs = len(jobs)

    cmat = nrng.integers(
        -(2**31), 2**31,
        size=(njobs, 256),
        dtype=np.int64,
    )

    # Count aligned burst requests. Invalid aligned addresses may
    # still be issued and return an error response.
    exp_ar = sum(
        (READ_BURSTS if aligned(a) else 0)
        + (READ_BURSTS if aligned(b) else 0)
        for a, b, c in jobs
    )

    exp_aw = sum(
        WRITE_BURSTS if aligned(c) else 0
        for a, b, c in jobs
    )

    # Golden memory after successful output stores.
    expected = init[:]

    for j, (a, b, c) in enumerate(jobs):
        if not write_err(c):
            for w in range(256):
                expected[c // 4 + w] = int(cmat[j][w]) & M32

    with open(os.path.join(WORK, "dma_dram_init.hex"), "w") as f:
        for value in init:
            f.write(f"{value:08x}\n")

    with open(os.path.join(WORK, "dma_script.hex"), "w") as f:
        f.write(f"{njobs:08x}\n")
        f.write(f"{exp_ar:08x}\n")
        f.write(f"{exp_aw:08x}\n")

        for a, b, c in jobs:
            row = [
                a, b, c,
                int(read_err(a)),
                int(read_err(b)),
                int(write_err(c)),
                0, 0,
            ]
            f.write(" ".join(f"{value:08x}" for value in row) + "\n")

    with open(os.path.join(WORK, "dma_cmat.hex"), "w") as f:
        for j in range(njobs):
            for value in cmat[j]:
                f.write(f"{int(value) & M32:08x}\n")

    err_jobs = sum(
        1 for a, b, c in jobs
        if read_err(a) or read_err(b) or write_err(c)
    )

    print(
        f"Generated {njobs} jobs ({err_jobs} with expected errors); "
        f"expected {exp_ar} AR bursts and {exp_aw} AW bursts"
    )

    return expected


def load_final():
    path = os.path.join(WORK, "dma_dram_final.hex")

    if not os.path.isfile(path):
        sys.exit(f"Missing simulation output: {path}")

    words = []

    with open(path) as f:
        for line in f:
            line = line.strip()

            if not line or line.startswith("//") or line.startswith("@"):
                continue

            for token in line.split():
                try:
                    words.append(int(token, 16))
                except ValueError:
                    words.append(-1)

    return words


def run(command):
    print(">", subprocess.list2cmdline(command))

    result = subprocess.run(
        command,
        cwd=WORK,
        capture_output=True,
        text=True,
    )

    if result.stdout:
        print(result.stdout)

    if result.stderr:
        print(result.stderr)

    if result.returncode != 0:
        sys.exit(f"Command failed: {os.path.basename(command[0])}")

    return result.stdout


def save_performance(output):
    matches = re.findall(
        r"PERF job=(\d+) op=(LOAD_A|LOAD_B|STORE_C) "
        r"cycles=(\d+) err=(\d+)",
        output,
    )

    if not matches:
        print("No performance lines found in simulator output.")
        return

    path = os.path.join(WORK, "dma_performance.csv")
    samples = {"LOAD_A": [], "LOAD_B": [], "STORE_C": []}

    with open(path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["job", "operation", "cycles", "error"])

        for job, op, cycles, err in matches:
            cycles = int(cycles)
            err = int(err)

            writer.writerow([int(job), op, cycles, err])

            if not err and cycles > 0:
                samples[op].append(cycles)

    print("\n========== DMA PERFORMANCE ==========")

    for op, values in samples.items():
        if values:
            print(
                f"AVG {op}: {sum(values) / len(values):.2f} cycles "
                f"({len(values)} successful samples)"
            )
        else:
            print(f"AVG {op}: no successful samples")

    print(f"Saved results to {path}")


def main():
    os.makedirs(WORK, exist_ok=True)

    xvlog = tool("xvlog")
    xelab = tool("xelab")
    xsim = tool("xsim")

    source_files = [os.path.join(SRC, f) for f in RTL]
    sim_files = [os.path.join(SIM, f) for f in SIM_FILES]

    missing = [
        path for path in source_files + sim_files
        if not os.path.isfile(path)
    ]

    if missing:
        sys.exit("Missing source files:\n" + "\n".join(missing))

    expected = gen_vectors()

    run([xvlog] + source_files + sim_files)

    run([
        xelab,
        "tb_axi_dma",
        "-s", "dma_snap",
        "-debug", "typical",
    ])

    output = run([xsim, "dma_snap", "-runall"])

    if "TEST PASSED" not in output:
        sys.exit("RESULT: FAIL (testbench checks)")

    actual = load_final()

    if len(actual) != MEMWORDS:
        sys.exit(
            f"RESULT: FAIL: got {len(actual)} memory words, "
            f"expected {MEMWORDS}"
        )

    mismatches = [
        i for i in range(MEMWORDS)
        if actual[i] != expected[i]
    ]

    if mismatches:
        for i in mismatches[:10]:
            print(
                f"DRAM mismatch at byte address 0x{i*4:04x}: "
                f"got {actual[i]:08x}, expected {expected[i]:08x}"
            )

        sys.exit(
            f"RESULT: FAIL ({len(mismatches)} DRAM words differ)"
        )

    print(f"DRAM image matches the Python model ({MEMWORDS} words).")
    save_performance(output)
    print("RESULT: PASS")


if __name__ == "__main__":
    main()