local wezterm = require 'wezterm'
local act     = wezterm.action
local M       = {}

local token_file   = wezterm.config_dir .. '/.sync_token'
local gist_id_file = wezterm.config_dir .. '/.sync_gist_id'

-- ─── Platform ────────────────────────────────────────────────────────────────

local function is_windows()
  return wezterm.target_triple:find('windows') ~= nil
end

local function is_mac()
  return wezterm.target_triple:find('apple') ~= nil
end

-- Convert a Windows path (C:\foo\bar) to a WSL path (/mnt/c/foo/bar).
-- No-op on Linux/macOS.
local function wsl_path(path)
  if not is_windows() then return path end
  return path:gsub('\\', '/'):gsub('^(%a):', function(d) return '/mnt/' .. d:lower() end)
end

-- Run a Python script with env vars and optional extra args accessible via sys.argv.
-- On Windows uses `wsl.exe env ...`; elsewhere uses `env ...` directly.
local function run_python(script, env_vars, extra_args)
  local cmd = is_windows() and { 'wsl.exe', 'env' } or { 'env' }
  for k, v in pairs(env_vars) do
    table.insert(cmd, k .. '=' .. v)
  end
  table.insert(cmd, 'python3')
  table.insert(cmd, '-c')
  table.insert(cmd, script)
  for _, a in ipairs(extra_args or {}) do
    table.insert(cmd, a)
  end
  return wezterm.run_child_process(cmd)
end

-- Check that python3 is reachable and surface a helpful message if not.
local function check_deps(window)
  local cmd = is_windows()
    and { 'wsl.exe', 'python3', '--version' }
    or  { 'python3', '--version' }
  local ok = wezterm.run_child_process(cmd)
  if not ok then
    if is_windows() then
      notify(window, 'python3 not found in WSL — run: wsl --install, then: sudo apt install python3')
    elseif is_mac() then
      notify(window, 'python3 not found — install it: brew install python3')
    else
      notify(window, 'python3 not found — install it: sudo apt install python3')
    end
    return false
  end
  return true
end

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

function notify(window, msg)
  window:toast_notification('WezTerm Sync', msg, nil, 4000)
end

-- ─── Push / Pull ─────────────────────────────────────────────────────────────

local PUSH_SCRIPT = [[
import json, os, sys, subprocess

token       = os.environ['WEZTERM_SYNC_TOKEN']
config_file = os.environ['WEZTERM_CONFIG_FILE']
method, url, mode = sys.argv[1], sys.argv[2], sys.argv[3]

with open(config_file) as f:
    content = f.read()

payload = {'files': {'wezterm.lua': {'content': content}}}
if mode == 'new':
    payload['description'] = 'WezTerm config'
    payload['public']      = False

r = subprocess.run(
    ['curl', '-s', '-X', method,
     '-H', 'Authorization: token ' + token,
     '-H', 'Content-Type: application/json',
     '-d', json.dumps(payload),
     url],
    capture_output=True, text=True
)
print(r.stdout)
if r.stderr:
    print(r.stderr, file=sys.stderr)
]]

local PULL_SCRIPT = [[
import json, os, sys, subprocess

token       = os.environ['WEZTERM_SYNC_TOKEN']
config_file = os.environ['WEZTERM_CONFIG_FILE']
gist_id     = sys.argv[1]

r = subprocess.run(
    ['curl', '-s',
     '-H', 'Authorization: token ' + token,
     'https://api.github.com/gists/' + gist_id],
    capture_output=True, text=True
)
data    = json.loads(r.stdout)
content = data['files']['wezterm.lua']['content']

with open(config_file, 'w') as f:
    f.write(content)

print('ok')
]]

local function do_push(window, pane, token, gist_id)
  if not check_deps(window) then return end

  local method = gist_id and 'PATCH' or 'POST'
  local url    = gist_id
    and ('https://api.github.com/gists/' .. gist_id)
    or  'https://api.github.com/gists'
  local mode   = gist_id and 'update' or 'new'

  local ok, stdout, stderr = run_python(PUSH_SCRIPT, {
    WEZTERM_SYNC_TOKEN  = token,
    WEZTERM_CONFIG_FILE = wsl_path(wezterm.config_file),
  }, { method, url, mode })

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
      wezterm.log_error('wezterm-sync: unexpected API response: ' .. stdout)
      notify(window, 'Push failed — unexpected API response (see debug log)')
    end
  else
    notify(window, 'Config pushed to Gist ✓')
  end
end

local function do_pull(window, pane, token, gist_id)
  if not check_deps(window) then return end

  if not gist_id then
    notify(window, 'No Gist ID found — push first to create one')
    return
  end

  local ok, stdout, stderr = run_python(PULL_SCRIPT, {
    WEZTERM_SYNC_TOKEN  = token,
    WEZTERM_CONFIG_FILE = wsl_path(wezterm.config_file),
  }, { gist_id })

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
