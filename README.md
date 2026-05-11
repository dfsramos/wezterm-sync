# wezterm-sync

A [WezTerm](https://wezfurlong.org/wezterm/) plugin that syncs your config to a private GitHub Gist — keeping it in sync across multiple machines with no dotfiles setup required.

## Features

- Push / Pull via the WezTerm command palette (`Ctrl+Shift+P` → type "Sync")
- First-run token prompt with instructions — no manual env var setup needed
- Gist is created automatically on first push; the ID is remembered locally
- Token stored in `~/.config/wezterm/.sync_token` (never synced to the Gist)
- Config reload triggered automatically after a pull

## Requirements

- `curl` and `python3` available in your shell (standard on macOS/Linux/WSL)
- A GitHub account and a [Personal Access Token](https://github.com/settings/tokens/new?scopes=gist) with the **gist** scope

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
2. Add the plugin require + `apply_to_config` call to a minimal `wezterm.lua`
3. Run **Sync › Pull** — your full config is restored and reloaded automatically

## Local files (not synced)

| File | Purpose |
|---|---|
| `~/.config/wezterm/.sync_token` | GitHub token (saved on first prompt) |
| `~/.config/wezterm/.sync_gist_id` | Gist ID (saved on first push) |

To use a different token, set the `WEZTERM_SYNC_TOKEN` environment variable — it takes precedence over the saved file.
