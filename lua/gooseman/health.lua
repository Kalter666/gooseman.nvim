local M = {}

function M.check()
  vim.health.start "gooseman.nvim"
  for _, t in ipairs {
    { "curl", "HTTP requests" },
    { "grpcurl", "GRPC requests" },
    { "websocat", "WS requests" },
    { "jq", "pretty JSON responses (optional)" },
    { "yq", "YAML specs in :Honk openapi (optional)" },
    { "git", "listing .http files in :Honk pick (optional)" },
  } do
    if vim.fn.executable(t[1]) == 1 then
      vim.health.ok(t[1] .. " found")
    else
      vim.health.warn(t[1] .. " not found: needed for " .. t[2])
    end
  end
end

return M
