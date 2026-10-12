#!/usr/bin/env python3
"""A minimal logind on a private bus: Inhibit() hands out a pipe fd and records when the client
closes it; test.Control.Emit(b) sends PrepareForSleep(b). For going to sleep it then waits (like
logind) for the delay inhibitors, at most 5 s.   mock_logind.py EVENTS_LOG"""
import os, sys, time
from gi.repository import Gio, GLib

LOG = open(sys.argv[1], "a", buffering=1)
T0 = time.monotonic()
def ev(msg):
    LOG.write(f"{time.monotonic() - T0:7.2f} {msg}\n")

XML = """<node>
 <interface name="org.freedesktop.login1.Manager">
  <method name="Inhibit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/>
   <arg type="s" direction="in"/><arg type="h" direction="out"/></method>
  <signal name="PrepareForSleep"><arg type="b"/></signal>
 </interface>
 <interface name="test.Control"><method name="Emit"><arg type="b" direction="in"/></method></interface>
</node>"""
node = Gio.DBusNodeInfo.new_for_xml(XML)
held = {}          # read fd -> (mode, why, t)
conn_box = []

def on_release(fd, cond, *_):
    mode, why, t = held.pop(fd)
    ev(f"release {mode} after {time.monotonic() - t:.1f}s ({why})")
    os.close(fd)
    return False

def call(conn, sender, path, iface, method, params, inv):
    if method == "Inhibit":
        what, who, why, mode = params.unpack()
        r, w = os.pipe()
        fdl = Gio.UnixFDList.new()
        idx = fdl.append(w)
        os.close(w)
        held[r] = (mode, why, time.monotonic())
        GLib.io_add_watch(r, GLib.IO_HUP | GLib.IO_ERR, on_release)
        ev(f"acquire {mode} what={what} who={who}")
        inv.return_value_with_unix_fd_list(GLib.Variant("(h)", (idx,)), fdl)
    elif method == "Emit":
        going = params.unpack()[0]
        inv.return_value(None)
        ev(f"PrepareForSleep({going})")
        conn.emit_signal(None, "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "PrepareForSleep", GLib.Variant("(b)", (going,)))
        if going:
            t = time.monotonic()
            def check():
                delays = [h for h in held.values() if h[0] == "delay"]
                if not delays or time.monotonic() - t > 5:
                    ev(f"sleeping ({'delay released' if not delays else 'TIMEOUT, delay still held'}) {time.monotonic() - t:.1f}s after PrepareForSleep")
                    return False
                return True
            GLib.timeout_add(20, check)

def on_bus(conn, name):
    for iface in node.interfaces:
        conn.register_object("/org/freedesktop/login1", iface, call, None, None)

Gio.bus_own_name_on_connection(Gio.bus_get_sync(Gio.BusType.SYSTEM), "org.freedesktop.login1", Gio.BusNameOwnerFlags.NONE, None, None)
on_bus(Gio.bus_get_sync(Gio.BusType.SYSTEM), None)
ev("ready")
GLib.MainLoop().run()
