#!/usr/bin/env python3
"""Measure Sorbet LSP time-to-Idle (TTI) and A/B two launch commands.

This is the turnkey measurement driver for the `--load-state` proof (issue #1). It
drives a Sorbet LSP server over stdio, sends `initialize`/`initialized`, and times how
long the server takes to finish its initial work and go idle.

Why spawn-relative, not initialize-relative
-------------------------------------------
The cold leg runs its full index+resolve in the LSP *slow path*, which happens AFTER
`initialize` (LSPTypechecker::initialize -> runSlowPath(Init)). The `--load-state` leg
deserializes the snapshot during process startup, BEFORE the server ever reads
`initialize`. So timing from "initialize sent" would silently hide the snapshot's load
cost and unfairly flatter the fork. We therefore measure TTI = (idle - process spawn),
which is apples-to-apples: it includes each leg's startup load plus all post-initialize
work. (We also print the initialize-relative number for transparency.)

How "idle" is detected
-----------------------
With `initializationOptions.supportsOperationNotifications = true`, Sorbet emits
`sorbet/showOperation` notifications with status "start"/"end" around Indexing,
SlowPathBlocking/NonBlocking, and FastPath (main/lsp/ShowOperation.cc). The server is
idle when no operation is in flight AND no new operation/diagnostic activity has arrived
for a short quiet window. The reported TTI is the timestamp of the LAST such activity
(not when we decided to stop), so the settle window never inflates the number. For a
perfectly green, zero-dirty `--load-state` boot the server may emit no operation at all;
in that case idle falls back to the `initialize` response time (the server is up and has
nothing to do).

Usage
-----
  # Single leg, prints one TTI in seconds:
  sorbet_lsp_tti.py once --cwd /workspaces/github \
      --cmd ".vscode/run-sorbet --lsp"

  # A/B (the headline). Runs each leg N times, interleaved, prints medians + % win:
  sorbet_lsp_tti.py ab --runs 3 --cwd /workspaces/github \
      --stock-cmd ".vscode/run-sorbet --lsp" \
      --fork-cmd  "vendor/sorbet-loadstate/run-sorbet --lsp"

The command strings are shell-tokenized (shlex) and launched with cwd set so Sorbet
auto-reads `sorbet/config`. Nothing is written to the repo.
"""
import argparse
import json
import os
import shlex
import statistics
import subprocess
import sys
import threading
import time


class LSPLeg:
    """Drives one Sorbet LSP server process and computes its time-to-Idle."""

    def __init__(self, argv, cwd, quiet, timeout, no_op_grace):
        self.argv = argv
        self.cwd = cwd
        self.quiet = quiet  # seconds of inactivity (inflight==0) that defines "settled"
        self.timeout = timeout  # hard cap; a hung/looping server fails the run
        self.no_op_grace = no_op_grace  # if no operation is ever seen, wait this long past init-response

        self.lock = threading.Lock()
        self.spawn_t = None
        self.init_response_t = None
        self.last_activity_t = None  # last showOperation/publishDiagnostics wall time
        self.inflight = 0
        self.op_seen = False
        self.diag_seen = False
        self.stopped = threading.Event()

    def _send(self, proc, obj):
        body = json.dumps(obj).encode()
        proc.stdin.write(b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
        proc.stdin.flush()

    def _reader(self, proc):
        f = proc.stdout
        while True:
            header = b""
            while b"\r\n\r\n" not in header:
                ch = f.read(1)
                if not ch:
                    self.stopped.set()
                    return
                header += ch
            clen = 0
            for line in header.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    clen = int(line.split(b":", 1)[1].strip())
            body = b""
            while len(body) < clen:
                chunk = f.read(clen - len(body))
                if not chunk:
                    self.stopped.set()
                    return
                body += chunk
            try:
                msg = json.loads(body)
            except Exception:
                continue
            self._on_message(msg)

    def _on_message(self, msg):
        now = time.monotonic()
        with self.lock:
            if msg.get("id") == 1 and "result" in msg and self.init_response_t is None:
                self.init_response_t = now
                return
            method = msg.get("method")
            if method == "sorbet/showOperation":
                status = (msg.get("params") or {}).get("status")
                if status == "start":
                    self.inflight += 1
                    self.op_seen = True
                elif status == "end":
                    self.inflight = max(0, self.inflight - 1)
                self.last_activity_t = now
            elif method == "textDocument/publishDiagnostics":
                self.diag_seen = True
                self.last_activity_t = now

    def _idle_timestamp(self):
        """The wall time we call 'idle', or None if not settled yet."""
        with self.lock:
            if self.init_response_t is None:
                return None
            now = time.monotonic()
            if self.inflight > 0:
                return None
            if self.op_seen or self.diag_seen:
                if self.last_activity_t is None:
                    return None
                if now - self.last_activity_t >= self.quiet:
                    return self.last_activity_t
                return None
            # No operation/diagnostic ever seen (e.g. green zero-dirty load-state boot):
            # idle is the moment the server became responsive, once the grace has elapsed.
            if now - self.init_response_t >= self.no_op_grace:
                return self.init_response_t
            return None

    def run(self):
        self.spawn_t = time.monotonic()
        proc = subprocess.Popen(
            self.argv, cwd=self.cwd,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        threading.Thread(target=self._reader, args=(proc,), daemon=True).start()
        self._send(proc, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "processId": os.getpid(),
                "rootUri": "file://" + os.path.abspath(self.cwd),
                "capabilities": {},
                "initializationOptions": {"supportsOperationNotifications": True},
            },
        })
        self._send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})

        idle_t = None
        deadline = self.spawn_t + self.timeout
        while time.monotonic() < deadline:
            if self.stopped.is_set():
                break
            idle_t = self._idle_timestamp()
            if idle_t is not None:
                break
            time.sleep(0.02)

        try:
            self._send(proc, {"jsonrpc": "2.0", "id": 99, "method": "shutdown", "params": {}})
            self._send(proc, {"jsonrpc": "2.0", "method": "exit", "params": {}})
        except Exception:
            pass
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()

        if idle_t is None:
            return None  # never settled within timeout
        return {
            "tti": idle_t - self.spawn_t,
            "tti_from_init": (idle_t - self.init_response_t) if self.init_response_t else None,
            "startup_to_init": (self.init_response_t - self.spawn_t) if self.init_response_t else None,
            "saw_operations": self.op_seen,
            "saw_diagnostics": self.diag_seen,
        }


def measure(argv, cwd, quiet, timeout, no_op_grace):
    return LSPLeg(argv, cwd, quiet, timeout, no_op_grace).run()


def fmt(x):
    return "n/a" if x is None else f"{x:.2f}s"


def cmd_once(args):
    r = measure(shlex.split(args.cmd), args.cwd, args.quiet, args.timeout, args.no_op_grace)
    if r is None:
        print("FAILED: server did not reach idle within timeout", file=sys.stderr)
        return 1
    print(f"time-to-Idle (spawn->idle):      {fmt(r['tti'])}")
    print(f"  of which startup->initialize:  {fmt(r['startup_to_init'])}")
    print(f"  initialize->idle:              {fmt(r['tti_from_init'])}")
    print(f"  operations seen: {r['saw_operations']}  diagnostics seen: {r['saw_diagnostics']}")
    return 0


def _one(label, argv, args):
    r = measure(argv, args.cwd, args.quiet, args.timeout, args.no_op_grace)
    tti = r["tti"] if r else None
    print(f"  [{label}] {fmt(tti)}" + ("" if r else "  (TIMEOUT)"), flush=True)
    return tti


def cmd_ab(args):
    stock_argv = shlex.split(args.stock_cmd)
    fork_argv = shlex.split(args.fork_cmd)
    stock, fork = [], []
    # Interleave the legs so transient system load averages out across both.
    for i in range(args.runs):
        stock.append(_one(f"stock {i + 1}/{args.runs}", stock_argv, args))
        fork.append(_one(f"fork  {i + 1}/{args.runs}", fork_argv, args))

    def med(vals):
        ok = [v for v in vals if v is not None]
        return statistics.median(ok) if ok else None

    ms, mf = med(stock), med(fork)
    print(f"\n==== time-to-Idle (spawn -> idle), median of {args.runs} ====")
    print(f"  stock : {fmt(ms)}")
    print(f"  fork  : {fmt(mf)}  (--load-state)")
    if ms and mf:
        win = 1.0 - (mf / ms)
        print(f"  delta : {fmt(ms - mf)} faster")
        print(f"  win   : {win * 100:.1f}%   ({'>=50% TARGET MET' if win >= 0.5 else 'below 50% target'})")
        return 0
    print("  win   : n/a (a leg failed to reach idle)", file=sys.stderr)
    return 1


def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--cwd", default=".", help="working dir for the server (so sorbet/config is read)")
    common.add_argument("--quiet", type=float, default=0.75, help="inactivity window (s) that defines settled")
    common.add_argument("--timeout", type=float, default=300.0, help="hard cap (s) per run")
    common.add_argument("--no-op-grace", type=float, default=2.0,
                        help="if no operation is ever emitted, wait this long past init-response before idle")

    ap = argparse.ArgumentParser(description="Sorbet LSP time-to-Idle measurement driver")
    sub = ap.add_subparsers(dest="mode", required=True)

    o = sub.add_parser("once", parents=[common], help="measure one launch command")
    o.add_argument("--cmd", required=True, help="server launch command (shell-quoted)")
    o.set_defaults(func=cmd_once)

    a = sub.add_parser("ab", parents=[common], help="A/B two launch commands")
    a.add_argument("--runs", type=int, default=3, help="repetitions per leg (median is reported)")
    a.add_argument("--stock-cmd", required=True, help="baseline server launch command (shell-quoted)")
    a.add_argument("--fork-cmd", required=True, help="--load-state server launch command (shell-quoted)")
    a.set_defaults(func=cmd_ab)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
