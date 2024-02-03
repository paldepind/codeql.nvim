local util = require "codeql.util"
local panel = require "codeql.panel"
local cli = require "codeql.cliserver"
local config = require "codeql.config"
local sarif = require "codeql.sarif"
local vim = vim

local M = {}

function M.process_results(opts, info)
  local conf = config.values
  local bqrsPath = opts.bqrs_path
  local queryPath = opts.query_path
  local dbPath = opts.db_path
  local kind = opts.query_kind
  local id = opts.query_id
  local save_bqrs = opts.save_bqrs
  local bufnr = opts.bufnr
  local ram_opts = config.ram_opts
  local resultsPath = vim.fn.tempname()
  if not info or info == vim.NIL or not info["result-sets"] then
    return
  end

  local query_kinds = info["compatible-query-kinds"]

  local count, total_count = 0, 0
  local found_select_rs = false
  for _, resultset in ipairs(info["result-sets"]) do
    if resultset.name == "#select" then
      found_select_rs = true
      count = resultset.rows
      break
    else
      total_count = total_count + resultset.rows
    end
  end
  if not found_select_rs then
    count = total_count
  end

  if count == 0 then
    util.message(string.format("No results for %s", queryPath))
    panel.render()
    return
  else
    util.message(string.format("Processing %d results for %s", count, queryPath))
  end

  -- process ASTs, definitions and references
  if
    vim.endswith(queryPath, "/localDefinitions.ql")
    or vim.endswith(queryPath, "/localReferences.ql")
    or vim.endswith(queryPath, "/printAst.ql")
  then
    local cmd = {
      "bqrs",
      "decode",
      "-v",
      "--log-to-stderr",
      "--format=json",
      "-o=" .. resultsPath,
      "--entities=id,url,string",
      bqrsPath,
    }
    vim.list_extend(cmd, ram_opts)
    cli.runAsync(
      cmd,
      vim.schedule_wrap(function(_)
        if not util.is_file(resultsPath) then
          util.err_message("Error: Failed to decode results for " .. queryPath)
          return
        end
        if vim.endswith(string.lower(queryPath), "/localdefinitions.ql") then
          require("codeql.defs").process_defs(resultsPath)
        elseif vim.endswith(string.lower(queryPath), "/localreferences.ql") then
          require("codeql.defs").process_refs(resultsPath)
        elseif vim.endswith(string.lower(queryPath), "/printast.ql") then
          require("codeql.ast").build_ast(resultsPath, bufnr)
        end
      end)
    )
    return
  end

  if count > 1000 then
    local continue = vim.fn.input(string.format("Too many results (%d). Open it? (Y/N): ", count))
    if string.lower(continue) ~= "y" then
      return
    end
  end

  if vim.tbl_contains(query_kinds, "Graph") and kind == "graph" and id ~= nil then
    -- process GRAPH results
    local cmd = {
      "bqrs",
      "interpret",
      "-v",
      "--log-to-stderr",
      "--output=" .. resultsPath,
      "--format=dot",
      "-t=id=" .. id,
      "-t=kind=" .. kind,
      "--no-group-results",
      bqrsPath,
    }
    vim.list_extend(cmd, ram_opts)
    cli.runAsync(
      cmd,
      vim.schedule_wrap(function(_)
        local path = resultsPath .. "/" .. id .. ".dot"
        if util.is_file(path) then
          M.load_dot_results(path)
        else
          util.err_message("Error: Cant find DOT results at " .. path)
        end
      end)
    )
    return
  end
  -- process SARIF results
  if vim.tbl_contains(query_kinds, "PathProblem") and kind == "path-problem" and id ~= nil then
    local cmd = {
      "bqrs",
      "interpret",
      "-v",
      "--log-to-stderr",
      "--output=" .. resultsPath,
      "--format=sarifv2.1.0",
      "-t=id=" .. id,
      "-t=kind=" .. kind,
      "--no-group-results",
      "--threads=0",
      "--max-paths=" .. conf.results.max_paths,
      bqrsPath,
    }
    -- TODO: add support for --source-archive and --source-location-prefix
    --"--source-archive /Users/pwntester/Library/Application Support/Code/User/workspaceStorage/50b9d24ec6c3ace332caf92c45290d52/GitHub.vscode-codeql/e23b52929290b5b766ad32367a9cef69c7f3f2e3/ruby/src.zip",
    --"--source-location-prefix /home/runner/work/github/github",

    -- TODO: add support for all tags
    --[[
    -t=name=Code injection
    -t=description=Interpreting unsanitized user input as code allows a malicious user to perform arbitrary code execution.
    -t=kind=path-problem
    -t=problem.severity=error
    -t=security-severity=9.3
    -t=sub-severity=high
    -t=precision=high
    -t=id=rb/code-injection
    -t=tags=security external/cwe/cwe-094 external/cwe/cwe-095 external/cwe/cwe-116
    ]]
    --

    --util.message(string.format("Processing SARIF results with %s", vim.inspect(cmd)))
    vim.list_extend(cmd, ram_opts)
    cli.runAsync(
      cmd,
      vim.schedule_wrap(function(_)
        if util.is_file(resultsPath) then
          M.load_sarif_results(resultsPath)
        else
          util.err_message("Error: Cant find SARIF results at " .. resultsPath)
          panel.render()
        end
      end)
    )
    if save_bqrs then
      require("codeql.history").save_bqrs(bqrsPath, queryPath, dbPath, kind, id, count, bufnr)
    end
    vim.api.nvim_command "redraw"
    return
  elseif vim.tbl_contains(query_kinds, "PathProblem") and kind == "path-problem" and id == nil then
    util.err_message "Insuficient Metadata for a Path Problem. Need at least @kind and @id elements"
    return
  end

  -- process RAW results
  local cmd = {
    "bqrs",
    "decode",
    "-v",
    "--log-to-stderr",
    "-o=" .. resultsPath,
    "--format=json",
    "--entities=string,url",
    bqrsPath,
  }
  vim.list_extend(cmd, ram_opts)
  cli.runAsync(
    cmd,
    vim.schedule_wrap(function(_)
      if util.is_file(resultsPath) then
        M.load_raw_results(resultsPath)
      else
        util.err_message("Error: Cant find raw results at " .. resultsPath)
        panel.render()
      end
    end)
  )
  if save_bqrs then
    require("codeql.history").save_bqrs(bqrsPath, queryPath, dbPath, kind, id, count, bufnr)
  end
  vim.api.nvim_command "redraw"
end

function M.load_raw_results(path)
  if not util.is_file(path) then
    return
  end
  local results = util.read_json_file(path)
  if results then
    local issues = {}
    local col_names = {}
    for name, v in pairs(results) do
      local tuples = v.tuples
      local columns = v.columns

      for _, tuple in ipairs(tuples) do
        path = {}
        for _, element in ipairs(tuple) do
          local node = {}
          -- objects with url info
          if type(element) == "table" and element.url then
            if element.url and element.url.endColumn then
              element.url.endColumn = element.url.endColumn + 1
            end
            local filename = util.uri_to_fname(element.url.uri)
            local line = element.url.startLine
            node = {
              label = element["label"],
              mark = "→",
              filename = filename,
              line = line,
              visitable = true,
              url = element.url,
            }

            -- objects with no url info
          elseif type(element) == "table" and not element.url then
            node = {
              label = element.label,
              mark = "≔",
              filename = nil,
              line = nil,
              visitable = false,
              url = nil,
            }

            -- string literal
          elseif type(element) == "string" or type(element) == "number" then
            node = {
              label = element,
              mark = "≔",
              filename = nil,
              line = nil,
              visitable = false,
              url = nil,
            }

            -- ???
          else
            util.err_message(string.format("Error processing node (%s)", type(element)))
          end
          table.insert(path, node)
        end

        -- add issue paths to issues list
        local paths = { path }

        table.insert(issues, {
          is_folded = true,
          paths = paths,
          active_path = 1,
          hidden = false,
          node = paths[1][1],
          query_id = name,
        })
      end

      col_names[name] = {}
      if columns then
        for _, col in ipairs(columns) do
          if col.name then
            table.insert(col_names[name], col.name)
          else
            table.insert(col_names[name], "---")
          end
        end
      else
        for _ = 1, #tuples[1] do
          table.insert(col_names[name], "---")
        end
      end
    end

    if vim.tbl_isempty(issues) then
      panel.render()
      return
    else
      panel.render {
        source = "raw",
        mode = "table",
        issues = issues,
        columns = col_names,
      }
      vim.api.nvim_command "redraw"
    end
  end
end

function M.load_sarif_results(path)
  local conf = config.values
  local issues = sarif.process_sarif {
    path = path,
    max_length = conf.results.max_path_depth,
    group_by = conf.panel.group_by,
  }
  panel.render {
    source = "sarif",
    mode = "tree",
    issues = issues,
  }
  vim.api.nvim_command "redraw"
end

function M.load_dot_results(path)
  local format = "pdf"
  local output = vim.fn.tempname()
  local cmd1 = "dot -T" .. format .. " -o '" .. output .. "." .. format .. "' '" .. path .. "'"
  local cmd2 = "open '" .. output .. "." .. format .. "'"
  vim.fn.system(cmd1)
  vim.fn.system(cmd2)
  print(".dot file: " .. path)
  print("Output: " .. output .. "." .. format)
end

return M
