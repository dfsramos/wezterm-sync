local wezterm = require 'wezterm'
local act     = wezterm.action
local M       = {}

-- Stored alongside the user's wezterm config, not inside the plugin cache
local token_file   = wezterm.config_dir .. '/.sync_token'
local gist_id_file = wezterm.config_dir .. '/.sync_gist_id'

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*l')
  f:close()
  return (s and s ~= '') and s or nil
end

local function write_file(path, content)
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function get_token()
  return os.getenv('WEZTERM_SYNC_TOKEN') or read_file(token_file)
end

local function get_gist_id(opts)
  return (opts and opts.gist_id) or read_file(gist_id_file)
end

local function notify(window, msg)
  window:toast_notification('WezTerm Sync', msg, nil, 4000)
end

-- Convert a Windows path (C:\foo\bar) to its WSL equivalent (/mnt/c/foo/bar)
local function to_wsl_path(path)
  return path:gsub('\\', '/'):gsub('^(%a):', function(d) return '/mnt/' .. d:lower() end)
end

-- ─── Push / Pull ─────────────────────────────────────────────────────────────

local function do_push(window, pane, token, gist_id)
  local config_file = to_wsl_path(wezterm.config_file)
  local method      = gist_id and 'PATCH' or 'POST'
  local url         = gist_id
    and ('https://api.github.com/gists/' .. gist_id)
    or  'https://api.github.com/gists'

  local init_fields = ''
  if not gist_id then
    init_fields = "payload['description'] = 'WezTerm config'\npayload['public'] = False\n"
  end

  -- Paths and token passed via env vars to avoid Windows backslash escaping issues
  local script = string.format([[
WEZTERM_SYNC_TOKEN='%s' WEZTERM_CONFIG_FILE='%s' python3 - <<'PYEOF'
import json, os, subprocess

config_path = os.environ['WEZTERM_CONFIG_FILE']
with open(config_path) as f:
    content = f.read()

token = os.environ['WEZTERM_SYNC_TOKEN']
payload = {'files': {'wezterm.lua': {'content': content}}}
%s
r = subprocess.run(
    ['curl', '-s', '-X', '%s',
     '-H', 'Authorization: token ' + token,
     '-H', 'Content-Type: application/json',
     '-d', json.dumps(payload),
     '%s'],
    capture_output=True, text=True
)
print(r.stdout)
PYEOF
]], token, config_file, init_fields, method, url)

  local ok, stdout, stderr = wezterm.run_child_process({ 'bash', '-c', script })

  if not ok then
    wezterm.log_error('wezterm-sync push failed\nstderr: ' .. (stderr or '') .. '\nstdout: ' .. (stdout or ''))
    local hint = (stderr and stderr ~= '') and stderr:match('([^\n]+)') or 'see Help › Show Debug Log Overlay'
    notify(window, 'Push failed: ' .. hint)
    return
  end

  if not gist_id then
    local id = stdout:match('"id"%s*:%s*"([a-f0-9]+)"')
    if id then
      write_file(gist_id_file, id)
      notify(window, 'Gist created (' .. id .. ') — config pushed!')
    else
      notify(window, 'Push failed — could not parse API response')
    end
  else
    notify(window, 'Config pushed to Gist ✓')
  end
end

local function do_pull(window, pane, token, gist_id)
  if not gist_id then
    notify(window, 'No Gist ID found — push first to create one')
    return
  end

  local config_file = to_wsl_path(wezterm.config_file)

  local script = string.format([[
WEZTERM_SYNC_TOKEN='%s' WEZTERM_CONFIG_FILE='%s' python3 - <<'PYEOF'
import json, os, subprocess

token = os.environ['WEZTERM_SYNC_TOKEN']
config_path = os.environ['WEZTERM_CONFIG_FILE']
r = subprocess.run(
    ['curl', '-s',
     '-H', 'Authorization: token ' + token,
     'https://api.github.com/gists/%s'],
    capture_output=True, text=True
)
data = json.loads(r.stdout)
content = data['files']['wezterm.lua']['content']
with open(config_path, 'w') as f:
    f.write(content)
print('ok')
PYEOF
]], token, config_file, gist_id)

  local ok, stdout, stderr = wezterm.run_child_process({ 'bash', '-c', script })

  if ok and stdout:match('ok') then
    notify(window, 'Config pulled ✓ — reloading…')
    window:perform_action(act.ReloadConfiguration, pane)
  else
    wezterm.log_error('wezterm-sync pull failed\nstderr: ' .. (stderr or '') .. '\nstdout: ' .. (stdout or ''))
    local hint = (stderr and stderr ~= '') and stderr:match('([^\n]+)') or 'see Help › Show Debug Log Overlay'
    notify(window, 'Pull failed: ' .. hint)
  end
end

-- ─── Token prompt ────────────────────────────────────────────────────────────

local function prompt_for_token(window, pane, on_token)
  window:perform_action(
    act.PromptInputLine {
      description = 'GitHub token (gist scope needed — create one at: github.com/settings/tokens/new?scopes=gist)',
      action = wezterm.action_callback(function(win, p, line)
        if not line or line == '' then return end
        write_file(token_file, line)
        notify(win, 'Token saved — proceeding…')
        on_token(win, p, line)
      end),
    },
    pane
  )
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--- Configure the sync plugin.
--- opts (optional):
---   gist_id  string  Hardcode a Gist ID instead of auto-detecting from file
function M.apply_to_config(config, opts)
  opts = opts or {}

  local function push_action(window, pane)
    local token = get_token()
    if not token then
      prompt_for_token(window, pane, function(win, p, t)
        do_push(win, p, t, get_gist_id(opts))
      end)
      return
    end
    do_push(window, pane, token, get_gist_id(opts))
  end

  local function pull_action(window, pane)
    local token = get_token()
    if not token then
      prompt_for_token(window, pane, function(win, p, t)
        do_pull(win, p, t, get_gist_id(opts))
      end)
      return
    end
    do_pull(window, pane, token, get_gist_id(opts))
  end

  wezterm.on('augment-command-palette', function(window, pane)
    return {
      {
        brief  = 'Sync › Push config to Gist',
        icon   = 'md_cloud_upload',
        action = wezterm.action_callback(push_action),
      },
      {
        brief  = 'Sync › Pull config from Gist',
        icon   = 'md_cloud_download',
        action = wezterm.action_callback(pull_action),
      },
    }
  end)
end

return M
