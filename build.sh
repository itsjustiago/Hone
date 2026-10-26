#!/bin/bash
# Compila, assina (com identidade estável) e instala o Hone em /Applications.
# A assinatura estável faz a permissão de Acessibilidade / Gravação de Ecrã colar
# de vez, em vez de se perder a cada recompilação (como acontece com ad-hoc).
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Hone Self Signed"
KEYCHAIN="$HOME/Library/Keychains/hone-signing.keychain-db"
CONFIG="${1:-release}"

# Garante o certificado estável.
if ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "▸ Certificado em falta — a criar…"
  ./setup-signing.sh
fi

echo "▸ A compilar ($CONFIG)…"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Hone"
# Adaptador de «a tocar agora»: dylib que o /usr/bin/perl carrega (o Hone não a liga).
NOWPLAYING="$BIN_DIR/libHoneNowPlaying.dylib"
# Sempre, não só quando falta: uma dylib de um build anterior ficava no .app mesmo
# com o adaptador alterado. É incremental, por isso custa pouco quando nada mudou.
swift build -c "$CONFIG" --product HoneNowPlaying

APP="Hone.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Hone"
# Vai para Frameworks/ antes de assinar: o `codesign --deep` assina-a com o resto.
cp "$NOWPLAYING" "$APP/Contents/Frameworks/libHoneNowPlaying.dylib"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "Hone.icns" ] && cp "Hone.icns" "$APP/Contents/Resources/Hone.icns"

sign() {
  security unlock-keychain -p "hone-signing" "$KEYCHAIN" 2>/dev/null || true
  codesign --force --deep --sign "$IDENTITY" --keychain "$KEYCHAIN" "$1"
}

echo "▸ A assinar com '$IDENTITY'…"
sign "$APP"

# Instalar em /Applications (path estável) e reiniciar.
DEST="/Applications/Hone.app"
# Relançamento, não saída: as ferramentas embebidas (ex.: o Sleepy ligado)
# mantêm o estado para o arranque seguinte. O Hone limpa a flag ao arrancar.
defaults write com.tiagof.hone relaunchingForUpdate -bool true
# Pede ao Hone que saia como pelo menu (pelo bundle id, nunca pelo nome: matar
# processos por nome já fechou outras apps do Tiago) e espera que saia mesmo.
swift quit-hone.swift || echo "⚠ O Hone não saiu a tempo; a instalação continua."
if rm -rf "$DEST" 2>/dev/null && cp -R "$APP" "$DEST" 2>/dev/null; then
  sign "$DEST"
  # Remove o staging da pasta do projeto: duas .app com o mesmo bundle-id no
  # disco confundem o Launch Services / TCC sobre qual está autorizada.
  rm -rf "$APP"
  open "$DEST"
  echo "✓ Instalado, assinado e reiniciado: $DEST"
else
  # O Hone já foi fechado: volta a abri-lo a partir do staging, senão um Sleepy
  # ligado ficava com o pmset armado e nenhum Hone a correr.
  open "$APP"
  echo "⚠ Não deu para instalar em /Applications — o Hone ficou a correr a partir de $PWD/$APP."
  echo "✓ Pronto: $APP  (copia para /Applications manualmente)"
  DEST="$APP"
fi

echo "  Requisito de assinatura:"
codesign -d --requirements - "$DEST" 2>&1 | grep -i designated | sed 's/^/    /'
