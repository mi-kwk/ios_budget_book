# iPhone家計簿アプリ

Notionの確定仕様に基づく、開発用の初期枠組みです。完成版ではありません。

## 開き方

Finderの「書類」→ `ios_budget_book` → `BudgetBook.xcodeproj` をダブルクリックします。
Xcodeで `BudgetBook` スキームとiPhoneシミュレータを選び、▶︎（Command + R）で実行します。
実機の場合は Signing & Capabilities で自分のTeamと固有のBundle Identifierを設定してください。

## 必要環境

- Xcode 26.3（今回ビルド確認した環境）
- iOS 17.0以降（仮の最低対応。製品仕様としては未確定）
- SwiftUI / Charts / Foundation。追加パッケージ・銀行API・広告SDKなし

## 構成

- `BudgetBook/App`：アプリ起動・状態管理・保存処理との接続
- `BudgetBook/Domain`：家計簿・取引・カテゴリ・タグ・入出金元、入力制約、集計
- `BudgetBook/Data`：Repositoryと暫定の端末内JSON保存
- `BudgetBook/Features`：ホーム・入出金・収支・入力・設定
- `Tests`：集計・入力制約の実行テスト
- `docs/implementation-status.md`：仕様との対応・仮決定・未実装項目

## 検証

```bash
bash Scripts/test-domain.sh
xcodebuild -project BudgetBook.xcodeproj -scheme BudgetBook -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

ローカル保存はApplication Support内の `BudgetBook/budget-v1.json` です。保存エラー時はUIの状態を確定せず、読込エラー時は空データで上書きせず編集を停止します。
これは暗号化バックアップ用ファイルではありません。現段階ではiCloud保存・復元機能は未実装です。

変更履歴はGitで管理し、GitHubの `mi-kwk/ios_budget_book` と連携します。
