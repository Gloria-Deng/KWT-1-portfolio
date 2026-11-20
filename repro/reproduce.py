#!/usr/bin/env python3
"""Generate synthetic vectors, then compare the original KWT-1 RTL bit-for-bit."""
from pathlib import Path
from random import Random
import argparse, os, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parent
CORE = ROOT / "rtl/core"
TB = ROOT / "tb"
MARKERS = ("REQUANT_PASS", "MAC_PASS W=10", "MAC_PASS W=12")

def requant(acc, bias, shift, bits):
    x = acc + bias
    y = (x + (1 << (shift - 1))) // (1 << shift) if shift > 0 else x << (-shift)
    return min((1 << (bits - 1)) - 1, max(-(1 << (bits - 1)), y))

def vectors(work):
    rand = Random(20261120)
    edge = [-2**31, -65537, -32768, -2049, -1025, -9, -3, -1, 0, 1, 3,
            9, 1023, 2047, 32767, 65535, 2**31 - 1]
    shifts = [-128, -33, -16, -12, -11, -2, -1, 0, 1, 2, 11, 15, 16, 31, 32, 33, 127]
    cases = [(a, b, s) for a in edge for b in edge for s in shifts]
    cases += [(rand.randrange(-2**31, 2**31), rand.randrange(-2**31, 2**31),
               rand.randrange(-128, 128)) for _ in range(1000)]
    with (work / "requant.txt").open("w") as f:
        for a, b, s in cases:
            vals = (a, b, s, *(requant(a,b,s,w) for w in (11,12,16)))
            print(*vals, file=f)
    for w in (10, 12):
        sums = [[[0]*64 for _ in range(2)] for _ in range(2)]
        with (work / f"mac{w}.txt").open("w") as f:
            for i in range(128):
                bank = i % 2
                xa, xb = [rand.randrange(-32000,32001) for _ in range(2)]
                weights = [rand.randrange(-(1 << (w-1)), 1 << (w-1)) for _ in range(64)]
                assert all(-2**31 <= sums[bank][row][lane] + x*weight < 2**31
                           for lane, weight in enumerate(weights)
                           for row,x in enumerate((xa,xb)))
                packed = sum((v & ((1 << w)-1)) << (w*j) for j,v in enumerate(weights))
                for j, v in enumerate(weights):
                    sums[bank][0][j] += xa*v
                    sums[bank][1][j] += xb*v
                print(bank,xa,xb,format(packed, "x"),file=f)
            for bank in range(2):
                for row in range(2):
                    print(*sums[bank][row],file=f)

def frame_vectors(work):
    rand = Random(52026)
    w = [[rand.randrange(-2048,2048) for _ in range(256)] for _ in range(64)]
    x = [[rand.randrange(-512,512) for _ in range(64)] for _ in range(99)]
    bias = [rand.randrange(-2**20,2**20) for _ in range(256)]
    shift = [rand.choice((-1,0,3,5,7,9,11)) for _ in range(256)]
    weight_words = []
    for row in w:
        for group in range(4):
            packed = sum((v & 0xfff) << (12*j)
                         for j,v in enumerate(row[group*64:(group+1)*64]))
            weight_words.extend((packed >> (32*j)) & 0xffffffff for j in range(24))
    params = [v & 0xffffffff for v in bias]
    params.extend(sum((shift[i+j] & 255) << (8*j) for j in range(4))
                  for i in range(0,256,4))
    flat_inputs = [v & 0xffff for row in x for v in row]
    columns = tuple(zip(*w))
    expected = []
    for row in x:
        y = [requant(sum(a*b for a,b in zip(row,col)),bias[i],shift[i],16) & 0xffff
             for i,col in enumerate(columns)]
        expected.extend(y[i] | (y[i+1] << 16) for i in range(0,256,2))
    for name,data in (("weights",weight_words),("params",params),
                      ("inputs",flat_inputs),("expected",expected)):
        (work / f"frame_{name}.hex").write_text("".join(f"{v:x}\n" for v in data),
                                               encoding="ascii")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--protocol", action="store_true",
                        help="also run the separate NICE controller regression (can take longer)")
    parser.add_argument("--frame", action="store_true", help="also simulate a complete 99×256 synthetic frame")
    args = parser.parse_args()
    cc, vm = (os.getenv("IVERILOG", "iverilog"), os.getenv("VVP", "vvp"))
    if not shutil.which(cc) or not shutil.which(vm):
        parser.error("install Icarus Verilog first (iverilog and vvp must be on PATH)")
    vlt = os.getenv("VERILATOR", "verilator")
    if args.frame and not shutil.which(vlt):
        parser.error("--frame needs Verilator 5 with timing support and C++ build tools (Linux/WSL)")
    ivl = os.getenv("IVL_MODULE_DIR")
    with tempfile.TemporaryDirectory(prefix="kwt-repro-") as tmp:
        work = Path(tmp)
        vectors(work)
        def sim(top, paths, marker, switches=()):
            compile_cmd = [cc] + (["-B",ivl] if ivl else [])
            run_cmd = [vm] + (["-M",ivl] if ivl else [])
            exe = str(work / (top+".vvp"))
            subprocess.run(compile_cmd+["-g2012","-s",top,"-o",exe,*switches,*map(str,paths)],
                           cwd=work,check=True,timeout=90)
            p = subprocess.run(run_cmd+[exe],cwd=work,check=False,timeout=180,
                               text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            print(p.stdout,end="")
            p.check_returncode()
            if not any(line.startswith(marker) for line in p.stdout.splitlines()):
                raise RuntimeError(f"expected PASS marker missing: {marker}")
        sim("tb_requant_repro",[CORE/"kwt_requant_target.v",TB/"tb_requant_repro.sv"], MARKERS[0])
        for w in (10,12):
            sim("tb_mac_repro",[CORE/"kwt_mac128_wide.v",TB/"tb_mac_repro.sv"],
                f"MAC_PASS W={w}",[f"-Ptb_mac_repro.W={w}"])
        if args.frame:
            frame_vectors(work)
            frame_core = [CORE / ("kwt_" + v + ".v") for v in
                          ("ffn_wide","input_rows4","lineng_wide","mac128_wide",
                           "param_store","requant_target","wmem_packed")]
            paths = [*frame_core, ROOT/"rtl/mem/kwt_sram_128x16.v", TB/"tb_frame_repro.sv"]
            build = work/"verilator"
            with (work/"compile.log").open("w+") as log:
                result = subprocess.run(
                    [vlt, "--binary", "--timing", "--top-module", "tb_frame_repro",
                     "-j", "2", "-Wno-fatal", "--Mdir", str(build), *map(str,paths)],
                    cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=240)
                if result.returncode:
                    log.seek(0)
                    print(log.read())
                    result.check_returncode()
            exe = "Vtb_frame_repro" + (".exe" if os.name=="nt" else "")
            result = subprocess.run([str(build/exe)], cwd=work, timeout=60, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            print(result.stdout, end="")
            result.check_returncode()
            if not any(line.startswith("FRAME_PASS") for line in result.stdout.splitlines()):
                raise RuntimeError("expected FRAME_PASS marker missing")
        if args.protocol:
            sim("tb_nice_prefetch_control_v13",[ROOT/"rtl/nice/kwt_nice_linear_v10.v",
                TB/"prefetch_core_endpoint.sv",TB/"tb_nice_prefetch_control_v13.sv"],
                "NICE_FINAL_V43_PROTOCOL_CONTROL_PASS",["-DNICE_LINEAR_WBITS=12"])
if __name__=="__main__":
    main()
