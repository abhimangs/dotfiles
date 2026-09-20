-- WezTerm — Catppuccin Mocha, matched to kitty and ghostty.
local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- ── Font ─────────────────────────────────────────────────────────────────────
-- ghostty's font and size. The fallback is the symbols-only Nerd Font that
-- install.sh installs silently alongside wezterm and nothing else
-- (SYMBOLS_FONT_PKG) — it covers the glyphs the tab bar draws.
config.font = wezterm.font_with_fallback({
	"JetBrainsMono Nerd Font",
	"Symbols Nerd Font Mono",
})
config.font_size = 15.0

-- ── Cursor ───────────────────────────────────────────────────────────────────
config.default_cursor_style = "BlinkingBar"
config.cursor_blink_rate = 500

-- ── Window ───────────────────────────────────────────────────────────────────
config.window_padding = { left = 12, right = 12, top = 8, bottom = 8 }
config.window_decorations = "RESIZE" -- no title bar, as in kitty and ghostty
config.window_close_confirmation = "NeverPrompt"
config.window_background_opacity = 1.0
config.scrollback_lines = 10000
config.hide_tab_bar_if_only_one_tab = true

-- ── Colours ──────────────────────────────────────────────────────────────────
-- Black background and the red-sun cursor, as kitty/custom.conf and
-- ghostty/config set them. WezTerm can do the wallpaper blend those two do
-- (window_background_image + a low hsb brightness); left out deliberately, so
-- this file needs nothing from ~/.config/wallpapers to render correctly.
config.colors = {
	foreground = "#cdd6f4",
	background = "#000000",

	cursor_bg = "#c0392b",
	cursor_fg = "#1e1e2e",
	cursor_border = "#c0392b",

	selection_fg = "#1e1e2e",
	selection_bg = "#f5e0dc",

	split = "#6c7086",

	ansi = {
		"#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
		"#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
	},
	brights = {
		"#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
		"#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
	},

	tab_bar = {
		background = "#11111b",
		active_tab = { bg_color = "#cba6f7", fg_color = "#11111b", intensity = "Bold" },
		inactive_tab = { bg_color = "#181825", fg_color = "#cdd6f4" },
		inactive_tab_hover = { bg_color = "#313244", fg_color = "#cdd6f4" },
		new_tab = { bg_color = "#11111b", fg_color = "#6c7086" },
		new_tab_hover = { bg_color = "#313244", fg_color = "#cdd6f4" },
	},
}

-- The fancy tab bar (the default) takes the bar's own background from
-- window_frame, not from colors.tab_bar.background.
config.window_frame = {
	active_titlebar_bg = "#11111b",
	inactive_titlebar_bg = "#11111b",
}

return config
