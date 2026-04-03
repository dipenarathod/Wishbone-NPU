with Input_Output_Helper;                   use Input_Output_Helper;
with Input_Output_Helper.Debug;             use Input_Output_Helper.Debug;
with Input_Output_Helper.Utils;             use Input_Output_Helper.Utils;
with Input_Output_Helper.Time_Measurements;
use Input_Output_Helper.Time_Measurements;
with Wb_Npu_Helper;                         use Wb_Npu_Helper;
with Wb_Npu_Address_Map;                    use Wb_Npu_Address_Map;
with Wb_Npu_Helper.Debug;                   use Wb_Npu_Helper.Debug;
with Wb_Npu_Helper.Activation;              use Wb_Npu_Helper.Activation;
with Wb_Npu_Helper.Pooling;                 use Wb_Npu_Helper.Pooling;
with Wb_Npu_Helper.Dense;                   use Wb_Npu_Helper.Dense;
with Wb_Npu_Helper.Conv2D;                  use Wb_Npu_Helper.Conv2D;
with Interfaces;                            use Interfaces;
with Ada.Text_IO;                           use Ada.Text_IO;
with Uart0;
with Runtime_Support;
with neorv32;                               use neorv32;
with RISCV.CSR;                             use RISCV.CSR;
with riscv.CSR_Generic;                     use riscv.CSR_Generic;
with System.Machine_Code;                   use System.Machine_Code;

with tensors_mnist_28x28_words; use tensors_mnist_28x28_words;

procedure Npu_Worst_Case_Timing_Test is

  --Words each layer will produce
  --For 3x3 Conv2D with valid padding and stride (1, 1):
  --Output side len = (Input side len - Kernel side len) / Stride + 1
  Conv_Kernel_Side_Len                 : constant Natural := 3;
  Conv_Stride                          : constant Natural := 1;

  --Layer 1 Conv
  Input_Len_First_Conv                 : constant Natural := 28;
  Output_Len_First_Conv                : constant Natural :=
   (Input_Len_First_Conv - Conv_Kernel_Side_Len) + 1;
  Number_Of_Input_Channels_First_Conv  : constant Natural := 1;
  Number_Of_Output_Channels_First_Conv : constant Natural := 14;
  Total_Bytes_Produced_First_Conv      : constant Natural :=
   (Output_Len_First_Conv ** 2) * Number_Of_Output_Channels_First_Conv;
  Total_Words_Produced_First_Conv      : constant Natural :=
   Tensor_Words (Total_Bytes_Produced_First_Conv, One_Dimensional => True);

  --Layer 3 2D Max Pooling
  Total_Bytes_Produced_First_MaxPool : constant Natural :=
   ((Output_Len_First_Conv / 2) ** 2) * Number_Of_Output_Channels_First_Conv;
  Total_Words_Produced_First_MaxPool : constant Natural :=
   Tensor_Words (Total_Bytes_Produced_First_MaxPool, One_Dimensional => True);

  --Layer 4 Conv
  Input_Len_Second_Conv                 : constant Natural := 13;
  Output_Len_Second_Conv                : constant Natural :=
   (Input_Len_Second_Conv - Conv_Kernel_Side_Len) + 1;
  Number_Of_Input_Channels_Second_Conv  : constant Natural := 14;
  Number_Of_Output_Channels_Second_Conv : constant Natural := 32;
  Total_Bytes_Produced_Second_Conv      : constant Natural :=
   (Output_Len_Second_Conv ** 2) * Number_Of_Output_Channels_Second_Conv;
  Total_Words_Produced_Second_Conv      : constant Natural :=
   Tensor_Words (Total_Bytes_Produced_Second_Conv, One_Dimensional => True);

  --Layer 6 2D Max Pooling
  Total_Bytes_Produced_Second_MaxPool : constant Natural :=
   ((Output_Len_Second_Conv / 2) ** 2) * Number_Of_Output_Channels_Second_Conv;
  Total_Words_Produced_Second_MaxPool : constant Natural :=
   Tensor_Words (Total_Bytes_Produced_Second_MaxPool, One_Dimensional => True);

  --Layer 7 Dense
  Inputs_First_Dense        : constant Natural :=
   ((Output_Len_Second_Conv / 2) ** 2) * Number_Of_Output_Channels_Second_Conv;
  Neurons_First_Dense       : constant Natural := 10;
  Neurons_First_Dense_Words : constant Natural :=
   Tensor_Words (Neurons_First_Dense, One_Dimensional => True);

  --Input tensor sizes for each standalone worst-case layer run
  Input_Bytes_First_Conv : constant Natural := 28 * 28;
  Input_Words_First_Conv : constant Natural :=
   Tensor_Words (Input_Bytes_First_Conv, One_Dimensional => True);

  First_Conv_Input     : Word_Array (0 .. Input_Words_First_Conv - 1);
  First_ReLU_Input     : Word_Array (0 .. Total_Words_Produced_First_Conv - 1);
  First_MaxPool_Input  : Word_Array (0 .. Total_Words_Produced_First_Conv - 1);
  Second_Conv_Input    : Word_Array (0 .. Total_Words_Produced_First_MaxPool - 1);
  Second_ReLU_Input    : Word_Array (0 .. Total_Words_Produced_Second_Conv - 1);
  Second_MaxPool_Input : Word_Array (0 .. Total_Words_Produced_Second_Conv - 1);
  Dense_Input          : Word_Array (0 .. Total_Words_Produced_Second_MaxPool - 1);
  SoftMax_Input        : Word_Array (0 .. Neurons_First_Dense_Words - 1);

  Result_Dense_Tensor  : Word_Array (0 .. Neurons_First_Dense_Words - 1);

  Start_Cycles : Unsigned_64;
  End_Cycles   : Unsigned_64;
  Total_Cycles : Unsigned_64 := 0;

  Worst_Positive_Word : constant Word := Word (16#7F7F7F7F#);
  Worst_Negative_Word : constant Word := Word (16#80808080#);
  Alternating_Word    : constant Word := Word (16#7F807F80#);

  --Weights and biases offset
  Weights_Base_First_Conv       : constant Natural := 0;
  Weights_Base_Second_Conv      : constant Natural :=
   layer_0_conv2d_Weights_Words'Length;
  Weights_Base_Second_Conv_INT8 : constant Natural :=
   Weights_Base_Second_Conv * 4;
  Weights_Base_First_Dense      : constant Natural :=
   Weights_Base_Second_Conv + layer_5_conv2d_1_Weights_Words'Length;
  Weights_Base_First_Dense_INT8 : constant Natural :=
   Weights_Base_First_Dense * 4;

  Biases_Base_First_Conv  : constant Natural := 0;
  Biases_Base_Second_Conv : constant Natural :=
   layer_0_conv2d_Bias_Words'Length;
  Biases_Base_First_Dense : constant Natural :=
   Biases_Base_Second_Conv + layer_5_conv2d_1_Bias_Words'Length;

  procedure Fill_Word_Array (Data : out Word_Array; Value : Word) is
  begin
    for I in Data'Range loop
      Data (I) := Value;
    end loop;
  end Fill_Word_Array;

begin
  --Load weights and biases once
  Write_Words_In_B (layer_0_conv2d_Weights_Words);
  Write_Words_In_B (layer_5_conv2d_1_Weights_Words, Weights_Base_Second_Conv);
  Write_Words_In_B (layer_12_dense_Weights_Words, Weights_Base_First_Dense);

  Write_Words_In_C (layer_0_conv2d_Bias_Words);
  Write_Words_In_C (layer_5_conv2d_1_Bias_Words, Biases_Base_Second_Conv);
  Write_Words_In_C (layer_12_dense_Bias_Words, Biases_Base_First_Dense);

  --Synthetic worst-case-style patterns
  Fill_Word_Array (First_Conv_Input, Worst_Positive_Word);
  Fill_Word_Array (First_ReLU_Input, Worst_Negative_Word);
  Fill_Word_Array (First_MaxPool_Input, Alternating_Word);
  Fill_Word_Array (Second_Conv_Input, Worst_Positive_Word);
  Fill_Word_Array (Second_ReLU_Input, Worst_Negative_Word);
  Fill_Word_Array (Second_MaxPool_Input, Alternating_Word);
  Fill_Word_Array (Dense_Input, Worst_Positive_Word);
  Fill_Word_Array (SoftMax_Input, Worst_Positive_Word);

  Put_Line ("--------------------------------");
  Put_Line ("NPU Worst-Case Layer Timing Test");
  Put_Line ("--------------------------------");

  --Layer 1 Conv
  Write_Words_In_A (First_Conv_Input);
  Start_Cycles := Read_Cycle;
  Apply_Conv2D_All_Words
   (N                                => Input_Len_First_Conv,
    Input_Channels                   => Number_Of_Input_Channels_First_Conv,
    Filters                          => Number_Of_Output_Channels_First_Conv,
    Weight_Base_Index                => Weights_Base_First_Conv,
    Bias_Base_Index                  => Biases_Base_First_Conv,
    Zero_Point                       => layer_0_conv2d_WZP,
    Quantized_Multiplier             => layer_0_conv2d_Quantized_Multiplier,
    Quantized_Multiplier_Right_Shift =>
     layer_0_conv2d_Quantized_Right_Shift);
  End_Cycles := Read_Cycle;
  Print_Time ("Worst-case First Conv Layer = ", End_Cycles - Start_Cycles);
  Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

  --Layer 2 ReLU
  Write_Words_In_A (First_ReLU_Input);
  Start_Cycles := Read_Cycle;
  Apply_ReLU_All_Words
   (Total_Bytes_Produced_First_Conv, One_Dimensional => True);
  End_Cycles := Read_Cycle;
  Print_Time ("Worst-case First ReLU = ", End_Cycles - Start_Cycles);
  Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

  --Layer 3 Max Pooling
  Write_Words_In_A (First_MaxPool_Input);
  Start_Cycles := Read_Cycle;
  Apply_MaxPool_Multi_Channel
   (Output_Len_First_Conv, Number_Of_Output_Channels_First_Conv);
  End_Cycles := Read_Cycle;
  Print_Time ("Worst-case First MaxPool = ", End_Cycles - Start_Cycles);
  Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

  --Layer 4 Conv
  Write_Words_In_A (Second_Conv_Input);
  Start_Cycles := Read_Cycle;
  Apply_Conv2D_All_Words
   (N                                => Input_Len_Second_Conv,
    Input_Channels                   => Number_Of_Input_Channels_Second_Conv,
    Filters                          => Number_Of_Output_Channels_Second_Conv,
    Weight_Base_Index                => Weights_Base_Second_Conv_INT8,
    Bias_Base_Index                  => Biases_Base_Second_Conv,
    Zero_Point                       => layer_5_conv2d_1_WZP,
    Quantized_Multiplier             => layer_5_conv2d_1_Quantized_Multiplier,
    Quantized_Multiplier_Right_Shift =>
     layer_5_conv2d_1_Quantized_Right_Shift);
  End_Cycles := Read_Cycle;
  Print_Time ("Worst-case Second Conv Layer = ", End_Cycles - Start_Cycles);
  Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

  --Layer 5 ReLU
  Write_Words_In_A (Second_ReLU_Input);
  Start_Cycles := Read_Cycle;
  Apply_ReLU_All_Words
   (Total_Bytes_Produced_Second_Conv, One_Dimensional => True);
  End_Cycles := Read_Cycle;
  Print_Time ("Worst-case Second ReLU = ", End_Cycles - Start_Cycles);
  Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

  --Layer 6 Max Pooling
  Write_Words_In_A (Second_MaxPool_Input);
  Start_Cycles := Read_Cycle;
  Apply_MaxPool_Multi_Channel
   (Output_Len_Second_Conv, Number_Of_Output_Channels_Second_Conv);
  End_Cycles := Read_Cycle;
  Print_Time ("Worst-case Second MaxPool = ", End_Cycles - Start_Cycles);
  Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

  --Layer 7 Dense
  Write_Words_In_A (Dense_Input);
  Start_Cycles := Read_Cycle;
  Apply_Dense_All_Words
   (Inputs                           => Inputs_First_Dense,
    Neurons                          => Neurons_First_Dense,
    Weight_Base_Index                => Weights_Base_First_Dense_INT8,
    Bias_Base_Index                  => Biases_Base_First_Dense,
    Zero_Point                       => layer_12_dense_WZP,
    Quantized_Multiplier             => layer_12_dense_Quantized_Multiplier,
    Quantized_Multiplier_Right_Shift =>
     Natural (layer_12_dense_Quantized_Right_Shift));
  End_Cycles := Read_Cycle;
  Print_Time ("Worst-case Dense Layer = ", End_Cycles - Start_Cycles);
  Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

  --Layer 8 SoftMax
  Write_Words_In_A (SoftMax_Input);
  Start_Cycles := Read_Cycle;
  Apply_SoftMax_All_Words (Neurons_First_Dense, One_Dimensional => True);
  End_Cycles := Read_Cycle;
  Print_Time ("Worst-case SoftMax = ", End_Cycles - Start_Cycles);
  Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

  --Optional readback just to ensure final stage completed cleanly
  Read_Words_From_R (Result_Dense_Tensor);

  Put_Line ("--------------------------------");
  Print_Time ("Total worst-case layer compute time = ", Total_Cycles);
  Put_Line ("Done");

  loop
    null;
  end loop;
end Npu_Worst_Case_Timing_Test;