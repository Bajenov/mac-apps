#!/bin/sh
# Установка «Снимка» или «Пульса» одной строкой:
#   curl -fsSL https://raw.githubusercontent.com/Bajenov/mac-apps/main/install.sh | sh -s snimok
#   curl -fsSL https://raw.githubusercontent.com/Bajenov/mac-apps/main/install.sh | sh -s pulse
set -e

case "$1" in
  snimok|Snimok|снимок) NAME="Snimok"; TITLE="Снимок"; MIN=15 ;;
  pulse|Pulse|пульс)    NAME="Pulse";  TITLE="Пульс";  MIN=14 ;;
  *) echo "Укажите программу: sh -s snimok  или  sh -s pulse"; exit 1 ;;
esac

DEST="${DEST:-/Applications}"
URL="https://github.com/Bajenov/mac-apps/releases/latest/download/$NAME.zip"

if [ "$(uname -m)" != "arm64" ]; then
  echo "«$TITLE» работает только на Mac с процессором Apple (M1 и новее)."; exit 1
fi
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt "$MIN" ]; then
  echo "Для «$TITLE» нужна macOS $MIN или новее, а у вас $(sw_vers -productVersion)."; exit 1
fi

echo "Скачиваю «$TITLE»…"
TMP=$(mktemp -d)
curl -fsSL "$URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"

# Закрываем запущенную копию, старую версию — в Корзину (не стираем насовсем).
pkill -x "$( [ "$NAME" = Pulse ] && echo MacPulse || echo Snimok )" 2>/dev/null || true
if [ -d "$DEST/$NAME.app" ]; then
  mv "$DEST/$NAME.app" "$HOME/.Trash/$NAME-старая-$(date +%Y%m%d-%H%M%S).app"
fi

ditto "$TMP/$NAME.app" "$DEST/$NAME.app"
xattr -dr com.apple.quarantine "$DEST/$NAME.app" 2>/dev/null || true
open "$DEST/$NAME.app"

echo "Готово: «$TITLE» в папке «Программы», значок — в строке меню справа сверху."
if [ "$NAME" = Snimok ]; then
  echo "Первый раз при ⌘⇧A: Системные настройки → Конфиденциальность и безопасность →"
  echo "«Запись экрана и системного звука» → включите «Снимок» и перезапустите его."
fi
