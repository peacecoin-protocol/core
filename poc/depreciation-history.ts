/**
 * PoC: Community Token Depreciation History
 *
 * Generates virtual depreciation entries for wallet history display.
 * Depreciation is calculated off-chain from on-chain parameters,
 * then merged with real transaction events at display time.
 *
 * Usage: npx ts-node poc/depreciation-history.ts
 * (or: bun run poc/depreciation-history.ts)
 */

// ---------- Types ----------

interface HistoryEntry {
  type: "mint" | "transfer_in" | "transfer_out" | "depreciation";
  /** UTC midnight timestamp (seconds) for depreciation, block timestamp for tx */
  timestamp: number;
  /** Display-amount delta (negative for depreciation / transfer_out) */
  displayAmount: bigint;
  /** Running display balance after this entry */
  balanceAfter: bigint;
  /** tx hash for real events, undefined for virtual depreciation entries */
  txHash?: string;
}

interface DepreciationParams {
  /** Contract storage: lastDecreaseTime (unix seconds) */
  lastDecreaseTime: number;
  /** Contract storage: decreaseIntervalDays */
  decreaseIntervalDays: number;
  /** Contract storage: afterDecreaseBp  (e.g. 9800 = 98%) */
  afterDecreaseBp: number;
  /** Contract storage: lastModifiedFactor */
  lastModifiedFactor: bigint;
}

/** Raw on-chain event (from MintArigatoCreation / PCETransfer logs) */
interface TxEvent {
  type: "mint" | "transfer_in" | "transfer_out";
  timestamp: number;
  displayAmount: bigint;
  rawAmount: bigint;
  txHash: string;
}

// ---------- Core: reproduce getCurrentFactor() in TS ----------

const BP_BASE = 10_000n;

/**
 * Mirrors PCECommunityToken.getCurrentFactor() exactly.
 * Uses the same day-floor and O(log n) binary exponentiation.
 */
function computeFactor(
  baseFactor: bigint,
  baseTime: number, // lastDecreaseTime at that point
  targetTime: number, // timestamp to compute for
  intervalDays: number,
  afterDecreaseBp: number,
): bigint {
  if (baseFactor === 0n) return 0n;
  if (intervalDays === 0) return baseFactor;

  const startDay = Math.floor(baseTime / 86400);
  const endDay = Math.floor(targetTime / 86400);
  if (endDay <= startDay) return baseFactor;

  const elapsed = endDay - startDay;
  if (elapsed < intervalDays) return baseFactor;

  const times = Math.floor(elapsed / intervalDays);

  // O(log n) binary exponentiation — same as Solidity
  let factor = baseFactor;
  let rate = BigInt(afterDecreaseBp);
  let base = BP_BASE;
  let n = times;
  while (n > 0) {
    if (n % 2 === 1) {
      factor = mulDiv(factor, rate, base);
    }
    rate = mulDiv(rate, rate, base);
    n = Math.floor(n / 2);
  }
  return factor;
}

/** Equivalent to OpenZeppelin Math.mulDiv (floor) */
function mulDiv(a: bigint, b: bigint, denominator: bigint): bigint {
  return (a * b) / denominator;
}

// ---------- Generate depreciation schedule ----------

/**
 * Returns UTC-midnight timestamps where depreciation occurs,
 * between `fromTime` and `toTime`.
 */
function getDepreciationTimestamps(
  params: DepreciationParams,
  fromTime: number,
  toTime: number,
): number[] {
  if (params.decreaseIntervalDays === 0) return [];

  const baseDay = Math.floor(params.lastDecreaseTime / 86400);
  const intervalDays = params.decreaseIntervalDays;

  // Find the first decay boundary >= fromTime
  const fromDay = Math.floor(fromTime / 86400);
  const elapsedFromBase = fromDay - baseDay;
  const periodsBeforeFrom = Math.ceil(elapsedFromBase / intervalDays);
  let nextDecayDay = baseDay + periodsBeforeFrom * intervalDays;

  const toDay = Math.floor(toTime / 86400);
  const timestamps: number[] = [];

  while (nextDecayDay <= toDay) {
    if (nextDecayDay > baseDay) {
      // Convert back to UTC midnight timestamp
      timestamps.push(nextDecayDay * 86400);
    }
    nextDecayDay += intervalDays;
  }
  return timestamps;
}

// ---------- Build merged history ----------

/**
 * Takes real tx events + contract params, returns a merged history
 * with virtual depreciation entries injected at display time.
 *
 * This is the main function the wallet app would call.
 */
function buildHistory(
  txEvents: TxEvent[],
  params: DepreciationParams,
  fromTime: number,
  toTime: number,
): HistoryEntry[] {
  // Sort events by timestamp
  const sorted = [...txEvents].sort((a, b) => a.timestamp - b.timestamp);

  // Get all depreciation boundaries in the range
  const depTimestamps = getDepreciationTimestamps(params, fromTime, toTime);

  // Merge into a single timeline
  const timeline: HistoryEntry[] = [];
  let txIdx = 0;
  let depIdx = 0;

  // Track raw balance to compute display amounts accurately
  let rawBalance = 0n;

  while (txIdx < sorted.length || depIdx < depTimestamps.length) {
    const txTime = txIdx < sorted.length ? sorted[txIdx].timestamp : Infinity;
    const depTime =
      depIdx < depTimestamps.length ? depTimestamps[depIdx] : Infinity;

    if (txTime <= depTime) {
      // Real transaction
      const ev = sorted[txIdx];
      const sign = ev.type === "transfer_out" ? -1n : 1n;
      rawBalance += sign * ev.rawAmount;

      const factor = computeFactor(
        params.lastModifiedFactor,
        params.lastDecreaseTime,
        ev.timestamp,
        params.decreaseIntervalDays,
        params.afterDecreaseBp,
      );
      const displayBalance = factor > 0n ? rawBalance / factor : rawBalance;

      timeline.push({
        type: ev.type,
        timestamp: ev.timestamp,
        displayAmount: sign * ev.displayAmount,
        balanceAfter: displayBalance,
        txHash: ev.txHash,
      });
      txIdx++;
    } else {
      // Virtual depreciation entry
      const depTimestamp = depTimestamps[depIdx];

      // Factor just before this depreciation
      const factorBefore = computeFactor(
        params.lastModifiedFactor,
        params.lastDecreaseTime,
        depTimestamp - 1,
        params.decreaseIntervalDays,
        params.afterDecreaseBp,
      );
      // Factor just after
      const factorAfter = computeFactor(
        params.lastModifiedFactor,
        params.lastDecreaseTime,
        depTimestamp,
        params.decreaseIntervalDays,
        params.afterDecreaseBp,
      );

      const displayBefore =
        factorBefore > 0n ? rawBalance / factorBefore : rawBalance;
      const displayAfter =
        factorAfter > 0n ? rawBalance / factorAfter : rawBalance;
      const delta = displayAfter - displayBefore; // negative

      if (delta !== 0n) {
        timeline.push({
          type: "depreciation",
          timestamp: depTimestamp,
          displayAmount: delta,
          balanceAfter: displayAfter,
        });
      }
      depIdx++;
    }
  }

  return timeline;
}

// ---------- Demo ----------

function demo() {
  // Simulate contract params: 2% decay every 7 days
  const now = Math.floor(Date.now() / 1000);
  const day = 86400;
  const startTime = now - 30 * day; // 30 days ago

  const params: DepreciationParams = {
    lastDecreaseTime: startTime,
    decreaseIntervalDays: 7,
    afterDecreaseBp: 9800, // 98% → 2% decay
    lastModifiedFactor: 10n ** 18n, // 1e18 initial factor
  };

  // Simulate some tx events
  const factor = params.lastModifiedFactor;
  const txEvents: TxEvent[] = [
    {
      type: "mint",
      timestamp: startTime + 1 * day,
      displayAmount: 1000n,
      rawAmount: 1000n * factor,
      txHash: "0xaaa...111",
    },
    {
      type: "mint",
      timestamp: startTime + 10 * day,
      displayAmount: 500n,
      rawAmount: 500n * computeFactor(factor, startTime, startTime + 10 * day, 7, 9800),
      txHash: "0xbbb...222",
    },
    {
      type: "transfer_out",
      timestamp: startTime + 20 * day,
      displayAmount: 200n,
      rawAmount: 200n * computeFactor(factor, startTime, startTime + 20 * day, 7, 9800),
      txHash: "0xccc...333",
    },
  ];

  const history = buildHistory(txEvents, params, startTime, now);

  console.log("=== Wallet History (display time injection) ===\n");
  for (const entry of history) {
    const date = new Date(entry.timestamp * 1000)
      .toISOString()
      .slice(0, 10);
    const sign = entry.displayAmount >= 0n ? "+" : "";
    const typeLabel = entry.type === "depreciation"
      ? "  📉 Depreciation"
      : entry.type === "mint"
        ? "  ⬆  Mint"
        : entry.type === "transfer_in"
          ? "  ⬆  Received"
          : "  ⬇  Sent";

    console.log(
      `${date} ${typeLabel}  ${sign}${entry.displayAmount}  →  balance: ${entry.balanceAfter}` +
        (entry.txHash ? `  (${entry.txHash})` : ""),
    );
  }
}

demo();

export {
  buildHistory,
  computeFactor,
  getDepreciationTimestamps,
  type DepreciationParams,
  type HistoryEntry,
  type TxEvent,
};
