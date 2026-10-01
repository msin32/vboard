#!/usr/bin/env python3
"""icebox_vlog emits `module chip (input a, output \\b[0] , ...);` and then re-declares some
ports as `reg`. Legal for some simulators, rejected by Verilator. Rewrite the header as
non-ANSI (`module chip (a, \\b[0] ); input a; output \\b[0] ;`) where redeclaration is fine."""
import re, sys

src = sys.stdin.read()
m = re.search(r"module\s+(\w+)\s*\((.*?)\);\n", src, re.S)
ports = re.findall(r"(input|output)\s+(\\\S+|\w+)", m.group(2))
names = ", ".join(n + (" " if n.startswith("\\") else "") for _, n in ports)
decls = "".join(f"{d} {n}{' ' if n.startswith(chr(92)) else ''};\n" for d, n in ports)
sys.stdout.write(src[:m.start()] + f"module {m.group(1)} ({names});\n{decls}" + src[m.end():])
