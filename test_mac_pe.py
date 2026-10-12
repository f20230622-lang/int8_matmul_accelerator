import os
import shutil
import subprocess
import sys
import numpy as np

ROOT = r"C:\Users\khnay\Desktop\MMUL\project_1"
SRC  = os.path.join(ROOT, "project_1.srcs", "sources_1", "new")
SIM  = os.path.join(ROOT, "project_1.srcs", "sim_1", "new")
WORK = os.path.join(ROOT, "python", "work_pe")
VIVADO_BIN = r"C:\AMDDesignTools\2025.2\Vivado\bin"


def tool(name):
    """Return the full path to a Vivado tool (.bat on Windows)."""
    for cand in (os.path.join(VIVADO_BIN, name + ".bat"),
                 os.path.join(VIVADO_BIN, name + ".exe")):
        if os.path.isfile(cand):
            return cand
    found = shutil.which(name)
    if found:
        return found
    sys.exit(f"{name} not found in {VIVADO_BIN} or on PATH.")

K = 16
NTRIALS = 200


def gen_vectors():
    os.makedirs(WORK, exist_ok=True)
    rng = np.random.default_rng(1234)
    a = rng.integers(-128, 128, size=(NTRIALS, K), dtype=np.int64)
    b = rng.integers(-128, 128, size=(NTRIALS, K), dtype=np.int64)

    # corner cases
    a[0, :], b[0, :] = 0, 0          # zeros
    a[1, :], b[1, :] = -128, -128    # largest positive sum (262144)
    a[2, :], b[2, :] = -128, 127     # most negative sum
    a[3, :], b[3, :] = 127, 127
    a[4, :], b[4, :] = -1, -1

    exp = (a * b).sum(axis=1)

    def dump(name, vals, width):
        with open(os.path.join(WORK, name), "w") as f:
            for v in vals:
                f.write(f"{int(v) & ((1 << (4 * width)) - 1):0{width}x}\n")

    dump("pe_a.hex", a.flatten(), 2)
    dump("pe_b.hex", b.flatten(), 2)
    dump("pe_exp.hex", exp, 8)
    print(f"Generated {NTRIALS} trials, range of expected: {exp.min()} .. {exp.max()}")


def run(cmd):
    print(">", " ".join(cmd))
    r = subprocess.run(cmd, cwd=WORK, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        sys.exit(f"Command failed: {cmd[0]}")
    return r.stdout


def main():
    xvlog, xelab, xsim = tool("xvlog"), tool("xelab"), tool("xsim")

    gen_vectors()
    run([xvlog, os.path.join(SRC, "mac_pe.v"), os.path.join(SIM, "tb_mac_pe.v")])
    run([xelab, "tb_mac_pe", "-s", "pe_snap", "-debug", "typical"])
    out = run([xsim, "pe_snap", "-runall"])
    print(out)

    if "TEST PASSED" in out:
        print("RESULT: PASS")
    else:
        sys.exit("RESULT: FAIL")


if __name__ == "__main__":
    main()