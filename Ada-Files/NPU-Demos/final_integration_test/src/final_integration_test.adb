with Input_Output_Helper;                   use Input_Output_Helper;
with Input_Output_Helper.Time_Measurements;
use Input_Output_Helper.Time_Measurements;
with Input_Output_Helper.Debug;             use Input_Output_Helper.Debug;
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
--with Ada.Real_Time;  use Ada.Real_Time;
with System.Machine_Code;                   use System.Machine_Code;
with Wb_Ov5640_Helper;                      use Wb_Ov5640_Helper;
with Wb_Ov5640_Address_Map;     use Wb_Ov5640_Address_Map;
with rps_gray100_savedmodelv3; use rps_gray100_savedmodelv3;

procedure Final_Integration_Test is

   Image_Side_Len    : constant Natural := 100;
   Image_Total_Bytes : constant Natural := 10_000;
   Image_Words       : constant Natural :=
     Tensor_Words (Image_Total_Bytes, True);
   Image_Captured    : Word_Array (0 .. Image_Words - 1);
   --AvgPool -> Conv2D -> ReLU -> MaxPool -> Conv2D -> ReLU -> Conv -> ReLU -> MaxPooling -> MaxPooling -> MaxPooling -> Dense -> ReLU -> Dense

   Predicted_Label          : Natural;
   --  Matches                  : Natural;
   --  Total_Samples            : constant Natural := Labels'Length;
   --  Accuracy                 : Float;
   Clock_Hz                 : constant Unsigned_64 := 72_000_000;
   Start_Cycles             : Unsigned_64;
   End_Cycles               : Unsigned_64;
   Delta_Cycles             : Unsigned_64;
   Weight_Bias_Write_Cycles : Unsigned_64;
   Total_Cycles             : Unsigned_64;

   --Words each layer will produce (words that need to be copied from R to A)
   --For 3x3 Conv2D with valid padding and stride (1, 1):
   --Output side len = (Input side len - Kernel side len) / Stride + 1
   Conv_Kernel_Side_Len : constant Natural := 3;
   Conv_Stride          : constant Natural := 1;

   --Layer 1 AvgPool
   Total_Bytes_Produced_First_AvgPool   : constant Natural :=
     (Image_Side_Len / 2) ** 2;
   Total_Words_Produced_First_AvgPool   : constant Natural :=
     Tensor_Words (Total_Bytes_Produced_First_AvgPool, True);
   Output_Len_First_Avg_Pool            : constant Natural :=
     Image_Side_Len / 2;
   --Layer 2 Conv
   Input_Len_First_Conv                 : constant Natural :=
     Output_Len_First_Avg_Pool;
   Output_Len_First_Conv                : constant Natural :=
     (Input_Len_First_Conv - Conv_Kernel_Side_Len) + 1;
   Number_Of_Input_Channels_First_Conv  : constant Natural := 1;
   Number_Of_Output_Channels_First_Conv : constant Natural := 8;
   Total_Bytes_Produced_First_Conv      : constant Natural :=
     (Output_Len_First_Conv ** 2) * Number_Of_Output_Channels_First_Conv;
   Total_Words_Produced_First_Conv      : constant Natural :=
     Tensor_Words (Total_Bytes_Produced_First_Conv, One_Dimensional => True);

   --Layer 3 ReLU
   --Tensor_First_Conv : Word_Array (0..Total_Words_Produced_First_Conv-1);
   --Layer 4 2D Max Pooling
   Total_Bytes_Produced_First_MaxPool : constant Natural :=
     ((Output_Len_First_Conv / 2) ** 2) * Number_Of_Output_Channels_First_Conv;
   Total_Words_Produced_First_MaxPool : constant Natural :=
     Tensor_Words
       (Total_Bytes_Produced_First_MaxPool, One_Dimensional => True);
   Output_Len_First_MaxPool           : constant Natural :=
     Output_Len_First_Conv / 2;

   --Layer 5 Conv
   Input_Len_Second_Conv                 : constant Natural :=
     Output_Len_First_MaxPool;
   Output_Len_Second_Conv                : constant Natural :=
     (Input_Len_Second_Conv - Conv_Kernel_Side_Len) + 1;
   Number_Of_Input_Channels_Second_Conv  : constant Natural := 8;
   Number_Of_Output_Channels_Second_Conv : constant Natural := 32;
   Total_Bytes_Produced_Second_Conv      : constant Natural :=
     (Output_Len_Second_Conv ** 2) * Number_Of_Output_Channels_Second_Conv;
   Total_Words_Produced_Second_Conv      : constant Natural :=
     Tensor_Words (Total_Bytes_Produced_Second_Conv, One_Dimensional => True);

   --Layer 6 ReLU
   --Tensor_Second_Conv : Word_Array (0..Total_Words_Produced_Second_Conv-1);

   --Layer 7 2D Max Pooling
   Total_Bytes_Produced_Second_MaxPool : constant Natural :=
     ((Output_Len_Second_Conv / 2) ** 2)
     * Number_Of_Output_Channels_Second_Conv;
   Total_Words_Produced_Second_MaxPool : constant Natural :=
     Tensor_Words
       (Total_Bytes_Produced_Second_MaxPool, One_Dimensional => True);
   Output_Len_Second_MaxPool           : constant Natural :=
     Output_Len_Second_Conv / 2;
   --  Tensor_Second_MaxPool               :
   --    Word_Array (0 .. Total_Words_Produced_Second_MaxPool - 1);
   --  Tensor_Second_MaxPool :
   --   Word_Array (0 .. Total_Words_Produced_Second_MaxPool - 1) := (Others => 0);

   --Layer 8 Conv
   Input_Len_Third_Conv                 : constant Natural :=
     Output_Len_Second_MaxPool;
   Output_Len_Third_Conv                : constant Natural :=
     (Input_Len_Third_Conv - Conv_Kernel_Side_Len) + 1;
   Number_Of_Input_Channels_Third_Conv  : constant Natural := 32;
   Number_Of_Output_Channels_Third_Conv : constant Natural := 64;
   Total_Bytes_Produced_Third_Conv      : constant Natural :=
     (Output_Len_Third_Conv ** 2) * Number_Of_Output_Channels_Third_Conv;
   Total_Words_Produced_Third_Conv      : constant Natural :=
     Tensor_Words (Total_Bytes_Produced_Third_Conv, One_Dimensional => True);

   --Layer 9 ReLU
   --Tensor_Second_Conv : Word_Array (0..Total_Words_Produced_Second_Conv-1);

   --Layer 10 2D Max Pooling
   Total_Bytes_Produced_Third_MaxPool : constant Natural :=
     ((Output_Len_Third_Conv / 2) ** 2) * Number_Of_Output_Channels_Third_Conv;
   Total_Words_Produced_Third_MaxPool : constant Natural :=
     Tensor_Words
       (Total_Bytes_Produced_Third_MaxPool, One_Dimensional => True);
   Output_Len_Third_MaxPool           : constant Natural :=
     Output_Len_Third_Conv / 2;

   --Layer 11 2D Max Pooling
   Total_Bytes_Produced_Fourth_MaxPool : constant Natural :=
     ((Output_Len_Third_MaxPool / 2) ** 2)
     * Number_Of_Output_Channels_Third_Conv;
   Total_Words_Produced_Fourth_MaxPool : constant Natural :=
     Tensor_Words
       (Total_Bytes_Produced_Fourth_MaxPool, One_Dimensional => True);
   Output_Len_Fourth_MaxPool           : constant Natural :=
     Output_Len_Third_MaxPool / 2;

   --Layer 12 2D Max Pooling
   Total_Bytes_Produced_Fifth_MaxPool : constant Natural :=
     ((Output_Len_Fourth_MaxPool / 2) ** 2)
     * Number_Of_Output_Channels_Third_Conv;
   Total_Words_Produced_Fifth_MaxPool : constant Natural :=
     Tensor_Words
       (Total_Bytes_Produced_Fifth_MaxPool, One_Dimensional => True);
   Output_Len_Fifth_MaxPool           : constant Natural :=
     Output_Len_Fourth_MaxPool / 2;

   --Layer 13 Dense
   Inputs_First_Dense        : constant Natural :=
     (Output_Len_Fifth_MaxPool ** 2) * Number_Of_Output_Channels_Third_Conv;
   Neurons_First_Dense       : constant Natural := 32;
   Neurons_First_Dense_Words : constant Natural :=
     Tensor_Words
       (Neurons_First_Dense, One_Dimensional => True); --(10+3)/4 = 3

   --Layer 14 ReLU
   --Layer 15 Dense
   Inputs_Second_Dense        : constant Natural := Neurons_First_Dense;
   Neurons_Second_Dense       : constant Natural := 3;
   Neurons_Second_Dense_Words : constant Natural :=
     Tensor_Words (Neurons_Second_Dense, One_Dimensional => True); --1
   --Layer 16 SoftMax

   Result_Tensor : Word_Array (0 .. Neurons_Second_Dense_Words - 1);

   --Weights and biases offset
   Weights_Base_First_Conv : constant Natural := 0;

   Weights_Base_Second_Conv      : constant Natural :=
     layer_3_conv2d_Weights_Words'Length;
   Weights_Base_Second_Conv_INT8 : constant Natural :=
     Weights_Base_Second_Conv * 4;

   Weights_Base_Third_Conv      : constant Natural :=
     Weights_Base_Second_Conv + layer_8_conv2d_1_Weights_Words'Length;
   Weights_Base_Third_Conv_INT8 : constant Natural :=
     Weights_Base_Third_Conv * 4;

   Weights_Base_First_Dense      : constant Natural :=
     Weights_Base_Third_Conv + layer_13_conv2d_2_Weights_Words'Length;
   Weights_Base_First_Dense_INT8 : constant Natural :=
     Weights_Base_First_Dense * 4;

   Weights_Base_Second_Dense      : constant Natural :=
     Weights_Base_First_Dense + layer_24_dense_Weights_Words'Length;
   Weights_Base_Second_Dense_INT8 : constant Natural :=
     Weights_Base_Second_Dense * 4;

   Biases_Base_First_Conv   : constant Natural := 0;
   Biases_Base_Second_Conv  : constant Natural :=
     layer_3_conv2d_Bias_Words'Length;
   Biases_Base_Third_Conv   : constant Natural :=
     Biases_Base_Second_Conv + layer_8_conv2d_1_Bias_Words'Length;
   Biases_Base_First_Dense  : constant Natural :=
     Biases_Base_Third_Conv + layer_13_conv2d_2_Bias_Words'Length;
   Biases_Base_Second_Dense : constant Natural :=
     Biases_Base_First_Dense + layer_24_dense_Bias_Words'Length;

   --Find the largest probability label in the word array
   function Largest_Probability
     (Input_Word_Array : in Word_Array; Classes : Natural) return Natural
   is
      Best_Class : Natural := 0;
      Best_Prob  : Integer := Integer'First;
   begin
      for I in 0 .. Classes - 1 loop
         declare
            Q07_Prob : Unsigned_Byte;
            Prob     : Integer;
         begin
            Q07_Prob := Get_Byte_From_Tensor (Input_Word_Array, I);
            Prob := Q07_To_Int (Q07_Prob);
            if (Prob > Best_Prob) then
               Best_Prob := Prob;
               Best_Class := I;
            end if;
         end;
      end loop;
      return Best_Class;
   end Largest_Probability;
begin
   Set_Image_Resolution (100, 100);

   Wait_For_Camera_Streaming;

   write_i2c (Word (16#3103#), Word (16#11#));
   write_i2c (Word (16#3008#), Word (16#82#));
   write_i2c (Word (16#3008#), Word (16#42#));

   write_i2c (Word (16#3017#), Word (16#ff#));
   write_i2c (Word (16#3018#), Word (16#ff#));

   write_i2c (Word (16#3103#), Word (16#03#));
   write_i2c (Word (16#3034#), Word (16#1A#));
   write_i2c (Word (16#3035#), Word (16#21#));
   write_i2c (Word (16#3036#), Word (16#46#));
   write_i2c (Word (16#3037#), Word (16#13#));
   write_i2c (Word (16#3108#), Word (16#01#));
   write_i2c (Word (16#3824#), Word (16#02#));
   write_i2c (Word (16#460C#), Word (16#22#));
   write_i2c (Word (16#4837#), Word (16#22#));

   write_i2c (Word (16#4300#), Word (16#30#));
   write_i2c (Word (16#501F#), Word (16#00#));
   write_i2c (Word (16#4740#), Word (16#20#));

   write_i2c (Word (16#3503#), Word (16#00#));
   write_i2c (Word (16#3a00#), Word (16#38#));
   write_i2c (Word (16#5001#), Word (16#ff#)); --a3
   write_i2c (Word (16#5003#), Word (16#08#));

   --Brightness settings
   write_i2c (Word (16#5587#), Word (16#20#));
   write_i2c (Word (16#5580#), Word (16#04#));
   write_i2c (Word (16#5588#), Word (16#01#));

   write_i2c (Word (16#3a0f#), Word (16#50#));
   write_i2c (Word (16#3a10#), Word (16#48#));
   write_i2c (Word (16#3a1b#), Word (16#50#));
   write_i2c (Word (16#3a1e#), Word (16#48#));
   write_i2c (Word (16#3a11#), Word (16#90#));
   write_i2c (Word (16#3a1f#), Word (16#21#));

   write_i2c (Word (16#3800#), Word (16#00#));
   write_i2c (Word (16#3801#), Word (16#08#));
   write_i2c (Word (16#3802#), Word (16#00#));
   write_i2c (Word (16#3803#), Word (16#02#));

   write_i2c (Word (16#3804#), Word (16#0a#));
   write_i2c (Word (16#3805#), Word (16#37#));
   write_i2c (Word (16#3806#), Word (16#07#));
   write_i2c (Word (16#3807#), Word (16#a1#));

   write_i2c (Word (16#3808#), Word (16#00#));
   write_i2c (Word (16#3809#), Word (16#64#));  --32 for 50x50
   write_i2c (Word (16#380a#), Word (16#00#));
   write_i2c (Word (16#380b#), Word (16#64#));  --32 for 50x50

   write_i2c (Word (16#380c#), Word (16#06#));
   write_i2c (Word (16#380d#), Word (16#14#));
   write_i2c (Word (16#380e#), Word (16#03#));
   write_i2c (Word (16#380f#), Word (16#D8#));

   write_i2c (Word (16#3810#), Word (16#00#));
   write_i2c (Word (16#3811#), Word (16#04#));
   write_i2c (Word (16#3812#), Word (16#00#));
   write_i2c (Word (16#3813#), Word (16#02#));

   write_i2c (Word (16#3814#), Word (16#31#));
   write_i2c (Word (16#3815#), Word (16#31#));

   write_i2c (Word (16#3820#), Word (16#47#));
   write_i2c (Word (16#3821#), Word (16#01#));
   write_i2c (Word (16#503d#), Word (16#00#));
   write_i2c (Word (16#300e#), Word (16#58#));
   write_i2c (Word (16#3008#), Word (16#02#));

   --Print_Registers;
   Wait_For_Camera_Streaming;
   Start_Capturing_Image;

   Write_Words_In_B (layer_3_conv2d_Weights_Words);
   Write_Words_In_B (layer_8_conv2d_1_Weights_Words, Weights_Base_Second_Conv);
   Write_Words_In_B (layer_13_conv2d_2_Weights_Words, Weights_Base_Third_Conv);
   Write_Words_In_B (layer_24_dense_Weights_Words, Weights_Base_First_Dense);
   Write_Words_In_B
     (layer_28_dense_1_Weights_Words, Weights_Base_Second_Dense);

   Write_Words_In_C (layer_3_conv2d_Bias_Words);
   Write_Words_In_C (layer_8_conv2d_1_Bias_Words, Biases_Base_Second_Conv);
   Write_Words_In_C (layer_13_conv2d_2_Bias_Words, Biases_Base_Third_Conv);
   Write_Words_In_C (layer_24_dense_Bias_Words, Biases_Base_First_Dense);
   Write_Words_In_C (layer_28_dense_1_Bias_Words, Biases_Base_Second_Dense);
   --Put_Line (Word'Image(read));
   Put_Line ("Done writing weights");

   Wait_While_Camera_Busy;
   Read_Words_From_Image_Buffer (Image_Captured);
   Write_Words_In_A (Image_Captured);
   loop
      Total_Cycles := 0;
      Start_Cycles := Read_Cycle;
      Start_Capturing_Image;
      End_Cycles := Read_Cycle;
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;
      --Layer 1 AvgPool
      Start_Cycles := Read_Cycle;
      Apply_AvgPool_2x2_All_words (Image_Side_Len);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for AvgPool", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_First_AvgPool);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 2 Conv
      Start_Cycles := Read_Cycle;
      Apply_Conv2D_All_Words
        (N                                => Input_Len_First_Conv,
         Input_Channels                   =>
           Number_Of_Input_Channels_First_Conv,
         Filters                          =>
           Number_Of_Output_Channels_First_Conv,
         Weight_Base_Index                => Weights_Base_First_Conv,
         Bias_Base_Index                  => Biases_Base_First_Conv,
         Zero_Point                       => layer_3_conv2d_WZP,
         Quantized_Multiplier             =>
           layer_3_conv2d_Quantized_Multiplier,
         Quantized_Multiplier_Right_Shift =>
           layer_3_conv2d_Quantized_Right_Shift);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for First Conv = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_First_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 3 ReLU
      Start_Cycles := Read_Cycle;
      Apply_ReLU_All_Words (Total_Bytes_Produced_First_Conv, True);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for First ReLU = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_First_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 4 MaxPool
      Start_Cycles := Read_Cycle;
      Apply_MaxPool_Multi_Channel
        (Output_Len_First_Conv, Number_Of_Output_Channels_First_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for First MaxPool = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_First_MaxPool);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;
      --Layer 5 Conv

      Start_Cycles := Read_Cycle;
      Apply_Conv2D_All_Words
        (N                                => Input_Len_Second_Conv,
         Input_Channels                   =>
           Number_Of_Input_Channels_Second_Conv,
         Filters                          =>
           Number_Of_Output_Channels_Second_Conv,
         Weight_Base_Index                => Weights_Base_Second_Conv_INT8,
         Bias_Base_Index                  => Biases_Base_Second_Conv,
         Zero_Point                       => layer_8_conv2d_1_WZP,
         Quantized_Multiplier             =>
           layer_8_conv2d_1_Quantized_Multiplier,
         Quantized_Multiplier_Right_Shift =>
           layer_8_conv2d_1_Quantized_Right_Shift);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for Second Conv = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Second_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 6 ReLU
      Start_Cycles := Read_Cycle;
      Apply_ReLU_All_Words (Total_Bytes_Produced_Second_Conv, True);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for ReLU = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Second_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 7 MaxPool
      Start_Cycles := Read_Cycle;
      Apply_MaxPool_Multi_Channel
        (Output_Len_Second_Conv, Number_Of_Output_Channels_Second_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for Second MaxPool = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Second_MaxPool);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 8 Conv
      Start_Cycles := Read_Cycle;
      Apply_Conv2D_All_Words
        (N                                => Input_Len_Third_Conv,
         Input_Channels                   =>
           Number_Of_Input_Channels_Third_Conv,
         Filters                          =>
           Number_Of_Output_Channels_Third_Conv,
         Weight_Base_Index                => Weights_Base_Third_Conv_INT8,
         Bias_Base_Index                  => Biases_Base_Third_Conv,
         Zero_Point                       => layer_13_conv2d_2_WZP,
         Quantized_Multiplier             =>
           layer_13_conv2d_2_Quantized_Multiplier,
         Quantized_Multiplier_Right_Shift =>
           layer_13_conv2d_2_Quantized_Right_Shift);

      --  Print_Time ("Time for Third Conv = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Third_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 9 ReLU
      Start_Cycles := Read_Cycle;
      Apply_ReLU_All_Words (Total_Bytes_Produced_Third_Conv, True);
      --  Print_Time ("Time for ReLU = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Third_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 10 Maxpool
      Start_Cycles := Read_Cycle;
      Apply_MaxPool_Multi_Channel
        (Output_Len_Third_Conv, Number_Of_Output_Channels_Third_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for Third MaxPool = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Third_MaxPool);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 11 Maxpool
      Start_Cycles := Read_Cycle;
      Apply_MaxPool_Multi_Channel
        (Output_Len_Third_MaxPool, Number_Of_Output_Channels_Third_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for Fourth MaxPool = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Fourth_MaxPool);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 12 Maxpool
      Start_Cycles := Read_Cycle;
      Apply_MaxPool_Multi_Channel
        (Output_Len_Fourth_MaxPool, Number_Of_Output_Channels_Third_Conv);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for Fifth MaxPool = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Fifth_MaxPool);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 13 Dense
      Start_Cycles := Read_Cycle;
      Apply_Dense_All_Words
        (Inputs                           => Inputs_First_Dense,
         Neurons                          => Neurons_First_Dense,
         Weight_Base_Index                => Weights_Base_First_Dense_INT8,
         Bias_Base_Index                  => Biases_Base_First_Dense,
         Zero_Point                       => layer_24_dense_WZP,
         Quantized_Multiplier             =>
           layer_24_dense_Quantized_Multiplier,
         Quantized_Multiplier_Right_Shift =>
           layer_24_dense_Quantized_Right_Shift);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for First Dense = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Neurons_First_Dense_Words);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;
      --Layer 14 ReLU
      Apply_ReLU_All_Words (Neurons_First_Dense, True);

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Neurons_First_Dense_Words);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 15 Dense
      Start_Cycles := Read_Cycle;
      Apply_Dense_All_Words
        (Inputs                           => Neurons_First_Dense,
         Neurons                          => Neurons_Second_Dense,
         Weight_Base_Index                => Weights_Base_Second_Dense_INT8,
         Bias_Base_Index                  => Biases_Base_Second_Dense,
         Zero_Point                       => layer_28_dense_1_WZP,
         Quantized_Multiplier             =>
           layer_28_dense_1_Quantized_Multiplier,
         Quantized_Multiplier_Right_Shift =>
           layer_28_dense_1_Quantized_Right_Shift);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time for Second Dense = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Neurons_Second_Dense_Words);
      End_Cycles := Read_Cycle;
      --  Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 16 Softmax
      Start_Cycles := Read_Cycle;
      Apply_Softmax_All_Words (Neurons_Second_Dense, True);
      End_Cycles := Read_Cycle;
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Read_Words_From_R (Result_Tensor);
      End_Cycles := Read_Cycle;
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;
      --   Print_Vector_Q07
      --    (Name          => "Result",
      --     Data          => Result_Tensor,
      --     Vector_Length => Neurons_Second_Dense);

      Start_Cycles := Read_Cycle;
      Predicted_Label :=
        Largest_Probability (Result_Tensor, Neurons_Second_Dense);
      End_Cycles := Read_Cycle;
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;
      Put_Line ("Predicted Label = " & Natural'Image (Predicted_Label));
      --  Print_Time
      --   ("Time taken to select highest probability = ",
      --    End_Cycles - Start_Cycles);

      Start_Cycles := Read_Cycle;
      Wait_While_Camera_Busy;
      Read_Words_From_Image_Buffer (Image_Captured);
      Write_Words_In_A (Image_Captured);
      End_Cycles := Read_Cycle;
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;
      --  Print_Time ("Time taken to copy image to A = ", End_Cycles - Start_Cycles);

      --Print_Time ("Time taken this iteration:", Total_Cycles);

   end loop;
end Final_Integration_Test;
