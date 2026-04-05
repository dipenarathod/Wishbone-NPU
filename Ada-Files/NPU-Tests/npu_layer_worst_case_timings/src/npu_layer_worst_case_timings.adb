--  Worst-case (full-tensor / max-buffer) timing for each NPU op, independently.
--  Output is CSV-friendly for plotting (timing only).
--
--  BRAM limits (RTL tensor_operations_base): A/R 2500 words, B 9000, C 2000;
--  four INT8 values per 32-bit word.

with Input_Output_Helper;           use Input_Output_Helper;
with Input_Output_Helper.Utils;    use Input_Output_Helper.Utils;
with Input_Output_Helper.Time_Measurements;
use Input_Output_Helper.Time_Measurements;
with Wb_Npu_Helper;               use Wb_Npu_Helper;
with Wb_Npu_Helper.Activation;     use Wb_Npu_Helper.Activation;
with Wb_Npu_Helper.Pooling;       use Wb_Npu_Helper.Pooling;
with Wb_Npu_Helper.Dense;         use Wb_Npu_Helper.Dense;
with Wb_Npu_Helper.Conv2D;        use Wb_Npu_Helper.Conv2D;
with Interfaces;                   use Interfaces;
with Ada.Text_IO;                 use Ada.Text_IO;
with Ada.Strings.Fixed;            use Ada.Strings.Fixed;
with Ada.Strings;                  use Ada.Strings;
with Uart0;
with Runtime_Support;

procedure Npu_Layer_Worst_Case_Timings is

   Clock_Hz : constant Unsigned_64 := 72_000_000;

   --  Packed pattern: all lanes saturated positive (stress path similar to “full” tensor)
   Full_Positive_Word : constant Word := Word (16#7F7F_7F7F#);

   --  -------------------------------------------------------------------------
   --  Worst-case geometry (tune here for your bitstream / thesis table)
   --  -------------------------------------------------------------------------

   --  Square N×N activations / pooling: N^2 <= 10_000 elements (tensor A)
   Worst_Spatial_N : constant Natural := 100;

   --  Dense: maximize Inputs×Neurons with weight bytes Inputs×Neurons <= 36_000
   Worst_Dense_Inputs  : constant Natural := 3_600;
   Worst_Dense_Neurons : constant Natural := 10;

   --  Conv2D valid 3×3: chosen so A/B/R/C stay within BRAM (see comments below)
   Worst_Conv_N     : constant Natural := 14;
   Worst_Conv_Cin   : constant Natural := 51;
   Worst_Conv_Cout  : constant Natural := 69;

   --  If True, also print scaling rows for ReLU / MaxPool (like legacy timing script)
   Run_Dimension_Sweep : constant Boolean := True;

   Sweep_Dims : constant array (Natural range <>) of Natural :=
     (4, 8, 12, 16, 20, 24, 28, 50, 100);

   Quant_Mult  : constant Integer  := 16#4000_0000#;
   Right_Shift : constant Natural := 7;

   procedure Print_Csv_Header is
   begin
      Put_Line ("layer,params,cycles,us");
   end Print_Csv_Header;

   procedure Print_Csv_Row
     (Layer, Params : String; Cycles : Unsigned_64)
   is
      US : constant Unsigned_64 := (Cycles * 1_000_000) / Clock_Hz;
   begin
      Put_Line
        (Layer & "," & Params & "," & Trim (Unsigned_64'Image (Cycles), Both)
         & "," & Trim (Unsigned_64'Image (US), Both));
   end Print_Csv_Row;

   procedure Fill_A_Words (Num_Words : Natural; W : Word) is
   begin
      for I in 0 .. Num_Words - 1 loop
         Write_Word_In_A (I, W);
      end loop;
   end Fill_A_Words;

   procedure Fill_B_Words (Num_Words : Natural; W : Word) is
   begin
      for I in 0 .. Num_Words - 1 loop
         Write_Word_In_B (I, W);
      end loop;
   end Fill_B_Words;

   procedure Fill_C_Words (Num_Words : Natural; W : Word) is
   begin
      for I in 0 .. Num_Words - 1 loop
         Write_Word_In_C (I, W);
      end loop;
   end Fill_C_Words;

   procedure Time_ReLU_NxN (N : Natural) is
      Words       : constant Natural := Tensor_Words (N);
      T0, T1      : Unsigned_64;
   begin
      Fill_A_Words (Words, Full_Positive_Word);
      T0 := Read_Cycle;
      Apply_ReLU_All_Words (N);
      T1 := Read_Cycle;
      Print_Csv_Row ("ReLU", "N=" & Trim (Natural'Image (N), Both), T1 - T0);
   end Time_ReLU_NxN;

   procedure Time_Sigmoid_NxN (N : Natural) is
      Words  : constant Natural := Tensor_Words (N);
      T0, T1 : Unsigned_64;
   begin
      Fill_A_Words (Words, Full_Positive_Word);
      T0 := Read_Cycle;
      Apply_Sigmoid_All_Words (N);
      T1 := Read_Cycle;
      Print_Csv_Row ("Sigmoid", "N=" & Trim (Natural'Image (N), Both), T1 - T0);
   end Time_Sigmoid_NxN;

   procedure Time_Softmax_NxN (N : Natural) is
      Words  : constant Natural := Tensor_Words (N);
      T0, T1 : Unsigned_64;
   begin
      Fill_A_Words (Words, Full_Positive_Word);
      T0 := Read_Cycle;
      Apply_Softmax_All_Words (N);
      T1 := Read_Cycle;
      Print_Csv_Row
        ("Softmax",
         "N="
         & Trim (Natural'Image (N), Both)
         & " (HW exp+div + Ada sum)",
         T1 - T0);
   end Time_Softmax_NxN;

   procedure Time_MaxPool_NxN (N : Natural) is
      Words  : constant Natural := Tensor_Words (N);
      T0, T1 : Unsigned_64;
   begin
      Fill_A_Words (Words, Full_Positive_Word);
      T0 := Read_Cycle;
      Apply_MaxPool_2x2_All_Words (N);
      T1 := Read_Cycle;
      Print_Csv_Row ("MaxPool2x2", "N=" & Trim (Natural'Image (N), Both), T1 - T0);
   end Time_MaxPool_NxN;

   procedure Time_AvgPool_NxN (N : Natural) is
      Words  : constant Natural := Tensor_Words (N);
      T0, T1 : Unsigned_64;
   begin
      Fill_A_Words (Words, Full_Positive_Word);
      T0 := Read_Cycle;
      Apply_AvgPool_2x2_All_Words (N);
      T1 := Read_Cycle;
      Print_Csv_Row ("AvgPool2x2", "N=" & Trim (Natural'Image (N), Both), T1 - T0);
   end Time_AvgPool_NxN;

   procedure Time_Dense
     (Inputs : Natural; Neurons : Natural; Tag : String)
   is
      Weight_Elements : constant Natural := Inputs * Neurons;
      Words_A         : constant Natural :=
        Tensor_Words (Inputs, One_Dimensional => True);
      Words_B         : constant Natural :=
        Tensor_Words (Weight_Elements, One_Dimensional => True);
      T0, T1          : Unsigned_64;
   begin
      Fill_A_Words (Words_A, Full_Positive_Word);
      Fill_B_Words (Words_B, Full_Positive_Word);
      for I in 0 .. Neurons - 1 loop
         Write_Word_In_C (I, 0);
      end loop;

      T0 := Read_Cycle;
      Apply_Dense_All_Words
        (Inputs                           => Inputs,
         Neurons                          => Neurons,
         Weight_Base_Index                => 0,
         Bias_Base_Index                  => 0,
         Zero_Point                       => 0,
         Quantized_Multiplier             => Quant_Mult,
         Quantized_Multiplier_Right_Shift => Right_Shift);
      T1 := Read_Cycle;
      Print_Csv_Row ("Dense", Tag, T1 - T0);
   end Time_Dense;

   procedure Time_Conv2D
     (N : Natural; Cin : Natural; Cout : Natural; Tag : String)
   is
      In_Els  : constant Natural := Cin * N * N;
      Wt_Els  : constant Natural := 9 * Cin * Cout;
      Words_A   : constant Natural :=
        Tensor_Words (In_Els, One_Dimensional => True);
      Words_B   : constant Natural :=
        Tensor_Words (Wt_Els, One_Dimensional => True);
      T0, T1    : Unsigned_64;
   begin
      Fill_A_Words (Words_A, Full_Positive_Word);
      Fill_B_Words (Words_B, Full_Positive_Word);
      for F in 0 .. Cout - 1 loop
         Write_Word_In_C (F, 0);
      end loop;

      T0 := Read_Cycle;
      Apply_Conv2D_All_Words
        (N                                => N,
         Input_Channels                   => Cin,
         Filters                          => Cout,
         Weight_Base_Index                => 0,
         Bias_Base_Index                  => 0,
         Zero_Point                       => 0,
         Quantized_Multiplier             => Quant_Mult,
         Quantized_Multiplier_Right_Shift => Right_Shift);
      T1 := Read_Cycle;
      Print_Csv_Row ("Conv2D", Tag, T1 - T0);
   end Time_Conv2D;

   procedure Run_Worst_Case_Block is
   begin
      Put_Line ("-- worst_case_full_buffer --");
      Print_Csv_Header;

      Time_ReLU_NxN (Worst_Spatial_N);
      Time_Sigmoid_NxN (Worst_Spatial_N);
      Time_Softmax_NxN (Worst_Spatial_N);
      Time_MaxPool_NxN (Worst_Spatial_N);
      Time_AvgPool_NxN (Worst_Spatial_N);

      Time_Dense
        (Worst_Dense_Inputs,
         Worst_Dense_Neurons,
         "in="
         & Trim (Natural'Image (Worst_Dense_Inputs), Both)
         & " out="
         & Trim (Natural'Image (Worst_Dense_Neurons), Both)
         & " macs="
         & Trim (Natural'Image (Worst_Dense_Inputs * Worst_Dense_Neurons), Both));

      Time_Conv2D
        (Worst_Conv_N,
         Worst_Conv_Cin,
         Worst_Conv_Cout,
         "N="
         & Trim (Natural'Image (Worst_Conv_N), Both)
         & " cin="
         & Trim (Natural'Image (Worst_Conv_Cin), Both)
         & " cout="
         & Trim (Natural'Image (Worst_Conv_Cout), Both)
         & " macs="
         & Trim
           (Natural'Image
              (9 * Worst_Conv_Cin * Worst_Conv_Cout
               * (Worst_Conv_N - 2)
               * (Worst_Conv_N - 2)),
            Both));
   end Run_Worst_Case_Block;

   procedure Run_Scaling_Sweep is
   begin
      Put_Line ("-- spatial_sweep_ReLU_MaxPool --");
      Print_Csv_Header;
      for D of Sweep_Dims loop
         Time_ReLU_NxN (D);
         Time_MaxPool_NxN (D);
      end loop;
   end Run_Scaling_Sweep;

begin
   Uart0.Init (19200);
   Put_Line ("NPU layer worst-case timings (CSV). Clock_Hz=" & Unsigned_64'Image (Clock_Hz));
   Put_Line
     ("AvgPool cost model matches MaxPool in HW; Sigmoid ~ ReLU element cost.");

   Run_Worst_Case_Block;

   if Run_Dimension_Sweep then
      New_Line;
      Run_Scaling_Sweep;
   end if;

   Put_Line ("done");
   loop
      null;
   end loop;
end Npu_Layer_Worst_Case_Timings;
