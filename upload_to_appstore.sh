#!/bin/bash
#
# MapSNS — App Store Connect 自動アップロード
# ビルド番号を+1 → アーカイブ → エクスポート → API キーでアップロード
# 完了後、App Store Connect 側の処理（数分）でビルドが表示されます。
#
# 事前準備（初回のみ）:
#   1. App Store Connect > Users and Access > Integrations > App Store Connect API でキー発行
#      （Role は「App Manager」推奨）
#   2. AuthKey_<KEYID>.p8 を ~/.appstoreconnect/private_keys/ に配置
#   3. ~/.appstoreconnect/credentials.template を credentials にコピーし KEY_ID / ISSUER_ID を記入
#
# 使い方:  ./upload_to_appstore.sh

set -euo pipefail

PROJECT_DIR="$HOME/Desktop/test/MapSNS"
PROJECT="MapSNS.xcodeproj"
SCHEME="MapSNS"
PBXPROJ="$PROJECT_DIR/$PROJECT/project.pbxproj"
EXPORT_OPTS="$PROJECT_DIR/exportOptions.plist"
CRED_FILE="$HOME/.appstoreconnect/credentials"
KEY_DIR="$HOME/.appstoreconnect/private_keys"

cd "$PROJECT_DIR"

echo "==> 認証情報を確認"
if [ -f "$CRED_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
fi
: "${ASC_KEY_ID:?ASC_KEY_ID が未設定です（$CRED_FILE に記入、または環境変数で指定）}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID が未設定です}"
KEY_FILE="$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
if [ ! -f "$KEY_FILE" ]; then
  echo "ERROR: APIキーが見つかりません: $KEY_FILE"
  exit 1
fi
echo "    KEY_ID=$ASC_KEY_ID / キーファイルOK"

echo "==> ビルド番号を更新"
CUR=$(grep -m1 'CURRENT_PROJECT_VERSION =' "$PBXPROJ" | sed -E 's/.*= ([0-9]+);.*/\1/')
NEW=$((CUR + 1))
echo "    CURRENT_PROJECT_VERSION: $CUR -> $NEW"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEW;/g" "$PBXPROJ"

ARCHIVE="$PROJECT_DIR/build/MapSNS_b${NEW}.xcarchive"
EXPORT_DIR="$PROJECT_DIR/build/export_b${NEW}"

echo "==> アーカイブ作成 (build $NEW)"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  | tail -3

echo "==> IPA エクスポート"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates \
  | tail -3

IPA="$(/bin/ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1)"
[ -n "$IPA" ] || { echo "ERROR: IPA が生成されませんでした"; exit 1; }
echo "    IPA: $IPA"

echo "==> App Store Connect へアップロード"
xcrun altool --upload-app \
  -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo ""
echo "✅ アップロード送信完了（build ${NEW}）。"
echo "   App Store Connect 側の処理（数分〜十数分）が終わると、"
echo "   TestFlight / 配信用ビルド一覧に build ${NEW} が表示されます。"
echo "   表示されたら、審査対象バージョンでそのビルドを選んで提出してください。"
