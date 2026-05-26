### ML Environment Setup and ONNX Export

1) Create a Python venv and install deps

```bash
cd "THE NEW BOT"
python3 -m venv .venv
".venv/bin/pip" install --upgrade pip
".venv/bin/pip" install -r requirements.txt
```

2) Train and export the regime classifier to ONNX

```bash
".venv/bin/python" train_regime_model.py \
  --symbol "EURUSD=X" \
  --interval "1h" \
  --lookback_days 365 \
  --num_features 20 \
  --onnx_out "regime_classifier.onnx" \
  --classes_out "regime_classes.json"
```

3) Copy artifacts to MT5
- Place `regime_classifier.onnx` and `regime_classes.json` into your terminal's `MQL5/Files/` folder.
- Example path (Windows): `C:\Users\<You>\AppData\Roaming\MetaQuotes\Terminal\<ID>\MQL5\Files\`
- macOS (Crossover/Wine) paths vary by installation; use MT5 File → Open Data Folder → `MQL5/Files/`.

4) Run demo in MT5
- Open and compile `ML_Regime_Demo.mq5`.
- Ensure `INP_MODEL_FILE` matches the copied filename.
- Run it as a Script on a chart; it prints predicted regime and scores in the Journal.

Notes
- Keep the same feature preprocessing between Python and MQL5. The demo builds a vector of the last N returns.
- If you only get 2 classes in training, class map will be `{0: TRENDING, 1: NON_TREND}` and the demo will adapt.
- MT5 Build 5200+ improves ONNX shape handling; ensure you’re on a recent build. See: [MT5 Build 5200 release notes](https://www.metatrader5.com/en/releasenotes/terminal/2400) 