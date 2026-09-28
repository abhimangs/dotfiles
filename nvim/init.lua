-- ~/.config/nvim/init.lua — Catppuccin Mocha and a statusline, nothing more.
--
-- Stowed by the installer when the `neovim` app is picked. The repo folder is
-- nvim/ because that is the directory Neovim reads, not the menu key.
--
-- Version floor: lazy.nvim and lualine want Neovim 0.8+. Arch and Ubuntu 24.04
-- (0.9.5) clear it; Debian 12 ships 0.7.2, which gets the plain options below
-- and a clean start instead of a wall of Lua errors. catppuccin v2 calls
-- vim.iter (0.10+) whatever its README says, so older builds stay on v1.11.0.

local o = vim.opt
o.number = true
o.relativenumber = true
o.mouse = "a"
o.ignorecase = true
o.smartcase = true
o.expandtab = true
o.shiftwidth = 4
o.tabstop = 4
o.undofile = true
o.signcolumn = "yes"
o.cursorline = true
o.scrolloff = 8
o.splitright = true
o.splitbelow = true
o.termguicolors = true
-- Only where a clipboard tool exists: on a headless box every yank would
-- otherwise print "clipboard: No provider".
if vim.fn.has("clipboard") == 1 then o.clipboard = "unnamedplus" end

if vim.fn.has("nvim-0.8") == 0 then return end

-- vim.uv is 0.10+; vim.loop is the same table under its old name.
local uv = vim.uv or vim.loop
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not uv.fs_stat(lazypath) then
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable",
    "https://github.com/folke/lazy.nvim.git", lazypath })
  if vim.v.shell_error ~= 0 then
    -- No git or no network: keep the editor usable, say why it is plain.
    vim.api.nvim_echo({ { "lazy.nvim not installed, plugins skipped:\n" .. out, "WarningMsg" } }, true, {})
    return
  end
end
o.rtp:prepend(lazypath)
o.showmode = false -- lualine shows the mode

require("lazy").setup({
  {
    "catppuccin/nvim",
    name = "catppuccin",
    tag = vim.fn.has("nvim-0.10") == 0 and "v1.11.0" or nil,
    priority = 1000,
    opts = { flavour = "mocha" },
    config = function(_, opts)
      require("catppuccin").setup(opts)
      -- catppuccin-mocha, not catppuccin: Neovim 0.12 ships its own
      -- `catppuccin` colorscheme, and the plugin's v2 renamed to avoid it.
      vim.cmd.colorscheme("catppuccin-mocha")
    end,
  },
  { "nvim-lualine/lualine.nvim", opts = { options = { theme = "catppuccin-mocha" } } },
}, {
  -- Into the data dir, not beside this file: ~/.config/nvim holds only stow
  -- symlinks, and a real file there makes the next install back the whole
  -- directory up as if it were the user's own config.
  lockfile = vim.fn.stdpath("data") .. "/lazy-lock.json",
  install = { colorscheme = { "catppuccin-mocha", "habamax" } },
  change_detection = { notify = false },
})
