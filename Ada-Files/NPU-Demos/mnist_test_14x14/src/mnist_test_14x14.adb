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

with tensors_mnist_14x14_words; use tensors_mnist_14x14_words;
with mnist_train_samples_14x14; use mnist_train_samples_14x14;

procedure mnist_test_14x14 is

   Tensor_A_Words : Natural := Tensor_Words (Samples (0)'Length, True);
   Tensor_A       : Word_Array (0 .. Tensor_A_Words - 1);

   --Model: 196 length image (14x14 = 196) -> Dense(32 neurons) -> ReLU -> Dense(10 neurons) -> SoftMax -> Classify
   Inputs_First_Dense   : constant Natural :=
     196;   --Inputs to first dense layer
   Neurons_First_Dense  : constant Natural :=
     32;    --Neurons in first dense layer
   Inputs_Second_Dense  : constant Natural :=
     32;    --Inputs to second dense layer
   Neurons_Second_Dense : constant Natural :=
     10;    --Neurons in second dense layer

   --Weight indexing for Apply_Dense_All_Words:
   Weights_Base_First_Dense : constant Natural := 0;
   Biases_Base_First_Dense  : constant Natural :=
     0;      --bias in C is in words

   Weights_Base_Second_Dense : constant Natural :=
     Inputs_First_Dense
     * Neurons_First_Dense;  --196*32 = 6272 bytes of weights
   Biases_Base_Second_Dense  : constant Natural :=
     Neurons_First_Dense;            --biases start at 32. Since biases are words, we need not divide by 4 to get the correct tensor index

   --Word offset into B for writing layer 1 weights = total weights/4. Bytes/4 gives the tensor word array index
   Weights_Word_Offset_For_Base_Second_Dense : constant Natural :=
     Weights_Base_Second_Dense / 4;  --1568

   Neurons_First_Dense_Words  : constant Natural :=
     Tensor_Words
       (Neurons_First_Dense, One_Dimensional => True); --(32+3)/4 = 8
   Neurons_Second_Dense_Words : constant Natural :=
     Tensor_Words
       (Neurons_Second_Dense, One_Dimensional => True); --(10+3)/4 = 3

   Neurons_First_Dense_Word_Array  :
     Word_Array (0 .. Neurons_First_Dense_Words - 1) := (others => 0);
   Neurons_Second_Dense_Word_Array :
     Word_Array (0 .. Neurons_Second_Dense_Words - 1) := (others => 0);

   Predicted_Label          : Natural;
   Matches                  : Natural;
   Total_Samples            : constant Natural := Labels'Length;
   Accuracy                 : Float;
   Clock_Hz                 : constant Unsigned_64 := 72_000_000;
   Start_Cycles             : Unsigned_64;
   End_Cycles               : Unsigned_64;
   Delta_Cycles             : Unsigned_64;
   Weight_Bias_Write_Cycles : Unsigned_64;
   Total_Cycles             : Unsigned_64;

   Best_Total_Cycles  : Unsigned_64 := Unsigned_64'Last;
   Worst_Total_Cycles : Unsigned_64 := 0;
   Sum_Total_Cycles   : Unsigned_64 := 0;
   Best_Sample_Index  : Natural := 0;
   Worst_Sample_Index : Natural := 0;
   Stage_Cycles       : Unsigned_64;

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
   Uart0.Init (19200);
   Put_Line ("MNIST 14x14 test starting");

   --Load weights into tensor B: dense layer 1 at 0, dense layer 2 at offset
   Start_Cycles := Read_Cycle;
   Write_Words_In_B (layer_0_dense_Weights_Words);
   Write_Words_In_B
     (layer_1_dense_1_Weights_Words,
      Weights_Word_Offset_For_Base_Second_Dense);

   --Load biases into tensor C: dense layer 1 at 0, dense layer 2 at offset
   Write_Words_In_C (layer_0_dense_Bias_Words);
   Write_Words_In_C (layer_1_dense_1_Bias_Words, Biases_Base_Second_Dense);

   End_Cycles := Read_Cycle;
   Print_Time
     ("Time taken to write weights and biases to B and C = ",
      End_Cycles - Start_Cycles);

   Weight_Bias_Write_Cycles := End_Cycles - Start_Cycles;

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
         Print_Time
           ("Time taken to write image to A after conversion = ",
            End_Cycles - Start_Cycles);

         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Start_Cycles := Read_Cycle;
         Apply_Dense_All_Words
           (Inputs                           => Inputs_First_Dense,
            Neurons                          => Neurons_First_Dense,
            Weight_Base_Index                => Weights_Base_First_Dense,
            Bias_Base_Index                  => Biases_Base_First_Dense,
            Zero_Point                       => layer_0_dense_WZP,
            Quantized_Multiplier             =>
              layer_0_dense_Quantized_Multiplier,
            Quantized_Multiplier_Right_Shift =>
              Natural (layer_0_dense_Quantized_Right_Shift));

         End_Cycles := Read_Cycle;
         Print_Time
           ("Time take for Dense First Layer = ", End_Cycles - Start_Cycles);

         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Start_Cycles := Read_Cycle;
         --Read_Words_From_R (Neurons_First_Dense_Word_Array);
         --Write_Words_In_A (Neurons_First_Dense_Word_Array);
         Copy_Result_To_Input (Neurons_First_Dense_Words);
         End_Cycles := Read_Cycle;
         Print_Time
           ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Start_Cycles := Read_Cycle;
         Apply_ReLU_All_Words (Neurons_First_Dense, One_Dimensional => True);
         End_Cycles := Read_Cycle;
         Print_Time ("Time taken for ReLU = ", End_Cycles - Start_Cycles);

         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Start_Cycles := Read_Cycle;
         --Read_Words_From_R (Neurons_First_Dense_Word_Array);
         --Write_Words_In_A (Neurons_First_Dense_Word_Array);
         Copy_Result_To_Input (Neurons_First_Dense_Words);
         End_Cycles := Read_Cycle;
         Print_Time
           ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Start_Cycles := Read_Cycle;
         Apply_Dense_All_Words
           (Inputs                           => Inputs_Second_Dense,
            Neurons                          => Neurons_Second_Dense,
            Weight_Base_Index                => Weights_Base_Second_Dense,
            Bias_Base_Index                  => Biases_Base_Second_Dense,
            Zero_Point                       => layer_1_dense_1_WZP,
            Quantized_Multiplier             =>
              layer_1_dense_1_Quantized_Multiplier,
            Quantized_Multiplier_Right_Shift =>
              Natural (layer_1_dense_1_Quantized_Right_Shift));

         End_Cycles := Read_Cycle;
         Print_Time
           ("Time take for Second dense layer = ", End_Cycles - Start_Cycles);

         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Start_Cycles := Read_Cycle;
         --Read_Words_From_R (Neurons_First_Dense_Word_Array);
         --Write_Words_In_A (Neurons_First_Dense_Word_Array);
         Copy_Result_To_Input (Neurons_First_Dense_Words);
         End_Cycles := Read_Cycle;
         Print_Time
           ("Time taken to copy R to A = ", End_Cycles - Start_Cycles);

         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Start_Cycles := Read_Cycle;
         Apply_SoftMax_All_Words
           (Neurons_Second_Dense, One_Dimensional => True);
         End_Cycles := Read_Cycle;
         Print_Time ("Time taken for SoftMax = ", End_Cycles - Start_Cycles);

         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Start_Cycles := Read_Cycle;
         Read_Words_From_R (Neurons_Second_Dense_Word_Array);
         End_Cycles := Read_Cycle;
         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Put_Line ("Probabilities:");
         for I in 0 .. Neurons_Second_Dense - 1 loop
            declare
               B : constant Unsigned_Byte :=
                 Get_Byte_From_Tensor (Neurons_Second_Dense_Word_Array, I);
            begin
               Put_Line
                 (Natural'Image (I) & " = " & Float'Image (Q07_To_Float (B)));
            end;
         end loop;

         Start_Cycles := Read_Cycle;
         Predicted_Label :=
           Largest_Probability
             (Neurons_Second_Dense_Word_Array, Neurons_Second_Dense);
         End_Cycles := Read_Cycle;
         Total_Cycles := Total_Cycles + End_Cycles - Start_Cycles;

         Put_Line ("Predicted Label: " & Natural'Image (Predicted_Label));
         if (Labels (S) = Predicted_Label) then
            Put_Line ("Matched");
            Matches := Matches + 1;
         else
            Put_Line ("Failed");
         end if;
         Print_Time ("Time taken this iteration = ", Total_Cycles);

         Sum_Total_Cycles := Sum_Total_Cycles + Total_Cycles;

         if Total_Cycles < Best_Total_Cycles then
            Best_Total_Cycles := Total_Cycles;
            Best_Sample_Index := S;
         end if;

         if Total_Cycles > Worst_Total_Cycles then
            Worst_Total_Cycles := Total_Cycles;
            Worst_Sample_Index := S;
         end if;

      end;
   end loop;
   Put_Line ("--------------------------------");
   Put_Line ("Total Matches = " & Natural'Image (Matches));
   Accuracy := Float (Matches) / Float (Total_Samples);
   Put_Line ("Accuracy = " & Float'Image (Accuracy));
   Put_Line ("Done");

   Put_Line ("--------------------------------");
   Put_Line ("Timing Summary Across All 28x28 Samples");
   Print_Time ("Best-case total inference time = ", Best_Total_Cycles);
   Put_Line
     ("Best-case sample index = "
      & Natural'Image (Best_Sample_Index)
      & ", label = "
      & Integer'Image (Labels (Best_Sample_Index)));
   Print_Time ("Worst-case total inference time = ", Worst_Total_Cycles);
   Put_Line
     ("Worst-case sample index = "
      & Natural'Image (Worst_Sample_Index)
      & ", label = "
      & Integer'Image (Labels (Worst_Sample_Index)));
   Print_Time
     ("Average total inference time = ",
      Sum_Total_Cycles / Unsigned_64 (Total_Samples));
   Put_Line ("Done");
   loop
      null;
   end loop;
end mnist_test_14x14;
