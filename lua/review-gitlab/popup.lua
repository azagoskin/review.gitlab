local M = {}

local config = require("review-gitlab.config")

---Простое окно ввода текста замечания (без выбора типа).
---@param initial_text? string
---@param callback fun(text: string|nil)
function M.open(initial_text, callback)
  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then
    vim.notify("nui.nvim требуется для окна комментария", vim.log.levels.ERROR, { title = "review.gitlab" })
    callback(nil)
    return
  end

  -- Запомнить текущее окно, чтобы вернуть фокус
  local prev_win = vim.api.nvim_get_current_win()

  local function restore_focus()
    vim.defer_fn(function()
      if prev_win and vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
      end
      vim.cmd("stopinsert")
    end, 10)
  end

  local cfg = config.get()
  local submit_key = cfg.keymaps.popup_submit
  local submit_hint = submit_key and string.format(" (%s: сохранить)", submit_key:gsub("^<(.+)>$", "%1")) or ""

  local text_popup = Popup({
    position = "50%",
    size = { width = 60, height = 8 },
    border = {
      style = "rounded",
      text = {
        top = " Комментарий" .. submit_hint .. " ",
        top_align = "center",
      },
    },
    win_options = {
      winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
    },
    buf_options = {
      modifiable = true,
      readonly = false,
    },
  })

  local function get_text()
    local lines = vim.api.nvim_buf_get_lines(text_popup.bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    text = text:gsub("%s+$", "")
    return text
  end

  local function submit()
    local text = get_text()
    text_popup:unmount()
    if text and text ~= "" then
      callback(text)
    else
      callback(nil)
    end
    restore_focus()
  end

  local function close()
    text_popup:unmount()
    callback(nil)
    restore_focus()
  end

  text_popup:mount()

  if initial_text and initial_text ~= "" then
    local lines = vim.split(initial_text, "\n")
    vim.api.nvim_buf_set_lines(text_popup.bufnr, 0, -1, false, lines)
  end

  vim.api.nvim_set_current_win(text_popup.winid)
  vim.bo[text_popup.bufnr].filetype = "markdown"
  vim.cmd("startinsert")

  -- <CR> НЕ привязываем к отправке: в insert-режиме это перенос строки.
  -- Сохранение — только по popup_submit (<C-s>), отмена — <Esc>/popup_cancel.
  local km = cfg.keymaps
  if km.popup_submit then
    vim.keymap.set({ "i", "n" }, km.popup_submit, submit, { buffer = text_popup.bufnr, noremap = true })
  end
  vim.keymap.set("n", "<Esc>", close, { buffer = text_popup.bufnr, noremap = true })
  if km.popup_cancel then
    vim.keymap.set("n", km.popup_cancel, close, { buffer = text_popup.bufnr, noremap = true })
  end
end

return M
