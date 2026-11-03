# review.gitlab

Плагин Neovim для код-ревью merge request'ов GitLab: выбрать открытый MR из
списка, просмотреть дифф (слева — целевая сторона MR, справа — ваша source-ветка),
расставить inline-замечания и одной командой выгрузить их как discussions в MR.

Весь цикл внутри одной команды `:CodeReview`:

1. `:CodeReview` — окно со списком открытых MR (через `glab`).
2. Выбираете MR — открывается дифф (визуализация на [codediff.nvim](https://github.com/esmuellert/codediff.nvim)).
3. Ставите замечания (`i` в readonly-режиме / `<localleader>cc`) — простое текстовое окно.
4. `:CodeReview upload` (или `u`) — публикация в MR; успешно загруженные замечания
   отмечаются локально (✓) и при повторной загрузке пропускаются.

Замечания хранятся локально в `stdpath("data")/review/<repo>/<branch>/comments.json`,
привязаны к точным SHA ревизий MR, и несут скрытый маркер — повторная загрузка
не дублирует.

## Требования

- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) — визуализация диффа.
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) — окно комментария и справка.
- [`glab`](https://gitlab.com/gitlab-org/cli), аутентифицированный для вашего
  GitLab-хоста (`glab auth login`). Хост, проект и доступ берутся из git-remote —
  плагин не хранит токенов.

## Установка

С `lazy.nvim`:

```lua
{
  "<you>/review.gitlab",
  dependencies = {
    "esmuellert/codediff.nvim",
    "MunifTanjim/nui.nvim",
  },
  config = function()
    require("review-gitlab").setup()
  end,
}
```

`setup` можно вызвать без аргументов — работают значения по умолчанию:

```lua
require("review-gitlab").setup({
  -- dry_run = false,               -- предпросмотр вместо постинга
  -- require_matching_head = true,  -- пропускать замечания против устаревшей head MR
  -- codediff = { readonly = true },
  -- log = false, log_level = "info",
})
```

## Использование

```
:CodeReview              " открыть список открытых MR и выбрать нужный
:CodeReview upload       " выгрузить замечания в выбранный MR
:CodeReview upload 42    " выгрузить в MR !42 (явный IID)
:CodeReview check        " предпросмотр: что будет выгружено, ничего не постит
:CodeReview note         " добавить замечание на строке (или :'<,'>CodeReview note на диапазон)
:CodeReview edit         " редактировать замечание под курсором
:CodeReview delete       " удалить замечание под курсором
:CodeReview list         " список всех замечаний
:CodeReview close        " закрыть ревью (замечания сохраняются)
:CodeReview clear        " удалить все замечания текущей ветки
:CodeReview log          " открыть лог (:CodeReview log clear — очистить)
```

Какой MR выгружать, плагин запоминает при выборе (`mr.json` рядом с замечаниями),
так что `:CodeReview upload` без аргументов идёт в тот же MR. Можно передать IID явно.

`:CodeReview check` (и каждая реальная загрузка) открывает отчёт: что ушло inline,
что стало комментарием к файлу, что пропущено и почему.

## Как замечания ложатся в GitLab

| Замечание | GitLab |
|---|---|
| строка на стороне **new** | `position.new_line` (+ `old_line` для контекстных строк) |
| строка на стороне **old** | `position.old_line` (+ `new_line` для контекстных строк) |
| диапазон строк | постится на первую строку; диапазон указан в теле |
| к файлу (`line == 0`) | общий discussion MR, без позиции |

`base_sha` / `start_sha` / `head_sha` позиции берутся из `diff_refs` MR, а
added/removed/context строки — из диффа MR; это то, что GitLab требует для
принятия позиции.

## Пропущенные замечания

Замечание помечается пропущенным (никогда не теряется молча), когда:

- оно **уже загружено** — локальная отметка `uploaded` или маркер в MR;
- у него **нет закоммиченной ревизии** — замечание сделано к рабочему дереву
  (`head_sha` не задан); ревьюйте по SHA MR, чтобы его можно было привязать;
- оно сделано **против ревизии, отличной от head MR**
  (отключается `require_matching_head = false`);
- его **файла или строки нет в диффе MR**.

## Отладка

Плагин умеет писать подробный лог (команды glab и их коды/ошибки, выбранный MR,
аргумент codediff с SHA, результат `get_revisions`, путь хранилища, план загрузки
с причинами пропуска):

```lua
require("review-gitlab").setup({ log = true, log_level = "debug" })
```

Лог: `stdpath("state")/review-gitlab.log` (открыть — `:CodeReview log`). При проблеме
воспроизведите её и приложите этот файл.

## Тесты

```
make test
```
