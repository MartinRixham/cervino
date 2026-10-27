-- Neovim's configuration for users without one of their own in
-- ~/.config/nvim: AstroNvim, as its template (github.com/AstroNvim/template)
-- sets it up, in one file. On first start lazy.nvim downloads AstroNvim and
-- its plugins into ~/.local/share/nvim. Unlike the template, it:
-- - keeps lazy.nvim's lock file there too, not in ~/.config/nvim, which
--   would then exist and stop Neovim reading this file;
-- - builds no Tree-sitter parsers, which needs a C compiler: Neovim takes
--   them from Alpine's tree-sitter-grammars.
-- To change it, start from AstroNvim's template in ~/.config/nvim.

local lazypath = vim.env.LAZY or vim.fn.stdpath "data" .. "/lazy/lazy.nvim"

if not (vim.env.LAZY or vim.uv.fs_stat(lazypath)) then
  -- stylua: ignore
  local result = vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath })
  if vim.v.shell_error ~= 0 then
    -- stylua: ignore
    vim.api.nvim_echo({ { ("Error cloning lazy.nvim:\n%s\n"):format(result), "ErrorMsg" }, { "Press any key to exit...", "MoreMsg" } }, true, {})
    vim.fn.getchar()
    vim.cmd.quit()
  end
end

vim.opt.rtp:prepend(lazypath)

-- validate that lazy is available
if not pcall(require, "lazy") then
  -- stylua: ignore
  vim.api.nvim_echo({ { ("Unable to load lazy from: %s\n"):format(lazypath), "ErrorMsg" }, { "Press any key to exit...", "MoreMsg" } }, true, {})
  vim.fn.getchar()
  vim.cmd.quit()
end

require("lazy").setup({
  {
    "AstroNvim/AstroNvim",
    version = "^6",
    import = "astronvim.plugins",
    opts = {
      mapleader = " ",
      maplocalleader = ",",
      icons_enabled = true,
      pin_plugins = nil,
      update_notifications = true,
    },
  },
  {
    "AstroNvim/astrocore",
    opts = function(_, opts)
      -- A function, as ensure_installed is a list lazy.nvim would add to.
      opts.treesitter.auto_install = false
      opts.treesitter.ensure_installed = {}
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    config = function(plugin, opts)
      require("nvim-treesitter").setup(opts)
      -- nvim-treesitter's queries, which it would copy next to the parsers
      -- it builds, and Alpine's parsers, which AstroCore would otherwise
      -- not use, as nvim-treesitter didn't build them. Those whose queries
      -- don't fit Alpine's version of the parser are left out, as AstroCore
      -- would fail on them; the language keeps Vim's syntax highlighting.
      vim.opt.rtp:append(plugin.dir .. "/runtime")
      local function usable(lang)
        if #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".so", false) == 0 then
          return false
        end
        for _, query in ipairs { "highlights", "injections", "indents", "folds", "textobjects" } do
          if not pcall(vim.treesitter.query.get, lang, query) then return false end
        end
        return true
      end
      local treesitter = require "astrocore.treesitter"
      local installed = treesitter.installed
      treesitter.installed = function(update)
        return setmetatable(installed(update), {
          __index = function(parsers, lang)
            rawset(parsers, lang, usable(lang))
            return rawget(parsers, lang)
          end,
        })
      end
    end,
  },
}, {
  lockfile = vim.fn.stdpath "data" .. "/lazy-lock.json",
  install = { colorscheme = { "astrotheme", "habamax" } },
  ui = { backdrop = 100 },
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip",
        "netrwPlugin",
        "tarPlugin",
        "tohtml",
        "zipPlugin",
      },
    },
  },
})
