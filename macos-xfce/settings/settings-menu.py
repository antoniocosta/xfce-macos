#!/usr/bin/python3 -I
"""Add an "xfce-macos" section to Xfce's Settings Manager.

Settings Manager groups its entries with a menu file (Personal, Hardware, System, Other). A copy in
~/.config/menus takes precedence over the system's, so this reads the system's file and writes a copy
with one more section, first in the list, that holds every entry with the category
X-XFCE-MacOSSettings (ours), and keeps those entries out of "Other".

  settings-menu.py MENU-OUT DIRECTORY-OUT [ICON]
"""
import sys
import xml.etree.ElementTree as ET

SYSTEM_MENU = "/etc/xdg/menus/xfce-settings-manager.menu"
CATEGORY = "X-XFCE-MacOSSettings"
HEADER = ('<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"\n'
          ' "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">\n')


def build(system_menu_text):
    root = ET.fromstring(system_menu_text)
    # the section is listed first
    layout = root.find("Layout")
    first = ET.Element("Menuname")
    first.text = "xfce-macos"
    layout.insert(0, first)
    # our section: every settings dialog of ours
    section = ET.Element("Menu")
    ET.SubElement(section, "Name").text = "xfce-macos"
    ET.SubElement(section, "Directory").text = "xfce-macos.directory"
    inc = ET.SubElement(section, "Include")
    and_ = ET.SubElement(inc, "And")
    ET.SubElement(and_, "Category").text = "Settings"
    ET.SubElement(and_, "Category").text = "X-XFCE-SettingsDialog"
    ET.SubElement(and_, "Category").text = CATEGORY
    root.insert(list(root).index(layout) + 1, section)
    # "Other" (and the menu's own top-level include) take everything that is not in another section:
    # leave ours out
    holders = [root.find("Include")] + [m for m in root.findall("Menu") if m.findtext("Name") == "Other"]
    for holder in holders:
        for or_ in holder.iter("Or"):
            extra = ET.Element("Category")
            extra.text = CATEGORY
            or_.insert(0, extra)
    ET.indent(root, space="  ")
    return HEADER + "\n" + ET.tostring(root, encoding="unicode") + "\n"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    out_menu, out_dir = sys.argv[1], sys.argv[2]
    icon = sys.argv[3] if len(sys.argv) > 3 else "xfce-macos-setup"
    with open(SYSTEM_MENU) as f:
        text = build(f.read())
    with open(out_menu, "w") as f:
        f.write(text)
    with open(out_dir, "w") as f:
        f.write(f"[Desktop Entry]\nVersion=1.0\nType=Directory\nName=xfce-macos\nComment=Settings added by xfce-macos\n"
                f"Icon={icon}\n")


if __name__ == "__main__":
    main()
