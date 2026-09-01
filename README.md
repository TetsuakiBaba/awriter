# AWriter

プロモーション用のミニマムな macOS テキストエディタ。機能よりも「書き心地と文字組みの美しさ」を優先した設計。

## 構成

- **書類ベースではない単一ウィンドウアプリ**。起動するといきなりエディタ画面が出る。ファイルの読み書き・保存確認・「編集済み」表示は一切なく、本文は `UserDefaults` に自動保存されて次回起動時に復元される
  - タイトルバーの名前は台本エディタの「ウィンドウ名」欄で自由に決める。既定は空でタイトルなし — [EditorView.swift](AWriter/EditorView.swift) の `EditorWindowTitle`
- 編集面のみ AppKit の `NSTextView`(TextKit 2)をラップ — [EditorTextView.swift](AWriter/EditorTextView.swift)
  - 行送り 1.7 倍、段落後アキ 0.4em
  - 本文カラムはウィンドウ幅に関わらず最大 720pt でウィンドウ中央に配置
  - ライトでは暖かい紙色、ダークでは焦げ茶がかった黒の背景(`NSColor.paper`)
- 設定はツールバーの「Aa」ポップオーバーに集約 — [TypographyPanel.swift](AWriter/TypographyPanel.swift)
  - **フォントセット**: macOS 同梱の日本語フォント(ヒラギノ明朝 / 凸版文久明朝 / 游明朝体 / ヒラギノ角ゴ / 凸版文久ゴ / ヒラギノ丸ゴ / 筑紫A丸ゴ / クレー / システム / New York)から実行環境に存在するものだけを表示 — [FontOption.swift](AWriter/FontOption.swift)
  - **文字サイズ**: 12–36pt スライダー
  - **文字色**: 和色スウォッチ(墨・煤竹・紺青・海老茶・千歳緑・胡粉)+「自動」(ライト/ダーク追従)+カスタムカラーピッカー — [TextInk.swift](AWriter/TextInk.swift)
  - **外観**: システム / ライト / ダーク。撮影中にシステム設定の切り替わりで地の色が変わらないよう、アプリ側で固定できる — [AppearanceMode.swift](AWriter/AppearanceMode.swift)。文字色を「自動」以外にしている場合は、地の明暗に合う外観を選ぶこと(暗い地に墨色を置くと読めなくなる)
  - 設定は `UserDefaults`(`@AppStorage`)に保存される
- 文字数カウンタを右下に控えめに表示

## デモ再生(撮影用キー入力の自動再生)

プロモーション撮影用に、台本化したキー入力列を再生する機能を「デモ」メニューに内蔵している。アプリが自分自身のイベントキューに CGEvent 裏付きの合成キーイベントを送るため、**本物の日本語 IME がかな合成・変換・候補表示・確定を行う**。アクセシビリティ権限は不要、サンドボックスもそのまま。

台本エディタは**アプリ起動時に一緒に開く**(閉じた場合は **デモ > 台本エディタ…** / ⌥⌘P、またはウィンドウメニューから) — [ScriptEditorView.swift](AWriter/ScriptEditorView.swift)。

- **再生**: エディタウィンドウを前面に出して再生
- **消去して再生**: エディタの本文を空にしてから再生する再撮り用。消去は ⌘Z で元に戻せる
- **停止**: **ESC**、再生中に出る赤バナーと HUD の停止ボタン、**デモ > 停止**(⌥⌘.)。中断すると未確定の変換中テキストは破棄される
- **ウィンドウ名**: エディタウィンドウのタイトルバーに出す名前。空ならタイトルなし

### 台本のタブ

台本は**アプリ内に自動保存**され、タブで複数のパターンを持てる — [ScriptLibrary.swift](AWriter/ScriptLibrary.swift)。

- `+` で追加、ダブルクリックまたは右クリック > 名前を変更でリネーム、`×` で削除、右クリック > 複製
- ファイル操作は保存ではなく受け渡し用: **インポート…** は `.keys` を新しいタブとして読み込み、**エクスポート…** は現在のタブを `.keys` に書き出す

### 台本フォーマット(.keys)

```
#lead 3          … 再生開始までの秒数
#interval 100    … 基本キー間隔 ms
#jitter 0.35     … 間隔のゆらぎ率(人間らしいリズム)
#speed 1.0       … 全体速度倍率

{kana}{wait 0.5}
yamamichiwonoborinagara,koukangaeta.{space}{enter}
```

- 通常文字は 1 打鍵ずつ送信。ローマ字→かな→変換は本物の IME が行う
- トークン: `{enter}` `{space}` `{tab}` `{esc}` `{bs}` `{up}` `{down}` `{left}` `{right}`、`{kana}` `{eisu}`(かな/英数キー)、`{wait 秒}`、`{cmd+n}` などの修飾キー組み合わせ
- 台本内の生改行はキーを送らない(改行は `{enter}` で明示)
- 変換候補の選択もキーとして台本に書く(スペース連打・`{down}`・数字キーなど)

### 再生中の表示

再生中であることが一目で分かるよう、次の表示が出る:

- **フローティング HUD**(常に最前面): 点滅する赤い点、開始前のカウントダウン、進捗、停止ボタン。書類ウィンドウが前面でも見える。キーフォーカスを奪わない非アクティブ化パネルなので、これを操作しても IME の変換は壊れない。ドラッグで移動でき、位置は記憶される。撮影に映り込む場合は台本エディタのチェックボックスでオフにできる — [PlaybackHUD.swift](AWriter/PlaybackHUD.swift)
- **台本エディタ**: 赤いバナー(カウントダウン・進捗・停止)、ウィンドウ全体の赤枠、再生/開く/保存とトークンボタンの無効化、本文の編集ロック

### 撮影時の注意

- 変換結果は **IME の学習状態に依存**する。撮影前に必ず 1 回リハーサル再生し、意図と違う変換は候補選択キーを台本に足すか、一度手で正しく変換して IME に学習させる
- ライブ変換の有無で挙動が変わる。台本はライブ変換オフを想定して書くのが安定
- 再生中はキーボードに触れない(ESC のみ停止として機能)
- **再生中は AWriter を前面のままにする**。他のアプリにフォーカスが移ると変換中のテキストは破棄され、以降のキーも届かない

## 開発中に動かす

Xcode 26 で `AWriter.xcodeproj` を開いて ⌘R。

## リリース(GitHub Releases 配布)

配布は Mac App Store ではなく GitHub Releases。Developer ID で署名し Apple の公証を通すので、利用者は普通にダブルクリックで開ける(右クリック > 開く のような回避操作は不要)。

```sh
./scripts/release.sh                 # ビルド → 署名 → 公証 → DMG
./scripts/release.sh --skip-notarize # 公証を飛ばす(手元確認用)
./scripts/release.sh --publish       # 公証済み DMG を GitHub Releases へ
```

`dist/AWriter-<バージョン>.dmg` ができる。arm64 + x86_64 のユニバーサルバイナリなので Intel Mac でも動く。

### 公証の初回設定

App 用パスワードを [appleid.apple.com](https://appleid.apple.com) で発行し、一度だけキーチェーンに登録する:

```sh
xcrun notarytool store-credentials "AWriter" \
  --apple-id <Apple ID> --team-id ZE8M4T49DP --password <App 用パスワード>
```

### バージョンを上げる

`AWriter.xcodeproj` の `MARKETING_VERSION`(現在 `1.0`)を変更する。DMG 名と `gh release` のタグはここから自動で決まる。

### 仕組み上の注意

- 配布ビルドでは `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` にしている。これを外すとデバッグ用の `get-task-allow` が入り、**公証が却下される**
- App Sandbox と Hardened Runtime は有効のまま(App Store 配布ではなくなったが、外す理由もないので維持)

## 残作業

- [ ] デモ再生機能を配布版に含めるか決める(撮影用の内部機能。残すとメニューが一般利用者にも見える)
- [ ] アプリアイコンの差し替え(現在は自動生成のプレースホルダ。macOS 26 スタイルにするなら Icon Composer 推奨)
