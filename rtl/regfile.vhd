-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   ARRAY TYPE     `reg_array_t` is a custom array of 32 word_t elements.
--       Arrays can model register files, memories, and lookup tables.
--       Initializing with (others => (others => '0')) zeros every register.
--
--   FUNCTION (combinational read)  `read_reg` is a pure function that takes
--       the full register array and an address, returning one word. Because
--       functions have no side effects, calling them in a concurrent signal
--       assignment produces purely combinational read logic.
--
--   RISING_EDGE write + bypass  The textbook (Harris & Harris) writes on the
--       falling edge so that the new value is visible to a same-cycle read.
--       This implementation writes on the rising edge instead, which is
--       required for correct BRAM inference on Xilinx/Intel FPGAs (BRAM
--       primitives only support single-edge clocking). A combinational
--       write-forwarding mux at each read port detects a simultaneous
--       read/write to the same address and bypasses the write data directly,
--       reproducing the same logical behaviour as the falling-edge scheme.
--       See docs/textbook_differences.md for more details.
--
--   SIGNAL vs VARIABLE  Signals (like `regs`) are scheduled updates that take
--       effect *after* the current simulation delta. Variables (inside
--       functions) update immediately within the sequential flow.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: regfile
-- Two-read/one-write RV32I register file with x0 hard-wired to zero.
-- Writes occur on the rising edge when `rd_write` is asserted. A same-cycle
-- write-forwarding bypass ensures that a read from the same address as an
-- active write returns the new data without an extra cycle of latency.
-- ============================================================================

entity regfile is
  port (
    clk      : in  std_logic;
    rs1_addr : in  std_logic_vector(4 downto 0);
    rs2_addr : in  std_logic_vector(4 downto 0);
    rd_addr  : in  std_logic_vector(4 downto 0);
    rd_data  : in  word_t;
    rd_write : in  std_logic;
    rs1_data : out word_t;
    rs2_data : out word_t
  );
end entity regfile;

architecture rtl of regfile is
  -- 32-entry XLEN register array with synchronous writes.
  type reg_array_t is array (31 downto 0) of word_t;
  signal regs : reg_array_t := (others => (others => '0'));

  -- Pure combinational read from the register array.
  function read_reg(
    arr  : reg_array_t;
    addr : std_logic_vector(4 downto 0)
  ) return word_t is
    variable res : word_t := (others => '0');
  begin
    -- synthesis translate_off
    if not addr_valid(addr) then
      return res;
    end if;
    -- synthesis translate_on
    if addr = "00000" then
      -- x0 is hardwired to zero and ignores memory contents.
      res := (others => '0');
    else
      res := arr(to_integer(unsigned(addr)));
    end if;
    return res;
  end function;
begin

  -- Write-back stage: register file captures rd on the rising edge.
  -- Rising-edge writes are required for BRAM inference on Xilinx/Intel FPGAs
  -- (BRAM primitives only support single-edge clocking). The write-forwarding
  -- bypass below compensates for the timing difference vs the textbook's
  -- falling-edge scheme.
  -- Purpose: Synchronous write port. Writes to x0 are ignored, and same-cycle
  -- read-after-write is handled by the bypass mux below.
  p_reg_write : process(clk)
  begin
    if rising_edge(clk) then
      if rd_write = '1'
         -- synthesis translate_off
         and addr_valid(rd_addr)
         -- synthesis translate_on
         and rd_addr /= "00000" then
        regs(to_integer(unsigned(rd_addr))) <= rd_data;
      end if;
    end if;
  end process p_reg_write;

  -- Combinational read with write-forwarding bypass.
  -- When the W stage writes the same register that D reads in the same cycle,
  -- the rising-edge write has not yet updated `regs`. The bypass mux detects
  -- this condition and forwards `rd_data` directly, giving the same result as
  -- the textbook's falling-edge write without requiring a half-cycle timing
  -- path or dual-edge clocking.
  rs1_data <= rd_data when (rd_write = '1' and rs1_addr = rd_addr and rs1_addr /= "00000")
              else read_reg(regs, rs1_addr);
  rs2_data <= rd_data when (rd_write = '1' and rs2_addr = rd_addr and rs2_addr /= "00000")
              else read_reg(regs, rs2_addr);

end architecture rtl;
