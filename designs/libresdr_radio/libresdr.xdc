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
# RX_D1_N is V18 by inference, not by direct reading. The schematic's pin table
# columns interleave badly enough that pdftotext lost that one net name, and
# W17 -- the obvious guess from the neighbouring pattern -- does not exist on
# clg400 at all. A differential pair must occupy both halves of one IO_L pair,
# V17 is IO_L21P_T3_DQS_34, and package_pins.csv gives V18 as the matching
# IO_L21N. Worth an eyeball on the real schematic before trusting samples from
# that lane.
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
