import os
import shutil
import subprocess
import sys
import numpy as np

ROOT = r"C:\Users\khnay\Desktop\MMUL\project_1"
SRC  = os.path.join(ROOT, "project_1.srcs", "sources_1", "new")
SIM  = os.path.join(ROOT, "project_1.srcs", "sim_1", "new")
WORK = os.path.join(ROOT, "python", "work_cbuf")
VIVADO_BIN = r"C:\AMDDesignTools\2025.2\Vivado\bin"

N = 16
NTRIALS = 16


def tool(name):
    for cand in (os.path.join(VIVADO_BIN, name + ".bat"),
                 os.path.join(VIVADO_BIN, name + ".exe")):
        if os.path.isfile(cand):
            return cand
    found = shutil.which(name)
    if found:
        return found
    sys.exit(f"{name} not found in {VIVADO_BIN} or on PATH.")


def gen_vectors():
    os.makedirs(WORK, exist_ok=True)
    rng = np.random.default_rng(99)

    # realistic C matrices from random INT8 products
    A = rng.integers(-128, 128, size=(NTRIALS, N, N), dtype=np.int64)
    B = rng.integers(-128, 128, size=(NTRIALS, N, N), dtype=np.int64)
    C = np.matmul(A, B)

    # corner and layout-sensitive cases
    C[0] = 0
    C[1] = 262144                                          # largest possible product sum
    C[2] = -260096
    C[3] = rng.integers(-2**31, 2**31, size=(N, N), dtype=np.int64)  # full INT32 range
    C[4] = np.arange(N * N).reshape(N, N) * 65537 + 1      # unique per element
    C[5] = C[4].T                                          # catches row/column swaps

    with open(os.path.join(WORK, "cbuf_c.hex"), "w") as f:
        for M in C:
            for v in M.flatten():                          # row-major, word = i*16+j
                f.write(f"{int(v) & 0xFFFFFFFF:08x}\n")
    print(f"Generated {NTRIALS} trials of {N}x{N} INT32")


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
    run([xvlog,
         os.path.join(SRC, "sram_buf.v"),
         os.path.join(SRC, "c_buf.v"),
         os.path.join(SIM, "tb_c_buf.v")])
    run([xelab, "tb_c_buf", "-s", "cbuf_snap", "-debug", "typical"])
    out = run([xsim, "cbuf_snap", "-runall"])
    print(out)

    if "TEST PASSED" in out:
        print("RESULT: PASS")
    else:
        sys.exit("RESULT: FAIL")


if __name__ == "__main__":
    main()