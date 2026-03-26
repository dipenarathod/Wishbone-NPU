#include <stdint.h>
#include "neorv32.h"

#define REG32(a) (*(volatile uint32_t*)(a))
#define CTRL   0x90000008u
#define STATUS 0x9000000Cu
#define DIM    0x90000010u
#define BASEI  0x90000014u
#define OUTI   0x90000018u
#define ABASE  0x90001000u
#define RBASE  0x90004000u

#define OP_MAX 0x02u
#define OP_AVG 0x03u
#define BUSY   (1u<<0)

static inline uint32_t pack4(int8_t b0,int8_t b1,int8_t b2,int8_t b3){
  return (uint8_t)b0 | ((uint32_t)(uint8_t)b1<<8)|((uint32_t)(uint8_t)b2<<16)|((uint32_t)(uint8_t)b3<<24);
}
static inline int8_t unpack(uint32_t w, unsigned i){ return (int8_t)((w>>(8*i))&0xFFu); }
static inline uint32_t tensor_words(uint32_t N){ uint32_t e=N*N; return (e+3u)/4u; }

static void load_A(const uint32_t* src, uint32_t nwords){
  for(uint32_t i=0;i<nwords;i++) REG32(ABASE + 4u*i) = src[i];
}
static void read_R(uint32_t* dst, uint32_t nwords){
  for(uint32_t i=0;i<nwords;i++) dst[i] = REG32(RBASE + 4u*i);
}
static int pool_once(uint32_t base_idx, uint32_t out_idx, uint32_t opcode){
  REG32(CTRL)=0u;
  REG32(BASEI)=base_idx;
  REG32(OUTI)=out_idx;
  REG32(CTRL)=((opcode&0x1Fu)<<1)|1u;
  uint32_t to=1000000;
  while((REG32(STATUS)&BUSY) && --to){ }
  return to?0:-1;
}

static void fill_pattern(int8_t* A, uint32_t N){
  for(uint32_t r=0;r<N;r++) for(uint32_t c=0;c<N;c++) A[r*N+c]=(int8_t)((r*7 + c*3)-64);
}
static int8_t sw_max2x2(const int8_t* A,uint32_t N,uint32_t r,uint32_t c){
  int8_t a=A[r*N+c], b=A[r*N+c+1], d=A[(r+1)*N+c], e=A[(r+1)*N+c+1];
  int8_t m=a; if(b>m)m=b; if(d>m)m=d; if(e>m)m=e; return m;
}
static int8_t sw_avg2x2(const int8_t* A,uint32_t N,uint32_t r,uint32_t c){
  int16_t s=A[r*N+c]+A[r*N+c+1]+A[(r+1)*N+c]+A[(r+1)*N+c+1];
  return (int8_t)(s>>2);
}

// Pretty-print an int8 tensor (rows x cols)
static void print_tensor(const char* name, const int8_t* T, uint32_t rows, uint32_t cols){
  neorv32_uart0_printf("%s (%ux%u):\n", name, (unsigned)rows, (unsigned)cols);
  for(uint32_t r=0;r<rows;r++){
    for(uint32_t c=0;c<cols;c++){
      neorv32_uart0_printf(" %d ", (int)T[r*cols + c]);
    }
    neorv32_uart0_printf("\n");
  }
}

// Quantize float -> Q0.7 (saturate to [-128,127])
static inline int8_t q07_from_float(float x) {
  float y = x * 128.0f;
  int32_t t = (int32_t)(y >= 0 ? (y + 0.5f) : (y - 0.5f));
  if (t > 127) t = 127;
  if (t < -128) t = -128;
  return (int8_t)t;
}

// Dequantize Q0.7 -> float
static inline float q07_to_float(int8_t q) { return (float)q / 128.0f; }

// Print Q0.7 value q as [-1.000, +0.992] using only integer math.
static void uart_print_q07(int8_t q) {
  int neg = (q < 0);
  int v = neg ? -q : q;                  // |q| in [0..128]
  int ip = (v == 128) ? 1 : 0;           // only -128 maps to 1.000
  int frac = (v == 128) ? 0 : ( (v * 1000 + 64) / 128 ); // round-to-nearest
  if (frac == 1000) { ip += 1; frac = 0; }               // carry if needed
  neorv32_uart0_printf(" %c%d.%u ", neg?'-':'+', ip, (unsigned)frac);
}

// Pretty-print Q0.7 tensor
static void print_tensor_q07(const char* name, const int8_t* T, uint32_t rows, uint32_t cols){
  neorv32_uart0_printf("%s (%ux%u):\n", name, (unsigned)rows, (unsigned)cols);
  for(uint32_t r=0; r<rows; r++){
    for(uint32_t c=0; c<cols; c++){
      //float v = q07_to_float(T[r*cols + c]);
      uart_print_q07(T[r*cols + c]);
    }
    neorv32_uart0_printf("\n");
  }
}




// Software 2x2 avg with round-to-nearest
static int8_t sw_avg2x2_q07(const int8_t* A, uint32_t N, uint32_t r, uint32_t c){
  int16_t s = A[r*N+c] + A[r*N+c+1] + A[(r+1)*N+c] + A[(r+1)*N+c+1];
  int16_t rn = (s >= 0) ? ((s + 2) >> 2) : ((s + 1) >> 2); // correct rounding for negatives
  if (rn > 127) rn = 127; if (rn < -128) rn = -128;
  return (int8_t)rn;
}

// Unpack packed words (4x int8 per word) to flat int8 array
static void unpack_words_to_i8(const uint32_t* words, uint32_t total_elems, int8_t* out){
  for(uint32_t i=0;i<total_elems;i++){
    uint32_t w = words[i/4u];
    out[i] = unpack(w, i%4u);
  }
}

int main(void){
  neorv32_uart0_setup(19200,0);
  neorv32_uart0_printf("start\n");

  const uint32_t N=8; // keep <= 28
  const uint32_t Awords=tensor_words(N);
  const uint32_t outN=N/2;
  const uint32_t Rwords=tensor_words(outN);

  static int8_t  A[28*28];
  static int8_t  Rm_sw[28*28];
  static int8_t  Ra_sw[28*28];
  static int8_t  Rm_hw[28*28];
  static int8_t  Ra_hw[28*28];
  static uint32_t Aw[196];
  static uint32_t Rw[196];

  // Probe mapped regs and program DIM
  volatile uint32_t s = REG32(STATUS); (void)s;
  REG32(DIM)=N&0xFFu;

  // Prepare A
  fill_pattern(A,N);
  // Print input tensor
  print_tensor_q07("A", A, N, N);

  // Pack and load A
  for(uint32_t i=0;i<Awords;i++){
    uint32_t base=4u*i;
    int8_t b0=(base+0<N*N)?A[base+0]:0;
    int8_t b1=(base+1<N*N)?A[base+1]:0;
    int8_t b2=(base+2<N*N)?A[base+2]:0;
    int8_t b3=(base+3<N*N)?A[base+3]:0;
    Aw[i]=pack4(b0,b1,b2,b3);
  }
  load_A(Aw,Awords);
  for(uint32_t i=0;i<Rwords;i++) REG32(RBASE+4u*i)=0;

  // SW refs for stride-2
  for(uint32_t r=0;r<outN;r++) for(uint32_t c=0;c<outN;c++){
    Rm_sw[r*outN + c] = sw_max2x2(A,N,2*r,2*c);
    Ra_sw[r*outN + c] = sw_avg2x2(A,N,2*r,2*c);
  }

  // MAXPOOL HW
  for(uint32_t r=0;r<outN;r++) for(uint32_t c=0;c<outN;c++){
    uint32_t base=(2*r)*N+(2*c), out=r*outN+c;
    if(pool_once(base,out,OP_MAX)<0){ neorv32_uart0_printf("busy timeout\n"); return 1; }
  }
  read_R(Rw,Rwords);
  unpack_words_to_i8(Rw, outN*outN, Rm_hw);

  // Print MAXPOOL result
  print_tensor_q07("R_max (HW)", Rm_hw, outN, outN);

  // Compare
  uint32_t err=0;
  for(uint32_t i=0;i<outN*outN;i++) if(Rm_hw[i]!=Rm_sw[i]) err++;
  neorv32_uart0_printf("max err=%u\n", err);

  // AVGPOOL HW
  for(uint32_t i=0;i<Rwords;i++) REG32(RBASE+4u*i)=0;
  for(uint32_t r=0;r<outN;r++) for(uint32_t c=0;c<outN;c++){
    uint32_t base=(2*r)*N+(2*c), out=r*outN+c;
    if(pool_once(base,out,OP_AVG)<0){ neorv32_uart0_printf("busy timeout\n"); return 1; }
  }
  read_R(Rw,Rwords);
  unpack_words_to_i8(Rw, outN*outN, Ra_hw);

  // Print AVGPOOL result
  print_tensor_q07("R_avg (HW)", Ra_hw, outN, outN);

  // Compare
  uint32_t erra=0;
  for(uint32_t i=0;i<outN*outN;i++) if(Ra_hw[i]!=Ra_sw[i]) erra++;
  neorv32_uart0_printf("avg err=%u\n", erra);

  neorv32_uart0_printf("done\n");
  return (err||erra)?1:0;
}

