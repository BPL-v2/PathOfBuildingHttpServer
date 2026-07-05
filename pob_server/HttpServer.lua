local function sendResponse(client, status, contentType, body)
    local response = table.concat({
        "HTTP/1.1 ", status, "\r\n",
        "Content-Type: ", contentType, "\r\n\r\n",
        body or "",
    })
    client:send(response)
    client:close()
    os.exit(0)
end

local function sendError(client, status, message)
    sendResponse(client, status, "text/plain", message)
end

local function readRequest(client)
    client:settimeout(2)

    local requestLine
    local headers = { }

    while true do
        local line = client:receive()
        if not line then
            break
        end
        if line == "" then
            break
        end
        if not requestLine then
            requestLine = line
        else
            headers[#headers + 1] = line
        end
    end

    local contentLength = 0
    for _, headerLine in ipairs(headers) do
        local length = headerLine:match("Content%-Length:%s*(%d+)")
        if length then
            contentLength = tonumber(length)
            break
        end
    end

    local body = ""
    if contentLength > 0 then
        body = client:receive(contentLength)
    end

    local method
    local path
    if requestLine then
        method, path = requestLine:match("^(%S+)%s+([^%s]+)")
    end

    return {
        requestLine = requestLine,
        headers = headers,
        body = body,
        method = method,
        path = path,
    }
end

local function serve(options)
    local socket = require("socket")
    local posix = require("posix")
    local port = assert(options.port, "Missing port")

    -- Requests are handled in forked children; line buffering makes sure
    -- their log output is flushed before the child calls os.exit().
    io.stdout:setvbuf("line")

    local server = assert(socket.bind(options.host or "*", port))
    local ok, err = pcall(function()
        while true do
            local client = server:accept()
            local pid = posix.fork()
            if pid == 0 then
                local request = readRequest(client)
                local handlerOk, handlerErr = pcall(options.handleRequest, client, request, {
                    sendResponse = sendResponse,
                    sendError = sendError,
                })
                if not handlerOk then
                    print("REQUEST FAILED: " .. tostring(handlerErr))
                    pcall(sendError, client, "500 Internal Server Error", "Internal server error.")
                end
                -- handleRequest is expected to exit via sendResponse/sendError;
                -- exit here too so a bug there can't loop this child back into accept().
                os.exit(1)
            else
                client:close()
                posix.wait(-1, posix.WNOHANG)
            end
        end
    end)

    if not ok then
        print("SERVER CRASHED: " .. tostring(err))
    end
    print("SERVER EXITING")
end

return {
    serve = serve,
    sendResponse = sendResponse,
    sendError = sendError,
}
