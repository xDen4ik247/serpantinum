#!/usr/bin/env python3
"""UPower on a private bus: property OnBattery, plus test.Control.SetOnBattery(b) which changes it and
emits PropertiesChanged like UPower does.   mock_upower.py INITIAL(true|false)"""
import sys
from gi.repository import Gio, GLib

state = {"OnBattery": sys.argv[1] == "true"}
XML = """<node>
 <interface name="org.freedesktop.UPower"><property name="OnBattery" type="b" access="read"/></interface>
 <interface name="test.Control"><method name="SetOnBattery"><arg type="b" direction="in"/></method></interface>
</node>"""
node = Gio.DBusNodeInfo.new_for_xml(XML)
bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)

def call(conn, sender, path, iface, method, params, inv):
    state["OnBattery"] = params.unpack()[0]
    inv.return_value(None)
    conn.emit_signal(None, "/org/freedesktop/UPower", "org.freedesktop.DBus.Properties", "PropertiesChanged",
                     GLib.Variant("(sa{sv}as)", ("org.freedesktop.UPower", {"OnBattery": GLib.Variant("b", state["OnBattery"])}, [])))

def get_prop(conn, sender, path, iface, prop):
    return GLib.Variant("b", state["OnBattery"])

bus.register_object("/org/freedesktop/UPower", node.interfaces[0], None, get_prop, None)
bus.register_object("/org/freedesktop/UPower", node.interfaces[1], call, None, None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.UPower", Gio.BusNameOwnerFlags.NONE, None, None)
GLib.MainLoop().run()
