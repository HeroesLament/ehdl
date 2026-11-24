defmodule Hw.ECP5.MULT18X18D do
  @moduledoc """
  ECP5 `MULT18X18D`. sysDSP 18x18 multiplier, optional input / pipeline / output registers. oxibit infers it from `*`, so instantiate it only for the registered or cascaded forms.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/dsp_probe.v`, `designs/mul_probe.v`), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :REG_INPUTA_CLK, default: "NONE"
  param :REG_INPUTA_CE, default: "CE0"
  param :REG_INPUTA_RST, default: "RST0"
  param :REG_INPUTB_CLK, default: "NONE"
  param :REG_INPUTB_CE, default: "CE0"
  param :REG_INPUTB_RST, default: "RST0"
  param :REG_INPUTC_CLK, default: "NONE"
  param :REG_INPUTC_CE, default: "CE0"
  param :REG_INPUTC_RST, default: "RST0"
  param :REG_PIPELINE_CLK, default: "NONE"
  param :REG_PIPELINE_CE, default: "CE0"
  param :REG_PIPELINE_RST, default: "RST0"
  param :REG_OUTPUT_CLK, default: "NONE"
  param :REG_OUTPUT_CE, default: "CE0"
  param :REG_OUTPUT_RST, default: "RST0"
  param :CLK0_DIV, default: "ENABLED"
  param :CLK1_DIV, default: "ENABLED"
  param :CLK2_DIV, default: "ENABLED"
  param :CLK3_DIV, default: "ENABLED"
  param :HIGHSPEED_CLK, default: "NONE"
  param :GSR, default: "ENABLED"
  param :CAS_MATCH_REG, default: "FALSE"
  param :SOURCEB_MODE, default: "B_SHIFT"
  param :MULT_BYPASS, default: "DISABLED"
  param :RESETMODE, default: "SYNC"

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
  input :signeda, 1
  input :signedb, 1
  input :sourcea, 1
  input :sourceb, 1
  input :clk3, 1
  input :clk2, 1
  input :clk1, 1
  input :clk0, 1
  input :ce3, 1
  input :ce2, 1
  input :ce1, 1
  input :ce0, 1
  input :rst3, 1
  input :rst2, 1
  input :rst1, 1
  input :rst0, 1
  input :sria17, 1
  input :sria16, 1
  input :sria15, 1
  input :sria14, 1
  input :sria13, 1
  input :sria12, 1
  input :sria11, 1
  input :sria10, 1
  input :sria9, 1
  input :sria8, 1
  input :sria7, 1
  input :sria6, 1
  input :sria5, 1
  input :sria4, 1
  input :sria3, 1
  input :sria2, 1
  input :sria1, 1
  input :sria0, 1
  input :srib17, 1
  input :srib16, 1
  input :srib15, 1
  input :srib14, 1
  input :srib13, 1
  input :srib12, 1
  input :srib11, 1
  input :srib10, 1
  input :srib9, 1
  input :srib8, 1
  input :srib7, 1
  input :srib6, 1
  input :srib5, 1
  input :srib4, 1
  input :srib3, 1
  input :srib2, 1
  input :srib1, 1
  input :srib0, 1
  output :sroa17, 1
  output :sroa16, 1
  output :sroa15, 1
  output :sroa14, 1
  output :sroa13, 1
  output :sroa12, 1
  output :sroa11, 1
  output :sroa10, 1
  output :sroa9, 1
  output :sroa8, 1
  output :sroa7, 1
  output :sroa6, 1
  output :sroa5, 1
  output :sroa4, 1
  output :sroa3, 1
  output :sroa2, 1
  output :sroa1, 1
  output :sroa0, 1
  output :srob17, 1
  output :srob16, 1
  output :srob15, 1
  output :srob14, 1
  output :srob13, 1
  output :srob12, 1
  output :srob11, 1
  output :srob10, 1
  output :srob9, 1
  output :srob8, 1
  output :srob7, 1
  output :srob6, 1
  output :srob5, 1
  output :srob4, 1
  output :srob3, 1
  output :srob2, 1
  output :srob1, 1
  output :srob0, 1
  output :roa17, 1
  output :roa16, 1
  output :roa15, 1
  output :roa14, 1
  output :roa13, 1
  output :roa12, 1
  output :roa11, 1
  output :roa10, 1
  output :roa9, 1
  output :roa8, 1
  output :roa7, 1
  output :roa6, 1
  output :roa5, 1
  output :roa4, 1
  output :roa3, 1
  output :roa2, 1
  output :roa1, 1
  output :roa0, 1
  output :rob17, 1
  output :rob16, 1
  output :rob15, 1
  output :rob14, 1
  output :rob13, 1
  output :rob12, 1
  output :rob11, 1
  output :rob10, 1
  output :rob9, 1
  output :rob8, 1
  output :rob7, 1
  output :rob6, 1
  output :rob5, 1
  output :rob4, 1
  output :rob3, 1
  output :rob2, 1
  output :rob1, 1
  output :rob0, 1
  output :roc17, 1
  output :roc16, 1
  output :roc15, 1
  output :roc14, 1
  output :roc13, 1
  output :roc12, 1
  output :roc11, 1
  output :roc10, 1
  output :roc9, 1
  output :roc8, 1
  output :roc7, 1
  output :roc6, 1
  output :roc5, 1
  output :roc4, 1
  output :roc3, 1
  output :roc2, 1
  output :roc1, 1
  output :roc0, 1
  output :p35, 1
  output :p34, 1
  output :p33, 1
  output :p32, 1
  output :p31, 1
  output :p30, 1
  output :p29, 1
  output :p28, 1
  output :p27, 1
  output :p26, 1
  output :p25, 1
  output :p24, 1
  output :p23, 1
  output :p22, 1
  output :p21, 1
  output :p20, 1
  output :p19, 1
  output :p18, 1
  output :p17, 1
  output :p16, 1
  output :p15, 1
  output :p14, 1
  output :p13, 1
  output :p12, 1
  output :p11, 1
  output :p10, 1
  output :p9, 1
  output :p8, 1
  output :p7, 1
  output :p6, 1
  output :p5, 1
  output :p4, 1
  output :p3, 1
  output :p2, 1
  output :p1, 1
  output :p0, 1
  output :signedp, 1

  blackbox :mult18x18d, "MULT18X18D",
    params: [
      REG_INPUTA_CLK: :REG_INPUTA_CLK,
      REG_INPUTA_CE: :REG_INPUTA_CE,
      REG_INPUTA_RST: :REG_INPUTA_RST,
      REG_INPUTB_CLK: :REG_INPUTB_CLK,
      REG_INPUTB_CE: :REG_INPUTB_CE,
      REG_INPUTB_RST: :REG_INPUTB_RST,
      REG_INPUTC_CLK: :REG_INPUTC_CLK,
      REG_INPUTC_CE: :REG_INPUTC_CE,
      REG_INPUTC_RST: :REG_INPUTC_RST,
      REG_PIPELINE_CLK: :REG_PIPELINE_CLK,
      REG_PIPELINE_CE: :REG_PIPELINE_CE,
      REG_PIPELINE_RST: :REG_PIPELINE_RST,
      REG_OUTPUT_CLK: :REG_OUTPUT_CLK,
      REG_OUTPUT_CE: :REG_OUTPUT_CE,
      REG_OUTPUT_RST: :REG_OUTPUT_RST,
      CLK0_DIV: :CLK0_DIV,
      CLK1_DIV: :CLK1_DIV,
      CLK2_DIV: :CLK2_DIV,
      CLK3_DIV: :CLK3_DIV,
      HIGHSPEED_CLK: :HIGHSPEED_CLK,
      GSR: :GSR,
      CAS_MATCH_REG: :CAS_MATCH_REG,
      SOURCEB_MODE: :SOURCEB_MODE,
      MULT_BYPASS: :MULT_BYPASS,
      RESETMODE: :RESETMODE
    ],
    ports: [
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
      SIGNEDA: :signeda,
      SIGNEDB: :signedb,
      SOURCEA: :sourcea,
      SOURCEB: :sourceb,
      CLK3: :clk3,
      CLK2: :clk2,
      CLK1: :clk1,
      CLK0: :clk0,
      CE3: :ce3,
      CE2: :ce2,
      CE1: :ce1,
      CE0: :ce0,
      RST3: :rst3,
      RST2: :rst2,
      RST1: :rst1,
      RST0: :rst0,
      SRIA17: :sria17,
      SRIA16: :sria16,
      SRIA15: :sria15,
      SRIA14: :sria14,
      SRIA13: :sria13,
      SRIA12: :sria12,
      SRIA11: :sria11,
      SRIA10: :sria10,
      SRIA9: :sria9,
      SRIA8: :sria8,
      SRIA7: :sria7,
      SRIA6: :sria6,
      SRIA5: :sria5,
      SRIA4: :sria4,
      SRIA3: :sria3,
      SRIA2: :sria2,
      SRIA1: :sria1,
      SRIA0: :sria0,
      SRIB17: :srib17,
      SRIB16: :srib16,
      SRIB15: :srib15,
      SRIB14: :srib14,
      SRIB13: :srib13,
      SRIB12: :srib12,
      SRIB11: :srib11,
      SRIB10: :srib10,
      SRIB9: :srib9,
      SRIB8: :srib8,
      SRIB7: :srib7,
      SRIB6: :srib6,
      SRIB5: :srib5,
      SRIB4: :srib4,
      SRIB3: :srib3,
      SRIB2: :srib2,
      SRIB1: :srib1,
      SRIB0: :srib0,
      SROA17: :sroa17,
      SROA16: :sroa16,
      SROA15: :sroa15,
      SROA14: :sroa14,
      SROA13: :sroa13,
      SROA12: :sroa12,
      SROA11: :sroa11,
      SROA10: :sroa10,
      SROA9: :sroa9,
      SROA8: :sroa8,
      SROA7: :sroa7,
      SROA6: :sroa6,
      SROA5: :sroa5,
      SROA4: :sroa4,
      SROA3: :sroa3,
      SROA2: :sroa2,
      SROA1: :sroa1,
      SROA0: :sroa0,
      SROB17: :srob17,
      SROB16: :srob16,
      SROB15: :srob15,
      SROB14: :srob14,
      SROB13: :srob13,
      SROB12: :srob12,
      SROB11: :srob11,
      SROB10: :srob10,
      SROB9: :srob9,
      SROB8: :srob8,
      SROB7: :srob7,
      SROB6: :srob6,
      SROB5: :srob5,
      SROB4: :srob4,
      SROB3: :srob3,
      SROB2: :srob2,
      SROB1: :srob1,
      SROB0: :srob0,
      ROA17: :roa17,
      ROA16: :roa16,
      ROA15: :roa15,
      ROA14: :roa14,
      ROA13: :roa13,
      ROA12: :roa12,
      ROA11: :roa11,
      ROA10: :roa10,
      ROA9: :roa9,
      ROA8: :roa8,
      ROA7: :roa7,
      ROA6: :roa6,
      ROA5: :roa5,
      ROA4: :roa4,
      ROA3: :roa3,
      ROA2: :roa2,
      ROA1: :roa1,
      ROA0: :roa0,
      ROB17: :rob17,
      ROB16: :rob16,
      ROB15: :rob15,
      ROB14: :rob14,
      ROB13: :rob13,
      ROB12: :rob12,
      ROB11: :rob11,
      ROB10: :rob10,
      ROB9: :rob9,
      ROB8: :rob8,
      ROB7: :rob7,
      ROB6: :rob6,
      ROB5: :rob5,
      ROB4: :rob4,
      ROB3: :rob3,
      ROB2: :rob2,
      ROB1: :rob1,
      ROB0: :rob0,
      ROC17: :roc17,
      ROC16: :roc16,
      ROC15: :roc15,
      ROC14: :roc14,
      ROC13: :roc13,
      ROC12: :roc12,
      ROC11: :roc11,
      ROC10: :roc10,
      ROC9: :roc9,
      ROC8: :roc8,
      ROC7: :roc7,
      ROC6: :roc6,
      ROC5: :roc5,
      ROC4: :roc4,
      ROC3: :roc3,
      ROC2: :roc2,
      ROC1: :roc1,
      ROC0: :roc0,
      P35: :p35,
      P34: :p34,
      P33: :p33,
      P32: :p32,
      P31: :p31,
      P30: :p30,
      P29: :p29,
      P28: :p28,
      P27: :p27,
      P26: :p26,
      P25: :p25,
      P24: :p24,
      P23: :p23,
      P22: :p22,
      P21: :p21,
      P20: :p20,
      P19: :p19,
      P18: :p18,
      P17: :p17,
      P16: :p16,
      P15: :p15,
      P14: :p14,
      P13: :p13,
      P12: :p12,
      P11: :p11,
      P10: :p10,
      P9: :p9,
      P8: :p8,
      P7: :p7,
      P6: :p6,
      P5: :p5,
      P4: :p4,
      P3: :p3,
      P2: :p2,
      P1: :p1,
      P0: :p0,
      SIGNEDP: :signedp
    ]
end
