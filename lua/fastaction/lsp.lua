local M = {}
local m = {}

m.textDocument_codeAction = 'textDocument/codeAction'
m.codeAction_resolve = 'codeAction/resolve'

---@return CodeAction[] | nil
local request_code_action = function(params)
    local buffer = vim.api.nvim_get_current_buf()
    ---@type table<integer, {result: lsp.CodeAction[], error: lsp.ResponseError? }>?, string?
    local results_lsp, err =
        vim.lsp.buf_request_sync(buffer, 'textDocument/codeAction', params, 10000)
    if err then return vim.notify('ERROR: ' .. err, vim.log.levels.ERROR) end
    if not results_lsp or vim.tbl_isempty(results_lsp) then
        return vim.notify('No results from textDocument/codeAction', vim.log.levels.INFO)
    end
    local commands = {}
    for client_id, response in pairs(results_lsp) do
        if response.result then
            local client = vim.lsp.get_client_by_id(client_id)
            for _, result in pairs(response.result) do
                ---@class lsp.CodeAction
                ---@field client_id integer
                ---@field client_name string
                ---@field buffer integer
                local res = result
                res.client_id = client_id
                res.client_name = client and client.name or ''
                res.buffer = buffer
                table.insert(commands, result)
            end
        end
    end
    return commands
end

function M.code_action()
    M.bufnr = vim.api.nvim_get_current_buf()
    local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
    local context = { diagnostics = vim.diagnostic.get(M.bufnr, { lnum = lnum }) }
    local params = vim.lsp.util.make_range_params()
    params.context = context
    return request_code_action(params)
end

function M.range_code_action()
    M.bufnr = vim.api.nvim_get_current_buf()
    local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
    local context = { diagnostics = vim.diagnostic.get(M.bufnr, { lnum = lnum }) }
    local params = vim.lsp.util.make_given_range_params()
    params.context = context
    return request_code_action(params)
end

---@param action lsp.Command|lsp.CodeAction
---@param client vim.lsp.Client
---@param ctx { bufnr: integer }
function m.apply_action(action, client, ctx)
    if action.edit then vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding) end
    local a_cmd = action.command
    if a_cmd then
        local command = type(a_cmd) == 'table' and a_cmd or action --[[@as lsp.Command]]
        local exec_cmd = client.exec_cmd or client._exec_cmd
        exec_cmd(client, command, ctx)
    end
end

---@param action CodeAction
function M.execute_command(action)
    local client = assert(vim.lsp.get_client_by_id(action.client_id))
    local ctx = { bufnr = action.buffer }
    ---@type lsp.Registration?
    local reg
    ---@type boolean
    local supports_resolve
    if action.data then
        reg = client.dynamic_capabilities:get(m.textDocument_codeAction, { bufnr = action.buffer })
        supports_resolve = vim.tbl_get(reg or {}, 'registerOptions', 'resolveProvider')
            or client.supports_method(m.codeAction_resolve)
    end
    if not action.edit and client and supports_resolve then
        client.request(m.codeAction_resolve, action, function(err, resolved_action)
            if err then
                if action.command then
                    m.apply_action(action, client, ctx)
                else
                    vim.notify(err.code .. ': ' .. err.message, vim.log.levels.ERROR)
                end
            else
                m.apply_action(resolved_action, client, ctx)
            end
        end, action.buffer)
    else
        m.apply_action(action, client, ctx)
    end
end

---@param priority Priority
---@param check_lsp? boolean
---@return ActionConfig[]
function M.get_priorities(priority, check_lsp)
    if not priority then return {} end
    local ft_priorities = priority[vim.bo.filetype]
    vim.list_extend(ft_priorities or {}, priority.default or {})
    if not check_lsp then return ft_priorities end
    local clients = vim.lsp.get_clients { bufnr = 0 }
    local lsps = m.map(clients, function(client) return client.name end)
    local lsp_priorities = m.map(lsps, function(p) return priority[p] end)
    return vim.list_extend(ft_priorities or {}, lsp_priorities or {})
end

---@generic K, V, R
---@param tbl table<K, V>
---@param f fun(value: V): R
---@return table<K, R>
function m.map(tbl, f)
    if not tbl then return {} end
    local t = {}
    ---@diagnostic disable-next-line: no-unknown
    for k, v in pairs(tbl) do
        ---@diagnostic disable-next-line: no-unknown
        t[k] = f(v)
    end
    return t
end

return M
