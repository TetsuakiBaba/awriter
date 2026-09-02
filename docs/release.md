# リリース手順(GitHub Actions)

タグを push すると [.github/workflows/release.yml](../.github/workflows/release.yml) が
macOS ランナー上で **ユニバーサルビルド → Developer ID 署名 → Apple 公証 → DMG 作成 →
GitHub Releases 公開** まで自動で行う。手元の [scripts/release.sh](../scripts/release.sh) は
ローカル確認用としてそのまま残してある。

バージョン番号はタグから注入される(`MARKETING_VERSION`)ため、
リリースのたびに `project.pbxproj` を編集する必要はない。

---

## 1. 一度だけの準備

### 1-1. Developer ID Application 証明書を .p12 で書き出す

CI には秘密鍵ごと渡す必要がある。

1. 「キーチェーンアクセス」.app を開く
2. 左で **ログイン > 自分の証明書** を選ぶ
3. `Developer ID Application: TETSUAKI BABA (ZE8M4T49DP)` を右クリック → **書き出す…**
4. フォーマット **個人情報交換(.p12)** で保存(例 `~/Desktop/awriter-devid.p12`)
5. 書き出し用パスワードを設定する(あとで secret に登録するので控えておく)

書き出した .p12 に鍵が入っているかの確認:

```bash
openssl pkcs12 -in ~/Desktop/awriter-devid.p12 -nodes -passin pass:<書き出しパスワード> | grep -c "PRIVATE KEY"
# → 1 以上ならOK
```

base64 にしてクリップボードへ:

```bash
base64 -i ~/Desktop/awriter-devid.p12 | pbcopy
```

### 1-2. 公証用の App 用パスワードを用意する

<https://appleid.apple.com> → サインインとセキュリティ → App 用パスワード で発行。
ローカルで `notarytool store-credentials` に使ったものがあれば同じものでよい。

---

## 2. GitHub Secrets を登録する

リポジトリの **Settings > Secrets and variables > Actions > New repository secret**、
または `gh` で:

```bash
# 証明書(base64)
base64 -i ~/Desktop/awriter-devid.p12 | gh secret set MACOS_CERTIFICATE_P12

# .p12 書き出し時に設定したパスワード
gh secret set MACOS_CERTIFICATE_PASSWORD

# 公証に使う Apple ID(メールアドレス)
gh secret set AC_APPLE_ID

# 上で発行した App 用パスワード(xxxx-xxxx-xxxx-xxxx)
gh secret set AC_APP_PASSWORD
```

| Secret | 中身 |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application 証明書 + 秘密鍵の .p12 を base64 化したもの |
| `MACOS_CERTIFICATE_PASSWORD` | .p12 書き出し時のパスワード |
| `AC_APPLE_ID` | 公証に使う Apple ID |
| `AC_APP_PASSWORD` | Apple ID の App 用パスワード |

チーム ID (`ZE8M4T49DP`) と署名 ID 名はワークフローの `env` に直書きしてある(秘密ではない)。

登録できたら .p12 は消しておく:

```bash
rm ~/Desktop/awriter-devid.p12
```

---

## 3. リリースする

```bash
git tag v1.0.1
git push origin v1.0.1
```

Actions タブでジョブを追う。公証待ちを含めて 10〜20 分ほど。
完了すると `AWriter-1.0.1.dmg` が付いた Release が作られる。

### 公開せずに試す

**Actions > Release > Run workflow** からバージョン番号を入れて実行すると、
Release は作らずビルド〜公証〜Gatekeeper 判定まで通し、DMG を
ワークフローの成果物(Artifacts)として置く。secrets の設定確認はこれで行う。

---

## つまずきやすいところ

- **`security find-identity` に何も出ない** — .p12 に秘密鍵が入っていない。
  証明書ではなく「自分の証明書」カテゴリから書き出したか確認する。
- **公証が `Invalid` で返る** — ジョブログの submission ID を控えて
  `xcrun notarytool log <id> --apple-id ... --team-id ZE8M4T49DP --password ...` で理由を見る。
  Hardened Runtime とタイムスタンプはワークフロー側で有効にしてある。
- **`spctl` が rejected** — 公証チケットの staple 前に判定している場合など。
  ジョブは公証 → staple → 判定の順に並べてある。
