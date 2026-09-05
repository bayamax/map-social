# marketing — App Store 素材（1.0.7〜）

## 構成
- `scripts/` 生成・アップロード用スクリプト（scratchpad から退避。パスは当時のまま＝要調整）
  - `shot.py` シミュレータで多言語スクショ撮影（`SHOT_DEV` で機種切替、`KEY=VAL` は `SIMCTL_CHILD_` 環境変数として渡る）
  - `rec.py` + `cut.py` App Preview 動画（起動→`SCREENSHOT_TOUR` で自動カメラ移動→録画→886x1920 に切り出し・クロスフェード連結）
  - `mk.py` / `e.py` / `ei.py` 枝豆色デザインのスクショ合成（iPhone 6.7" 1320x2868 ／ iPad 13" 2064x2752）
  - `meta_107.py` ストア文言（ja / en-US / ru）、`asc_107.py` バージョン作成＋文言＋スクショ差し替え、`asc_preview_107.py` 動画アップロード、`attach_b12.py` ビルド紐付け
  - `asc.py` App Store Connect API ラッパ（鍵は `~/.appstoreconnect/` から読む。リポジトリに鍵は入れない）
- `screenshots_1.0.7/` 提出済み最終画像（E1〜E6 iPhone、P1〜P2 iPad、strip_* は確認用の横並び）
- `preview_1.0.7/` App Preview 動画（ja/en/ru、24.7s、886x1920 H.264 + 無音AAC）
- `captures/` 合成元のシミュレータ撮影素材（git 管理外・ローカルのみ）

## 撮影用 DEBUG 環境変数（Release には含まれない）
`SCREENSHOT_CAMERA=lat,lon,distance[,pitch]`（`SCREENSHOT_CAMERA_DELAY` 秒後に適用）、`SCREENSHOT_VEHICLES=1`、
`SCREENSHOT_MOCK_AIRCRAFT=1`（ローカル表示のみモック・注視点の周りに撒く／世界モードは実データ）、`SCREENSHOT_MOCK_PRESENCE=1`、
`SCREENSHOT_OPENCAM=<webcam id>`、
`SCREENSHOT_TOUR="at,dur,lat,lon,distance,pitch[,heading];at,spin,dur,lat0,lon0,lat1,lon1,distance;at,cam,<id>;at,close"`

動画の撮り方（例・日本語）:
```
python3 rec.py ja 29 59 out.mov SCREENSHOT_CAMERA=22,105,12000000,0 SCREENSHOT_CAMERA_DELAY=1 SCREENSHOT_VEHICLES=1 \
  SCREENSHOT_MOCK_PRESENCE=1 SCREENSHOT_MOCK_AIRCRAFT=1 \
  "SCREENSHOT_TOUR=30,spin,9,22,105,24,128,12000000;41,5,35.549,139.784,5000,60,0;47,2,35.549,139.784,4500,62,0;59,4,34.6687,135.5013,1700,55,0;65,cam,dotonbori"
python3 cut.py out.mov preview_ja.mp4 "1-10,17-25,34-36.5,45-52"
```
