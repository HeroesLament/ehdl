defmodule Hw.ECP5.ALU54B do
  @moduledoc """
  ECP5 `ALU54B`. sysDSP 54-bit ALU after two MULT18X18Ds (MA / MB). OP is the 11-bit opcode: MA + MB is 0x225 (bits 1:0 and 3:2 select the two inputs: 01 MA / MB, 10 A, 11 zero).

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/alu_probe.v`), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :REG_INPUTC0_CLK, default: "NONE"
  param :REG_INPUTC0_CE, default: "CE0"
  param :REG_INPUTC0_RST, default: "RST0"
  param :REG_INPUTC1_CLK, default: "NONE"
  param :REG_INPUTC1_CE, default: "CE0"
  param :REG_INPUTC1_RST, default: "RST0"
  param :REG_OPCODEOP0_0_CLK, default: "NONE"
  param :REG_OPCODEOP0_0_CE, default: "CE0"
  param :REG_OPCODEOP0_0_RST, default: "RST0"
  param :REG_OPCODEOP1_0_CLK, default: "NONE"
  param :REG_OPCODEOP0_1_CLK, default: "NONE"
  param :REG_OPCODEOP0_1_CE, default: "CE0"
  param :REG_OPCODEOP0_1_RST, default: "RST0"
  param :REG_OPCODEOP1_1_CLK, default: "NONE"
  param :REG_OPCODEIN_0_CLK, default: "NONE"
  param :REG_OPCODEIN_0_CE, default: "CE0"
  param :REG_OPCODEIN_0_RST, default: "RST0"
  param :REG_OPCODEIN_1_CLK, default: "NONE"
  param :REG_OPCODEIN_1_CE, default: "CE0"
  param :REG_OPCODEIN_1_RST, default: "RST0"
  param :REG_OUTPUT0_CLK, default: "NONE"
  param :REG_OUTPUT0_CE, default: "CE0"
  param :REG_OUTPUT0_RST, default: "RST0"
  param :REG_OUTPUT1_CLK, default: "NONE"
  param :REG_OUTPUT1_CE, default: "CE0"
  param :REG_OUTPUT1_RST, default: "RST0"
  param :REG_FLAG_CLK, default: "NONE"
  param :REG_FLAG_CE, default: "CE0"
  param :REG_FLAG_RST, default: "RST0"
  param :MCPAT_SOURCE, default: "STATIC"
  param :MASKPAT_SOURCE, default: "STATIC"
  param :MASK01, default: "0x00000000000000"
  param :REG_INPUTCFB_CLK, default: "NONE"
  param :REG_INPUTCFB_CE, default: "CE0"
  param :REG_INPUTCFB_RST, default: "RST0"
  param :CLK0_DIV, default: "ENABLED"
  param :CLK1_DIV, default: "ENABLED"
  param :CLK2_DIV, default: "ENABLED"
  param :CLK3_DIV, default: "ENABLED"
  param :MCPAT, default: "0x00000000000000"
  param :MASKPAT, default: "0x00000000000000"
  param :RNDPAT, default: "0x00000000000000"
  param :GSR, default: "ENABLED"
  param :RESETMODE, default: "SYNC"
  param :MULT9_MODE, default: "DISABLED"
  param :FORCE_ZERO_BARREL_SHIFT, default: "DISABLED"
  param :LEGACY, default: "DISABLED"

  input :ce3, 1
  input :ce2, 1
  input :ce1, 1
  input :ce0, 1
  input :clk3, 1
  input :clk2, 1
  input :clk1, 1
  input :clk0, 1
  input :rst3, 1
  input :rst2, 1
  input :rst1, 1
  input :rst0, 1
  input :signedia, 1
  input :signedib, 1
  input :signedcin, 1
  input :a35, 1
  input :a34, 1
  input :a33, 1
  input :a32, 1
  input :a31, 1
  input :a30, 1
  input :a29, 1
  input :a28, 1
  input :a27, 1
  input :a26, 1
  input :a25, 1
  input :a24, 1
  input :a23, 1
  input :a22, 1
  input :a21, 1
  input :a20, 1
  input :a19, 1
  input :a18, 1
  input :a17, 1
  input :a16, 1
  input :a15, 1
  input :a14, 1
  input :a13, 1
  input :a12, 1
  input :a11, 1
  input :a10, 1
  input :a9, 1
  input :a8, 1
  input :a7, 1
  input :a6, 1
  input :a5, 1
  input :a4, 1
  input :a3, 1
  input :a2, 1
  input :a1, 1
  input :a0, 1
  input :b35, 1
  input :b34, 1
  input :b33, 1
  input :b32, 1
  input :b31, 1
  input :b30, 1
  input :b29, 1
  input :b28, 1
  input :b27, 1
  input :b26, 1
  input :b25, 1
  input :b24, 1
  input :b23, 1
  input :b22, 1
  input :b21, 1
  input :b20, 1
  input :b19, 1
  input :b18, 1
  input :b17, 1
  input :b16, 1
  input :b15, 1
  input :b14, 1
  input :b13, 1
  input :b12, 1
  input :b11, 1
  input :b10, 1
  input :b9, 1
  input :b8, 1
  input :b7, 1
  input :b6, 1
  input :b5, 1
  input :b4, 1
  input :b3, 1
  input :b2, 1
  input :b1, 1
  input :b0, 1
  input :c53, 1
  input :c52, 1
  input :c51, 1
  input :c50, 1
  input :c49, 1
  input :c48, 1
  input :c47, 1
  input :c46, 1
  input :c45, 1
  input :c44, 1
  input :c43, 1
  input :c42, 1
  input :c41, 1
  input :c40, 1
  input :c39, 1
  input :c38, 1
  input :c37, 1
  input :c36, 1
  input :c35, 1
  input :c34, 1
  input :c33, 1
  input :c32, 1
  input :c31, 1
  input :c30, 1
  input :c29, 1
  input :c28, 1
  input :c27, 1
  input :c26, 1
  input :c25, 1
  input :c24, 1
  input :c23, 1
  input :c22, 1
  input :c21, 1
  input :c20, 1
  input :c19, 1
  input :c18, 1
  input :c17, 1
  input :c16, 1
  input :c15, 1
  input :c14, 1
  input :c13, 1
  input :c12, 1
  input :c11, 1
  input :c10, 1
  input :c9, 1
  input :c8, 1
  input :c7, 1
  input :c6, 1
  input :c5, 1
  input :c4, 1
  input :c3, 1
  input :c2, 1
  input :c1, 1
  input :c0, 1
  input :cfb53, 1
  input :cfb52, 1
  input :cfb51, 1
  input :cfb50, 1
  input :cfb49, 1
  input :cfb48, 1
  input :cfb47, 1
  input :cfb46, 1
  input :cfb45, 1
  input :cfb44, 1
  input :cfb43, 1
  input :cfb42, 1
  input :cfb41, 1
  input :cfb40, 1
  input :cfb39, 1
  input :cfb38, 1
  input :cfb37, 1
  input :cfb36, 1
  input :cfb35, 1
  input :cfb34, 1
  input :cfb33, 1
  input :cfb32, 1
  input :cfb31, 1
  input :cfb30, 1
  input :cfb29, 1
  input :cfb28, 1
  input :cfb27, 1
  input :cfb26, 1
  input :cfb25, 1
  input :cfb24, 1
  input :cfb23, 1
  input :cfb22, 1
  input :cfb21, 1
  input :cfb20, 1
  input :cfb19, 1
  input :cfb18, 1
  input :cfb17, 1
  input :cfb16, 1
  input :cfb15, 1
  input :cfb14, 1
  input :cfb13, 1
  input :cfb12, 1
  input :cfb11, 1
  input :cfb10, 1
  input :cfb9, 1
  input :cfb8, 1
  input :cfb7, 1
  input :cfb6, 1
  input :cfb5, 1
  input :cfb4, 1
  input :cfb3, 1
  input :cfb2, 1
  input :cfb1, 1
  input :cfb0, 1
  input :ma35, 1
  input :ma34, 1
  input :ma33, 1
  input :ma32, 1
  input :ma31, 1
  input :ma30, 1
  input :ma29, 1
  input :ma28, 1
  input :ma27, 1
  input :ma26, 1
  input :ma25, 1
  input :ma24, 1
  input :ma23, 1
  input :ma22, 1
  input :ma21, 1
  input :ma20, 1
  input :ma19, 1
  input :ma18, 1
  input :ma17, 1
  input :ma16, 1
  input :ma15, 1
  input :ma14, 1
  input :ma13, 1
  input :ma12, 1
  input :ma11, 1
  input :ma10, 1
  input :ma9, 1
  input :ma8, 1
  input :ma7, 1
  input :ma6, 1
  input :ma5, 1
  input :ma4, 1
  input :ma3, 1
  input :ma2, 1
  input :ma1, 1
  input :ma0, 1
  input :mb35, 1
  input :mb34, 1
  input :mb33, 1
  input :mb32, 1
  input :mb31, 1
  input :mb30, 1
  input :mb29, 1
  input :mb28, 1
  input :mb27, 1
  input :mb26, 1
  input :mb25, 1
  input :mb24, 1
  input :mb23, 1
  input :mb22, 1
  input :mb21, 1
  input :mb20, 1
  input :mb19, 1
  input :mb18, 1
  input :mb17, 1
  input :mb16, 1
  input :mb15, 1
  input :mb14, 1
  input :mb13, 1
  input :mb12, 1
  input :mb11, 1
  input :mb10, 1
  input :mb9, 1
  input :mb8, 1
  input :mb7, 1
  input :mb6, 1
  input :mb5, 1
  input :mb4, 1
  input :mb3, 1
  input :mb2, 1
  input :mb1, 1
  input :mb0, 1
  input :cin53, 1
  input :cin52, 1
  input :cin51, 1
  input :cin50, 1
  input :cin49, 1
  input :cin48, 1
  input :cin47, 1
  input :cin46, 1
  input :cin45, 1
  input :cin44, 1
  input :cin43, 1
  input :cin42, 1
  input :cin41, 1
  input :cin40, 1
  input :cin39, 1
  input :cin38, 1
  input :cin37, 1
  input :cin36, 1
  input :cin35, 1
  input :cin34, 1
  input :cin33, 1
  input :cin32, 1
  input :cin31, 1
  input :cin30, 1
  input :cin29, 1
  input :cin28, 1
  input :cin27, 1
  input :cin26, 1
  input :cin25, 1
  input :cin24, 1
  input :cin23, 1
  input :cin22, 1
  input :cin21, 1
  input :cin20, 1
  input :cin19, 1
  input :cin18, 1
  input :cin17, 1
  input :cin16, 1
  input :cin15, 1
  input :cin14, 1
  input :cin13, 1
  input :cin12, 1
  input :cin11, 1
  input :cin10, 1
  input :cin9, 1
  input :cin8, 1
  input :cin7, 1
  input :cin6, 1
  input :cin5, 1
  input :cin4, 1
  input :cin3, 1
  input :cin2, 1
  input :cin1, 1
  input :cin0, 1
  input :op10, 1
  input :op9, 1
  input :op8, 1
  input :op7, 1
  input :op6, 1
  input :op5, 1
  input :op4, 1
  input :op3, 1
  input :op2, 1
  input :op1, 1
  input :op0, 1
  output :r53, 1
  output :r52, 1
  output :r51, 1
  output :r50, 1
  output :r49, 1
  output :r48, 1
  output :r47, 1
  output :r46, 1
  output :r45, 1
  output :r44, 1
  output :r43, 1
  output :r42, 1
  output :r41, 1
  output :r40, 1
  output :r39, 1
  output :r38, 1
  output :r37, 1
  output :r36, 1
  output :r35, 1
  output :r34, 1
  output :r33, 1
  output :r32, 1
  output :r31, 1
  output :r30, 1
  output :r29, 1
  output :r28, 1
  output :r27, 1
  output :r26, 1
  output :r25, 1
  output :r24, 1
  output :r23, 1
  output :r22, 1
  output :r21, 1
  output :r20, 1
  output :r19, 1
  output :r18, 1
  output :r17, 1
  output :r16, 1
  output :r15, 1
  output :r14, 1
  output :r13, 1
  output :r12, 1
  output :r11, 1
  output :r10, 1
  output :r9, 1
  output :r8, 1
  output :r7, 1
  output :r6, 1
  output :r5, 1
  output :r4, 1
  output :r3, 1
  output :r2, 1
  output :r1, 1
  output :r0, 1
  output :co53, 1
  output :co52, 1
  output :co51, 1
  output :co50, 1
  output :co49, 1
  output :co48, 1
  output :co47, 1
  output :co46, 1
  output :co45, 1
  output :co44, 1
  output :co43, 1
  output :co42, 1
  output :co41, 1
  output :co40, 1
  output :co39, 1
  output :co38, 1
  output :co37, 1
  output :co36, 1
  output :co35, 1
  output :co34, 1
  output :co33, 1
  output :co32, 1
  output :co31, 1
  output :co30, 1
  output :co29, 1
  output :co28, 1
  output :co27, 1
  output :co26, 1
  output :co25, 1
  output :co24, 1
  output :co23, 1
  output :co22, 1
  output :co21, 1
  output :co20, 1
  output :co19, 1
  output :co18, 1
  output :co17, 1
  output :co16, 1
  output :co15, 1
  output :co14, 1
  output :co13, 1
  output :co12, 1
  output :co11, 1
  output :co10, 1
  output :co9, 1
  output :co8, 1
  output :co7, 1
  output :co6, 1
  output :co5, 1
  output :co4, 1
  output :co3, 1
  output :co2, 1
  output :co1, 1
  output :co0, 1
  output :eqz, 1
  output :eqzm, 1
  output :eqom, 1
  output :eqpat, 1
  output :eqpatb, 1
  output :over, 1
  output :under, 1
  output :overunder, 1
  output :signedr, 1

  blackbox :alu54b, "ALU54B",
    params: [
      REG_INPUTC0_CLK: :REG_INPUTC0_CLK,
      REG_INPUTC0_CE: :REG_INPUTC0_CE,
      REG_INPUTC0_RST: :REG_INPUTC0_RST,
      REG_INPUTC1_CLK: :REG_INPUTC1_CLK,
      REG_INPUTC1_CE: :REG_INPUTC1_CE,
      REG_INPUTC1_RST: :REG_INPUTC1_RST,
      REG_OPCODEOP0_0_CLK: :REG_OPCODEOP0_0_CLK,
      REG_OPCODEOP0_0_CE: :REG_OPCODEOP0_0_CE,
      REG_OPCODEOP0_0_RST: :REG_OPCODEOP0_0_RST,
      REG_OPCODEOP1_0_CLK: :REG_OPCODEOP1_0_CLK,
      REG_OPCODEOP0_1_CLK: :REG_OPCODEOP0_1_CLK,
      REG_OPCODEOP0_1_CE: :REG_OPCODEOP0_1_CE,
      REG_OPCODEOP0_1_RST: :REG_OPCODEOP0_1_RST,
      REG_OPCODEOP1_1_CLK: :REG_OPCODEOP1_1_CLK,
      REG_OPCODEIN_0_CLK: :REG_OPCODEIN_0_CLK,
      REG_OPCODEIN_0_CE: :REG_OPCODEIN_0_CE,
      REG_OPCODEIN_0_RST: :REG_OPCODEIN_0_RST,
      REG_OPCODEIN_1_CLK: :REG_OPCODEIN_1_CLK,
      REG_OPCODEIN_1_CE: :REG_OPCODEIN_1_CE,
      REG_OPCODEIN_1_RST: :REG_OPCODEIN_1_RST,
      REG_OUTPUT0_CLK: :REG_OUTPUT0_CLK,
      REG_OUTPUT0_CE: :REG_OUTPUT0_CE,
      REG_OUTPUT0_RST: :REG_OUTPUT0_RST,
      REG_OUTPUT1_CLK: :REG_OUTPUT1_CLK,
      REG_OUTPUT1_CE: :REG_OUTPUT1_CE,
      REG_OUTPUT1_RST: :REG_OUTPUT1_RST,
      REG_FLAG_CLK: :REG_FLAG_CLK,
      REG_FLAG_CE: :REG_FLAG_CE,
      REG_FLAG_RST: :REG_FLAG_RST,
      MCPAT_SOURCE: :MCPAT_SOURCE,
      MASKPAT_SOURCE: :MASKPAT_SOURCE,
      MASK01: :MASK01,
      REG_INPUTCFB_CLK: :REG_INPUTCFB_CLK,
      REG_INPUTCFB_CE: :REG_INPUTCFB_CE,
      REG_INPUTCFB_RST: :REG_INPUTCFB_RST,
      CLK0_DIV: :CLK0_DIV,
      CLK1_DIV: :CLK1_DIV,
      CLK2_DIV: :CLK2_DIV,
      CLK3_DIV: :CLK3_DIV,
      MCPAT: :MCPAT,
      MASKPAT: :MASKPAT,
      RNDPAT: :RNDPAT,
      GSR: :GSR,
      RESETMODE: :RESETMODE,
      MULT9_MODE: :MULT9_MODE,
      FORCE_ZERO_BARREL_SHIFT: :FORCE_ZERO_BARREL_SHIFT,
      LEGACY: :LEGACY
    ],
    ports: [
      CE3: :ce3,
      CE2: :ce2,
      CE1: :ce1,
      CE0: :ce0,
      CLK3: :clk3,
      CLK2: :clk2,
      CLK1: :clk1,
      CLK0: :clk0,
      RST3: :rst3,
      RST2: :rst2,
      RST1: :rst1,
      RST0: :rst0,
      SIGNEDIA: :signedia,
      SIGNEDIB: :signedib,
      SIGNEDCIN: :signedcin,
      A35: :a35,
      A34: :a34,
      A33: :a33,
      A32: :a32,
      A31: :a31,
      A30: :a30,
      A29: :a29,
      A28: :a28,
      A27: :a27,
      A26: :a26,
      A25: :a25,
      A24: :a24,
      A23: :a23,
      A22: :a22,
      A21: :a21,
      A20: :a20,
      A19: :a19,
      A18: :a18,
      A17: :a17,
      A16: :a16,
      A15: :a15,
      A14: :a14,
      A13: :a13,
      A12: :a12,
      A11: :a11,
      A10: :a10,
      A9: :a9,
      A8: :a8,
      A7: :a7,
      A6: :a6,
      A5: :a5,
      A4: :a4,
      A3: :a3,
      A2: :a2,
      A1: :a1,
      A0: :a0,
      B35: :b35,
      B34: :b34,
      B33: :b33,
      B32: :b32,
      B31: :b31,
      B30: :b30,
      B29: :b29,
      B28: :b28,
      B27: :b27,
      B26: :b26,
      B25: :b25,
      B24: :b24,
      B23: :b23,
      B22: :b22,
      B21: :b21,
      B20: :b20,
      B19: :b19,
      B18: :b18,
      B17: :b17,
      B16: :b16,
      B15: :b15,
      B14: :b14,
      B13: :b13,
      B12: :b12,
      B11: :b11,
      B10: :b10,
      B9: :b9,
      B8: :b8,
      B7: :b7,
      B6: :b6,
      B5: :b5,
      B4: :b4,
      B3: :b3,
      B2: :b2,
      B1: :b1,
      B0: :b0,
      C53: :c53,
      C52: :c52,
      C51: :c51,
      C50: :c50,
      C49: :c49,
      C48: :c48,
      C47: :c47,
      C46: :c46,
      C45: :c45,
      C44: :c44,
      C43: :c43,
      C42: :c42,
      C41: :c41,
      C40: :c40,
      C39: :c39,
      C38: :c38,
      C37: :c37,
      C36: :c36,
      C35: :c35,
      C34: :c34,
      C33: :c33,
      C32: :c32,
      C31: :c31,
      C30: :c30,
      C29: :c29,
      C28: :c28,
      C27: :c27,
      C26: :c26,
      C25: :c25,
      C24: :c24,
      C23: :c23,
      C22: :c22,
      C21: :c21,
      C20: :c20,
      C19: :c19,
      C18: :c18,
      C17: :c17,
      C16: :c16,
      C15: :c15,
      C14: :c14,
      C13: :c13,
      C12: :c12,
      C11: :c11,
      C10: :c10,
      C9: :c9,
      C8: :c8,
      C7: :c7,
      C6: :c6,
      C5: :c5,
      C4: :c4,
      C3: :c3,
      C2: :c2,
      C1: :c1,
      C0: :c0,
      CFB53: :cfb53,
      CFB52: :cfb52,
      CFB51: :cfb51,
      CFB50: :cfb50,
      CFB49: :cfb49,
      CFB48: :cfb48,
      CFB47: :cfb47,
      CFB46: :cfb46,
      CFB45: :cfb45,
      CFB44: :cfb44,
      CFB43: :cfb43,
      CFB42: :cfb42,
      CFB41: :cfb41,
      CFB40: :cfb40,
      CFB39: :cfb39,
      CFB38: :cfb38,
      CFB37: :cfb37,
      CFB36: :cfb36,
      CFB35: :cfb35,
      CFB34: :cfb34,
      CFB33: :cfb33,
      CFB32: :cfb32,
      CFB31: :cfb31,
      CFB30: :cfb30,
      CFB29: :cfb29,
      CFB28: :cfb28,
      CFB27: :cfb27,
      CFB26: :cfb26,
      CFB25: :cfb25,
      CFB24: :cfb24,
      CFB23: :cfb23,
      CFB22: :cfb22,
      CFB21: :cfb21,
      CFB20: :cfb20,
      CFB19: :cfb19,
      CFB18: :cfb18,
      CFB17: :cfb17,
      CFB16: :cfb16,
      CFB15: :cfb15,
      CFB14: :cfb14,
      CFB13: :cfb13,
      CFB12: :cfb12,
      CFB11: :cfb11,
      CFB10: :cfb10,
      CFB9: :cfb9,
      CFB8: :cfb8,
      CFB7: :cfb7,
      CFB6: :cfb6,
      CFB5: :cfb5,
      CFB4: :cfb4,
      CFB3: :cfb3,
      CFB2: :cfb2,
      CFB1: :cfb1,
      CFB0: :cfb0,
      MA35: :ma35,
      MA34: :ma34,
      MA33: :ma33,
      MA32: :ma32,
      MA31: :ma31,
      MA30: :ma30,
      MA29: :ma29,
      MA28: :ma28,
      MA27: :ma27,
      MA26: :ma26,
      MA25: :ma25,
      MA24: :ma24,
      MA23: :ma23,
      MA22: :ma22,
      MA21: :ma21,
      MA20: :ma20,
      MA19: :ma19,
      MA18: :ma18,
      MA17: :ma17,
      MA16: :ma16,
      MA15: :ma15,
      MA14: :ma14,
      MA13: :ma13,
      MA12: :ma12,
      MA11: :ma11,
      MA10: :ma10,
      MA9: :ma9,
      MA8: :ma8,
      MA7: :ma7,
      MA6: :ma6,
      MA5: :ma5,
      MA4: :ma4,
      MA3: :ma3,
      MA2: :ma2,
      MA1: :ma1,
      MA0: :ma0,
      MB35: :mb35,
      MB34: :mb34,
      MB33: :mb33,
      MB32: :mb32,
      MB31: :mb31,
      MB30: :mb30,
      MB29: :mb29,
      MB28: :mb28,
      MB27: :mb27,
      MB26: :mb26,
      MB25: :mb25,
      MB24: :mb24,
      MB23: :mb23,
      MB22: :mb22,
      MB21: :mb21,
      MB20: :mb20,
      MB19: :mb19,
      MB18: :mb18,
      MB17: :mb17,
      MB16: :mb16,
      MB15: :mb15,
      MB14: :mb14,
      MB13: :mb13,
      MB12: :mb12,
      MB11: :mb11,
      MB10: :mb10,
      MB9: :mb9,
      MB8: :mb8,
      MB7: :mb7,
      MB6: :mb6,
      MB5: :mb5,
      MB4: :mb4,
      MB3: :mb3,
      MB2: :mb2,
      MB1: :mb1,
      MB0: :mb0,
      CIN53: :cin53,
      CIN52: :cin52,
      CIN51: :cin51,
      CIN50: :cin50,
      CIN49: :cin49,
      CIN48: :cin48,
      CIN47: :cin47,
      CIN46: :cin46,
      CIN45: :cin45,
      CIN44: :cin44,
      CIN43: :cin43,
      CIN42: :cin42,
      CIN41: :cin41,
      CIN40: :cin40,
      CIN39: :cin39,
      CIN38: :cin38,
      CIN37: :cin37,
      CIN36: :cin36,
      CIN35: :cin35,
      CIN34: :cin34,
      CIN33: :cin33,
      CIN32: :cin32,
      CIN31: :cin31,
      CIN30: :cin30,
      CIN29: :cin29,
      CIN28: :cin28,
      CIN27: :cin27,
      CIN26: :cin26,
      CIN25: :cin25,
      CIN24: :cin24,
      CIN23: :cin23,
      CIN22: :cin22,
      CIN21: :cin21,
      CIN20: :cin20,
      CIN19: :cin19,
      CIN18: :cin18,
      CIN17: :cin17,
      CIN16: :cin16,
      CIN15: :cin15,
      CIN14: :cin14,
      CIN13: :cin13,
      CIN12: :cin12,
      CIN11: :cin11,
      CIN10: :cin10,
      CIN9: :cin9,
      CIN8: :cin8,
      CIN7: :cin7,
      CIN6: :cin6,
      CIN5: :cin5,
      CIN4: :cin4,
      CIN3: :cin3,
      CIN2: :cin2,
      CIN1: :cin1,
      CIN0: :cin0,
      OP10: :op10,
      OP9: :op9,
      OP8: :op8,
      OP7: :op7,
      OP6: :op6,
      OP5: :op5,
      OP4: :op4,
      OP3: :op3,
      OP2: :op2,
      OP1: :op1,
      OP0: :op0,
      R53: :r53,
      R52: :r52,
      R51: :r51,
      R50: :r50,
      R49: :r49,
      R48: :r48,
      R47: :r47,
      R46: :r46,
      R45: :r45,
      R44: :r44,
      R43: :r43,
      R42: :r42,
      R41: :r41,
      R40: :r40,
      R39: :r39,
      R38: :r38,
      R37: :r37,
      R36: :r36,
      R35: :r35,
      R34: :r34,
      R33: :r33,
      R32: :r32,
      R31: :r31,
      R30: :r30,
      R29: :r29,
      R28: :r28,
      R27: :r27,
      R26: :r26,
      R25: :r25,
      R24: :r24,
      R23: :r23,
      R22: :r22,
      R21: :r21,
      R20: :r20,
      R19: :r19,
      R18: :r18,
      R17: :r17,
      R16: :r16,
      R15: :r15,
      R14: :r14,
      R13: :r13,
      R12: :r12,
      R11: :r11,
      R10: :r10,
      R9: :r9,
      R8: :r8,
      R7: :r7,
      R6: :r6,
      R5: :r5,
      R4: :r4,
      R3: :r3,
      R2: :r2,
      R1: :r1,
      R0: :r0,
      CO53: :co53,
      CO52: :co52,
      CO51: :co51,
      CO50: :co50,
      CO49: :co49,
      CO48: :co48,
      CO47: :co47,
      CO46: :co46,
      CO45: :co45,
      CO44: :co44,
      CO43: :co43,
      CO42: :co42,
      CO41: :co41,
      CO40: :co40,
      CO39: :co39,
      CO38: :co38,
      CO37: :co37,
      CO36: :co36,
      CO35: :co35,
      CO34: :co34,
      CO33: :co33,
      CO32: :co32,
      CO31: :co31,
      CO30: :co30,
      CO29: :co29,
      CO28: :co28,
      CO27: :co27,
      CO26: :co26,
      CO25: :co25,
      CO24: :co24,
      CO23: :co23,
      CO22: :co22,
      CO21: :co21,
      CO20: :co20,
      CO19: :co19,
      CO18: :co18,
      CO17: :co17,
      CO16: :co16,
      CO15: :co15,
      CO14: :co14,
      CO13: :co13,
      CO12: :co12,
      CO11: :co11,
      CO10: :co10,
      CO9: :co9,
      CO8: :co8,
      CO7: :co7,
      CO6: :co6,
      CO5: :co5,
      CO4: :co4,
      CO3: :co3,
      CO2: :co2,
      CO1: :co1,
      CO0: :co0,
      EQZ: :eqz,
      EQZM: :eqzm,
      EQOM: :eqom,
      EQPAT: :eqpat,
      EQPATB: :eqpatb,
      OVER: :over,
      UNDER: :under,
      OVERUNDER: :overunder,
      SIGNEDR: :signedr
    ]
end
