import os
import random
import shutil
import subprocess
import sys

ROOT = r"C:\Users\khnay\Desktop\MMUL\project_1"
SRC  = os.path.join(ROOT, "project_1.srcs", "sources_1", "new")
SIM  = os.path.join(ROOT, "project_1.srcs", "sim_1", "new")
WORK = os.path.join(ROOT, "python", "work_axil")
VIVADO_BIN = r"C:\AMDDesignTools\2025.2\Vivado\bin"

VERSION = 0x4D4D0001
M32 = 0xFFFFFFFF


def tool(name):
    for cand in (os.path.join(VIVADO_BIN, name + ".bat"),
                 os.path.join(VIVADO_BIN, name + ".exe")):
        if os.path.isfile(cand):
            return cand
    found = shutil.which(name)
    if found:
        return found
    sys.exit(f"{name} not found in {VIVADO_BIN} or on PATH.")


class Model:
    """Golden model of axil_regs, one method per script opcode."""

    def __init__(self):
        self.ops = []
        self.irq_en = 0
        self.done = 0
        self.err = 0
        self.regs = {2: 0, 3: 0, 4: 0}
        self.busy = 0
        self.cycles = 0
        self.start_cnt = 0
        self.soft_cnt = 0

    def emit(self, op, f1=0, f2=0, f3=0, f4=0, f5=0):
        self.ops.append((op, f1, f2, f3, f4, f5))

    @staticmethod
    def decode(addr):
        idx = (addr >> 2) & 7
        return idx, ((addr >> 5) == 0 and idx <= 6)

    def write(self, addr, data, strb=0xF):
        idx, ok = self.decode(addr)
        if ok:
            if idx == 0 and (strb & 1):
                if (data & 1) and not self.busy:
                    self.start_cnt += 1
                    self.done = self.err = 0
                if data & 2:
                    self.soft_cnt += 1
                    self.done = self.err = 0
                self.irq_en = (data >> 2) & 1
            elif idx == 1 and (strb & 1):
                if data & 2:
                    self.done = 0
                if data & 4:
                    self.err = 0
            elif idx in (2, 3, 4):
                mask = sum(0xFF << (8 * i) for i in range(4) if (strb >> i) & 1)
                self.regs[idx] = ((self.regs[idx] & ~mask) | (data & mask)) & M32
        self.emit(0, addr, data, strb, 0 if ok else 2)

    def read(self, addr):
        idx, ok = self.decode(addr)
        val = 0
        if ok:
            val = {0: self.irq_en << 2,
                   1: self.busy | (self.done << 1) | (self.err << 2),
                   2: self.regs[2], 3: self.regs[3], 4: self.regs[4],
                   5: self.cycles, 6: VERSION}[idx]
        self.emit(1, addr, val, 0 if ok else 2)

    def set_busy(self, v):
        self.busy = v & 1
        self.emit(2, self.busy)

    def pulse_done(self):
        self.done = 1
        self.emit(3)

    def pulse_err(self):
        self.err = 1
        self.emit(4)

    def set_cycles(self, v):
        self.cycles = v & M32
        self.emit(5, self.cycles)

    def check_irq(self):
        self.emit(6, self.irq_en & (self.done | self.err))

    def check_addrs(self):
        self.emit(7, self.regs[2], self.regs[3], self.regs[4])

    def check_pulses(self):
        self.emit(8, self.start_cnt, self.soft_cnt)

    def idle(self, n):
        self.emit(9, n)


def build_script():
    m = Model()

    # --- reset values and unmapped reads
    for a in (0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x40, 0xFC):
        m.read(a)

    # --- address registers: full, byte-strobe and partial writes
    m.write(0x08, 0x12345678)
    m.write(0x0C, 0xA5A5A5A5)
    m.write(0x10, 0xDEADBEEF)
    m.read(0x08); m.read(0x0C); m.read(0x10)
    m.write(0x08, 0xFFFFFFFF, 0x2)          # only byte 1
    m.write(0x0C, 0x11223344, 0x5)          # bytes 0 and 2
    m.write(0x10, 0x99999999, 0x8)          # only byte 3
    m.write(0x08, 0x00000000, 0x0)          # no strobes: no change
    m.read(0x08); m.read(0x0C); m.read(0x10)
    m.check_addrs()

    # --- read-only registers ignore writes (OKAY response)
    m.set_cycles(0x000001D4)
    m.write(0x14, 0xFFFFFFFF)
    m.write(0x18, 0xFFFFFFFF)
    m.read(0x14); m.read(0x18)

    # --- unmapped writes: SLVERR, no side effects
    m.write(0x1C, 0x12345678)
    m.write(0x20, 0x12345678)
    m.write(0xFC, 0xFFFFFFFF)
    m.read(0x08); m.check_addrs()

    # --- START: accepted when idle, ignored when busy
    m.write(0x00, 0x1)
    m.check_pulses()
    m.set_busy(1)
    m.read(0x04)                              # BUSY visible in STATUS
    m.write(0x00, 0x1)                        # ignored
    m.check_pulses()
    m.set_busy(0)

    # --- DONE / ERR flags, W1C, and START clearing stale flags
    m.pulse_done(); m.read(0x04)
    m.pulse_err();  m.read(0x04)
    m.write(0x04, 0x2); m.read(0x04)          # clear DONE only
    m.write(0x04, 0x4); m.read(0x04)          # clear ERR only
    m.pulse_done(); m.pulse_err()
    m.write(0x00, 0x1); m.read(0x04)          # START clears both
    m.check_pulses()

    # --- IRQ
    m.write(0x00, 0x4); m.read(0x00); m.check_irq()
    m.pulse_done(); m.check_irq()
    m.write(0x04, 0x2); m.check_irq()
    m.pulse_err(); m.check_irq()
    m.write(0x00, 0x0); m.check_irq()         # IRQ_EN off masks it
    m.write(0x00, 0x4); m.check_irq()
    m.write(0x04, 0x4); m.check_irq()

    # --- soft reset clears flags, keeps addresses
    m.pulse_done(); m.pulse_err()
    m.write(0x00, 0x2); m.read(0x04)
    m.check_addrs(); m.check_pulses()
    m.write(0x00, 0x2, 0xE)                   # strobe excludes byte 0: ignored
    m.check_pulses()

    # --- randomized section
    rng = random.Random(1234)
    addrs = [0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x7C, 0xFC]
    for _ in range(250):
        r = rng.random()
        if r < 0.35:
            addr = rng.choice(addrs)
            data = rng.getrandbits(32)
            if addr == 0x00 and rng.random() < 0.7:
                data &= 0x7
            if addr == 0x04:
                data = rng.choice([0, 2, 4, 6, rng.getrandbits(32)])
            strb = rng.choice([0xF, 0xF, 0x1, 0x2, 0x4, 0x8, 0x3, 0xC, 0x0,
                               rng.randrange(16)])
            m.write(addr, data, strb)
        elif r < 0.70:
            m.read(rng.choice(addrs))
        elif r < 0.78:
            m.set_busy(rng.getrandbits(1))
        elif r < 0.84:
            m.pulse_done()
        elif r < 0.90:
            m.pulse_err()
        elif r < 0.94:
            m.set_cycles(rng.getrandbits(32))
        else:
            rng.choice([m.check_irq, m.check_addrs, m.check_pulses])()

    # --- final sweep
    m.check_irq(); m.check_addrs(); m.check_pulses()
    for a in (0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18):
        m.read(a)
    m.idle(4)
    return m.ops


def write_script(ops):
    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, "axil_script.hex"), "w") as f:
        f.write(f"{len(ops):08x}\n")
        for op in ops:
            f.write(" ".join(f"{v & M32:08x}" for v in op) + "\n")
    print(f"Generated script with {len(ops)} ops")


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

    write_script(build_script())
    run([xvlog, os.path.join(SRC, "axil_regs.v"),
         os.path.join(SIM, "tb_axil_regs.v")])
    run([xelab, "tb_axil_regs", "-s", "axil_snap", "-debug", "typical"])
    out = run([xsim, "axil_snap", "-runall"])
    print(out)

    if "TEST PASSED" in out:
        print("RESULT: PASS")
    else:
        sys.exit("RESULT: FAIL")


if __name__ == "__main__":
    main()