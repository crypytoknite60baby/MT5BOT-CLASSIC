#property strict
#property script_show_inputs

#include <Trade/Trade.mqh>
#include "OnnxModel.mqh"

input string INP_MODEL_FILE = "regime_classifier.onnx";
input string INP_CLASSES_FILE = "regime_classes.json";
input int    INP_NUM_FEATURES = 20;
input ENUM_TIMEFRAMES INP_TF = PERIOD_H1;

OnnxModel g_model;
string    g_class_map[10];
int       g_num_outputs = 3; // default; will adjust if we read 2-class mapping

bool LoadClassMap(const string file_name) {
   ResetLastError();
   int handle = FileOpen(file_name, FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle == INVALID_HANDLE) {
      Print("[ML_Regime_Demo] Could not open class map: ", file_name, " Error ", GetLastError());
      return false;
   }
   string content = FileReadString(handle, (int)FileSize(handle));
   FileClose(handle);

   // Very simple parse: expect a JSON like {"0":"TRENDING","1":"RANGING","2":"VOLATILE"}
   ArrayInitialize(g_class_map, "");
   g_num_outputs = 0;
   for(int i=0; i<10; i++) {
      string key = IntegerToString(i);
      int pos = StringFind(content, '"' + key + '"');
      if(pos >= 0) {
         int colon = StringFind(content, ":", pos);
         int q1 = StringFind(content, '"', colon+1);
         int q2 = StringFind(content, '"', q1+1);
         if(q1>0 && q2>q1) {
            g_class_map[i] = StringSubstr(content, q1+1, q2-q1-1);
            g_num_outputs = i+1;
         }
      }
   }
   if(g_num_outputs < 2) g_num_outputs = 3; // fallback
   return true;
}

int OnInit() {
   bool ok_map = LoadClassMap(INP_CLASSES_FILE);
   if(!ok_map) Print("[ML_Regime_Demo] Proceeding with default class names.");

   if(!g_model.Load(INP_MODEL_FILE, INP_NUM_FEATURES, g_num_outputs)) {
      Print("[ML_Regime_Demo] Failed to load ONNX model. Place ", INP_MODEL_FILE, " in MQL5/Files.");
      return INIT_FAILED;
   }
   Print("[ML_Regime_Demo] Model loaded with features=", INP_NUM_FEATURES, " outputs=", g_num_outputs);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   g_model.Release();
}

void OnStart() {
   // Build features: last INP_NUM_FEATURES returns at INP_TF
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(_Symbol, INP_TF, 0, INP_NUM_FEATURES+1, close) < INP_NUM_FEATURES+1) {
      Print("[ML_Regime_Demo] Not enough bars to build features");
      return;
   }

   float feats[];
   ArrayResize(feats, INP_NUM_FEATURES);
   for(int i=0; i<INP_NUM_FEATURES; i++) {
      double c0 = close[i];
      double c1 = close[i+1];
      double r = (c0 - c1) / MathMax(1e-12, c1);
      feats[INP_NUM_FEATURES-1-i] = (float)r; // oldest->newest ordering expected by trainer
   }

   float out[];
   ArrayResize(out, g_num_outputs);
   if(!g_model.Infer(feats, out)) {
      Print("[ML_Regime_Demo] Inference failed");
      return;
   }

   // Argmax
   int best_idx = 0;
   float best_val = out[0];
   for(int i=1;i<g_num_outputs;i++) if(out[i] > best_val) { best_val = out[i]; best_idx = i; }

   string cls = (g_class_map[best_idx] != "") ? g_class_map[best_idx] : (best_idx==0?"TRENDING":best_idx==1?"RANGING":"VOLATILE");
   PrintFormat("[ML_Regime_Demo] Predicted class=%s (idx=%d) scores=%G,%G,%G", cls, best_idx,
               g_num_outputs>0?out[0]:0.0, g_num_outputs>1?out[1]:0.0, g_num_outputs>2?out[2]:0.0);
} 