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
WORK = os.path.join(ROOT, "python", "work_top")
VIVADO_BIN = r"C:\AMDDesignTools\2025.2\Vivado\bin"

MEMWORDS = 4096
BAD = 0x3000
M32 = 0xFFFFFFFF

# 64-bit AXI:
# A/B reads: 16 beats per burst.
# C writeback: 32 beats per burst.
A_BURST_BYTES = 16 * 8
C_BURST_BYTES = 32 * 8

A_BURSTS = 256 // A_BURST_BYTES
C_BURSTS = 1024 // C_BURST_BYTES

RTL = [
    "mac_pe.v",
    "systolic_array.v",
    "sram_buf.v",
    "a_buf.v",
    "b_buf.v",
    "c_buf.v",
    "mmul_feeder.v",
    "mmul_ctrl.v",
    "axil_regs.v",
    "axi_dma.v",
    "mmul_top.v",
]

# Your testbench is named tb_mmul_top.v.
SIMF = [
    "axi_mem_model.v",
    "tb_mmul_top.v",
]


def tool(name):
    candidates = [
        os.path.join(VIVADO_BIN, name + ".bat"),
        os.path.join(VIVADO_BIN, name + ".exe"),
    ]

    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate

    found = shutil.which(name)
    if found:
        return found

    sys.exit(
        f"ERROR: {name} not found in {VIVADO_BIN} or on PATH."
    )


def aligned(addr):
    return addr % 128 == 0


def addr_err(addr):
    return (not aligned(addr)) or addr >= BAD


def gen_vectors():
    os.makedirs(WORK, exist_ok=True)
    rng = random.Random(77)

    img = np.array(
        [rng.getrandbits(32) for _ in range(MEMWORDS)],
        dtype=np.uint32,
    )

    def put_bytes(addr, mat):
        raw = np.ascontiguousarray(
            mat, dtype=np.int8
        ).tobytes()

        img[
            addr // 4:
            addr // 4 + len(raw) // 4
        ] = np.frombuffer(raw, dtype="<u4")

    # Corner-case operands.
    put_bytes(0x0000, np.full((16, 16), -128))
    put_bytes(0x0100, np.full((16, 16), -128))
    put_bytes(0x0200, np.eye(16))
    put_bytes(0x0C00, np.zeros((16, 16)))

    def al(lo, hi):
        return (
            rng.randrange(lo // 128, hi // 128 + 1)
            * 128
        )

    def normal():
        return [
            al(0x1000, 0x2F00),
            al(0x1000, 0x2F00),
            al(0x1000, 0x2C00),
            0,
        ]

    jobs = [
        [0x0000, 0x0100, 0x0400, 0],
        [0x0200, 0x0300, 0x0800, 0],
        [0x0C00, 0x0D00, 0x0E00, 0],
    ]

    for _ in range(8):
        jobs.append(normal())

    # Misalignment tests.
    j = normal()
    j[0] += 0x20
    jobs.append(j)

    j = normal()
    j[1] += 4
    jobs.append(j)

    j = normal()
    j[2] += 0x3C
    jobs.append(j)

    # Invalid addresses should return errors.
    j = normal()
    j[0] = BAD + 128 * rng.randrange(0, 31)
    jobs.append(j)

    j = normal()
    j[1] = BAD + 128 * rng.randrange(0, 31)
    jobs.append(j)

    j = normal()
    j[2] = BAD + 128 * rng.randrange(0, 25)
    jobs.append(j)

    # Soft-reset scenarios.
    j = normal()
    j[3] = 1
    jobs.append(j)

    jobs.append(normal())

    j = normal()
    j[3] = 1
    jobs.append(j)

    jobs.append(normal())
    jobs[7][3] = 1

    # --------------------------------------------------
    # NumPy golden model and expected AXI burst counts.
    # --------------------------------------------------
    exp = img.copy()
    exp_ar = 0
    exp_aw = 0

    for a, b, c, soft in jobs:
        a_err = addr_err(a)
        b_err = addr_err(b)
        c_err = addr_err(c)

        # Reads are counted for aligned addresses,
        # including aligned invalid addresses.
        if aligned(a):
            exp_ar += A_BURSTS

        if not a_err:
            if aligned(b):
                exp_ar += A_BURSTS

            if not b_err:
                if aligned(c):
                    exp_aw += C_BURSTS

                if not c_err:
                    A = np.frombuffer(
                        exp[a // 4:a // 4 + 64]
                        .astype("<u4").tobytes(),
                        dtype=np.int8,
                    ).reshape(16, 16).astype(np.int64)

                    B = np.frombuffer(
                        exp[b // 4:b // 4 + 64]
                        .astype("<u4").tobytes(),
                        dtype=np.int8,
                    ).reshape(16, 16).astype(np.int64)

                    C = A @ B

                    exp[c // 4:c // 4 + 256] = (
                        C.flatten() & M32
                    ).astype(np.uint32)

    # Initial DRAM image.
    with open(
        os.path.join(WORK, "top_dram_init.hex"),
        "w",
    ) as f:
        for value in img:
            f.write(f"{int(value):08x}\n")

    # Testbench control file.
    with open(
        os.path.join(WORK, "top_script.hex"),
        "w",
    ) as f:
        f.write(
            f"{len(jobs):08x}\n"
            f"{exp_ar:08x}\n"
            f"{exp_aw:08x}\n"
        )

        for a, b, c, soft in jobs:
            err = int(
                addr_err(a)
                or addr_err(b)
                or addr_err(c)
            )

            row = [a, b, c, soft, err, 0, 0, 0]
            f.write(
                " ".join(f"{value:08x}" for value in row)
                + "\n"
            )

    n_err = sum(
        1
        for a, b, c, soft in jobs
        if addr_err(a) or addr_err(b) or addr_err(c)
    )

    print(
        f"Generated {len(jobs)} jobs "
        f"({n_err} expected errors, "
        f"{sum(s for *_, s in jobs)} soft resets); "
        f"expect {exp_ar} AR, {exp_aw} AW bursts"
    )

    return exp


def load_final():
    words = []

    path = os.path.join(WORK, "top_dram_final.hex")

    if not os.path.isfile(path):
        sys.exit(f"ERROR: DRAM output file not found: {path}")

    with open(path) as f:
        for line in f:
            line = line.strip()

            if (
                not line
                or line.startswith("//")
                or line.startswith("@")
            ):
                continue

            for token in line.split():
                try:
                    words.append(int(token, 16))
                except ValueError:
                    words.append(-1)

    return words


def run(cmd):
    print(">", subprocess.list2cmdline(cmd))

    result = subprocess.run(
        cmd,
        cwd=WORK,
        capture_output=True,
        text=True,
    )

    if result.stdout:
        print(result.stdout)

    if result.stderr:
        print(result.stderr)

    if result.returncode != 0:
        sys.exit(
            f"Command failed: {os.path.basename(cmd[0])}"
        )

    return result.stdout


def save_performance(output):
    matches = re.findall(
        r"PERF_TOP job=(\d+) cycles=(\d+)",
        output,
    )

    if not matches:
        print("No PERF_TOP measurements found.")
        return

    path = os.path.join(
        WORK,
        "top_performance_64bit.csv",
    )

    values = []

    with open(path, "w", newline="") as f:
        writer = csv.writer(f)

        writer.writerow([
            "job",
            "cycles",
            "latency_us_at_100MHz",
        ])

        for job, cycles in matches:
            job = int(job)
            cycles = int(cycles)
            values.append(cycles)

            writer.writerow([
                job,
                cycles,
                cycles / 100.0,
            ])

    avg = sum(values) / len(values)

    print("\n========== END-TO-END PERFORMANCE ==========")
    print(f"Measured jobs: {len(values)}")
    print(f"Average cycles: {avg:.2f}")
    print(
        f"Average latency at 100 MHz: "
        f"{avg / 100.0:.4f} us"
    )
    print(f"Saved results to {path}")


def main():
    os.makedirs(WORK, exist_ok=True)

    xvlog = tool("xvlog")
    xelab = tool("xelab")
    xsim = tool("xsim")

    # Catch incorrect filenames before invoking Vivado.
    required_files = (
        [os.path.join(SRC, f) for f in RTL]
        + [os.path.join(SIM, f) for f in SIMF]
    )

    missing = [
        path for path in required_files
        if not os.path.isfile(path)
    ]

    if missing:
        print("ERROR: Required source files are missing:")
        for path in missing:
            print(f"  {path}")
        sys.exit(1)

    exp = gen_vectors()

    # Compile RTL and simulation files.
    run(
        [xvlog]
        + [os.path.join(SRC, f) for f in RTL]
        + [os.path.join(SIM, f) for f in SIMF]
    )

    # The testbench module remains named tb_mmul_top.
    run([
        xelab,
        "tb_mmul_top",
        "-s",
        "top_snap",
        "-debug",
        "typical",
    ])

    output = run([
        xsim,
        "top_snap",
        "-runall",
    ])

    if "TEST PASSED" not in output:
        sys.exit("RESULT: FAIL (testbench checks)")

    got = load_final()

    if len(got) != MEMWORDS:
        sys.exit(
            f"RESULT: FAIL (dump has {len(got)} words; "
            f"expected {MEMWORDS})"
        )

    bad = [
        i
        for i in range(MEMWORDS)
        if got[i] != int(exp[i])
    ]

    if bad:
        for i in bad[:10]:
            print(
                f"DRAM mismatch at 0x{i * 4:04x}: "
                f"got {got[i]:08x}, "
                f"expected {int(exp[i]):08x}"
            )

        sys.exit(
            f"RESULT: FAIL ({len(bad)} words differ "
            f"from the NumPy model)"
        )

    print(
        f"DRAM image matches NumPy: "
        f"{MEMWORDS} words checked"
    )

    save_performance(output)
    print("RESULT: PASS")


if __name__ == "__main__":
    main()
