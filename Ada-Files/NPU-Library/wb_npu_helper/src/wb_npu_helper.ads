with Interfaces;
with System;
with input_output_helper; use input_output_helper;
with input_output_helper; use input_output_helper;

package Wb_Npu_Helper is

   --Opcodes
   --00 and 01 are reserved for add/sub, which are not used
   OP_MAX     : constant Word := 16#02#; --Max pooling
   OP_AVG     : constant Word := 16#03#; --Average pooling
   OP_SIG     : constant Word := 16#04#; --Sigmoid activation
   OP_RELU    : constant Word := 16#05#; --ReLU activation
   OP_SOFTMAX : constant Word :=
     16#06#; --Softmax (mode flag controls EXP vs DIV)

   OP_DENSE           : constant Word := 16#07#; --Dense
   OP_CONV2D          : constant Word := 16#08#;
   OP_COPY_R_TO_A     : constant Word := 30; --NOP
   OP_NOP             : constant Word := 31; --NOP
   MAX_ALLOWED_OPCODE : constant Word := 31;  --Largest opcode possible

   --Softmax mode values
   SOFTMAX_MODE_EXP : constant Word := 0; --Exponent phase
   SOFTMAX_MODE_DIV : constant Word := 1; --Division phase

   --CTRL/STATUS bit masks
   Perform_Bit  : constant Word := 1;      --CTRL[0]
   Opcode_Shift : constant Natural :=
     1;   --Bits to shift to place an opcode in CTRL[5:1] = 1
   Busy_Mask    : constant Word := 1;      --STATUS[0] = 0b1
   Done_Mask    : constant Word := 2;      --STATUS[1] = 0b10

   --Register setters
   procedure Set_Dim (N : Natural); --N in LSB 8 bits
   procedure Set_Pool_Base_Index (Index : Natural); --pooling index in A
   procedure Set_Out_Index (Index : Natural); --index in R
   procedure Set_Word_Index (Index : Natural);
   procedure Set_Softmax_Mode (Mode : Word);  --Set softmax mode (0=EXP, 1=DIV)
   procedure Set_Sum_Param
     (Sum : Word);      --Set sum parameter for softmax DIV phase
   procedure Set_Weight_Base_Index
     (Index :
        Natural); --Set the base index in B (for from when the weights of this layer begin)
   procedure Set_Bias_Base_Index
     (Index :
        Natural); --Set the bias index in C (for from when the weights of this layer begin)
   procedure Set_N_Inputs
     (N :
        Natural); --Set number of inputs for the dense layer (or input channels for the conv layer)
   --  procedure Set_Scale_Register
   --    (Scale : Natural); --Set scale for requantization
   procedure Set_Zero_Point
     (Zero_Point : Integer); --Set zero point for requantization
   procedure Set_Quantized_Multiplier_Register
     (Multiplier : Integer); --Set quantized multiplier for requantization
   procedure Set_Quantized_Multiplier_Right_Shift_Register
     (Right_Shift :
        Natural); --Set right shift for quantized multiplier for requantization
   procedure Set_N_Outputs
     (N : Natural); --Dense: Number of neurons. Conv: Set number of filters
   procedure Set_Words_To_Copy_From_R_To_A (Words_To_Copy : Natural); --Set words to copy from R to A

   --Operation control
   procedure Perform_Op (Opcode : Word);
   procedure Perform_Max_Pool;
   procedure Perform_Avg_Pool;
   procedure Perform_Sigmoid;
   procedure Perform_ReLU;
   procedure Perform_Softmax;
   procedure Perform_Dense;
   procedure Perform_Conv2D;
   procedure Perform_Copy_R_To_A;

   function Is_Busy return Boolean;
   function Is_Done return Boolean;
   procedure Wait_While_Busy;
   --procedure Wait_Until_Done;

   procedure Write_Word_In_A (Index : Natural; Value : Word);
   procedure Write_Words_In_A
     (Src : in Word_Array; Start_Index : Natural := 0);

   function Read_Word_From_A (Index : Natural) return Word;
   procedure Read_Words_From_A
     (Dest : out Word_Array; Start_Index : Natural := 0);

   procedure Write_Word_In_B (Index : Natural; Value : Word);
   procedure Write_Words_In_B
     (Src : in Word_Array; Start_Index : Natural := 0);

   function Read_Word_From_B (Index : Natural) return Word;
   procedure Read_Words_From_B
     (Dest : out Word_Array; Start_Index : Natural := 0);

   procedure Write_Word_In_C (Index : Natural; Value : Word);
   procedure Write_Words_In_C
     (Src : in Word_Array; Start_Index : Natural := 0);

   function Read_Word_From_C (Index : Natural) return Word;
   procedure Read_Words_From_C
     (Dest : out Word_Array; Start_Index : Natural := 0);

   function Read_Word_From_R (Index : Natural) return Word;
   procedure Read_Words_From_R
     (Dest : out Word_Array; Start_Index : Natural := 0);

   procedure Copy_Result_To_Input (Words_To_Copy : Natural);

   --Pragmas
   pragma Inline (Set_Dim);
   pragma Inline (Set_Pool_Base_Index);
   pragma Inline (Set_Out_Index);
   pragma Inline (Set_Word_Index);
   pragma Inline (Set_Softmax_Mode);
   pragma Inline (Set_Sum_Param);
   pragma Inline (Set_Weight_Base_Index);
   pragma Inline (Set_Bias_Base_Index);
   pragma Inline (Set_N_Inputs);
   --pragma Inline (Set_Scale_Register);
   pragma Inline (Set_Zero_Point);
   pragma Inline (Set_Quantized_Multiplier_Register);
   pragma Inline (Set_Quantized_Multiplier_Right_Shift_Register);
   pragma Inline (Set_N_Outputs);
   pragma Inline (Set_Words_To_Copy_From_R_To_A);

   pragma Inline (Perform_Op);
   pragma Inline (Perform_Max_Pool);
   pragma Inline (Perform_Avg_Pool);
   pragma Inline (Perform_Sigmoid);
   pragma Inline (Perform_ReLU);
   pragma Inline (Perform_Softmax);
   pragma Inline (Perform_Dense);
   pragma Inline (Perform_Conv2D);
   pragma Inline (Perform_Copy_R_To_A);

   pragma Inline (Is_Busy);
   pragma Inline (Is_Done);
   pragma Inline (Wait_While_Busy);

   pragma Inline (Write_Word_In_A);
   pragma Inline (Write_Words_In_A);

   pragma Inline (Read_Word_From_A);
   pragma Inline (Read_Words_From_A);

   pragma Inline (Write_Word_In_B);
   pragma Inline (Write_Words_In_B);

   pragma Inline (Read_Word_From_B);
   pragma Inline (Read_Words_From_B);

   pragma Inline (Write_Word_In_C);
   pragma Inline (Write_Words_In_C);

   pragma Inline (Read_Word_From_C);
   pragma Inline (Read_Words_From_C);

   pragma Inline (Read_Word_From_R);
   pragma Inline (Read_Words_From_R);

   pragma Inline (Copy_Result_To_Input);

end Wb_Npu_Helper;
