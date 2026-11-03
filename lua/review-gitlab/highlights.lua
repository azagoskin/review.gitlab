local M = {}

function M.setup()
  local links = {
    ReviewComment = "DiagnosticInfo", -- рамка/знак обычного замечания
    ReviewUploaded = "DiagnosticOk", -- замечание, уже загруженное в MR
    ReviewSign = "Comment",
    ReviewPickerMeta = "Comment",
    ReviewPickerHash = "Identifier",
  }

  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end

  -- Подсветка строк замечания (тёмный фон, без подчёркивания)
  vim.api.nvim_set_hl(0, "ReviewCommentLine", { bg = "#0d1f28", underline = false, default = true })
  vim.api.nvim_set_hl(0, "ReviewUploadedLine", { bg = "#152015", underline = false, default = true })

  vim.fn.sign_define("ReviewComment", {
    text = "●",
    texthl = "ReviewSign",
  })
end

return M
