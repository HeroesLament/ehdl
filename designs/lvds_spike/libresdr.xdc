# LibreSDR (xc7z020clg400-1) — LVDS spike constraints.
#
# Pins taken from zynqsdr_rev5.pdf and cross-checked against
# prjxray-db/zynq7/xc7z020clg400-1/package_pins.csv, which is the authoritative
# pin -> site -> tile mapping the flow itself uses.
#
#   N20  IO_L14P_T2_SRCC_34   DATA_CLK_P   clock capable, as a source-synchronous
#   P20  IO_L14N_T2_SRCC_34   DATA_CLK_N   receive clock has to be
#   Y18  IO_L17P_T2_34        RX_D0_P
#   Y19  IO_L17N_T2_34        RX_D0_N
#   J20  IO_L17P_T2_AD5P_35   PL_LED0      different bank, independent VCCO
#
# Every AD9363 signal on this board is in bank 34. LVDS_25 requires that bank
# at 2.5 V — the schematic shows +2.5V_A feeding the AD9363 section, but this
# has not been measured. Do not load this on hardware without checking.

set_property PACKAGE_PIN N20 [get_ports ad9363_data_clk_p]
set_property PACKAGE_PIN P20 [get_ports ad9363_data_clk_n]
set_property PACKAGE_PIN Y18 [get_ports ad9363_rx_d0_p]
set_property PACKAGE_PIN Y19 [get_ports ad9363_rx_d0_n]
set_property PACKAGE_PIN J20 [get_ports pl_led0]

set_property IOSTANDARD LVDS_25 [get_ports ad9363_data_clk_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_data_clk_n]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d0_p]
set_property IOSTANDARD LVDS_25 [get_ports ad9363_rx_d0_n]
set_property IOSTANDARD LVCMOS33 [get_ports pl_led0]
