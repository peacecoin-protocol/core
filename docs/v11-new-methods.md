# PCECommunityTokenV11 / PCETokenV11 新規メソッド仕様

## 概要

V11では、コミュニティトークン → PCEトークンへの日次回収（swap）に対して**累計量のトラッキング**を導入しました。これにより、UIから「あとどれだけ回収できるか」をリアルタイムに取得できます。

---

## 新規 View メソッド（PCECommunityTokenV11）

### `getRemainingSwapableToPCEBalance()`

**本日のグローバル残り回収可能量**を返します。

| 項目 | 内容 |
|------|------|
| 戻り値 | `uint256` — 本日あとどれだけ（display単位）全体として回収可能か |
| ガス | view（無料） |
| 呼び出し元制限 | なし（誰でも読める） |

**計算ロジック:**
```
残り = 本日のグローバル限度額 − 本日の累計回収量
```
- 日が変わると累計回収量は自動的に0にリセットされます
- グローバル限度額は従来の `getTodaySwapableToPCEBalance()` と同じ値です

**UIでの使い方:**
- 回収画面で「本日の残り回収枠: ○○ TCT」と表示
- 残りが0の場合は「本日の回収上限に達しました」と表示

---

### `getRemainingSwapableToPCEBalanceForIndividual(address account)`

**指定ユーザーの本日の個人別残り回収可能量**を返します。

| 項目 | 内容 |
|------|------|
| 引数 | `account` — 確認対象のウォレットアドレス |
| 戻り値 | `uint256` — そのユーザーが本日あとどれだけ（display単位）回収可能か |
| ガス | view（無料） |
| 呼び出し元制限 | なし（誰でも読める） |

**計算ロジック:**
```
残り = 本日の個人限度額 − 本日のそのユーザーの累計回収量
```
- 日が変わると累計回収量は自動的に0にリセットされます
- 個人限度額は従来の `getTodaySwapableToPCEBalanceForIndividual()` と同じ値です

**UIでの使い方:**
- ログインユーザーの回収画面で「あなたの残り回収枠: ○○ TCT」と表示
- 回収フォームの最大入力値のバリデーションに使用
- `min(グローバル残り, 個人残り)` が実際に回収可能な最大量です

---

## 変更メソッド（PCETokenV11）

### `swapFromLocalToken(address fromToken, uint256 amountToSwap)`

コミュニティトークンをPCEトークンに回収するメソッド（既存）。V11での変更点：

| 項目 | V10 | V11 |
|------|-----|-----|
| 限度額チェック | `getTodaySwapableToPCEBalance` | `getRemainingSwapableToPCEBalance` |
| 累計記録 | なし | あり（`recordSwapToPCE` を内部で呼出） |
| 同日複数回呼出 | 限度額を超過可能（バグ） | 正しく制限される |
| エラーメッセージ | `"Insufficient balance"` | `"Exceeds daily swap limit"` / `"Exceeds daily individual swap limit"` |

**UIでのエラーハンドリング:**

| revertメッセージ | 意味 | UIでの表示例 |
|-----------------|------|-------------|
| `Exceeds daily swap limit` | コミュニティ全体の日次上限超過 | 「本日のコミュニティ全体の回収上限に達しました」 |
| `Exceeds daily individual swap limit` | 個人の日次上限超過 | 「本日のあなたの回収上限に達しました」 |
| `Insufficient balance` | トークン残高不足 | 「残高が不足しています」 |

---

## 参照用: 既存メソッド（変更なし）

| メソッド | 説明 |
|---------|------|
| `getTodaySwapableToPCEBalance()` | 本日のグローバル限度額（上限値そのもの） |
| `getTodaySwapableToPCEBalanceForIndividual(address)` | 本日の個人限度額（上限値そのもの） |

> これらは引き続き利用可能です。プログレスバー等で「上限値」と「残り」の両方を表示する場合に使えます。

---

## UI実装例

### 回収画面の表示

```
本日の回収上限:     100 TCT  ← getTodaySwapableToPCEBalanceForIndividual(user)
本日の回収済み:      30 TCT  ← 上限 − 残り
残り回収可能量:      70 TCT  ← getRemainingSwapableToPCEBalanceForIndividual(user)
[===========-------] 30%

コミュニティ全体:
  上限 500 TCT / 残り 420 TCT  ← getTodaySwapableToPCEBalance() / getRemainingSwapableToPCEBalance()
```

### 入力バリデーション

```javascript
const globalRemaining = await communityToken.getRemainingSwapableToPCEBalance();
const individualRemaining = await communityToken.getRemainingSwapableToPCEBalanceForIndividual(userAddress);
const userBalance = await communityToken.balanceOf(userAddress);

const maxSwapable = min(globalRemaining, individualRemaining, userBalance);

// 入力フォームの最大値に設定
inputField.max = formatEther(maxSwapable);
```

---

## 日次リセットのタイミング

- UTC 0:00 を基準に日が変わります
- 厳密には、日をまたいだ後の**最初のトランザクション実行時**にリセットされます
- View メソッド（`getRemaining~`）は、日をまたいでいれば即座に累計0として計算します（トランザクション不要）
