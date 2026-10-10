keymap("macos-xfce - terminals: switch desktops", {
    C("LC-Left"):               [bind,C("Super-Left")],         # Ctrl+Left: previous desktop (like macOS)
    C("LC-Right"):              [bind,C("Super-Right")],        # Ctrl+Right: next desktop (like macOS)
    C("LC-Up"):                 C("Super-Up"),                  # Ctrl+Up: Mission Control (skippy-xd)
}, when = lambda ctx:
    cnfg.screen_has_focus and
    ctx_app_is_terminal
)

keymap("macos-xfce - tab switching", {
    C("Super-Tab"):             [bind,C("C-Tab")],              # Ctrl+Tab: next tab (like macOS)
    C("Shift-Super-Tab"):       [bind,C("C-Shift-Tab")],        # Ctrl+Shift+Tab: previous tab (like macOS)
}, when = lambda ctx:
    cnfg.screen_has_focus and
    not ctx_app_is_terminal and
    not ctx_app_is_remote
)

keymap("macos-xfce - full screen", {
    C("RC-Super-f"):            C("Alt-F11"),                   # Cmd+Ctrl+F: full screen (Xfce's own toggle)
    C("LC-RC-f"):               C("Alt-F11"),                   # the same in terminals, where Ctrl stays Ctrl
}, when = lambda ctx:
    cnfg.screen_has_focus
)
