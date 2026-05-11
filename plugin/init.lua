local wezterm = require 'wezterm'
local act     = wezterm.action
local M       = {}

local token_file   = wezterm.config_dir .. '/.sync_token'
local gist_id_file = wezterm.config_dir .. '/.sync_gist_id'

-- ─── Pure-Lua JSON helpers ────────────────────────────────────────────────────
-- No external dependencies — encode/decode only what the Gist API needs.

local function json_encode_string(s)
  return '"' .. s
    :gsub('\\', '\\\\')
    :gsub('"',  '\\"')
    :gsub('\n', '\\n')
    :gsub('\r', '\\r')
    :gsub('\t', '\\t')
    :gsub('%c', function(c) return ('\\u%04x'):format(c:byte()) end)
    .. '"'
end

local function build_push_payload(content, is_new)
  local files = '{"wezterm.lua":{"content":' .. json_encode_string(content) .. '}}'
  if is_new then
    return '{"description":"WezTerm config","public":false,"files":' .. files .. '}'
  end
  return '{"files":' .. files .. '}'
end

-- Read a JSON string value from s starting at the opening '"' (position pos).
-- Returns the decoded string and the position after the closing '"'.
local function read_json_string(s, pos)
  local i, t = pos + 1, {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(t), i + 1
    elseif c ~= '\\' then
      table.insert(t, c); i = i + 1
    else
      local e = s:sub(i + 1, i + 1)
      if     e == 'n'  then table.insert(t, '\n');  i = i + 2
      elseif e == 'r'  then table.insert(t, '\r');  i = i + 2
      elseif e == 't'  then table.insert(t, '\t');  i = i + 2
      elseif e == '"'  then table.insert(t, '"');   i = i + 2
      elseif e == '\\' then table.insert(t, '\\');  i = i + 2
      elseif e == '/'  then table.insert(t, '/');   i = i + 2
      elseif e == 'u'  then
        local cp = tonumber(s:sub(i + 2, i + 5), 16) or 0
        if     cp < 0x80  then
          table.insert(t, string.char(cp))
        elseif cp < 0x800 then
          table.insert(t, string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64)))
        else
          table.insert(t, string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + math.floor((cp % 4096) / 64),
            0x80 + (cp % 64)
          ))
        end
        i = i + 6
      else
        table.insert(t, e); i = i + 2
      end
    end
  end
  return nil
end

-- Extract the first "id" string value from a Gist API response.
local function parse_gist_id(json)
  local key_pos = json:find('"id"')
  if not key_pos then return nil end
  local q = json:find('"', key_pos + 5)
  if not q then return nil end
  return read_json_string(json, q)
end

-- Extract the file content from a Gist API response.
local function parse_gist_content(json)
  local file_pos = json:find('"wezterm%.lua"')
  if not file_pos then return nil, 'wezterm.lua not found in Gist' end
  local key_pos = json:find('"content"', file_pos)
  if not key_pos then return nil, '"content" key not found' end
  local q = json:find('"', key_pos + 10)
  if not q then return nil, '"content" value not found' end
  local content = read_json_string(json, q)
  if not content then return nil, 'could not parse content string' end
  return content
end

-- ─── HTTP via curl ────────────────────────────────────────────────────────────
-- curl ships built-in on Windows 10+, macOS, and virtually all Linux distros.
-- run_child_process passes args as a direct array (no shell), so the JSON body
-- is passed as-is with no quoting or escaping concerns.

local curl_ok = nil  -- cached after first check

local function check_curl(window)
  if curl_ok == nil then
    curl_ok = wezterm.run_child_process({ 'curl', '--version' })
  end
  if not curl_ok then
    notify(window,
      'curl not found — it ships with Windows 10+, macOS, and most Linux distros')
    return false
  end
  return true
end

local function curl_request(method, url, token, body)
  local cmd = {
    'curl', '-s', '-X', method,
    '-H', 'Authorization: token ' .. token,
    '-H', 'Content-Type: application/json',
  }
  if body then
    table.insert(cmd, '--data')
    table.insert(cmd, body)
  end
  table.insert(cmd, url)
  return wezterm.run_child_process(cmd)
end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return (s ~= '') and s or nil
end

local function read_file_line(path)
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
  return os.getenv('WEZTERM_SYNC_TOKEN') or read_file_line(token_file)
end

local function get_gist_id(opts)
  return (opts and opts.gist_id) or read_file_line(gist_id_file)
end

function notify(window, msg)
  window:toast_notification('WezTerm Sync', msg, nil, 4000)
end

-- ─── Push / Pull ──────────────────────────────────────────────────────────────

local function do_push(window, pane, token, gist_id)
  if not check_curl(window) then return end

  local content = read_file(wezterm.config_file)
  if not content then
    notify(window, 'Could not read config file: ' .. wezterm.config_file)
    return
  end

  local is_new  = not gist_id
  local method  = is_new and 'POST' or 'PATCH'
  local url     = is_new
    and 'https://api.github.com/gists'
    or  ('https://api.github.com/gists/' .. gist_id)
  local payload = build_push_payload(content, is_new)

  local ok, stdout, stderr = curl_request(method, url, token, payload)

  if not ok then
    wezterm.log_error('wezterm-sync push failed\n' .. (stderr or ''))
    notify(window, 'Push failed — curl error (see Help › Show Debug Log Overlay)')
    return
  end

  if is_new then
    local id = parse_gist_id(stdout)
    if id then
      write_file(gist_id_file, id)
      notify(window, 'Gist created (' .. id .. ') — config pushed!')
    else
      wezterm.log_error('wezterm-sync: unexpected API response:\n' .. stdout)
      notify(window, 'Push failed — unexpected API response (see debug log)')
    end
  else
    notify(window, 'Config pushed to Gist ✓')
  end
end

local function do_pull(window, pane, token, gist_id)
  if not check_curl(window) then return end

  if not gist_id then
    notify(window, 'No Gist ID found — push first to create one')
    return
  end

  local ok, stdout, stderr = curl_request(
    'GET', 'https://api.github.com/gists/' .. gist_id, token, nil)

  if not ok then
    wezterm.log_error('wezterm-sync pull failed\n' .. (stderr or ''))
    notify(window, 'Pull failed — curl error (see Help › Show Debug Log Overlay)')
    return
  end

  local content, err = parse_gist_content(stdout)
  if not content then
    wezterm.log_error('wezterm-sync: could not parse response: ' .. err .. '\n' .. stdout)
    notify(window, 'Pull failed: ' .. err)
    return
  end

  if not write_file(wezterm.config_file, content) then
    notify(window, 'Pull failed — could not write to ' .. wezterm.config_file)
    return
  end

  notify(window, 'Config pulled ✓ — reloading…')
  window:perform_action(act.ReloadConfiguration, pane)
end

-- ─── Token prompt ─────────────────────────────────────────────────────────────

local function prompt_for_token(window, pane, on_token)
  window:perform_action(
    act.PromptInputLine {
      description = 'GitHub token (gist scope — create at: github.com/settings/tokens/new?scopes=gist)',
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

-- ─── Public API ───────────────────────────────────────────────────────────────

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
