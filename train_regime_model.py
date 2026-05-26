#!/usr/bin/env python3
import argparse
import json
import os
from datetime import datetime, timedelta

import numpy as np
import pandas as pd

# Optional imports; provide friendly errors if missing
try:
    import yfinance as yf
except Exception as e:
    yf = None

try:
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import StandardScaler
except Exception as e:
    raise SystemExit("scikit-learn is required. Install with: pip install scikit-learn")

try:
    from skl2onnx import convert_sklearn
    from skl2onnx.common.data_types import FloatTensorType
except Exception as e:
    raise SystemExit("skl2onnx is required. Install with: pip install skl2onnx onnx")


def fetch_prices_yf(symbol: str, start: datetime, end: datetime, interval: str) -> pd.DataFrame:
    if yf is None:
        raise SystemExit("yfinance is required for data download. Install with: pip install yfinance")
    ticker = yf.Ticker(symbol)
    df = ticker.history(start=start, end=end, interval=interval)
    if df.empty:
        raise RuntimeError(f"No data returned for {symbol} using yfinance.")
    df = df.rename(columns={"Close": "close"})
    df = df[["close"]].dropna()
    return df


def build_dataset(prices: pd.DataFrame, num_features: int = 20) -> tuple[np.ndarray, np.ndarray]:
    close = prices["close"].values.astype(np.float64)
    rets = np.diff(close) / close[:-1]
    # Pad to align length
    rets = np.concatenate([[0.0], rets])

    # Rolling stats for labeling
    win = max(10, min(50, num_features))
    roll_std = pd.Series(rets).rolling(win).std().values
    roll_mean = pd.Series(rets).rolling(win).mean().values

    # Labeling rules (3 classes): 0=TRENDING, 1=RANGING, 2=VOLATILE
    # - VOLATILE: high std
    # - TRENDING: abs(mean) large but not too volatile
    # - RANGING: otherwise
    std_q = np.nanpercentile(roll_std, 80)
    mean_q = np.nanpercentile(np.abs(roll_mean), 80)

    labels = np.zeros_like(rets, dtype=np.int64)
    labels[(roll_std > std_q)] = 2
    cond_trend = (np.abs(roll_mean) > mean_q) & (roll_std <= std_q)
    labels[cond_trend] = 0
    labels[(~cond_trend) & (roll_std <= std_q)] = 1

    # Build features: last num_features returns
    X = []
    y = []
    for i in range(num_features, len(rets)):
        feat = rets[i - num_features: i]
        if np.any(np.isnan(feat)):
            continue
        X.append(feat.astype(np.float32))
        y.append(labels[i])

    X = np.asarray(X, dtype=np.float32)
    y = np.asarray(y, dtype=np.int64)

    # Filter to ensure all classes present
    classes_present = set(y.tolist())
    if not {0, 1, 2}.issubset(classes_present):
        # Fallback: collapse to binary trend vs not-trend in edge cases
        y = np.where(y == 0, 0, 1).astype(np.int64)
        print("Warning: Not all 3 classes present. Falling back to 2-class (trend vs other).")
    return X, y


def train_and_export(symbol: str, interval: str, lookback_days: int, num_features: int,
                      onnx_path: str, classes_path: str):
    end = datetime.utcnow()
    start = end - timedelta(days=lookback_days)

    print(f"Downloading data for {symbol} [{interval}] from {start.date()} to {end.date()} ...")
    prices = fetch_prices_yf(symbol, start, end, interval)

    X, y = build_dataset(prices, num_features=num_features)
    if len(np.unique(y)) < 2:
        raise RuntimeError("Insufficient class diversity to train a model. Try a longer lookback.")

    print(f"Samples: {len(X)}, Features: {X.shape[1]}, Classes: {sorted(set(y.tolist()))}")

    # Simple, stable classifier
    pipe = Pipeline([
        ("scaler", StandardScaler(with_mean=True, with_std=True)),
        ("clf", LogisticRegression(max_iter=200, multi_class="auto"))
    ])
    pipe.fit(X, y)

    # Export ONNX
    initial_type = [("input", FloatTensorType([None, X.shape[1]]))]
    onnx_model = convert_sklearn(pipe, initial_types=initial_type)

    os.makedirs(os.path.dirname(onnx_path), exist_ok=True) if os.path.dirname(onnx_path) else None
    with open(onnx_path, "wb") as f:
        f.write(onnx_model.SerializeToString())
    print(f"Saved ONNX model to: {onnx_path}")

    # Save class mapping (0,1,2 for 3-class; or 0,1 for binary fallback)
    class_map = {
        "0": "TRENDING",
        "1": "RANGING" if len(np.unique(y)) > 2 else "NON_TREND",
    }
    if len(np.unique(y)) > 2:
        class_map["2"] = "VOLATILE"

    with open(classes_path, "w") as f:
        json.dump(class_map, f, indent=2)
    print(f"Saved class mapping to: {classes_path}")

    print("Done. Copy the ONNX file into your terminal's MQL5/Files folder for the EA to load.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train a simple regime classifier and export ONNX.")
    parser.add_argument("--symbol", default="EURUSD=X", help="yfinance symbol (e.g., EURUSD=X, GBPUSD=X)")
    parser.add_argument("--interval", default="1h", help="Data interval (e.g., 15m, 1h, 4h, 1d)")
    parser.add_argument("--lookback_days", type=int, default=365, help="Lookback window in days")
    parser.add_argument("--num_features", type=int, default=20, help="Number of lagged returns as features")
    parser.add_argument("--onnx_out", default="regime_classifier.onnx", help="Output ONNX filename")
    parser.add_argument("--classes_out", default="regime_classes.json", help="Output class map filename")
    args = parser.parse_args()

    train_and_export(
        symbol=args.symbol,
        interval=args.interval,
        lookback_days=args.lookback_days,
        num_features=args.num_features,
        onnx_path=args.onnx_out,
        classes_path=args.classes_out,
    ) 