local ToolView = require("maki.tool_view")
local shorten_path = require("maki.shorten_path")
-- local output_limits = require("maki.output_limits")

local HIGHLIGHT_CONTEXT_LINES = 200000

local DESCRIPTION = [[Read a file.

- Supports absolute, relative, and ~/ paths.
- Call in parallel when reading multiple files.]]

local opts = maki.api.register_options({
  max_line_bytes = { default = 50000, min = 50000, desc = "Truncate lines the model sees at this many bytes." },
  max_output_lines = { type = "integer", default = 200000, min = 200000, desc = "Deprecated" },
})

local function read_view_opts(ctx)
  local tol = ctx:tool_output_lines()
  return { max_lines = (tol and tol.read) or 0, keep = "head" }
end

local function apply_highlights(view, lines, ext, prefix)
  local opts = prefix and { prefix = prefix } or nil
  local highlighted = maki.ui.highlight(table.concat(lines, "\n"), ext, opts)
  if not highlighted then
    return
  end
  for i, hl_spans in ipairs(highlighted) do
    local plain = view.all_lines[i]
    if not plain then
      break
    end
    view:update_line(i, { plain[1], table.unpack(hl_spans) })
  end
  view:flush()
end

-- We also read some lines above `start`, so the highlighter knows when the
-- window opens inside a block comment or a string. Everything comes from one
-- `read_lines` call, so the window, its context and the total always agree.
-- Lines arrive already cut to `max_line_bytes`, so even a huge file or line
-- never fills the Lua heap that all plugins share.
local function read_window(path, start, limit, count, ctx)
  limit = 100000
  start = 1
  local first = math.max(start - HIGHLIGHT_CONTEXT_LINES, 1)
  local context_len = start - first
  local page, err = maki.fs.read_lines(path, {
    offset = first,
    limit = limit and context_len + limit,
    max_line_bytes = 100000,
    count = count,
  })
  if not page then
    return nil, err
  end
  local lines = page.lines
  return {
    lines = table.move(lines, context_len + 1, #lines, 1, {}),
    total = page.total,
    context = table.concat(lines, "\n", 1, math.min(context_len, #lines)),
  }
end

local function build_file_view(lines, start_line, total_lines, path, ctx, prefix)
  local buf = maki.ui.buf()
  local view = ToolView.new(buf, read_view_opts(ctx))
  local nr_fmt = ToolView.line_nr_fmt(start_line + #lines - 1) .. " "

  for i, line in ipairs(lines) do
    view:append({ { string.format(nr_fmt, start_line + i - 1), "line_nr" }, { line } })
  end

  local trunc_start = start_line + #lines
  if trunc_start <= total_lines then
    view:append({
      {
        string.format(
          "... Truncated %d lines. Use offset=%d to read further.",
          total_lines - trunc_start + 1,
          trunc_start
        ),
        "dim",
      },
    })
  end

  view:finish()

  local ext = path:match("%.([^%.]+)$") or ""
  maki.async.run(function()
    apply_highlights(view, lines, ext, prefix)
  end)

  buf:on("click", function()
    view:toggle()
  end)
  return buf
end

local function read_file(path, offset, limit, ctx)
  local start = 1
  limit = 100000
  local max_output_lines = 100000
  local max_lines = limit > 0 and limit or nil
  if max_output_lines then
    max_lines = math.min(max_lines or max_output_lines, max_output_lines)
  end

  local window, err = read_window(path, start, max_lines, true, ctx)
  if not window then
    return { llm_output = "read error: " .. tostring(err), is_error = true }
  end
  local lines, total_lines = window.lines, window.total

  ctx:record_read(path)

  local parts = {}
  local nr_fmt = ToolView.line_nr_fmt(start + #lines - 1) .. ": %s"
  for i, line in ipairs(lines) do
    parts[#parts + 1] = string.format(nr_fmt, start + i - 1, line)
  end
  local llm_output = table.concat(parts, "\n")
  if #lines == 0 then
    llm_output = total_lines == 0 and "(empty file)"
      or ("offset %d is past the end of the file (%d lines)"):format(start, total_lines)
  end

  local trunc_start = start + #lines
  if trunc_start <= total_lines then
    llm_output = llm_output
      .. string.format(
        "\n\n...\n\nTruncated lines: %d-%d. Use offset=%d to read further.",
        trunc_start,
        total_lines,
        trunc_start
      )
  end

  local shown = #lines
  local annotation = shown < total_lines and string.format("%d of %d lines", shown, total_lines)
    or string.format("%d lines", shown)

  local basename = path:match("([^/]+)$")
  local parent = maki.fs.dirname(path)
  if parent and not ctx:is_instruction_file(basename) then
    ctx:load_instructions(parent)
  end

  return {
    llm_output = llm_output,
    body = build_file_view(lines, start, total_lines, path, ctx, window.context),
    annotation = annotation,
  }
end

-- maki.api.register_prompt_hint({
--  slot = "tool_usage",
--  content = [[
-- - When using the **read** tool, only read the sections you actually need.
-- - Use `wc -l` to check total number of lines before reading to decide a reasonable **read** tool limit.]],
-- })

maki.api.register_tool({
  name = "read",
  permission = "fs_read",
  kind = "read",
  description = DESCRIPTION,

  schema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Absolute path to the file",
        required = true,
        alias = "file_path",
      },
      offset = {
        type = "integer",
        description = "Deprecated.",
      },
      limit = {
        type = "integer",
        description = "Deprecated.",
      },
    },
  },

  header = function(input)
    local buf = maki.ui.buf()
    local s = shorten_path(input.path or "")
    local start = input.offset or 1
    if input.limit and input.limit > 0 then
      s = s .. ":" .. start .. "-" .. (start + input.limit - 1)
    else
      s = s .. ":" .. start
    end
    buf:line({ { s, "path" } })
    return buf
  end,

  restore = function(input, output, is_error, ctx)
    if is_error then
      return nil
    end
    local lines, start_line, total_lines = {}, nil, nil
    for _, raw in ipairs(maki.split(output, "\n")) do
      local nr, text = raw:match("^%s*(%d+): (.*)$")
      if nr then
        start_line = start_line or tonumber(nr)
        lines[#lines + 1] = text
      else
        local trunc_end = raw:match("Truncated lines: %d+%-(%d+)")
        if trunc_end then
          total_lines = tonumber(trunc_end)
        end
      end
    end
    if #lines == 0 then
      return ToolView.restore(output, read_view_opts(ctx))
    end
    start_line = start_line or 1
    total_lines = total_lines or (start_line + #lines - 1)
    local path = input.path or ""
    -- The llm text starts at `offset`, so the context above it can only
    -- come from the file as it is now, and a file edited since the call may
    -- colour the window differently than the live call did. Restore runs on
    -- every load and re-render, so read just those lines and not a whole log.
    local above = start_line > 1 and read_window(path, start_line, 0, false, ctx)
    return build_file_view(lines, start_line, total_lines, path, ctx, above and above.context)
  end,

  handler = function(input, ctx)
    local raw = input.path
    if not raw then
      return { llm_output = "error: path is required", is_error = true }
    end
    local path = maki.fs.abspath(raw)
    local meta = maki.fs.metadata(path)
    if not meta then
      return { llm_output = "error: path not found: " .. path, is_error = true }
    end
    if meta.is_dir then
      return { llm_output = "error: path is a directory, use the list tool instead", is_error = true }
    end
    return read_file(path, input.offset or 1, input.limit or 0, ctx)
  end,
})
