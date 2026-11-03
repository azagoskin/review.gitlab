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

## Формат замечаний (для агента код-ревью)

Замечания можно генерировать внешним агентом: он пишет файл `comments.json`, а
вы открываете MR в nvim (`:CodeReview`) и только просматриваете/выгружаете их.
Плагин сам ничего из агента не вызывает — контракт только через файл.

### Куда писать

```
<data>/review/<repo>/<branch>/comments.json
```

- `<data>` — `stdpath("data")`, обычно `~/.local/share/nvim`.
- `<repo>` — имя каталога git-репозитория (`basename` от `git rev-parse --show-toplevel`).
- `<branch>` — **source-ветка MR** (та, что ревьюим), с заменой небезопасных для
  имени файла символов на `_` (регэксп `[^%w%-_]` → `_`). Например ветка
  `feature/auth` → каталог `feature_auth`.

Рядом полезно (не обязательно) положить `mr.json` — тогда `:CodeReview upload`
будет знать IID без выбора MR в UI (иначе выберите MR в nvim — файл создастся сам):

```json
{ "iid": 128, "source_branch": "feature_auth", "target_branch": "develop",
  "diff_refs": { "base_sha": "9f8e…", "start_sha": "9f8e…", "head_sha": "1a2b…" } }
```

### Структура `comments.json`

Словарь `путь_файла → Comment[]` (пути относительно git-root):

```json
{
  "lua/app/auth.lua": [
    {
      "id": "agent_1730629200_1",
      "file": "lua/app/auth.lua",
      "line": 42,
      "line_end": 45,
      "side": "new",
      "text": "Нет проверки на nil токен — возможен краш на logout.",
      "created_at": 1730629200,
      "uploaded": false,
      "revisions": { "head_sha": "1a2b3c4d…", "head_ref": "feature_auth" }
    }
  ],
  "README.md": [
    {
      "id": "agent_1730629200_2",
      "file": "README.md",
      "line": 0,
      "side": "new",
      "text": "Обновить раздел про установку.",
      "created_at": 1730629200,
      "uploaded": false
    }
  ]
}
```

### Поля `Comment`

| Поле | Обяз. | Смысл |
|---|---|---|
| `id` | да | уникальная строка; рекомендуется `<prefix>_<unixtime>_<n>` |
| `file` | да | путь относительно git-root (как в диффе MR, сторона new) |
| `line` | да | номер строки, 1-based. **`0` = комментарий ко всему файлу** |
| `line_end` | нет | конец диапазона (многострочное замечание) |
| `side` | да | `"new"` — строка в новой версии (правая сторона); `"old"` — удалённая строка (левая) |
| `text` | да | текст замечания; многострочный — через `\n` |
| `created_at` | да | unix-время (секунды) |
| `uploaded` | да | ставьте `false` — плагин выставит `true` после публикации |
| `revisions.head_sha` | для inline | **должен равняться `head_sha` из `diff_refs` MR**, иначе inline-замечание будет пропущено при загрузке (`require_matching_head`). Для `line == 0` (к файлу) не требуется |
| `revisions.head_ref` | нет | source-ветка; помогает резолвить MR, если нет `mr.json` |

`head_sha` берётся из MR: `glab api projects/:id/merge_requests/<iid>` → поле
`diff_refs.head_sha` (или `glab mr view <iid> --output json`). Номера строк и
сторона (`new`/`old`) должны соответствовать диффу MR — это то, что GitLab
проверяет при простановке позиции (см. ниже).

### Как агенту это собрать

1. Узнать MR и его ревизии: `glab api projects/:id/merge_requests/<iid>` →
   `source_branch`, `diff_refs.{base_sha,start_sha,head_sha}`.
2. Прогнать ревью по диффу MR (`.../merge_requests/<iid>/diffs`), для каждого
   замечания запомнить `new_path`/`old_path`, сторону и номер строки из диффа.
3. Записать `comments.json` (и по желанию `mr.json`) в каталог выше.
4. В nvim: `:CodeReview` → выбрать этот MR → замечания отрисуются поверх диффа;
   `:CodeReview upload` — опубликовать их как discussions.

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
