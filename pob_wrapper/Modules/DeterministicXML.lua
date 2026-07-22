-- PoB's common.xml.ComposeXML (PathOfBuilding/runtime/lua/xml.lua) writes
-- each element's attributes by iterating node.attrib with pairs(), whose
-- order depends on Lua's hash-table internals rather than insertion order.
-- Since build:SaveDB rebuilds those attrib tables from scratch on every
-- export, two exports of the same build can come out byte-different -
-- purely from attribute reshuffling, with no actual content change. That
-- makes exports impossible to diff meaningfully.
--
-- This installs a drop-in replacement for common.xml.ComposeXML that is
-- otherwise identical but always emits attributes in sorted-key order, so
-- exporting the same build twice produces byte-identical XML. It duplicates
-- xml.lua's composeNode/encodeContent rather than patching the vendored
-- checkout, since PathOfBuilding/ is re-synced from upstream on every
-- scripts/pull-pob-runtimes.sh run and any local edit there would be lost.

local t_insert = table.insert

local function encodeContent(text)
    local subTbl = { ["<"] = "lt", [">"] = "gt", ["&"] = "amp", ["'"] = "apos", ['"'] = "quot" }
    return (text:gsub("[<>&'\"]", function(chr)
        return "&" .. subTbl[chr] .. ";"
    end))
end

local function sortedAttribKeys(attrib)
    local keys = { }
    for key in pairs(attrib) do
        t_insert(keys, key)
    end
    table.sort(keys)
    return keys
end

local function composeNode(frag, node, lvl)
    if type(node.elem) ~= "string" then
        return "invalid xml tree (missing element name)"
    end
    t_insert(frag, string.rep("\t", lvl))
    t_insert(frag, '<')
    t_insert(frag, node.elem)
    if node.attrib then
        for _, key in ipairs(sortedAttribKeys(node.attrib)) do
            local val = node.attrib[key]
            if val then
                if type(val) ~= "string" then
                    return "invalid xml tree (value for attribute '" .. key .. "' in <" .. node.elem .. "> is not a string)"
                end
                t_insert(frag, ' ')
                t_insert(frag, key)
                t_insert(frag, '="')
                t_insert(frag, encodeContent(val))
                t_insert(frag, '"')
            end
        end
    end
    if not node[1] then
        t_insert(frag, '/>\n')
        return
    end
    t_insert(frag, '>\n')
    for _, n in ipairs(node) do
        if type(n) == "table" then
            local errMsg = composeNode(frag, n, lvl + 1)
            if errMsg then
                return errMsg
            end
        elseif type(n) == "string" then
            t_insert(frag, string.rep("\t", lvl + 1))
            t_insert(frag, encodeContent(n))
            t_insert(frag, '\n')
        else
            return "invalid xml tree (child of <" .. node.elem .. "> is not table or string)"
        end
    end
    t_insert(frag, string.rep("\t", lvl))
    t_insert(frag, '</')
    t_insert(frag, node.elem)
    t_insert(frag, '>\n')
end

local function composeXMLDeterministic(rootNode)
    if type(rootNode) ~= "table" then
        return nil, "invalid xml tree"
    end
    local frag = { '<?xml version="1.0" encoding="UTF-8"?>\n' }
    local errMsg = composeNode(frag, rootNode, 0)
    if errMsg then
        return nil, errMsg
    end
    return table.concat(frag)
end

-- Call once, after PoB's own Launch.lua has populated the global `common`
-- table (common.xml = require("xml")), so there is something to override.
local function install()
    common.xml.ComposeXML = composeXMLDeterministic
end

return install
