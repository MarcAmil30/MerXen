"""Translate one of MerXen's Dockerfiles into an Apptainer definition file.

For clusters with Apptainer but no Docker (see docs/containers.md): the image
is built from the same instructions. FROM -> Bootstrap docker, RUN -> %post
(in order; a failing RUN fails the build, as in Docker), ENV -> exported in
%post from that point on and in %environment, ARG -> shell variable with its
default, WORKDIR -> mkdir + cd, COPY -> %files, CMD -> %runscript. Handles
single-stage Dockerfiles only and fails on any other instruction.

Usage: python containers/dockerfile2def.py containers/Dockerfile merxen.def
"""
import json, posixpath, shlex, sys

src, dst = sys.argv[1], sys.argv[2]
lines, buf = [], ""
for raw in open(src):
    s = raw.rstrip("\n")
    if not buf and (not s.strip() or s.lstrip().startswith("#")):
        continue
    if s.rstrip().endswith("\\"):
        buf += s.rstrip() + "\n"
        continue
    lines.append(buf + s); buf = ""

base, post, envs, files, cmd = None, [], [], [], None
for ln in lines:
    op, _, rest = ln.strip().partition(" ")
    op = op.upper(); rest = rest.strip()
    if op == "FROM":
        if base: sys.exit("multi-stage Dockerfile not supported")
        base = rest.split()[0]
    elif op == "RUN":
        # Docker fails the build when a RUN's command fails; mirror that.
        post.append("{ " + rest + "\n} || { echo 'RUN failed' >&2; exit 1; }")
    elif op == "ENV":
        toks = shlex.split(rest.replace("\\\n", " "), posix=True)
        if len(toks) == 2 and "=" not in toks[0]:
            toks = [f"{toks[0]}={toks[1]}"]
        for t in toks:
            k, v = t.split("=", 1)
            envs.append((k, v)); post.append(f'export {k}="{v}"')
    elif op == "ARG":
        k, _, v = rest.partition("=")
        v = v.strip('"')
        post.append(f'{k}="${{{k}:-{v}}}"')
    elif op == "WORKDIR":
        post.append(f"mkdir -p {rest} && cd {rest}")
        workdir = rest
    elif op == "COPY":
        *srcs, d = shlex.split(rest)
        for s_ in srcs:
            if s_.startswith("--"): sys.exit(f"COPY flag not supported: {s_}")
            target = d if d.startswith("/") else f"{workdir}/{d}"
            if d.endswith("/") or d in (".", "./"):
                target = f"{target}/{posixpath.basename(s_)}"
            target = posixpath.normpath(target)
            if target == "/tmp" or target.startswith("/tmp/"):
                # %post runs with its own /tmp, so park the file and move it in
                parked = "/opt/dockerfile-copy" + target
                files.append((s_, parked))
                post.append(f"mkdir -p {posixpath.dirname(target)} && cp -a {parked} {target}")
                continue
            files.append((s_, target))
    elif op == "CMD":
        cmd = json.loads(rest)
    else:
        sys.exit(f"unsupported instruction: {op}")

out = [f"Bootstrap: docker", f"From: {base}", "", f"# Generated from {src} by dockerfile2def.py", ""]
if files:
    out.append("%files")
    for s_, t in files:
        out.append(f"    {s_} {t}")
    out.append("")
out.append("%post")
out.append("    set -eux")
for p in post:
    out.append("    " + p.replace("\n", "\n    "))
if any(t.startswith("/opt/dockerfile-copy/") for _, t in files):
    out.append("    rm -rf /opt/dockerfile-copy")
out.append("")
out.append("%environment")
for k, v in envs:
    out.append(f'    export {k}="{v}"')
out.append("")
if cmd:
    out.append("%runscript")
    out.append("    exec " + " ".join(shlex.quote(c) for c in cmd) + ' "$@"')
open(dst, "w").write("\n".join(out) + "\n")
