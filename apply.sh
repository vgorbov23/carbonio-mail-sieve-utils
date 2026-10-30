#!/bin/bash
# mail-sieve 1.2: apply.sh
# Генерирует Sieve из whitelist.txt и rules.conf, создаёт папки в ящиках
# и загружает скрипт в zimbraAdminSieveScriptAfter на уровне доменов.
#
# Запуск от пользователя zextras:  ./apply.sh [--dry-run] [--no-folders]
#   --dry-run     только сгенерировать и показать Sieve, ничего не менять
#   --no-folders  не создавать папки в ящиках
# Переменные окружения: FORCE=1: перезаписать на домене чужой Sieve-скрипт.
set -euo pipefail

export PATH="/opt/zextras/bin:/opt/zextras/libexec:$PATH"
export LANG=C.UTF-8 LC_ALL=C.UTF-8

DIR=${MAIL_SIEVE_DIR:-/opt/mail-sieve}
OUT=$DIR/generated.sieve
STATE=$DIR/.folders_done        # acct|папка: «обработано», повторно не трогаем
CREATED=$DIR/.folders_created   # acct|папка: реально создано нами (для uninstall)
MARKER='# managed-by: mail-sieve'
FORCE=${FORCE:-0}
DRY_RUN=0
DO_FOLDERS=1

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=1 ;;
    --no-folders) DO_FOLDERS=0 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Неизвестный параметр: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

# --- Настройки по умолчанию (переопределяются в mail-sieve.conf) ---
NEWS_FOLDER="Рассылки"
EXTRA_FOLDERS=()
DOMAINS=""
EXCLUDE_REGEX='^(galsync|spam\.|ham\.|virus-quarantine\.)'
if [ -r "$DIR/mail-sieve.conf" ]; then
  # shellcheck disable=SC1091
  source "$DIR/mail-sieve.conf"
fi

for f in rules.conf whitelist.txt; do
  [ -r "$DIR/$f" ] || { echo "Нет файла $DIR/$f" >&2; exit 1; }
done

clean() { grep -vE '^[[:space:]]*(#|$)' "$1" || true; }
trim()  { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
q()     { local s="$1"; s="${s//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }   # экранирование для Sieve

FOLDERS=("$NEWS_FOLDER")
if [ ${#EXTRA_FOLDERS[@]} -gt 0 ]; then
  for _f in "${EXTRA_FOLDERS[@]}"; do
    _f=$(trim "$_f"); _f="${_f#/}"; _f="${_f%/}"
    if [ -n "$_f" ]; then FOLDERS+=("$_f"); fi
  done
fi

# ---------------------------------------------------------------- генерация
generate() {
  local type a b c f addrs doms line cond
  echo "$MARKER"
  echo "# Не редактируйте вручную: файл создаётся скриптом apply.sh"
  echo 'require ["fileinto"];'
  echo
  echo '# --- 1. Пользовательские правила (rules.conf) ---'
  while IFS=';' read -r type a b c; do
    type=$(trim "$type"); a=$(trim "${a:-}"); b=$(trim "${b:-}"); c=$(trim "${c:-}")
    f=""
    case "$type" in
      header-exists)
        f=$b; [ -n "$a" ] && [ -n "$f" ] || { echo "rules.conf: неполное правило: $type;$a;$b;$c" >&2; exit 1; }
        echo "if exists \"$(q "$a")\" { fileinto \"$(q "$f")\"; stop; }" ;;
      header-contains)
        f=$c; [ -n "$a" ] && [ -n "$b" ] && [ -n "$f" ] || { echo "rules.conf: неполное правило: $type;$a;$b;$c" >&2; exit 1; }
        echo "if header :contains \"$(q "$a")\" \"$(q "$b")\" { fileinto \"$(q "$f")\"; stop; }" ;;
      subject-contains)
        f=$b; [ -n "$a" ] && [ -n "$f" ] || { echo "rules.conf: неполное правило: $type;$a;$b;$c" >&2; exit 1; }
        echo "if header :contains \"subject\" \"$(q "$a")\" { fileinto \"$(q "$f")\"; stop; }" ;;
      from-domain)
        f=$b; [ -n "$a" ] && [ -n "$f" ] || { echo "rules.conf: неполное правило: $type;$a;$b;$c" >&2; exit 1; }
        echo "if address :domain :is \"from\" \"$(q "$a")\" { fileinto \"$(q "$f")\"; stop; }" ;;
      from-address)
        f=$b; [ -n "$a" ] && [ -n "$f" ] || { echo "rules.conf: неполное правило: $type;$a;$b;$c" >&2; exit 1; }
        echo "if address :is \"from\" \"$(q "$a")\" { fileinto \"$(q "$f")\"; stop; }" ;;
      *) echo "rules.conf: неизвестный тип правила: '$type'" >&2; exit 1 ;;
    esac
    FOLDERS+=("$f")
  done < <(clean "$DIR/rules.conf")

  echo
  echo '# --- 2. Белый список (остаётся во Входящих) ---'
  addrs=""; doms=""
  while IFS= read -r line; do
    line=$(trim "$line")
    [ -n "$line" ] || continue
    if [[ "$line" == @* ]]; then
      doms+="${doms:+, }\"$(q "${line#@}")\""
    else
      addrs+="${addrs:+, }\"$(q "$line")\""
    fi
  done < <(clean "$DIR/whitelist.txt")
  cond=""
  if [ -n "$addrs" ]; then cond="address :is \"from\" [$addrs]"; fi
  if [ -n "$doms" ]; then cond="${cond:+$cond, }address :domain :is \"from\" [$doms]"; fi
  if [ -n "$cond" ]; then echo "if anyof ($cond) { stop; }"; fi

  echo
  echo '# --- 3. Общие рассылки ---'
  cat <<EOF
if anyof (
    exists "List-Unsubscribe",
    exists "List-Id",
    header :contains "Precedence" ["bulk", "list", "junk"]
) {
    fileinto "$(q "$NEWS_FOLDER")";
}
EOF
}

generate > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "Сгенерировано: $OUT"

if [ "$DRY_RUN" = 1 ]; then
  echo "----- dry-run: ничего не изменено -----"
  cat "$OUT"
  exit 0
fi

# ---------------------------------------------------------------- проверки
if [ "${MAIL_SIEVE_ANY_USER:-0}" != 1 ] && [ "$(id -un)" != zextras ]; then
  echo "Запускайте от пользователя zextras (su - zextras)." >&2
  exit 1
fi

exec 9>"$DIR/.lock"
flock -n 9 || { echo "Уже выполняется другой экземпляр apply.sh"; exit 0; }

[ -n "$DOMAINS" ] || DOMAINS=$(carbonio prov gad)

# zmmailbox без шума log4j; код возврата сохраняется
mb() {
  local o rc=0
  o=$(zmmailbox -z -m "$1" "${@:2}" 2>&1) || rc=$?
  grep -v ' main INFO ' <<<"$o" || true
  return "$rc"
}

# Системные ящики (zimbraIsSystemAccount=TRUE) исключаются автоматически.
# EXCLUDE_REGEX из mail-sieve.conf работает как дополнительная страховка.
SYSTEM_ACCOUNTS=""
load_system_accounts() {
  local out
  if out=$(carbonio prov -l sa '(zimbraIsSystemAccount=TRUE)' 2>/dev/null); then
    SYSTEM_ACCOUNTS=$(grep -E '^[^[:space:]#]+@[^[:space:]]+$' <<<"$out" || true)
    echo "Системных ящиков исключено: $(grep -c . <<<"$SYSTEM_ACCOUNTS" || true)"
  else
    echo "ВНИМАНИЕ: не удалось получить системные ящики, используется только EXCLUDE_REGEX" >&2
  fi
}

accounts() {
  local d
  for d in $DOMAINS; do carbonio prov -l gaa "$d"; done \
    | { grep -vE "$EXCLUDE_REGEX" || true; } \
    | { if [ -n "$SYSTEM_ACCOUNTS" ]; then grep -vxFf <(printf '%s\n' "$SYSTEM_ACCOUNTS") || true; else cat; fi; }
}

# ---------------------------------------------------------------- папки
ensure_folders() {
  local acct f p path out line listing ok
  local -a need parts UNIQ
  local -A have
  mapfile -t UNIQ < <(printf '%s\n' "${FOLDERS[@]}" | sort -u)
  touch "$STATE" "$CREATED"

  for acct in $(accounts); do
    need=()
    for f in "${UNIQ[@]}"; do
      if ! grep -qxF "$acct|$f" "$STATE"; then need+=("$f"); fi
    done
    [ ${#need[@]} -gt 0 ] || continue

    if ! listing=$(mb "$acct" getAllFolders); then
      echo "ОШИБКА $acct: не удалось получить список папок: $listing" >&2
      continue
    fi
    have=()
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]+[a-z]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+(/.*)$ ]]; then
        have["${BASH_REMATCH[1]}"]=1
      fi
    done <<<"$listing"

    for f in "${need[@]}"; do
      path=""; ok=1
      IFS='/' read -ra parts <<<"$f"
      for p in "${parts[@]}"; do
        path="$path/$p"
        if [ -n "${have[$path]+x}" ]; then continue; fi
        # -V message обязателен: без него папка получает тип unknown и не видна в почте
        if out=$(mb "$acct" createFolder -V message "$path"); then
          have["$path"]=1
          echo "${acct}|${path#/}" >> "$CREATED"
          echo "создана: $acct $path"
        elif grep -qiE 'already.?exists' <<<"$out"; then
          have["$path"]=1
        else
          echo "ОШИБКА $acct $path: $out" >&2
          ok=0; break
        fi
      done
      if [ "$ok" = 1 ]; then echo "$acct|$f" >> "$STATE"; fi
    done
  done
}

if [ "$DO_FOLDERS" = 1 ]; then load_system_accounts; ensure_folders; fi

# ---------------------------------------------------------------- загрузка на домены
rc=0
mkdir -p "$DIR/backup"
for d in $DOMAINS; do
  if ! raw=$(carbonio prov gd "$d" zimbraAdminSieveScriptAfter 2>&1); then
    echo "ОШИБКА чтения домена $d: $raw" >&2; rc=1; continue
  fi
  if grep -q '^zimbraAdminSieveScriptAfter:' <<<"$raw" && ! grep -qF 'managed-by: mail-sieve' <<<"$raw"; then
    printf '%s\n' "$raw" > "$DIR/backup/$d.sieve"
    if [ "$FORCE" != 1 ]; then
      echo "ПРОПУСК $d: на домене уже задан чужой Sieve-скрипт (копия: $DIR/backup/$d.sieve). FORCE=1 ./apply.sh чтобы перезаписать." >&2
      rc=1; continue
    fi
    echo "ВНИМАНИЕ $d: чужой скрипт перезаписан, копия: $DIR/backup/$d.sieve"
  fi
  if carbonio prov md "$d" zimbraAdminSieveScriptAfter "$(cat "$OUT")"; then
    echo "OK $d"
  else
    echo "ОШИБКА записи на домен $d" >&2; rc=1
  fi
done
carbonio prov fc domain >/dev/null 2>&1 || true

echo "Готово: $(wc -w <<<"$DOMAINS") дом., правил: $(clean "$DIR/rules.conf" | wc -l)"
exit "$rc"
