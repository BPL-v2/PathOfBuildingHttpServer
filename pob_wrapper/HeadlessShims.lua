local function install(context)
    local scriptPath = assert(context.scriptPath, "Missing scriptPath")

    local callbackTable = { }
    mainObject = nil

    function runCallback(name, ...)
        if callbackTable[name] then
            return callbackTable[name](...)
        elseif mainObject and mainObject[name] then
            return mainObject[name](mainObject, ...)
        end
    end

    function SetCallback(name, func)
        callbackTable[name] = func
    end

    function GetCallback(name)
        return callbackTable[name]
    end

    function SetMainObject(obj)
        mainObject = obj
    end

    local imageHandleClass = { }
    imageHandleClass.__index = imageHandleClass

    function NewImageHandle()
        return setmetatable({ }, imageHandleClass)
    end

    function imageHandleClass:Load()
        self.valid = true
    end

    function imageHandleClass:Unload()
        self.valid = false
    end

    function imageHandleClass:IsValid()
        return self.valid
    end

    function imageHandleClass:SetLoadingPriority() end

    function imageHandleClass:ImageSize()
        return 1, 1
    end

    function RenderInit() end

    function GetScreenSize()
        return 1920, 1080
    end

    function GetScreenScale()
        return 1
    end

    function GetVirtualScreenSize()
        return GetScreenSize()
    end

    function GetDPIScaleOverridePercent()
        return 1
    end

    function SetDPIScaleOverridePercent() end
    function SetClearColor() end
    function SetDrawLayer() end
    function SetViewport() end
    function SetDrawColor() end
    function DrawImage() end
    function DrawImageQuad() end
    function DrawString() end

    function DrawStringWidth()
        return 1
    end

    function DrawStringCursorIndex()
        return 0
    end

    function StripEscapes(text)
        return text:gsub("%^%d", ""):gsub("%^x%x%x%x%x%x%x", "")
    end

    function GetAsyncCount()
        return 0
    end

    function SetWindowTitle() end

    function GetCursorPos()
        return 0, 0
    end

    function SetCursorPos() end
    function ShowCursor() end
    function IsKeyDown() end
    function Copy() end
    function Paste() end

    function NewFileSearch(path, dirsOnly)
        local lfs = require("lfs")
        local dir
        local pattern

        if path:match("[*?]") then
            dir = path:match("^(.*/)[^/]*$") or "./"
            pattern = path:match("([^/]*)$")
            pattern = "^" .. pattern:gsub("%.", "%%."):gsub("%*", ".*"):gsub("%?", ".") .. "$"
        else
            local attr = lfs.attributes(path)
            if not attr then
                return nil
            end
            if dirsOnly and attr.mode ~= "directory" then
                return nil
            end
            return {
                GetFileName = function()
                    return path:match("([^/]+)$")
                end,
                GetFileModifiedTime = function()
                    return attr.modification
                end,
                NextFile = function()
                    return false
                end,
            }
        end

        local files = { }
        local ok, iter, state, var = pcall(lfs.dir, dir)
        if not ok then
            return nil
        end

        for file in iter, state, var do
            if file ~= "." and file ~= ".." and file:match(pattern) then
                local fullPath = dir .. file
                local attr = lfs.attributes(fullPath)
                if attr and (not dirsOnly or attr.mode == "directory") then
                    table.insert(files, {
                        name = file,
                        fullPath = fullPath,
                        modified = attr.modification,
                    })
                end
            end
        end

        if #files == 0 then
            return nil
        end

        table.sort(files, function(a, b)
            return a.name < b.name
        end)

        local index = 1
        return {
            GetFileName = function()
                return files[index] and files[index].name
            end,
            GetFileModifiedTime = function()
                return files[index] and files[index].modified
            end,
            NextFile = function()
                index = index + 1
                return index <= #files
            end,
        }
    end

    local zlib

    function Deflate(data)
        if not zlib then
            zlib = require("zlib")
        end
        local deflater = zlib.deflate()
        return deflater(data, "finish")
    end

    function Inflate(data)
        if not zlib then
            zlib = require("zlib")
        end
        local inflater = zlib.inflate()
        return inflater(data, "finish")
    end

    function GetTime()
        return os.clock()
    end

    function GetScriptPath()
        return scriptPath
    end

    function GetRuntimePath()
        return ""
    end

    function GetUserPath()
        return scriptPath
    end

    function MakeDir() end
    function RemoveDir() end
    function SetWorkDir() end

    function GetWorkDir()
        return ""
    end

    function LaunchSubScript() end
    function AbortSubScript() end
    function IsSubScriptRunning() end

    function LoadModule(fileName, ...)
        if not fileName:match("%.lua") then
            fileName = fileName .. ".lua"
        end
        local func, err = loadfile(fileName)
        if func then
            return func(...)
        end
        error("LoadModule() error loading '" .. fileName .. "': " .. err)
    end

    function PLoadModule(fileName, ...)
        if not fileName:match("%.lua") then
            fileName = fileName .. ".lua"
        end
        local func, err = loadfile(fileName)
        if func then
            return PCall(func, ...)
        end
        error("PLoadModule() error loading '" .. fileName .. "': " .. err)
    end

    function PCall(func, ...)
        local ret = { pcall(func, ...) }
        if ret[1] then
            table.remove(ret, 1)
            return nil, unpack(ret)
        end
        return ret[2]
    end

    function ConPrintf() end
    function ConPrintTable() end
    function ConExecute() end
    function ConClear() end
    function SpawnProcess() end
    function OpenURL() end
    function SetProfiling() end
    function Restart() end
    function Exit() end
    function TakeScreenshot() end

    function GetCloudProvider()
        return nil, nil, nil
    end

    local originalRequire = require
    function require(name)
        if name == "lcurl.safe" then
            return
        end
        return originalRequire(name)
    end
end

return install
