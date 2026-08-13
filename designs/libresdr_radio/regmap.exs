# Register map for the LibreSDR radio fabric -- SINGLE SOURCE OF TRUTH.
#
# Fields pack LSB-first in declaration order. Offsets are never written by hand;
# that is the entire point. The `0x2B1 is GAIN_RX2` misread and the hand-carried
# `ctrl2[16..16]` arm bit are the failure modes this exists to remove.
#
# access:
#   :rw      CPU writes, fabric reads          (ctrl* words)
#   :ro      fabric drives, CPU reads          (status* words)
#   :wtoggle CPU flips the bit, fabric edge-detects -> one-shot command.
#            Implemented with the EXISTING AXI slave: no auto-clear needed,
#            which is what `cap_arm` already does by hand.
#
# A true :wpulse (write-1, hardware auto-clears) would need the slave to clear
# the bit; :wtoggle is the version that works today.
%{
  # --- control (CPU -> fabric) ------------------------------------------
  ctrl0: [
    {:spi_tx_data,   :rw, 8},
    {:spi_cs_hold,   :rw, 1},
    {:spi_go,        :wtoggle, 1}
  ],
  ctrl1: [
    {:ad9363_resetb, :rw, 1},
    {:ad9363_enable, :rw, 1},
    {:ad9363_txnrx,  :rw, 1},
    {:ad9363_en_agc, :rw, 1}
  ],
  ctrl2: [
    {:cap_rd_addr,   :rw, 12},
    {:_pad,          :rw, 4},
    {:cap_arm,       :wtoggle, 1}
  ],

  # --- status (fabric -> CPU) -------------------------------------------
  status0: [
    {:spi_rx_data,   :ro, 8},
    {:spi_done,      :ro, 1},
    {:spi_tx_ready,  :ro, 1}
  ],
  status1: [
    {:heartbeat,     :ro, 24}
  ],
  status2: [
    {:dclk_count,    :ro, 24}
  ],
  status3: [
    {:cap_word,      :ro, 26},
    {:cap_done,      :ro, 1}
  ]
}
