#!/usr/bin/env bash
#
# Постоянная подпись для локальных сборок агента. Запускать на маке один раз.
#
# Зачем: при ad-hoc подписи требование подписи — хеш бинарника, и после каждой
# пересборки macOS считает агент новой программой: слетают «Device Control and
# Data Access» (Accessibility), Bluetooth и доступ к Keychain. С постоянным
# сертификатом требование — идентификатор бандла + сертификат, и разрешения
# переживают пересборки.
#
# Сертификат самоподписанный, лежит в ОТДЕЛЬНОЙ связке ключей
# ~/.cache/sweep-signing.keychain-db, которая не входит в список поиска и не
# трогает login.keychain. Пароль от неё — в ~/.cache/sweep-signing.pass (600):
# это не секрет пользователя, а ключ к локальной подписи, им build.sh отпирает
# связку по ssh, где login.keychain заперт.

set -euo pipefail

NAME="Sweep Agent Local Signing"
KEYCHAIN="$HOME/.cache/sweep-signing.keychain-db"
PASSFILE="$HOME/.cache/sweep-signing.pass"

if [[ -f "$KEYCHAIN" ]]; then
  echo "уже есть: $KEYCHAIN" >&2
  exit 0
fi

mkdir -p "$HOME/.cache"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

umask 077
openssl rand -hex 24 > "$PASSFILE"
pass=$(cat "$PASSFILE")

cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
  -passout "pass:$pass" -out "$work/identity.p12"

security create-keychain -p "$pass" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # без автоблокировки по таймеру
security unlock-keychain -p "$pass" "$KEYCHAIN"
security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
# Разрешить codesign пользоваться ключом без диалога.
security set-key-partition-list -S apple-tool:,apple: -s -k "$pass" "$KEYCHAIN" >/dev/null

echo "готово: «${NAME}» в ${KEYCHAIN}"
