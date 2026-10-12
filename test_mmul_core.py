import os
import shutil
import subprocess
import sys
import numpy as np

ROOT = r"C:\Users\khnay\Desktop\MMUL\project_1"
SRC  = os.path.join(ROOT, "project_1.srcs", "sources_1", "new")
SIM  = os.path.join(ROOT, "project_1.srcs", "sim_1", "new")
WORK = os.path.join(ROOT, "python", "work_core")
VIVADO_BIN = r"C:\AMDDesignTools\2025.2\Vivado\bin"

N = 16
NTRIALS = 24

RTL = ["mac_pe.v", "systolic_array.v", "sram_buf.v", "a_buf.v", "b_buf.v", "mmul_feeder.v"]


def tool(name):
    for cand in (os.path.join(VIVADO_BIN, name + ".bat"),
                 os.path.join(VIVADO_BIN, name + ".exe")):
        if os.path.isfile(cand):
            return cand
    found = shutil.which(name)
    if found:
        return found
    sys.exit(f"{name} not found in {VIVADO_BIN} or on PATH.")


def dump_words(name, mats):
    """Row-major INT8 matrices packed as little-endian 32-bit words (as in DRAM)."""
    with open(os.path.join(WORK, name), "w") as f:
        for M in mats:
            raw = np.ascontiguousarray(M).astype(np.int8).tobytes()
            for w in np.frombuffer(raw, dtype="<u4"):
                f.write(f"{int(w):08x}\n")


def dump_int32(name, mats):
    with open(os.path.join(WORK, name), "w") as f:
        for M in mats:
            for v in M.flatten():
                f.write(f"{int(v) & 0xFFFFFFFF:08x}\n")


def gen_vectors():
    os.makedirs(WORK, exist_ok=True)
    rng = np.random.default_rng(2024)
    A = rng.integers(-128, 128, size=(NTRIALS, N, N), dtype=np.int64)
    B = rng.integers(-128, 128, size=(NTRIALS, N, N), dtype=np.int64)

    idx = (np.arange(N)[:, None] * N + np.arange(N)[None, :]) - 128
    A[0], B[0] = 0, 0
    A[1], B[1] = -128, -128          # max: 262144
    A[2], B[2] = -128, 127           # most negative
    A[3], B[3] = 127, 127
    A[4], B[4] = np.eye(N, dtype=np.int64), idx
    A[5], B[5] = idx, np.eye(N, dtype=np.int64)
    A[6], B[6] = idx.T, idx[::-1, ::-1]
    A[7], B[7] = -1, -1

    C = np.matmul(A, B)
    dump_words("core_a_words.hex", A)
    dump_words("core_b_words.hex", B)
    dump_int32("core_exp.hex", C)
    print(f"Generated {NTRIALS} trials of {N}x{N}; C range {C.min()} .. {C.max()}")


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

    gen_vectors()
    run([xvlog] + [os.path.join(SRC, f) for f in RTL]
        + [os.path.join(SIM, "tb_mmul_core.v")])
    run([xelab, "tb_mmul_core", "-s", "core_snap", "-debug", "typical"])
    out = run([xsim, "core_snap", "-runall"])
    print(out)

    if "TEST PASSED" in out:
        print("RESULT: PASS")
    else:
        sys.exit("RESULT: FAIL")


if __name__ == "__main__":
    main()