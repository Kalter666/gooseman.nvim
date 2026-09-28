-- the curl command the curl demo "copied from devtools"
vim.fn.setreg("+", {
  "curl 'http://localhost:8080/geese?page=2' \\",
  "  -H 'Accept: application/json' \\",
  "  -H 'Authorization: Bearer static-token' \\",
  "  --compressed",
})
