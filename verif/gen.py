#!/usr/bin/env python3
# Copyright 2026 Maktab-e-Digital Systems Lahore.
# SPDX-License-Identifier: Apache-2.0
"""Build the testbench image and its expected retirement stream from the RISC-V
toolchain: the image comes from objcopy, the expectations from spike.  Nothing
here models the ISA.

    python3 verif/gen.py [program] [--require-rv64i]     # default: rv64i_full

The program is verif/<program>.s, or verif/<program>.c linked behind crt0.s.
Writes verif/prog_<program>.svh (parameters) and two $readmemh files,
verif/<program>.img.hex (the image) and verif/<program>.exp.hex (one expected
retirement per line).  Needs riscv64-unknown-elf-{gcc,objcopy,objdump,nm} and
spike, so it is a host step; the generated files are committed and the
simulation itself needs only Verilator.

Spike runs the program to completion (it exits on the program's tohost write)
with both the commit log and the instruction log on.  The commit log gives
every retired instruction's pc, encoding, privilege, register write and memory
access.  It omits an instruction that traps -- that instruction never retires
-- so its record is rebuilt from the instruction log's `exception` line.  RVFI
reports a trapping instruction (rvfi_trap = 1), so the testbench needs it.

With --require-rv64i the program must cover all 52 RV64I instructions, and this
script refuses to write anything otherwise, so the coverage claim is checked,
not asserted.  Spike must also exit 0: the program wrote tohost = 1, i.e. its
own self-check passed.
"""
import pathlib
import re
import subprocess
import sys

BASE = 0x80000000
HERE = pathlib.Path(__file__).resolve().parent
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
NAME = ARGS[0] if ARGS else "rv64i_full"
REQUIRE_RV64I = "--require-rv64i" in sys.argv
CSRC = HERE / f"{NAME}.c"
SRC = CSRC if CSRC.exists() else HERE / f"{NAME}.s"
ELF = HERE / f"{NAME}.elf"
BIN = HERE / f"{NAME}.bin"
OUT = HERE / f"prog_{NAME}.svh"
IMG = HERE / f"{NAME}.img.hex"
EXP = HERE / f"{NAME}.exp.hex"
RV = "/opt/riscv/bin"
ISA = "rv64i_zicsr"          # Zicsr only for the trap handler and minstret

RV64I = """lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu sb sh sw
           addi slti sltiu xori ori andi slli srli srai add sub sll slt sltu xor
           srl sra or and fence ecall ebreak lwu ld sd addiw slliw srliw sraiw
           addw subw sllw srlw sraw""".split()
assert len(RV64I) == 52


def tool(name, *args, **kw):
    return subprocess.run([f"{RV}/{name}", *map(str, args)], check=True,
                          capture_output=True, text=True, **kw)


# ---- compile/assemble and link at BASE; .text and .data contiguous (-N) -----
# A C program is plain RV64I at -O2 (no Zicsr: it needs no CSR), medany so it
# can live at 0x80000000, and with no library calls the compiler might invent.
LINK = ["-mabi=lp64", "-nostdlib", "-nostartfiles", "-Wl,-N", "-Wl,--build-id=none",
        "-Wl,--no-relax", "-Wl,--no-warn-rwx-segments", f"-Ttext=0x{BASE:x}",
        "-e", "_start", "-o", ELF]
if SRC.suffix == ".c":
    tool("riscv64-unknown-elf-gcc", "-march=rv64i", "-mcmodel=medany", "-O2",
         "-ffreestanding", "-fno-builtin", "-fno-tree-loop-distribute-patterns",
         "-Wall", "-Werror", *LINK, HERE / "crt0.s", SRC)
else:
    tool("riscv64-unknown-elf-gcc", f"-march={ISA}", *LINK, SRC)

syms = {}
for ln in tool("riscv64-unknown-elf-nm", ELF).stdout.splitlines():
    f = ln.split()
    if len(f) == 3:
        syms[f[2]] = int(f[0], 16)
for need in ("_start", "spin", "tohost"):
    if need not in syms:
        sys.exit(f"{SRC.name}: no `{need}` symbol -- the program must end by "
                 "writing tohost and spinning at `spin`")
SPIN = syms["spin"]

# ---- image: objcopy -> flat binary -> 32-bit words ---------------------------
tool("riscv64-unknown-elf-objcopy", "-O", "binary", ELF, BIN)
blob = BIN.read_bytes()
blob += bytes(-len(blob) % 4)
words = [int.from_bytes(blob[i:i + 4], "little") for i in range(0, len(blob), 4)]

# ---- mnemonics, from the disassembler, for the coverage report ---------------
mnem = {}
for ln in tool("riscv64-unknown-elf-objdump", "-d", "-M", "no-aliases",
               ELF).stdout.splitlines():
    m = re.match(r"^\s*([0-9a-f]+):\s+[0-9a-f]+\s+(\S+)", ln)
    if m:
        mnem[int(m.group(1), 16)] = m.group(2)

# ---- expectations: spike ----------------------------------------------------
try:
    run = subprocess.run([f"{RV}/spike", f"--isa={ISA}", "--priv=mu", "-l",
                          "--log-commits", str(ELF)],
                         capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    sys.exit("spike did not exit: the program never wrote tohost")
if run.returncode != 0:
    sys.exit(f"spike exited {run.returncode}: the program's self-check failed "
             f"(main returned {run.returncode})")
log = run.stderr.splitlines()

EXEC = re.compile(r"^core\s+\d+:\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)")
COMMIT = re.compile(r"^core\s+\d+:\s+(\d)\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)$")
TRAP = re.compile(r"^core\s+\d+:\s+exception\s+(\S+),\s+epc\s+0x([0-9a-f]+)")

recs, last_exec, prv = [], None, None
for ln in log:
    ln = ln.strip()
    m = COMMIT.match(ln)
    if m:
        pc = int(m.group(2), 16)
        prv = int(m.group(1))
        if pc < BASE:
            continue                          # spike's boot ROM
        if pc == SPIN:
            break
        r = dict(pc=pc, insn=int(m.group(3), 16), mode=prv, trap=0, rd=0,
                 val=0, mkind=0, maddr=0, mmask=0, mdata=0)
        tok = m.group(4).split()
        i = 0
        while i < len(tok):
            t = tok[i]
            if re.fullmatch(r"x\d+", t):
                r["rd"], r["val"] = int(t[1:]), int(tok[i + 1], 16)
                i += 2
            elif t == "mem":
                r["maddr"] = int(tok[i + 1], 16)
                i += 2
                if i < len(tok) and tok[i].startswith("0x"):
                    hexd = tok[i][2:]                    # store: data, sized
                    r["mkind"], r["mdata"] = 2, int(hexd, 16)
                    r["mmask"] = (1 << (len(hexd) // 2)) - 1
                    i += 1
                else:                                    # load: size is funct3[1:0]
                    r["mkind"] = 1
                    r["mmask"] = (1 << (1 << ((r["insn"] >> 12) & 3))) - 1
            else:
                i += 2                                   # cNNN_name value
        recs.append(r)
        continue
    m = EXEC.match(ln)
    if m:
        last_exec = (int(m.group(1), 16), int(m.group(2), 16))
        continue
    m = TRAP.match(ln)
    if m:
        epc = int(m.group(2), 16)
        if epc < BASE:
            continue
        if last_exec is None or last_exec[0] != epc:
            sys.exit(f"trap at 0x{epc:x} without its instruction in the log")
        # The trapping instruction ran at the privilege of the one before it,
        # unless that one changed privilege -- refuse to guess.
        if recs and recs[-1]["insn"] == 0x30200073:
            sys.exit(f"trap at 0x{epc:x} directly after mret: privilege ambiguous")
        recs.append(dict(pc=epc, insn=last_exec[1], mode=prv, trap=1, rd=0,
                         val=0, mkind=0, maddr=0, mmask=0, mdata=0, why=m.group(1)))
else:
    sys.exit("spike's log never reached `spin`")

if not recs:
    sys.exit("no retirements parsed from spike -- check the log format")

# pc_wdata is the next record's pc; the last real instruction's successor is the
# spin, which the log stops at.
for a, b in zip(recs, recs[1:]):
    a["npc"] = b["pc"]
recs[-1]["npc"] = SPIN

# ---- coverage: every RV64I instruction must have retired (or trapped) --------
count = {}
for r in recs:
    count[mnem.get(r["pc"], "?")] = count.get(mnem.get(r["pc"], "?"), 0) + 1
missing = [i for i in RV64I if i not in count]
if REQUIRE_RV64I and missing:
    sys.exit(f"{SRC.name} does not exercise: {' '.join(missing)}")
traps = sum(r["trap"] for r in recs)
umode = sum(1 for r in recs if r["mode"] == 0)
loads = sum(1 for r in recs if r["mkind"] == 1)
stores = sum(1 for r in recs if r["mkind"] == 2)

# ---- emit ---------------------------------------------------------------------
# One expected retirement per line of EXP, fields MSB first; the testbench
# unpacks it with the same layout (tb_s1_core.sv, exp_t).
FIELDS = [("pc", 64), ("insn", 32), ("mode", 2), ("trap", 1), ("rd", 5), ("val", 64),
          ("npc", 64), ("mkind", 2), ("maddr", 64), ("mmask", 8), ("mdata", 64)]
EXP_W = sum(w for _, w in FIELDS)
rel = lambda p: p.relative_to(HERE.parent)
lines = []
for r in recs:
    v = 0
    for f, w in FIELDS:
        v = (v << w) | (r[f] & ((1 << w) - 1))
    lines.append(f"{v:0{(EXP_W + 3) // 4}x}")
EXP.write_text("\n".join(lines) + "\n")
IMG.write_text("\n".join(f"{w:08x}" for w in words) + "\n")

out = ["// GENERATED by gen.py -- do not edit.",
       "// Image from riscv64-unknown-elf-objcopy; expectations from spike",
       f"// (--priv=mu).  Program: verif/{SRC.name}.",
       f"// {len(words)} words, {len(recs)} retirements: {traps} traps, "
       f"{loads} loads, {stores} stores, {umode} in U-mode.",
       "//",
       f"// RV64I coverage ({52 - len(missing)}/52), retirements per instruction:"]
cov = [f"{i}={count.get(i, 0)}" for i in RV64I]
for k in range(0, len(cov), 8):
    out.append("//   " + "  ".join(cov[k:k + 8]))
out += ["",
        f"localparam int unsigned N_WORDS = {len(words)};",
        f"localparam int unsigned N_EXP   = {len(recs)};",
        f"localparam int unsigned EXP_W   = {EXP_W};",
        f"localparam logic [63:0] PROG_BASE  = 64'h{BASE:x};",
        f"localparam logic [63:0] PROG_ENTRY = 64'h{syms['_start']:x};",
        f"localparam logic [63:0] SPIN_PC    = 64'h{SPIN:x};",
        f"localparam logic [63:0] TOHOST     = 64'h{syms['tohost']:x};",
        f'localparam string IMG_HEX = "{rel(IMG)}";',
        f'localparam string EXP_HEX = "{rel(EXP)}";']
OUT.write_text("\n".join(out) + "\n")
for p in (ELF, BIN):
    p.unlink()
print(f"{rel(OUT)}: {len(words)} words, {len(recs)} retirements "
      f"({traps} traps, {loads} loads, {stores} stores, {umode} U-mode); "
      f"{52 - len(missing)}/52 RV64I instructions")
