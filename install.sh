#!/bin/bash
# mail-sieve 1.2: install.sh
# Устанавливает скрипты в /opt/mail-sieve, cron и logrotate.
# Существующие whitelist.txt, rules.conf и mail-sieve.conf НЕ перезаписываются,
# поэтому этот же скрипт используется и для обновления.
#
# Запуск от root:  ./install.sh [--no-cron]
set -euo pipefail

DIR=/opt/mail-sieve
SRC=$(cd "$(dirname "$0")" && pwd)
WITH_CRON=1

for arg in "$@"; do
  case "$arg" in
    --no-cron) WITH_CRON=0 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный параметр: $arg" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != 0 ]; then echo "Запустите от root." >&2; exit 1; fi
id zextras >/dev/null 2>&1 || { echo "Пользователь zextras не найден: это не сервер Carbonio?" >&2; exit 1; }
command -v flock >/dev/null || { echo "Нужна утилита flock (пакет util-linux)." >&2; exit 1; }
command -v runuser >/dev/null || { echo "Нужна утилита runuser (пакет util-linux)." >&2; exit 1; }

install -d -o zextras -g zextras -m 750 "$DIR"
install -o zextras -g zextras -m 750 "$SRC/apply.sh" "$SRC/uninstall.sh" "$DIR/"
install -o zextras -g zextras -m 640 "$SRC/README.md" "$DIR/README.md"

for f in whitelist.txt rules.conf mail-sieve.conf; do
  if [ -e "$DIR/$f" ]; then
    echo "оставлен существующий: $DIR/$f"
  else
    install -o zextras -g zextras -m 640 "$SRC/$f" "$DIR/$f"
    echo "установлен: $DIR/$f"
  fi
done

if [ "$WITH_CRON" = 1 ]; then
  cat > /etc/cron.d/mail-sieve <<'EOF'
# mail-sieve: раз в сутки создаёт папки новым ящикам и применяет правила
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/zextras/bin
LANG=C.UTF-8
15 3 * * * zextras /opt/mail-sieve/apply.sh >> /opt/mail-sieve/apply.log 2>&1
EOF
  chmod 644 /etc/cron.d/mail-sieve
  cat > /etc/logrotate.d/mail-sieve <<'EOF'
/opt/mail-sieve/apply.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
    create 640 zextras zextras
}
EOF
  echo "установлены: /etc/cron.d/mail-sieve, /etc/logrotate.d/mail-sieve"
fi

cat <<EOF

Установка завершена. Дальше:
  1. Отредактируйте $DIR/rules.conf и $DIR/whitelist.txt
  2. su - zextras
  3. cd $DIR && ./apply.sh --dry-run     # посмотреть Sieve
  4. ./apply.sh                          # применить
Подробности: $DIR/README.md
EOF
