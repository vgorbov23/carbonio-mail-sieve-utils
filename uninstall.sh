#!/bin/bash
# mail-sieve 1.2: uninstall.sh
# Снимает Sieve-скрипт с доменов и удаляет cron/logrotate.
#
# Запуск от root:  ./uninstall.sh [--folders] [--purge] [-y]
#   --folders  дополнительно удалить папки, созданные скриптом, но ТОЛЬКО пустые
#              (папки с письмами и ранее существовавшие папки не трогаются)
#   --purge    удалить каталог /opt/mail-sieve целиком (настройки, логи, бэкапы)
#   -y         не спрашивать подтверждение
#
# По умолчанию делает минимум: снимает скрипт с доменов, убирает cron и logrotate.
# Настройки и папки в ящиках остаются.
set -euo pipefail

export PATH="/opt/zextras/bin:/opt/zextras/libexec:$PATH"
export LANG=C.UTF-8 LC_ALL=C.UTF-8

DIR=${MAIL_SIEVE_DIR:-/opt/mail-sieve}
STATE=$DIR/.folders_done
CREATED=$DIR/.folders_created
WANT_FOLDERS=0; PURGE=0; ASSUME_YES=0; INNER=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --folders) WANT_FOLDERS=1 ;;
    --purge)   PURGE=1 ;;
    -y)        ASSUME_YES=1 ;;
    --inner)   INNER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный параметр: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

DOMAINS=""
EXCLUDE_REGEX='^(galsync|spam\.|ham\.|virus-quarantine\.)'
if [ -r "$DIR/mail-sieve.conf" ]; then
  # shellcheck disable=SC1091
  source "$DIR/mail-sieve.conf"
fi

mb() {
  local o rc=0
  o=$(zmmailbox -z -m "$1" "${@:2}" 2>&1) || rc=$?
  grep -v ' main INFO ' <<<"$o" || true
  return "$rc"
}

# ------------------------------------------------ часть, выполняемая от zextras
inner() {
  local d raw acct f path line has k
  [ -n "$DOMAINS" ] || DOMAINS=$(carbonio prov gad)

  echo "== Снятие Sieve-скрипта с доменов =="
  for d in $DOMAINS; do
    raw=$(carbonio prov gd "$d" zimbraAdminSieveScriptAfter 2>&1) || { echo "ОШИБКА чтения $d" >&2; continue; }
    if grep -qF 'managed-by: mail-sieve' <<<"$raw"; then
      carbonio prov md "$d" zimbraAdminSieveScriptAfter '' && echo "снят: $d"
    elif grep -q '^zimbraAdminSieveScriptAfter:' <<<"$raw"; then
      echo "пропуск $d: на домене чужой скрипт (не наш), не трогаю"
    else
      echo "пропуск $d: скрипт не задан"
    fi
  done
  carbonio prov fc domain >/dev/null 2>&1 || true

  [ "$WANT_FOLDERS" = 1 ] || return 0

  echo "== Удаление пустых папок, созданных скриптом =="
  [ -s "$CREATED" ] || { echo "Список созданных папок пуст, удалять нечего."; return 0; }

  local -A cnt
  local -a deleted=()
  for acct in $(cut -d'|' -f1 "$CREATED" | sort -u); do
    cnt=()
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]+[a-z]+[[:space:]]+[0-9]+[[:space:]]+([0-9]+)[[:space:]]+(/.*)$ ]]; then
        cnt["${BASH_REMATCH[2]}"]=${BASH_REMATCH[1]}
      fi
    done < <(mb "$acct" getAllFolders || true)

    # глубокие папки первыми
    while IFS= read -r f; do
      path="/$f"
      if [ -z "${cnt[$path]+x}" ]; then continue; fi
      if [ "${cnt[$path]}" != 0 ]; then
        echo "пропуск $acct $path: в папке есть письма (${cnt[$path]})"; continue
      fi
      has=0
      for k in "${!cnt[@]}"; do
        if [[ "$k" == "$path/"* ]]; then has=1; break; fi
      done
      if [ "$has" = 1 ]; then echo "пропуск $acct $path: есть вложенные папки"; continue; fi
      if mb "$acct" deleteFolder "$path" >/dev/null; then
        echo "удалена: $acct $path"
        unset "cnt[$path]"
        deleted+=("$acct|$f")
      else
        echo "ОШИБКА удаления $acct $path" >&2
      fi
    done < <(awk -F'|' -v a="$acct" '$1==a {print $2}' "$CREATED" \
             | awk '{n=gsub("/","/"); print n "\t" $0}' | sort -t$'\t' -k1,1nr | cut -f2-)
  done

  if [ ${#deleted[@]} -gt 0 ]; then
    printf '%s\n' "${deleted[@]}" > "$DIR/.deleted.tmp"
    grep -vxFf "$DIR/.deleted.tmp" "$CREATED" > "$CREATED.new" || true
    mv "$CREATED.new" "$CREATED"
    if [ -f "$STATE" ]; then
      grep -vxFf "$DIR/.deleted.tmp" "$STATE" > "$STATE.new" || true
      mv "$STATE.new" "$STATE"
    fi
    rm -f "$DIR/.deleted.tmp"
  fi
}

if [ "$INNER" = 1 ]; then inner; exit 0; fi

# ------------------------------------------------ часть от root
if [ "$(id -u)" != 0 ]; then echo "Запустите от root." >&2; exit 1; fi

if [ "$ASSUME_YES" != 1 ]; then
  echo "Будет выполнено:"
  echo "  - снятие Sieve-скрипта mail-sieve с доменов (чужие скрипты не трогаются)"
  echo "  - удаление /etc/cron.d/mail-sieve и /etc/logrotate.d/mail-sieve"
  if [ "$WANT_FOLDERS" = 1 ]; then echo "  - удаление ПУСТЫХ папок, созданных скриптом"; fi
  if [ "$PURGE" = 1 ]; then echo "  - удаление каталога $DIR"; fi
  read -r -p "Продолжить? [y/N] " ans
  [[ "$ans" =~ ^[yY]$ ]] || { echo "Отменено."; exit 1; }
fi

args=(--inner)
if [ "$WANT_FOLDERS" = 1 ]; then args+=(--folders); fi
runuser -u zextras -- env MAIL_SIEVE_DIR="$DIR" bash "$(readlink -f "$0")" "${args[@]}"

rm -f /etc/cron.d/mail-sieve /etc/logrotate.d/mail-sieve
echo "cron и logrotate удалены"

if [ "$PURGE" = 1 ]; then
  rm -rf "$DIR"
  echo "Каталог $DIR удалён"
else
  echo "Каталог $DIR оставлен (настройки, логи). Удалить: ./uninstall.sh --purge"
fi
echo "Готово."
