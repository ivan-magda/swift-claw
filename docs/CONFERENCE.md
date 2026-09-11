# Конференционный режим: установка с нуля на macOS

Руководство для членов ПК: собрать swift-claw из ветки PR, подключить своего Telegram-бота,
свой GitHub-аккаунт и свой публичный репозиторий, затем проверить путь
«решение участника → подтверждение → реализация → черновик PR → ответ в топике».
Предварительная установка личного swift-claw не нужна.

**Нужная версия находится в ветке `feature/conference-coding-challenge`, PR
[#199](https://github.com/ivan-magda/swift-claw/pull/199). Мержить её в `main` для запуска не нужно.**
Команды ниже устанавливают именно эту ветку. Обычный `install.sh` и готовые релизы
не гарантируют наличие этой функциональности; для конференции используйте сборку ниже.

## Что подготовить

- Mac с полным Xcode и **Swift 6.3.x**. Для iOS-проекта нужны соответствующий SDK и симулятор.
  Версия macOS должна поддерживать выбранный Xcode.
- Telegram-аккаунт организатора и отдельный бот для этой установки.
- Свой GitHub-аккаунт и **публичный репозиторий с кодом проекта**, в котором этот аккаунт
  может создавать ветки и PR. В репозитории уже должна существовать ветка с исходным кодом.
- Доступ к разговорной модели и Codex. Основной путь ниже использует ChatGPT;
  в обоих процессах можно войти одним аккаунтом с соответствующим доступом.
- Формулировку кейса: что предлагается улучшить, ограничения и способ проверки.

Репозиториев два: `ivan-magda/swift-claw` содержит бота, а **ваш репозиторий проекта** — приложение,
которое будут менять решения участников. Адрес второго задаётся в кейсе.
`wowlocal/crew18-sim` и `ivan-magda/crew18-sim` не обязательны: они использовались при проверке PR.
Fork нужен только если вы берёте чужой проект за основу. Свой репозиторий используйте напрямую.

Для общего мероприятия выберите один компьютер, на котором будет постоянно работать бот.
Для независимых пробных установок коллегам нужны разные боты: два процесса с одним Telegram-токеном
конфликтуют даже при разных папках состояния.

Для мероприятия используйте отдельную учётную запись macOS без личных файлов, SSH-ключей и
интеграций. Отдельная папка состояния предотвращает смешивание данных агентов, но не является
песочницей ОС: native Codex исполняет код с правами своей установки.
Для собственного пробного прогона можно использовать свой GitHub-аккаунт; для общего мероприятия
выделите аккаунт публикации и ограниченный токен. Участникам GitHub-аккаунты не нужны.

## 1. Установить инструменты

Установите [Xcode](https://developer.apple.com/xcode/), откройте его, примите лицензию и дождитесь
установки компонентов. Для iOS-кейса установите simulator runtime в настройках Xcode.
Одних Command Line Tools для сборки iOS-приложения недостаточно.

В Terminal выберите Xcode для этой сессии. Если приложение называется иначе, измените путь:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version
swift --version
git --version
```

Ожидается Swift 6.3.x. Проверенная при разработке конфигурация — Xcode 26.6 / Swift 6.3.3.
Если компилятор старее, сначала установите подходящий Xcode.

Нужны Node.js с npm и Python 3. Если они уже работают, переустанавливать их не нужно:

```sh
node --version
npm --version
python3 --version
```

На новом компьютере установите [Homebrew](https://brew.sh/) по инструкции на его сайте,
выполните напечатанные им команды настройки PATH, затем:

```sh
brew install node python
```

GitHub CLI (`gh`) для конференционного pipeline не обязателен: публикацией занимается daemon.

## 2. Скачать ветку и собрать отдельный binary

Выполняйте шаги установки в одном окне Terminal. Все пути относятся к новой установке
`~/.swift-claw-conference/`. Личный `~/.swift-claw/` не используется.
Не копируйте из личного агента базу данных, секреты, workspace или конфигурацию Codex.

```sh
conference_source="$HOME/Developer/swift-claw-conference"
conference_root="$HOME/.swift-claw-conference"

mkdir -p "$HOME/Developer"
git clone --branch feature/conference-coding-challenge --single-branch \
  https://github.com/ivan-magda/swift-claw.git "$conference_source"
cd "$conference_source"
git branch --show-current
git rev-parse HEAD
swift build -c release --product clawd
```

Ожидается ветка `feature/conference-coding-challenge` и `Build complete!` без ошибок.
После успешной сборки:

```sh
install -d -m 700 "$conference_root" "$conference_root/bin" \
  "$conference_root/logs" "$conference_root/cases" \
  "$conference_root/codex-home" "$conference_root/conference-home"
install -m 755 "$conference_source/.build/release/clawd" "$conference_root/bin/clawd"
git -C "$conference_source" rev-parse HEAD > "$conference_root/build-commit.txt"

npm install --prefix "$conference_root/tools/codex" --save-exact @openai/codex@0.154.0
conference_codex="$conference_root/tools/codex/node_modules/.bin/codex"
"$conference_codex" --version
```

Codex CLI `0.154.0` использовался в живой проверке этого PR. Установка выше локальная и не заменяет
глобальный Codex. Не отключайте optional dependencies npm: они содержат платформенный binary.
Совместимость требуемых CLI-флагов дополнительно проверит `coder setup`.

Если ветка переименована, в checkout можно получить PR командами
`git fetch origin pull/199/head` и `git switch -c conference-pr199 FETCH_HEAD`.
Обычный checkout `main` эту замену не выполняет.

## 3. Создать Telegram-бота и группу

1. В [@BotFather](https://t.me/BotFather) выполните `/newbot`, задайте имя и username.
   Сохраните токен. Это пароль бота; не публикуйте его в чате или GitHub.
2. Создайте группу. Если нужны топики, включите Topics в настройках группы.
3. Добавьте бота **администратором** для проверки членства при подтверждении решения.
   Если добавление в группы запрещено, включите его через `/setjoingroups` в BotFather.
4. От своего обычного аккаунта отправьте в топике `@YourConferenceBot setup`, заменив username.
   До запуска daemon ответа не будет.

Для бота-администратора отключать Privacy Mode не требуется. Telegram гарантирует проверку
чужого членства через `getChatMember` именно для администраторов.
См. [Telegram FAQ](https://core.telegram.org/bots/faq#what-messages-will-my-bot-get) и
[getChatMember](https://core.telegram.org/bots/api#getchatmember).

Нужны два числа: **ID группы** (обычно отрицательный) и **ваш ID пользователя** (положительный).
До первого запуска daemon выполните скрипт. Он запрашивает токен скрыто, без записи в историю shell,
и выводит идентификаторы из поступивших сообщений:

```sh
python3 - <<'PY'
import getpass
import json
import urllib.error
import urllib.request

token = getpass.getpass("Токен нового конференционного бота: ").strip()
request = urllib.request.Request(
    "https://api.telegram.org/bot" + token + "/getUpdates",
    data=json.dumps({"timeout": 0, "allowed_updates": ["message", "my_chat_member"]}).encode(),
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(request, timeout=15) as response:
        result = json.load(response)
except (urllib.error.URLError, TimeoutError):
    raise SystemExit("Проверьте токен, сеть и отсутствие другого процесса с этим ботом.") from None

found = False
for update in result.get("result", []):
    item = update.get("message") or update.get("my_chat_member") or {}
    chat, sender = item.get("chat", {}), item.get("from", {})
    if chat.get("type") in ("group", "supergroup"):
        found = True
        print("Группа:", chat.get("title"), "CLAW_GROUP_CHATS=" + str(chat["id"]))
        if sender.get("id") and not sender.get("is_bot"):
            print("Автор события: CLAW_ALLOWLIST=" + str(sender["id"]))
if not found:
    print("Отправьте @YourConferenceBot setup в группе и повторите команду.")
PY
```

Возьмите ID автора **своего** сообщения. ID топика в конфиг добавлять не нужно:
`CLAW_GROUP_CHATS` разрешает группу вместе с её топиками и General.
Не запускайте `getUpdates` параллельно работающему daemon. Конференционный режим игнорирует личку,
поэтому обычный способ «написать `/start` в личку боту и получить ID» здесь не подходит.

## 4. Подготовить свой GitHub и токен

Убедитесь, что в своём публичном репозитории уже есть код проекта и целевая ветка, например `main`.
В этой версии **источник кода и место создания PR — один репозиторий**.
Бот не создаёт fork автоматически и не отправляет PR в другой upstream.

Для отдельного аккаунта публикации зарегистрируйте обычный GitHub-аккаунт с отдельной почтой.
Разместите репозиторий под ним либо предоставьте ему права в организации. Для личного пробного
прогона подходят ваш существующий аккаунт и ваш репозиторий.

Под аккаунтом будущего автора PR откройте GitHub → Settings → Developer settings →
Personal access tokens → Fine-grained tokens → Generate new token:

- Resource owner: владелец вашего репозитория.
- Repository access: Only select repositories → выбранный проект.
- Repository permissions: **Contents — Read and write**, **Pull requests — Read and write**.
  Metadata — Read предоставляется автоматически.
- Expiration: токен должен действовать во время подготовки и мероприятия.

Для изменения `.github/workflows/` дополнительно требуется **Workflows — Read and write**.
В организации может понадобиться одобрение токена администратором.
У fine-grained PAT есть ограничения для outside collaborators; простой путь — собственный
репозиторий аккаунта либо членство аккаунта в организации с правом Write.
См. [GitHub: personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).

Сохраните токен для `GH_TOKEN`. В `CLAW_CONFERENCE_EXPECTED_GITHUB_ACTOR` нужно записать
**login аккаунта токена**, а не имя организации. GitHub App installation token здесь не подходит.

## 5. Зафиксировать исходную версию и описать кейс

Frozen baseline — полный SHA исходного коммита. **Ветка `main` подходит**, если во время кейса
она остаётся на этом коммите. Все решения начинаются с одинакового кода и публикуются в отдельных
ветках `conference/<UUID>`; не мержите их в исходную ветку во время активности.

Замените `YOUR_GITHUB/YOUR_REPOSITORY` своим адресом. Команда получает SHA именно из вашего
репозитория и создаёт пробный кейс:

```sh
conference_repository='YOUR_GITHUB/YOUR_REPOSITORY'
conference_base='main'
python3 - "$conference_root" "$conference_repository" "$conference_base" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

root, repository, branch = sys.argv[1:]
url = "https://github.com/" + repository
ref = "refs/heads/" + branch
output = subprocess.check_output(
    ["git", "ls-remote", "--exit-code", "--refs", url, ref], text=True
)
matches = [line.split()[0] for line in output.splitlines() if line.split()[1] == ref]
if len(matches) != 1 or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", matches[0]):
    raise SystemExit("Не удалось определить полный SHA целевой ветки.")
case = {
    "id": "smoke-01",
    "title": "Понятность интерфейса",
    "prompt": "Предложите одно небольшое улучшение понятности интерфейса проекта. "
              "Опишите конкретное поведение и способ проверки. Сохраните основную функциональность.",
    "repositoryURL": url,
    "baselineRef": matches[0],
    "baseBranch": branch,
}
path = pathlib.Path(root) / "cases" / "smoke-01.json"
with path.open("x") as file:
    json.dump(case, file, ensure_ascii=False, indent=2)
    file.write("\n")
print("Кейс:", path)
print("Исходный коммит:", matches[0])
PY
nano "$conference_root/cases/smoke-01.json"
```

В редакторе измените вопрос под свой проект. Обязательны все шесть полей из примера.
`baselineRef` — полный SHA, не слово `main`. Для `id` используйте уникальное имя из строчных
латинских букв, цифр и дефисов (до 64 символов). Заголовок — до 200 символов, вопрос — до 20 000.
На один запуск daemon выбирается один активный кейс.

До приглашения участников откройте проект из этого коммита на конференционном Mac и выполните
его обычную сборку. Для iOS выберите установленный simulator в Xcode и запустите приложение.
Требования и команды сборки приложения определяет **ваш проект**; сборка swift-claw их не проверяет.

## 6. Создать clawd.env и launcher

Блок создаёт минимальный конфиг с раскрытыми абсолютными путями.
Повторный запуск не перезаписывает существующий файл:

```sh
python3 - "$conference_root" "$DEVELOPER_DIR" <<'PY'
import pathlib
import shlex
import sys

root = pathlib.Path(sys.argv[1]).resolve()
settings = {
    "CLAW_STATE_ROOT": str(root),
    "CLAW_TELEGRAM_BOT_TOKEN": "REPLACE_TELEGRAM_TOKEN",
    "CLAW_ALLOWLIST": "REPLACE_YOUR_NUMERIC_USER_ID",
    "CLAW_GROUP_CHATS": "REPLACE_NUMERIC_GROUP_ID",
    "CLAW_LLM_MODEL": "",
    "CLAW_LLM_BASE_URL": "",
    "CLAW_LLM_API_KEY": "",
    "CLAW_LLM_STRUCTURED_OUTPUT": "off",
    "CLAW_CONFERENCE_ENABLED": "true",
    "CLAW_CONFERENCE_CASE_FILE": str(root / "cases" / "smoke-01.json"),
    "CLAW_CONFERENCE_EXPECTED_GITHUB_ACTOR": "REPLACE_GITHUB_LOGIN",
    "GH_TOKEN": "REPLACE_GITHUB_TOKEN",
    "CLAW_CODER_ENABLED": "true",
    "CLAW_CODER_MAX_CONCURRENT_JOBS": "1",
    "CLAW_CODER_JOB_TIMEOUT_SECONDS": "1800",
    "CLAW_CODER_EXECUTABLE": str(root / "tools/codex/node_modules/.bin/codex"),
    "CLAW_CODER_CONFIG_HOME": str(root / "codex-home"),
    "DEVELOPER_DIR": sys.argv[2],
}
path = root / "clawd.env"
with path.open("x") as file:
    path.chmod(0o600)
    for key, value in settings.items():
        file.write(key + "=" + shlex.quote(value) + "\n")
PY
nano "$conference_root/clawd.env"
```

Замените все `REPLACE_...`: Telegram-токен, свой числовой Telegram ID, ID группы, GitHub login
и PAT. В nano сохранить: Ctrl-O, Enter; выйти: Ctrl-X. Модель пока оставьте пустой.
Токены храните внутри одинарных кавычек, например `GH_TOKEN='ваш-токен'`.

`CLAW_ALLOWLIST` содержит организатора для обычной диагностики. **Участников добавлять не нужно**:
в конференционном режиме доступ определяется членством в разрешённой группе.

Создайте launcher, загружающий этот env и проверяющий папку состояния перед каждой командой:

```sh
cat > "$conference_root/bin/run-clawd.sh" <<'SH'
#!/bin/sh
set -eu
conference_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
readonly conference_root
set -a
. "$conference_root/clawd.env"
set +a
if [ "${CLAW_STATE_ROOT:-}" != "$conference_root" ]; then
  echo "CLAW_STATE_ROOT должен совпадать с папкой этого launcher." >&2
  exit 1
fi
export CLAW_ENV_FILE="$conference_root/clawd.env"
cd "$conference_root"
if [ "$#" -eq 0 ]; then
  set -- run
fi
exec "$conference_root/bin/clawd" "$@"
SH
chmod 700 "$conference_root/bin/run-clawd.sh"
```

Все команды `clawd` ниже выполняются через launcher. Binary не загружает env автоматически,
а один `CLAW_ENV_FILE` не выбирает папку состояния.
В `clawd.env` оставляйте буквальные значения: не пишите `$HOME`, `$(command -v codex)` или `$PATH`.
`coder setup` читает файл как данные и отвергает shell-подстановки.
Не добавляйте пустые необязательные строки вроде `CLAW_CODER_PROFILE=`: ненужную строку опускают.

## 7. Авторизовать разговорную модель

Daemon пока должен быть остановлен. Выполните:

```sh
"$conference_root/bin/run-clawd.sh" auth login
```

Откройте показанную ссылку, введите код и завершите вход. Выберите модель из доступного аккаунту
каталога. Команда напечатает `CLAW_LLM_MODEL=openai-chatgpt/…` — перенесите **это конкретное
значение** в `clawd.env`:

```sh
nano "$conference_root/clawd.env"
"$conference_root/bin/run-clawd.sh" secrets seal --env-file "$conference_root/clawd.env"
"$conference_root/bin/run-clawd.sh" auth status
```

`CLAW_LLM_BASE_URL` и `CLAW_LLM_API_KEY` остаются пустыми, `CLAW_LLM_STRUCTURED_OUTPUT=off`.
Это реализованный в swift-claw неофициальный маршрут подписки ChatGPT.
Не копируйте название модели другого организатора: доступные модели могут отличаться.
Если каталог временно не загрузился, повторите login после восстановления сети.

Альтернатива — OpenAI-compatible Chat Completions endpoint: вместо `auth login` задайте в env
`CLAW_LLM_BASE_URL`, `CLAW_LLM_MODEL` без префикса `openai-chatgpt/` и `CLAW_LLM_API_KEY`
из настроек провайдера, затем выполните ту же команду `secrets seal`.
Модель должна поддерживать tool calls. В этом варианте ChatGPT `auth status` не требуется.

`secrets seal` шифрует Telegram-токен и ключи LLM, очищая их plaintext-строки в env.
Пустой `CLAW_TELEGRAM_BOT_TOKEN` после команды — ожидаемое состояние.
**`GH_TOKEN` не шифруется этой командой**: он остаётся в файле с правами `0600`.
Не коммитьте и не пересылайте env, `secret.key`, encrypted stores или Codex `auth.json`.

## 8. Отдельно авторизовать Codex

Разговорная модель отвечает в Telegram, native Codex реализует решение в коде. Это два процесса
с разными хранилищами авторизации. Предыдущий login не авторизует Codex; аккаунт может быть тем же.

```sh
printf '%s\n' 'cli_auth_credentials_store = "file"' \
  > "$conference_root/codex-home/config.toml"
chmod 600 "$conference_root/codex-home/config.toml"

(
  cd "$conference_root/conference-home"
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_CONFIG_DIR -u SSH_AUTH_SOCK -u GIT_ASKPASS \
    HOME="$conference_root/conference-home" \
    CODEX_HOME="$conference_root/codex-home" \
    "$conference_codex" login
)

env -u GH_TOKEN -u GITHUB_TOKEN -u GH_CONFIG_DIR -u SSH_AUTH_SOCK -u GIT_ASKPASS \
  HOME="$conference_root/conference-home" \
  CODEX_HOME="$conference_root/codex-home" \
  "$conference_codex" login status
chmod 600 "$conference_root/codex-home/auth.json"
```

Завершите вход в браузере; `login status` должен подтвердить авторизацию.
Эти HOME/CODEX_HOME соответствуют реальному конференционному worker. Файловое хранение
делает авторизацию доступной сервису в том же отдельном каталоге.
См. [Codex: credential storage](https://learn.chatgpt.com/docs/auth#credential-storage).

Из этого же Terminal, где работает Node, сохраните рабочий PATH для Coder:

```sh
"$conference_root/bin/run-clawd.sh" coder setup --env-file "$conference_root/clawd.env"
"$conference_root/bin/run-clawd.sh" doctor --check-config
```

`coder setup` проверит CLI и локальный login, сохранит `CLAW_CODER_PATH` и включит Coder.
Он не выполняет вход и не запускает сервис. Разговорная `CLAW_LLM_MODEL` не выбирает модель Codex.
`doctor --check-config` должен завершиться успешно с encrypted secrets. Это предварительная
проверка: она не проверяет кейс, GitHub actor, возможность push/PR или реальное выполнение Codex.
Конференционная конфигурация проверяется при `run`; права публикации — живым прогоном.

## 9. Запустить и проверить в группе

```sh
"$conference_root/bin/run-clawd.sh" run
```

Оставьте Terminal открытым. При старте проверяются кейс, отдельный Codex home, GitHub login токена
и доступность публичного исходного кода. Если процесс завершился с ошибкой, исправьте её.
Из другого окна можно запустить полную диагностику:

```sh
"$HOME/.swift-claw-conference/bin/run-clawd.sh" doctor
```

В Telegram используйте **группу или её топик**; личка игнорируется.
Замените `YourConferenceBot` на username своего бота:

1. Напишите `@YourConferenceBot покажи текущий кейс`. Бот должен показать ваш вопрос.
2. Отправьте **полное решение одним сообщением**, адаптировав пример к проекту:

   > @YourConferenceBot вот моё решение: на стартовом экране добавить короткую подсказку
   > «Выберите действие, чтобы начать». Проверка: открыть стартовый экран и убедиться,
   > что подсказка видна, помещается на экране и не перекрывает элементы управления.

3. Появится карточка **«Отправить решение?»** с решением, вашим репозиторием, веткой и SHA.
   Для проверки отмены нажмите **«Отмена»**, затем отправьте полное решение снова.
   Отмена не расходует попытку. Если карточка длинная, кнопки находятся на последнем сообщении.
4. Нажмите **«Отправить решение»** со своего аккаунта. После проверки предложения бот должен
   сообщить, что решение поставлено в очередь, и показать UUID заявки.
5. В том же топике спросите `@YourConferenceBot какой статус моей заявки?`.
6. Дождитесь результата со ссылкой на **draft PR**. Убедитесь, что PR создан в вашем репозитории
   от ожидаемого аккаунта, содержит предложение и изменения, а его base — выбранная ветка.
   Исходная ветка должна остаться на прежнем SHA.

**Эти шаги подтверждают основной e2e-путь.** Карточка, `queued` или `running` ещё не подтверждают
публикацию и доставку результата. Созданный PR не означает, что приложение собрано или реализация
верна: проверяйте diff и фактически выполненные проверки.

Повторите путь вторым Telegram-аккаунтом. Он не должен подтверждать или отменять вашу карточку,
а вопрос «моя заявка» должен возвращать его собственную заявку. По UUID чужая заявка недоступна.
Даже свою заявку нельзя запросить из другого топика: статус связан с автором **и исходным топиком**.
При этом сообщения и результаты в группе видны её участникам — это не приватные диалоги.

Один участник может иметь **одну принятую заявку на один `id` кейса**, в том числе при последующей
ошибке реализации. Для нового полного прогона создайте новый кейс (`smoke-02`), как описано ниже.
Повторное подтверждение не должно создавать вторую заявку или PR.
Отклонённая проверкой предложения отправка ничего не ставит в очередь: её можно исправить и
подтвердить заново. Просьба «отправь мой предыдущий ответ» не заменяет полного текста решения.

## 10. Включить автозапуск отдельного агента

Дождитесь завершения пробной заявки, затем остановите foreground через Ctrl-C.
Не держите foreground и сервис одновременно с одним ботом.
Блок создаёт отдельный LaunchAgent, не используя личные service files:

```sh
python3 - "$conference_root" <<'PY'
import pathlib
import plistlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
path = pathlib.Path.home() / "Library/LaunchAgents/com.ivanmagda.swift-claw-conference.plist"
path.parent.mkdir(parents=True, exist_ok=True)
settings = {
    "Label": "com.ivanmagda.swift-claw-conference",
    "ProgramArguments": [str(root / "bin/run-clawd.sh")],
    "WorkingDirectory": str(root),
    "RunAtLoad": True,
    "KeepAlive": {"SuccessfulExit": False},
    "ThrottleInterval": 10,
    "StandardOutPath": str(root / "logs/clawd.out.log"),
    "StandardErrorPath": str(root / "logs/clawd.err.log"),
}
with path.open("xb") as file:
    path.chmod(0o600)
    plistlib.dump(settings, file)
print(path)
PY

plutil -lint "$HOME/Library/LaunchAgents/com.ivanmagda.swift-claw-conference.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.ivanmagda.swift-claw-conference.plist"
launchctl print "gui/$(id -u)/com.ivanmagda.swift-claw-conference"
```

Проверьте `state = running` и снова спросите текущий кейс в группе. Логи:

```sh
tail -n 80 "$HOME/.swift-claw-conference/logs/clawd.err.log"
tail -n 80 "$HOME/.swift-claw-conference/logs/clawd.out.log"
```

LaunchAgent работает после входа этого пользователя в macOS. На мероприятии оставьте пользователя
залогиненным, Mac подключённым к питанию и без сна; для предотвращения idle sleep можно держать
в отдельном Terminal `caffeinate -i`.

Остановка **только конференционного агента**:

```sh
launchctl bootout "gui/$(id -u)/com.ivanmagda.swift-claw-conference"
```

Повторный запуск — та же команда `launchctl bootstrap` выше.
Не используйте `killall clawd` или личный service label `com.ivanmagda.swift-claw`.

## Ежедневная работа, новый кейс и обновление ветки

В новом Terminal восстановите переменные:

```sh
conference_source="$HOME/Developer/swift-claw-conference"
conference_root="$HOME/.swift-claw-conference"
conference_codex="$conference_root/tools/codex/node_modules/.bin/codex"
```

**Новый кейс.** Дождитесь завершения работ, остановите сервис, скопируйте JSON в новый файл,
измените `id`, вопрос и при необходимости репозиторий/ветку/SHA. В `clawd.env` укажите абсолютный
путь к новому `CLAW_CONFERENCE_CASE_FILE`, затем запустите сервис. Спросите бота о текущем кейсе.
Не переиспользуйте один `id` с другими условиями. Для нового дня можно создать отдельную
base-ветку в GitHub на выбранном коммите вместо `main`.

Queued-заявки сохраняют собственный снимок кейса: смена активного JSON их не переписывает.
Старую неподтверждённую карточку после смены кейса может потребоваться отправить заново.
Для статуса старой заявки укажите UUID в исходном топике.

**Обновление swift-claw.** После завершения работ получите изменения той же ветки и соберите binary:

```sh
cd "$conference_source"
git switch feature/conference-coding-challenge
git pull --ff-only origin feature/conference-coding-challenge
swift build -c release --product clawd
```

После успешной сборки остановите конференционный сервис, сохраните binary и установите новый:

```sh
launchctl bootout "gui/$(id -u)/com.ivanmagda.swift-claw-conference"
cp "$conference_root/bin/clawd" "$conference_root/bin/clawd.previous"
install -m 755 "$conference_source/.build/release/clawd" "$conference_root/bin/clawd"
git -C "$conference_source" rev-parse HEAD > "$conference_root/build-commit.txt"
"$conference_root/bin/run-clawd.sh" doctor --check-config
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.ivanmagda.swift-claw-conference.plist"
```

Мерж в `main` и обычный release updater не нужны. Checkout через `pull/199/head` обновляйте через
`git fetch origin pull/199/head` и `git merge --ff-only FETCH_HEAD` вместо переключения именованной ветки.
В новом Terminal перед сборкой также восстановите `DEVELOPER_DIR` из шага 1.
Повторите живой прогон с новым пробным `id`. Перед сменой версии делайте закрытую резервную копию
всего state root при остановленном сервисе: откат binary не откатывает миграции базы.

**Изменение Codex/Node.** После изменения путей повторите `coder setup` и перезапустите сервис.
LaunchAgent не читает `.zshrc` и настройки nvm: ему нужны сохранённые пути.
Изменение executable, PATH, profile или config home делает старые подтверждения недействительными.
Уже принятые заявки с другой execution policy переходят в `needs_review`, без нового запуска.
В v1 нет автоматического повторного подтверждения таких заявок.

## Если что-то не работает

| Симптом | Что проверить |
|---|---|
| Бот молчит | Процесс и логи; токен; числовой **ID группы**, а не топика; `CLAW_CONFERENCE_ENABLED=true`; обращение через `@username` или reply боту. Личка игнорируется. Пишите от пользователя, не канала/анонимного администратора. |
| Telegram conflict / 409 | Где-то ещё запущен тот же бот: другой компьютер, foreground, сервис или ручной `getUpdates`. Остановите лишний экземпляр именно этого бота. |
| Кнопка не подтверждает решение | Нажимает автор сообщения; он остаётся участником; бот — администратор; карточка не устарела. Чужое нажатие не должно закрывать её. |
| Новые сообщения ждут | Завершите ожидающее подтверждение в этом топике кнопкой своей карточки. Разговорная очередь топика общая. |
| `clawd is running for this state root` / exit 12 | Перед login или seal остановите конференционный сервис. Личный daemon не трогайте. |
| Invalid conference setting / case file invalid | Абсолютный путь к JSON, все поля, корректный `id`, полный SHA, существующая base-ветка. `doctor` не валидирует весь conference config. |
| GitHub credential belongs to … expected … | PAT принадлежит другому аккаунту. Исправьте токен или ожидаемый login, сохранив нужного автора публикации. |
| GitHub 401/403 или push/PR failure | Срок PAT, выбранный репозиторий, Contents/Pull requests Write, права аккаунта и одобрение организации. Проверка login не доказывает право публикации. |
| Base/baseline mismatch | Ветка должна оставаться на SHA из кейса. Создайте новый кейс с корректной baseline; не подменяйте условия принятых заявок. |
| Codex unavailable / missing flags | Выбран установленный CLI `0.154.0`; работают Node и его PATH; повторите `coder setup`. Не обходите отказ более широким режимом разрешений. |
| Codex not authenticated | Повторите шаг 8 с теми же HOME/CODEX_HOME. Личный `codex login` другую папку не авторизует. |
| Ошибка разговорной модели | Модель соответствует аккаунту/провайдеру; выполнен вход. Для ChatGPT повторите шаг 7 при остановленном сервисе. |
| Долго `queued` | Coder занят, недоступен или исходный Git временно недоступен; смотрите doctor и логи. При одном worker заявки ждут FIFO. |
| `running` после выполнения Codex | Возможна повторная попытка публикации после сетевой ошибки. Проверьте GitHub и логи; не создавайте второй PR вручную. |
| `needs_review`, `blocked`, `failed` | Сохраните причину, UUID и workspace для разбора. Не удаляйте строки SQLite ради повтора. Для нового независимого smoke используйте новый кейс. |

Для замены Telegram/API-токена остановите сервис, запишите новое значение в env, выполните
`secrets seal --env-file` через launcher и снова запустите сервис. Уже запечатанные значения
сохраняются при пустых env-строках. Для замены `GH_TOKEN` достаточно отредактировать env и
перезапустить: токен читает supervisor, а из окружения native Coder он удаляется.

Очередь хранится на диске. Прерванная или неоднозначно завершённая native-работа требует разбора
и не запускается заново автоматически. Временные сбои исходников сохраняют FIFO-позицию;
повторная публикация использует прежнюю ветку и ищет существующий draft PR.
Закрытый, смерженный, переведённый из draft или не соответствующий заявке PR не заменяется
автоматически. Сохраняйте workspace до окончания публикации/разбора.

Результат приходит ответом на исходное предложение в том же топике; длинная карточка может
состоять из нескольких сообщений. После потери сетевого подтверждения Telegram возможна
повторная доставка, хотя логическое уведомление в базе одно.

## Что проверить перед мероприятием

- Два реальных участника прошли путь до разных draft PR; авторство, baseline и доставка в топики верны.
- Проверены отмена, чужое нажатие, собственный статус и недоступность чужой заявки по UUID.
- Исходная ветка не меняется; текст участника сохранён в PR. Числовые Telegram ID не публикуются в PR.
- Собраны исходное приложение и хотя бы один результат; ПК понимает, какие проверки выполняются.
- Сервис работает после входа в macOS, компьютер не спит, авторизации доступны сервисному пользователю.
- Сохранены commit swift-claw, версия Codex, SHA кейса и ссылки на пробные PR; без секретов и приватных ID.
- На тестовом кейсе проверены очередь при занятом worker и восстановление после остановки.
- Безопасное предложение принимается; явный запрос вне кейса, например получить секреты хоста,
  отклоняется без очереди. Это проверка поведения фильтра, не доказательство его неуязвимости.

Режим не выставляет оценки, не мержит PR, не регистрирует участников и не гарантирует денежный лимит.
Проверка предложения моделью не является оценкой качества или песочницей.
Её запросы и native Codex расходуются отдельно от разговорного `/cost`; concurrency и timeout
не являются бюджетом. `/stop` останавливает разговорный ход, а не фоновую заявку;
`/new` меняет общую сессию топика, а не лимит заявок на кейс.

Нормативное поведение: [ARCHITECTURE.md §13.3](ARCHITECTURE.md#133-conference-coding-challenge).
Карта автоматизированных проверок: [conference acceptance notes](design/conference-coding-challenge.md).
