import os
import subprocess
import sys

TESTS = [
    "test_mac_pe.py", "test_systolic_array.py", "test_mmul_bufs.py",
    "test_mmul_core.py", "test_c_buf.py", "test_mmul_ctrl.py",
    "test_axil_regs.py", "test_axi_dma.py", "test_mmul_top_perf.py",
]

here = os.path.dirname(os.path.abspath(__file__))
results = []
for t in TESTS:
    path = os.path.join(here, t)
    if not os.path.isfile(path):
        results.append((t, "MISSING"))
        continue
    r = subprocess.run([sys.executable, path], cwd=here, capture_output=True, text=True)
    ok = r.returncode == 0 and "RESULT: PASS" in r.stdout
    results.append((t, "PASS" if ok else "FAIL"))
    if not ok:
        print(r.stdout[-1500:])
        print(r.stderr[-800:])

print()
for t, s in results:
    print(f"{s:8s} {t}")
n = sum(1 for _, s in results if s == "PASS")
print(f"\n{n}/{len(TESTS)} passed")
sys.exit(0 if n == len(TESTS) else 1)