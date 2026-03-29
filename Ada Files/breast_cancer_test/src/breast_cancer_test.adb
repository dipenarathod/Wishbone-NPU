with Input_Output_Helper;                   use Input_Output_Helper;
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
--with Ada.Real_Time;  use Ada.Real_Time;
with System.Machine_Code;                   use System.Machine_Code;

with breast_cancer_test_samples; use breast_cancer_test_samples;
with breast_cancer_test_weights;       use breast_cancer_test_weights;

procedure Breast_Cancer_Test is

  Tensor_A_Words                   : Natural :=
   Tensor_Words (Samples (0)'Length, True);
  Tensor_A                         : Word_Array (0 .. Tensor_A_Words - 1);

  Accuracy                         : Float;
  Matches                          : Natural := 0;
  Total_Samples                    : constant Natural := Labels'Length;
  Start_Cycles                     : Unsigned_64;
  End_Cycles                       : Unsigned_64;
  Delta_Cycles                     : Unsigned_64;
  Weight_Bias_Write_Cycles         : Unsigned_64;
  Total_Cycles                     : Unsigned_64;

  Best_Total_Cycles        : Unsigned_64 := Unsigned_64'Last;
  Worst_Total_Cycles       : Unsigned_64 := 0;
  Sum_Total_Cycles         : Unsigned_64 := 0;
  Best_Sample_Index        : Natural := 0;
  Worst_Sample_Index       : Natural := 0;
  Stage_Cycles             : Unsigned_64;

  --Model: 30 inputs -> Dense(64 neurons) -> ReLU -> Dense(32 neurons) -> ReLU -> Dense(16 neurons) -> ReLU -> Dense(1 neuron) -> Sigmoid -> Classify
  Inputs_First_Dense               : constant Natural :=
   30;   --Inputs to first dense layer
  Neurons_First_Dense              : constant Natural :=
   64;    --Neurons in first dense layer
  Total_Words_Produced_First_Dense : constant Natural :=
   Tensor_Words (Neurons_First_Dense, True);
  Total_Bytes_Produced_First_Dense : constant Natural :=
   Total_Words_Produced_First_Dense * 4;

  Inputs_Second_Dense               : constant Natural :=
   Neurons_First_Dense;    --Inputs to second dense layer
  Neurons_Second_Dense              : constant Natural :=
   32;    --Neurons in second dense layer
  Total_Words_Produced_Second_Dense : constant Natural :=
   Tensor_Words (Neurons_Second_Dense, True);
  Total_Bytes_Produced_Second_Dense : constant Natural :=
   Total_Words_Produced_Second_Dense * 4;

  Inputs_Third_Dense               : constant Natural :=
   Neurons_Second_Dense;    --Inputs to third dense layer
  Neurons_Third_Dense              : constant Natural :=
   16;    --Neurons in third dense layer
  Total_Words_Produced_Third_Dense : constant Natural :=
   Tensor_Words (Neurons_Third_Dense, True);
  Total_Bytes_Produced_Third_Dense : constant Natural :=
   Total_Words_Produced_Third_Dense * 4;

  Inputs_Fourth_Dense               : constant Natural :=
   Neurons_Third_Dense;    --Inputs to fourth dense layer
  Neurons_Fourth_Dense              : constant Natural :=
   1;    --Neurons in fourth dense layer
  Total_Words_Produced_Fourth_Dense : constant Natural :=
   Tensor_Words (Neurons_Fourth_Dense, True);

  Result_Dense_Tensor      :
   Word_Array (0 .. Total_Words_Produced_Fourth_Dense - 1);
  Result_Unsigned_Byte     : Unsigned_Byte;
  Result_Byte              : Integer;
  --Weights and biases offset
  Weights_Base_First_Dense : constant Natural := 0;

  Weights_Base_Second_Dense      : constant Natural :=
   Weights_Base_First_Dense + layer_0_dense_Weights_Words'Length;
  Weights_Base_Second_Dense_INT8 : constant Natural :=
   Weights_Base_Second_Dense * 4;

  Weights_Base_Third_Dense      : constant Natural :=
   Weights_Base_Second_Dense + layer_3_dense_1_Weights_Words'Length;
  Weights_Base_Third_Dense_INT8 : constant Natural :=
   Weights_Base_Third_Dense * 4;

  Weights_Base_Fourth_Dense      : constant Natural :=
   Weights_Base_Third_Dense + layer_6_dense_2_Weights_Words'Length;
  Weights_Base_Fourth_Dense_INT8 : constant Natural :=
   Weights_Base_Fourth_Dense * 4;

  Biases_Base_First_Dense  : constant Natural := 0;
  Biases_Base_Second_Dense : constant Natural :=
   Biases_Base_First_Dense + layer_0_dense_Bias_Words'Length;
  Biases_Base_Third_Dense  : constant Natural :=
   Biases_Base_Second_Dense + layer_3_dense_1_Bias_Words'Length;
  Biases_Base_Fourth_Dense : constant Natural :=
   Biases_Base_Third_Dense + layer_6_dense_2_Bias_Words'Length;

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

  Write_Words_In_B (layer_0_dense_Weights_Words);
  Write_Words_In_B (layer_3_dense_1_Weights_Words, Weights_Base_Second_Dense);
  Write_Words_In_B (layer_6_dense_2_Weights_Words, Weights_Base_Third_Dense);
  Write_Words_In_B (layer_9_dense_3_Weights_Words, Weights_Base_Fourth_Dense);

  Write_Words_In_C (layer_0_dense_Bias_Words);
  Write_Words_In_C (layer_3_dense_1_Bias_Words, Biases_Base_Second_Dense);
  Write_Words_In_C (layer_6_dense_2_Bias_Words, Biases_Base_Third_Dense);
  Write_Words_In_C (layer_9_dense_3_Bias_Words, Biases_Base_Fourth_Dense);

  for S in Samples'Range loop
    --Try inference on all samples
    declare
      Pred : Natural;
    begin
      Put_Line ("--------------------------------");
      Put_Line
       ("Sample"
        & Natural'Image (S)
        & " expected = "
        & Integer'Image (Labels (S)));
      Total_Cycles := 0;

      Start_Cycles := Read_Cycle;
      Create_Word_Array_From_Integer_Array (Samples (S), Tensor_A);
      Write_Words_In_A (Tensor_A);
      End_Cycles := Read_Cycle;
      --  Read_Words_From_A (Tensor_A);
      --  Print_Tensor_Q07 (Name => "A:", Data => Tensor_A, Dimension => 28);
      Print_Time
       ("Time taken to write image to A after conversion = ",
        End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      --Layer 1 Dense
      Start_Cycles := Read_Cycle;
      Apply_Dense_All_Words
       (Inputs                           => Inputs_First_Dense,
        Neurons                          => Neurons_First_Dense,
        Weight_Base_Index                => 0,
        Bias_Base_Index                  => 0,
        Zero_Point                       => layer_0_dense_WZP,
        Quantized_Multiplier             => layer_0_dense_Quantized_Multiplier,
        Quantized_Multiplier_Right_Shift =>
         layer_0_dense_Quantized_Right_Shift);

      End_Cycles := Read_Cycle;
      Print_Time
       ("Time take for First Dense Layer = ", End_Cycles - Start_Cycles);

      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_First_Dense);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

      --Layer 2 ReLU
      Start_Cycles := Read_Cycle;
      Apply_ReLU_All_Words
       (Total_Bytes_Produced_First_Dense, One_Dimensional => True);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken for ReLU = ", End_Cycles - Start_Cycles);

      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_First_Dense);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

      --Layer 3 Dense
      Start_Cycles := Read_Cycle;
      Apply_Dense_All_Words
       (Inputs                           => Inputs_Second_Dense,
        Neurons                          => Neurons_Second_Dense,
        Weight_Base_Index                => Weights_Base_Second_Dense_INT8,
        Bias_Base_Index                  => Biases_Base_Second_Dense,
        Zero_Point                       => layer_3_dense_1_WZP,
        Quantized_Multiplier             =>
         layer_3_dense_1_Quantized_Multiplier,
        Quantized_Multiplier_Right_Shift =>
         layer_3_dense_1_Quantized_Right_Shift);

      End_Cycles := Read_Cycle;
      Print_Time
       ("Time take for Second Dense Layer = ", End_Cycles - Start_Cycles);

      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_First_Dense);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

      --Layer 4 ReLU
      Start_Cycles := Read_Cycle;
      Apply_ReLU_All_Words
       (Total_Bytes_Produced_Second_Dense, One_Dimensional => True);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken for ReLU = ", End_Cycles - Start_Cycles);

      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Second_Dense);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

      --Layer 5 Dense
      Start_Cycles := Read_Cycle;
      Apply_Dense_All_Words
       (Inputs                           => Inputs_Third_Dense,
        Neurons                          => Neurons_Third_Dense,
        Weight_Base_Index                => Weights_Base_Third_Dense_INT8,
        Bias_Base_Index                  => Biases_Base_Third_Dense,
        Zero_Point                       => layer_6_dense_2_WZP,
        Quantized_Multiplier             =>
         layer_6_dense_2_Quantized_Multiplier,
        Quantized_Multiplier_Right_Shift =>
         layer_6_dense_2_Quantized_Right_Shift);

      End_Cycles := Read_Cycle;
      Print_Time
       ("Time take for Third Dense Layer = ", End_Cycles - Start_Cycles);

      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Third_Dense);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

      --Layer 6 ReLU
      Start_Cycles := Read_Cycle;
      Apply_ReLU_All_Words
       (Total_Bytes_Produced_Third_Dense, One_Dimensional => True);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken for ReLU = ", End_Cycles - Start_Cycles);

      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Third_Dense);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

      --Layer 7 Dense
      Start_Cycles := Read_Cycle;
      Apply_Dense_All_Words
       (Inputs                           => Inputs_Fourth_Dense,
        Neurons                          => Neurons_Fourth_Dense,
        Weight_Base_Index                => Weights_Base_Fourth_Dense_INT8,
        Bias_Base_Index                  => Biases_Base_Fourth_Dense,
        Zero_Point                       => layer_9_dense_3_WZP,
        Quantized_Multiplier             =>
         layer_9_dense_3_Quantized_Multiplier,
        Quantized_Multiplier_Right_Shift =>
         layer_9_dense_3_Quantized_Right_Shift);

      End_Cycles := Read_Cycle;
      Print_Time
       ("Time take for Fourth Dense Layer = ", End_Cycles - Start_Cycles);

      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Copy_Result_To_Input (Total_Words_Produced_Fourth_Dense);
      End_Cycles := Read_Cycle;
      Print_Time ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

      --Layer 8 Sigmoid
      Start_Cycles := Read_Cycle;
      Apply_Sigmoid_All_Words (1, True);
      End_Cycles := Read_Cycle;
      Print_Time ("Time take for Sigmoid Layer = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Read_Words_From_R (Result_Dense_Tensor);
      End_Cycles := Read_Cycle;
      Print_Time
       ("Time taken to Read R to predict label = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Start_Cycles := Read_Cycle;
      Result_Unsigned_Byte :=
       Unpack_Byte_At_Index (Result_Dense_Tensor (0), 0);
      Result_Byte := Q07_To_Int (Result_Unsigned_Byte);

      if (Result_Byte >= 64) then
        Pred := 1;
      else
        Pred := 0;
      end if;
      End_Cycles := Read_Cycle;

      Print_Time
       ("Time taken to make prediction = ", End_Cycles - Start_Cycles);
      Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

      Put_Line ("Predicted Label: " & Natural'Image (Pred));

      if (Pred = Labels (S)) then
        Matches := Matches + 1;
      end if;

      Sum_Total_Cycles := Sum_Total_Cycles + Total_Cycles;

      if (Total_Cycles < Best_Total_Cycles) then
        Best_Total_Cycles := Total_Cycles;
        Best_Sample_Index := S;
      end if;

      if (Total_Cycles > Worst_Total_Cycles) then
        Worst_Total_Cycles := Total_Cycles;
        Worst_Sample_Index := S;
      end if;

    end;
  end loop;

  Put_Line ("--------------------------------");
  Put_Line ("Total Matches = " & Natural'Image (Matches));
  Accuracy := Float (Matches) / Float (Total_Samples);
  Put_Line ("Accuracy = " & Float'Image (Accuracy));
  Put_Line ("--------------------------------");
  Put_Line ("Timing Summary Across All Test Samples");
  Print_Time ("Best-case total inference time = ", Best_Total_Cycles);
  Put_Line ("Best-case sample index = " & Natural'Image (Best_Sample_Index) & ", label = " & Integer'Image (Labels (Best_Sample_Index)));
  Print_Time ("Worst-case total inference time = ", Worst_Total_Cycles);
  Put_Line ("Worst-case sample index = " & Natural'Image (Worst_Sample_Index) & ", label = " & Integer'Image (Labels (Worst_Sample_Index)));
  Print_Time ("Average total inference time = ", Sum_Total_Cycles / Unsigned_64 (Total_Samples));
  Put_Line ("Done");

  loop
    null;
  end loop;
end Breast_Cancer_Test;
