import os
import shutil
import subprocess
import sys
import numpy as np

ROOT = r"C:\Users\khnay\Desktop\MMUL\project_1"
SRC  = os.path.join(ROOT, "project_1.srcs", "sources_1", "new")
SIM  = os.path.join(ROOT, "project_1.srcs", "sim_1", "new")
WORK = os.path.join(ROOT, "python", "work_sa")
VIVADO_BIN = r"C:\AMDDesignTools\2025.2\Vivado\bin"

N = 16
NTRIALS = 24


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
    rng = np.random.default_rng(42)
    A = rng.integers(-128, 128, size=(NTRIALS, N, N), dtype=np.int64)
    B = rng.integers(-128, 128, size=(NTRIALS, N, N), dtype=np.int64)

    # corner cases
    A[0], B[0] = 0, 0                                # zeros
    A[1], B[1] = -128, -128                          # max positive: 262144
    A[2], B[2] = -128, 127                           # most negative
    A[3], B[3] = 127, 127
    A[4], B[4] = np.eye(N, dtype=np.int64), B[4]     # identity * B
    A[5], B[5] = A[5], np.eye(N, dtype=np.int64)     # A * identity
    A[6], B[6] = -1, -1

    C = np.matmul(A, B)

    def dump(name, arr, width):
        mask = (1 << (4 * width)) - 1
        with open(os.path.join(WORK, name), "w") as f:
            for v in arr.flatten():
                f.write(f"{int(v) & mask:0{width}x}\n")

    dump("sa_a.hex", A, 2)
    dump("sa_b.hex", B, 2)
    dump("sa_exp.hex", C, 8)
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
    run([xvlog,
         os.path.join(SRC, "mac_pe.v"),
         os.path.join(SRC, "systolic_array.v"),
         os.path.join(SIM, "tb_systolic_array.v")])
    run([xelab, "tb_systolic_array", "-s", "sa_snap", "-debug", "typical"])
    out = run([xsim, "sa_snap", "-runall"])
    print(out)

    if "TEST PASSED" in out:
        print("RESULT: PASS")
    else:
        sys.exit("RESULT: FAIL")


if __name__ == "__main__":
    main()