// test_sigmoid.c
#include <stdint.h>
#include "neorv32.h"

#define REG32(a) (*(volatile uint32_t*)(a))

#define CTRL     0x90000008u   //[0]=start, [5:1]=opcode
#define STATUS   0x9000000Cu   //[0]=busy, [1]=done
#define DIM      0x90000010u   //N in LSB 8 bits
#define WORDI    0x9000001Cu   //packed word index

#define ABASE    0x90001000u   //A tensor window
#define RBASE    0x90004000u   //R tensor window

#define OP_SIG   0x04u         //CTRL[5:1] = 00100 (OP_SIGMOID)
#define OP_RELU  0x05u         //00101 (OP_RELU)
#define BUSY     (1u<<0)

static inline uint32_t pack4(int8_t b0,int8_t b1,int8_t b2,int8_t b3){
  return (uint8_t)b0 | ((uint32_t)(uint8_t)b1<<8)|((uint32_t)(uint8_t)b2<<16)|((uint32_t)(uint8_t)b3<<24);
}
static inline int8_t unpack(uint32_t w, unsigned index){
    return (int8_t)((w>>(8*index))&0xFFu); 
 }
static inline uint32_t tensor_words(uint32_t N){ uint32_t e=N*N; return (e+3u)/4u; }

//Load packed words into A
static void load_A_words(const uint32_t* src, uint32_t nwords){
  for(uint32_t i=0;i<nwords;i++){
    REG32(ABASE + 4u*i) = src[i];
   }
}
//Read packed words from R
static void read_R_words(uint32_t* dst, uint32_t nwords){
  for(uint32_t i=0;i<nwords;i++){
    dst[i] = REG32(RBASE + 4u*i);
   }
}

//Issue one sigmoid op for a given packed word index
static void sigmoid_once(uint32_t word_idx){
  REG32(CTRL) = 0;
  REG32(WORDI) = word_idx;
  REG32(CTRL) = ((OP_SIG & 0x1Fu) << 1) | 1u; //opcode in [5:1], start=1
  while (REG32(STATUS) & BUSY) { ; }          //poll busy
}

//Tiny one-shot runner for ReLU
static void relu_once(uint32_t word_idx){
  REG32(CTRL) = 0;
  REG32(WORDI) = word_idx;
  REG32(CTRL) = ((OP_RELU & 0x1Fu) << 1) | 1u; //opcode in [5:1], start=1
  while (REG32(STATUS) & BUSY) { ; }           //poll busy
}

//Print Q0.7 value q as [-1.000, +0.992] using only integer math.
static void uart_print_q07(int8_t q) {
  int neg = (q < 0);
  int v = neg ? -q : q;                  // |q| in [0..128]
  int ip = (v == 128) ? 1 : 0;           // only -128 maps to 1.000
  int frac = (v == 128) ? 0 : ( (v * 1000 + 64) / 128 ); // round-to-nearest
  if (frac == 1000) { ip += 1; frac = 0; }               // carry if needed
  neorv32_uart0_printf(" %c%d.%u ", neg?'-':'+', ip, (unsigned)frac);
}

//Print 1 row of 4 Q0.7 bytes
static void print_q07_row(const char* tag, uint32_t w){
  neorv32_uart0_printf("%s:", tag);
  for(unsigned i=0;i<4;i++){
    int8_t q = unpack(w,i);
    uart_print_q07(q);
  }
  neorv32_uart0_printf("\n");
}

int main(void){
  neorv32_uart0_setup(19200, 0);

  const uint32_t N = 8; //Can be upto 28
  const uint32_t nwords = tensor_words(N);
  REG32(DIM) = N;

  static uint32_t A_words[196];
  static uint32_t R_words[196];
  static uint32_t R_relu[196];
  for(uint32_t i=0;i<nwords;i++){
    int base = (int)i*4 - 40;
    int8_t b0 = (int8_t)(base);
    int8_t b1 = (int8_t)(base + 16);
    int8_t b2 = (int8_t)(base + 32);
    int8_t b3 = (int8_t)(base + 48);
    A_words[i] = pack4(b0,b1,b2,b3);
  }

  load_A_words(A_words, nwords);

  //Run hardware sigmoid for each packed word
  for(uint32_t w=0; w<nwords; w++){
    REG32(WORDI) = w;
    sigmoid_once(w);
  }

  read_R_words(R_words, nwords);
  
/*  for(uint32_t i=0;i<nwords;i++){
    uint32_t w_in = A_words[i];
    uint32_t w_hw = R_words[i];
    if (i < 4) {
      print_q07_row("IN ", w_in);
      print_q07_row("HW ", w_hw);
      neorv32_uart0_printf("\n");
    }
  }*/

  //ReLU over same inputs
  for (uint32_t w=0; w<nwords; w++) {
    relu_once(w);
  }

  read_R_words(R_relu, nwords);

  for(uint32_t i=0;i<nwords;i++){
    if (i < 4) {
      print_q07_row("IN ",  A_words[i]);
      print_q07_row("SIG",  R_words[i]);
      print_q07_row("REL",  R_relu[i]);
      neorv32_uart0_printf("\n");
    }
  }

  return 0;
}

