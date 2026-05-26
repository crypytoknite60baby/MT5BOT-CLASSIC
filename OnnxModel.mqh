#property strict

class OnnxModel {
private:
   int m_handle;
   int m_num_inputs;
   int m_num_outputs;
   int m_input_size;
   int m_output_size;
public:
   OnnxModel(): m_handle(-1), m_num_inputs(0), m_num_outputs(0), m_input_size(0), m_output_size(0) {}

   bool Load(const string file_name, const int input_size, const int output_size) {
      if(m_handle != -1) {
         OnnxRelease(m_handle);
         m_handle = -1;
      }
      m_input_size = input_size;
      m_output_size = output_size;

      m_handle = OnnxCreate(file_name);
      if(m_handle == INVALID_HANDLE || m_handle < 0) {
         Print("[OnnxModel] Failed to create ONNX handle for file: ", file_name);
         return false;
      }
      // Shapes: using ulong arrays (implicit conversion supported in Build 5200)
      ulong in_shape[2];
      ulong out_shape[2];
      in_shape[0] = 1; in_shape[1] = (ulong)m_input_size;
      out_shape[0] = 1; out_shape[1] = (ulong)m_output_size;

      if(!OnnxSetInputShape(m_handle, 0, in_shape)) {
         Print("[OnnxModel] Failed to set input shape");
         return false;
      }
      if(!OnnxSetOutputShape(m_handle, 0, out_shape)) {
         Print("[OnnxModel] Failed to set output shape");
         return false;
      }
      return true;
   }

   bool IsLoaded() const { return (m_handle != -1); }

   bool Infer(const float &features[], float &outputs[]) {
      if(m_handle == -1) return false;
      // Set input tensor, run, get output
      if(!OnnxSetInput(m_handle, 0, features, 1, m_input_size)) {
         Print("[OnnxModel] Failed to set input data");
         return false;
      }
      if(!OnnxRun(m_handle)) {
         Print("[OnnxModel] OnnxRun failed");
         return false;
      }
      if(!OnnxGetOutput(m_handle, 0, outputs, 1, m_output_size)) {
         Print("[OnnxModel] Failed to get output data");
         return false;
      }
      return true;
   }

   void Release() {
      if(m_handle != -1) {
         OnnxRelease(m_handle);
         m_handle = -1;
      }
   }
}; 