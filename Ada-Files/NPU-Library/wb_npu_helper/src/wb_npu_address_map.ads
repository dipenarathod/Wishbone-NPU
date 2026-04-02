with System;
package wb_npu_address_map is

--Address is a type in Ada
   --Register addresses
   CTRL_Addr                                 : constant System.Address :=
     System'To_Address
       (16#90000008#); --Control register. [0]= start flag. [5:1]=opcode
   STATUS_Addr                               : constant System.Address :=
     System'To_Address
       (16#9000000C#); --Status register. [0] = busy. [1] = done
   DIM_Addr                                  : constant System.Address :=
     System'To_Address
       (16#90000010#); --Address to store dimensions(side length) of square tensor
   BASEI_Addr                                : constant System.Address :=
     System'To_Address (16#90000014#); --top-left idx in A
   OUTI_Addr                                 : constant System.Address :=
     System'To_Address (16#90000018#); --out idx in R
   WORDI_Addr                                : constant System.Address :=
     System'To_Address (16#9000001C#); --word index for operations
   SUM_Addr                                  : constant System.Address :=
     System'To_Address (16#90000020#); --Softmax sum parameter (write-only)
   SOFTMAX_MODE_Addr                         : constant System.Address :=
     System'To_Address (16#90000024#); --Softmax mode: 0=EXP, 1=DIV
   WEIGHT_BASE_INDEX_Addr                    : constant System.Address :=
     System'To_Address (16#90000028#); --Dense: weight base index in B
   BIAS_BASE_INDEX_Addr                      : constant System.Address :=
     System'To_Address (16#9000002C#); --Dense: bias index in C
   N_INPUTS_Addr                             : constant System.Address :=
     System'To_Address (16#90000030#); --Dense: number of inputs N
   --  SCALE_REG_Addr                            : constant System.Address :=
   --    System'To_Address (16#90000034#); --Scale register
   ZERO_POINT_REG_Addr                       : constant System.Address :=
     System'To_Address (16#9000003C#); --Zero point register
   QUANTIZED_MULTIPLIER_REG_Addr             : constant System.Address :=
     System'To_Address (16#90000040#); --Quantized multiplier
   QUANTIZED_MULTIPLIER_RIGHT_SHIFT_REG_Addr : constant System.Address :=
     System'To_Address
       (16#90000044#); --Quantized multiplier right shift register
   N_OUTPUTS_ADDRESS                         : constant System.Address :=
     System'To_Address
       (16#90000048#);  --indices to move from the last row of an input channel to the first row of the next input channel
   WORDS_TO_COPY_FROM_R_TO_A_ADDRESS                         : constant System.Address :=
     System'To_Address
       (16#9000004C#);  --total words to copy from R to A
   REQUANT_PROD_HI_ADDRESS                         : constant System.Address :=
     System'To_Address
       (16#90000050#);  --total words to copy from R to A
   REQUANT_PROD_LO_ADDRESS                         : constant System.Address :=
     System'To_Address
       (16#90000054#);  --total words to copy from R to A
   REQUANT_RESULT_32_ADDRESS                         : constant System.Address :=
     System'To_Address
       (16#9000005C#);  --total words to copy from R to A
   REQUANT_RESULT_8_ADDRESS                         : constant System.Address :=
     System'To_Address
       (16#90000060#);  --total words to copy from R to A
   ACCUMULATOR_ADDRESS                         : constant System.Address :=
     System'To_Address
       (16#90000064#);  --total words to copy from R to A
   ABASE_Addr                                : constant System.Address :=
     System'To_Address (16#90000600#); --Tensor A address
   BBASE_Addr                                : constant System.Address :=
     System'To_Address (16#90002D10#); --Tensor B address
   CBASE_Addr                                : constant System.Address :=
     System'To_Address (16#9000B9B0#); --Tensor C address
   RBASE_Addr                                : constant System.Address :=
     System'To_Address (16#9000D8F0#); --Tensor R(result) address

end wb_npu_address_map;