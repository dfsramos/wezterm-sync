# wezterm-sync

A [WezTerm](https://wezfurlong.org/wezterm/) plugin that syncs your config to a private GitHub Gist — keeping it in sync across multiple machines with no dotfiles setup required.

## Features

- Push / Pull via the WezTerm command palette (`Ctrl+Shift+P` → type "Sync")
- First-run token prompt with instructions — no manual setup needed
- Gist is created automatically on first push; the ID is remembered locally
- Token stored in `~/.config/wezterm/.sync_token` (never synced to the Gist)
- Config reload triggered automatically after a pull
- **Zero external dependencies** — pure Lua JSON encoding/decoding + `curl` (built-in on Windows 10+, macOS, and virtually all Linux distros)

## Requirements

- WezTerm (any platform — Windows, macOS, Linux)
- A GitHub account and a [Personal Access Token](https://github.com/settings/tokens/new?scopes=gist) with the **gist** scope
- `curl` — ships built-in on Windows 10+, macOS, and most Linux distros

## Installation

Add to your `wezterm.lua`:

```lua
local sync = wezterm.plugin.require("https://github.com/dfsramos/wezterm-sync")
sync.apply_to_config(config)
```

That's it. On first push you'll be prompted for your GitHub token.

## Options

```lua
sync.apply_to_config(config, {
  gist_id = "abc123",  -- optional: hardcode an existing Gist ID
})
```

## Usage

1. Open the command palette: `Ctrl+Shift+P`
2. Type **Sync**
3. Choose **Sync › Push config to Gist** or **Sync › Pull config from Gist**

### On a new machine

1. Install WezTerm
2. Create a minimal `wezterm.lua` with just the plugin require:
   ```lua
   local wezterm = require 'wezterm'
   local config  = wezterm.config_builder()
   local sync    = wezterm.plugin.require("https://github.com/dfsramos/wezterm-sync")
   sync.apply_to_config(config)
   return config
   ```
3. Open the command palette → **Sync › Pull** — your full config is restored and reloaded automatically

## How it works

The plugin is implemented entirely in Lua with no external dependencies beyond `curl`:

- **Push**: reads your `wezterm.lua` with Lua's `io.open`, JSON-encodes the content using a pure Lua string encoder, then calls `curl` directly via `wezterm.run_child_process` to POST/PATCH the GitHub Gist API
- **Pull**: fetches the Gist via `curl`, decodes the JSON response using a pure Lua character-by-character parser (handling all escape sequences including `\uXXXX` → UTF-8), writes the content back to your config file, then triggers a config reload
- **No shell involved**: `curl` is invoked as a direct argument array — no bash, no PowerShell, no quoting issues across platforms
- **Token security**: the GitHub token is passed via HTTP header at runtime and stored in a local file outside the Gist

## Local files (not synced)

| File | Purpose |
|---|---|
| `~/.config/wezterm/.sync_token` | GitHub token (saved on first prompt) |
| `~/.config/wezterm/.sync_gist_id` | Gist ID (saved on first push) |

To use a different token, set the `WEZTERM_SYNC_TOKEN` environment variable — it takes precedence over the saved file.
