# iCloudバックアップの接続設定

コードと画面は実装済みですが、Apple側の接続設定と実通信の検証は未完了です。既定の `BUDGET_CLOUD_ENABLED = NO` ではCloudKitを初期化せず、設定不足の案内を表示します。

## Xcodeでの設定

1. `BudgetBook.xcodeproj` を開き、BudgetBookターゲットのSigning & Capabilitiesで利用するTeamと固有のBundle Identifierを設定する。
2. ＋ CapabilityからiCloudを追加し、CloudKitを有効にする。自分のTeamで利用可能なコンテナを作成・選択する。Apple側でiCloudを利用できる開発アカウントとプロビジョニングが必要。
3. Xcodeが生成するentitlementsのコンテナIDと、`BudgetBook/BackupInfo.plist` の `BudgetCloudContainer` を一致させる。`Config/CloudKit.entitlements.example` は内容確認用で、ビルドには組み込まれていない。Xcodeで生成した実ファイルがCode Signing Entitlementsに設定されていることを確認する。
4. CloudKit Consoleで対象コンテナのDevelopment環境にレコード型 `BudgetBackup` を作る。フィールドは `backupDate`（Date/Time）と `payload`（Asset）。全件取得に必要な `recordName` のQueryableインデックスを用意する。Private Databaseを利用し、公開データベースには保存しない。
5. ターゲットのBuild Settingsで `BUDGET_CLOUD_ENABLED` を `YES` にする。Debugでまず検証する。署名・コンテナを用意せずこのフラグだけを有効化しない。
6. iCloudへサインインした検証用iPhoneへ実行する。設定→バックアップ・復元でiCloud用パスワードを確認入力し、手動保存→一覧更新→復号プレビューを確認する。
7. 配布前にスキーマをProductionへデプロイし、配布用署名・実機でも検証する。CloudKitのDevelopment/Productionデータは別環境。

## 利用上の動作

- 8文字以上のiCloud用パスワードを端末のKeychainへ保存する。端末ロック解除中のみ取得でき、他端末には同期しない。忘れるとバックアップを復号できないため、安全な場所で管理する。
- ファイル書き出しのパスワードは毎回指定し、保存しない。iCloud用パスワードとは別に管理できる。
- iCloudパスワードを変更しても以前の世代は再暗号化しない。以前の世代には当時のパスワードが必要。
- 自動保存はアプリが前面にある間、変更があり当日まだ成功していない場合に実行。前面で毎分と変更後に条件を確認する。バックグラウンドでの毎日定時実行ではない。
- 最新3件を保持する。サーバー保存後に整理できなければ警告して多めに残す。次の成功時に再整理する。一覧のサーバー反映に遅延がある場合も削除を控える。
- CloudKitには作成日時と暗号化Assetを保存する。家計簿名・件数・金額などは暗号化本文内。バックアップ日時自体はCloudKitのメタデータとして見える。
- 復元は全置換。復元前の状態を端末内へ7日間退避する。復元・戻す直後は自動保存を一時停止するため、確認後にスイッチを再度有効化する。
- iCloudアカウント変更時は自動保存を停止する。新しいアカウントで保存する場合はパスワード設定をやり直す。

## 検証チェック

テスト用データで手動保存・3世代整理・新端末での復号復元・戻す・自動保存・オフライン復帰・容量不足・アカウント切替を確認する。現在はテスト用Transportでのロジック検証とシミュレータ向けビルドまでであり、実iCloud通信を確認したものではない。
