# LibreSDR (xc7z020clg400-1) — AD9363 control plane.
#
# Pins from zynqsdr_rev5.pdf, cross-checked against
# prjxray-db/zynq7/xc7z020clg400-1/package_pins.csv:
#
#   R14  IO_L6N_T0_VREF_34   SPI_CLK
#   P15  IO_L24P_T3_34       SPI_DI    (PL drives -> AD9363 data in)
#   R19  IO_0_34             SPI_DO    (AD9363 drives -> PL reads)
#   P18  IO_L23N_T3_34       SPI_ENB   (chip select, active low)
#   N17  IO_L23P_T3_34       RESETB    (active low)
#   R18  IO_L20N_T3_34       ENABLE
#   P14  IO_L6P_T0_34        TXNRX
#   P16  IO_L24N_T3_34       EN_AGC
#
# All bank 34. Its VCCO is 2.5 V — the AD9363's VDD_INTERFACE rail — so these
# are LVCMOS25. Not 3.3 V: a bank has a single VCCO, and the LVDS pairs sharing
# bank 34 require 2.5 V.

set_property PACKAGE_PIN R14 [get_ports ad9363_spi_clk]
set_property PACKAGE_PIN P15 [get_ports ad9363_spi_di]
set_property PACKAGE_PIN R19 [get_ports ad9363_spi_do]
set_property PACKAGE_PIN P18 [get_ports ad9363_spi_enb]
set_property PACKAGE_PIN N17 [get_ports ad9363_resetb]
set_property PACKAGE_PIN R18 [get_ports ad9363_enable]
set_property PACKAGE_PIN P14 [get_ports ad9363_txnrx]
set_property PACKAGE_PIN P16 [get_ports ad9363_en_agc]

set_property IOSTANDARD LVCMOS25 [get_ports ad9363_spi_clk]
set_property IOSTANDARD LVCMOS25 [get_ports ad9363_spi_di]
set_property IOSTANDARD LVCMOS25 [get_ports ad9363_spi_do]
set_property IOSTANDARD LVCMOS25 [get_ports ad9363_spi_enb]
set_property IOSTANDARD LVCMOS25 [get_ports ad9363_resetb]
set_property IOSTANDARD LVCMOS25 [get_ports ad9363_enable]
set_property IOSTANDARD LVCMOS25 [get_ports ad9363_txnrx]
set_property IOSTANDARD LVCMOS25 [get_ports ad9363_en_agc]

# --- LVDS receive bus ---------------------------------------------------------
#
#   N20/P20  IO_L14P/N_T2_SRCC_34   DATA_CLK   clock capable, as it must be
#   U18/U19  IO_L12P/N_T1_MRCC_34   RX_FRAME
#   Y18/Y19  IO_L17P/N_T2_34        RX_D0
#   V17/V18  IO_L21P/N_T3_DQS_34    RX_D1   (see note)
#   V20/W20  IO_L16P/N_T2_34        RX_D2
#   R16/R17  IO_L19P/N_T3_34        RX_D3
#   W18/W19  IO_L22P/N_T3_34        RX_D4
#   V16/W16  IO_L18P/N_T2_34        RX_D5
#
# RX_D1_N is V18: first inferred (pdftotext lost the net name; V17 is
# IO_L21P_T3_DQS_34 and package_pins.csv pairs it with V18), then CONFIRMED
# 2026-09-26 by reading zynqsdr_rev5.pdf page 16 directly (symbol U2C: V18 =
# IO_L21N_T3_DQS_34 = AD9363_RX_D1_N; also agrees with pdftotext -bbox rows).
#
# DIFF_TERM is set on every IBUFDS and nextpnr-xilinx silently ignores it: there
# is no termination feature anywhere in the emitted FASM, and prjxray documents
# only IN_DIFF for RIOB33, not the on-die 100 ohm LVDS termination. The board
# carries no external termination either -- the traces are impedance-controlled
# and rely on the receiver's. Whether that matters at ~16 MHz is an open
# question to settle by counting errors on the AD9363's BIST pattern, not by
# argument.

set_property PACKAGE_PIN N20 [get_ports ad9363_data_clk_p]
set_property PACKAGE_PIN P20 [get_ports ad9363_data_clk_n]
set_property PACKAGE_PIN U18 [get_ports ad9363_rx_frame_p]
set_property PACKAGE_PIN U19 [get_ports ad9363_rx_frame_n]
set_property PACKAGE_PIN Y18 [get_ports ad9363_rx_d0_p]
set_property PACKAGE_PIN Y19 [get_ports ad9363_rx_d0_n]
set_property PACKAGE_PIN V17 [get_ports ad9363_rx_d1_p]
set_property PACKAGE_PIN V18 [get_ports ad9363_rx_d1_n]
set_property PACKAGE_PIN V20 [get_ports ad9363_rx_d2_p]
set_property PACKAGE_PIN W20 [get_ports ad9363_rx_d2_n]
set_property PACKAGE_PIN R16 [get_ports ad9363_rx_d3_p]
set_property PACKAGE_PIN R17 [get_ports ad9363_rx_d3_n]
set_property PACKAGE_PIN W18 [get_ports ad9363_rx_d4_p]
set_property PACKAGE_PIN W19 [get_ports ad9363_rx_d4_n]
set_property PACKAGE_PIN V16 [get_ports ad9363_rx_d5_p]
set_property PACKAGE_PIN W16 [get_ports ad9363_rx_d5_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_data_clk_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_data_clk_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_frame_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_frame_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d0_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d0_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d1_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d1_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d2_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d2_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d3_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d3_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d4_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d4_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d5_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d5_n]

# --- LVDS transmit bus (Hw.AD936xTxPort -> ODDR -> OBUFDS) --------------------
#
# From zynqsdr_rev5.pdf page 16 (symbol U2C, bank 34), read visually and
# cross-checked with pdftotext -bbox, 2026-09-26. All bank 34, so LVDS_25 like
# the receive bus. TX_D3_N was missing from the plain-text extraction (same
# failure as RX_D1_N); the page shows U17 = IO_L9N_T1_DQS_34.
#
#   N18/P19  IO_L13P/N_T2_MRCC_34   FB_CLK    (PL -> AD9363, forwarded clock)
#   Y16/Y17  IO_L7P/N_T1_34         TX_FRAME
#   W14/Y14  IO_L8P/N_T1_34         TX_D0
#   T12/U12  IO_L2P/N_T0_34         TX_D1
#   U14/U15  IO_L11P/N_T1_SRCC_34   TX_D2
#   T16/U17  IO_L9P/N_T1_DQS_34     TX_D3
#   V12/W13  IO_L4P/N_T0_34         TX_D4
#   V15/W15  IO_L10P/N_T1_34        TX_D5
#
# No DIFF_TERM here: these are outputs; termination is the AD9363's.
set_property PACKAGE_PIN N18 [get_ports ad9363_fb_clk_p]
set_property PACKAGE_PIN P19 [get_ports ad9363_fb_clk_n]
set_property PACKAGE_PIN Y16 [get_ports ad9363_tx_frame_p]
set_property PACKAGE_PIN Y17 [get_ports ad9363_tx_frame_n]
set_property PACKAGE_PIN W14 [get_ports ad9363_tx_d0_p]
set_property PACKAGE_PIN Y14 [get_ports ad9363_tx_d0_n]
set_property PACKAGE_PIN T12 [get_ports ad9363_tx_d1_p]
set_property PACKAGE_PIN U12 [get_ports ad9363_tx_d1_n]
set_property PACKAGE_PIN U14 [get_ports ad9363_tx_d2_p]
set_property PACKAGE_PIN U15 [get_ports ad9363_tx_d2_n]
set_property PACKAGE_PIN T16 [get_ports ad9363_tx_d3_p]
set_property PACKAGE_PIN U17 [get_ports ad9363_tx_d3_n]
set_property PACKAGE_PIN V12 [get_ports ad9363_tx_d4_p]
set_property PACKAGE_PIN W13 [get_ports ad9363_tx_d4_n]
set_property PACKAGE_PIN V15 [get_ports ad9363_tx_d5_p]
set_property PACKAGE_PIN W15 [get_ports ad9363_tx_d5_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_fb_clk_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_fb_clk_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_frame_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_frame_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d0_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d0_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d1_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d1_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d2_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d2_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d3_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d3_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d4_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d4_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d5_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_tx_d5_n]

# Real clock constraints (2026-09-26). build.exs's --freq 50 was the only
# target before, while FCLK0 (axi_clk) runs at 100 MHz: builds met it only by
# placement luck (141 MHz estimated for build_txdma, 82.7 for the first
# STF-detector build). DATA_CLK is 32 MHz at 8 Msps 2R2T; revisit if the
# sample rate goes up.
create_clock -period 10.000 [get_nets axi_clk]
create_clock -period 31.250 [get_nets data_clk]
