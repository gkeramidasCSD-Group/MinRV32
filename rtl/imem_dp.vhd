-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   TRUE DUAL-PORT BRAM  A single memory array with two independent read
--       ports (Port A for instruction fetch, Port B for data-side reads
--       from the text region). Both Vivado and GHDL handle this template
--       identically: Vivado infers a true dual-port BRAM (RAMB36E1 TDP
--       mode), while GHDL simulates the shared array with correct semantics.
--       Using one dual-port primitive instead of two separate ROMs halves
--       the BRAM utilization for instruction memory.
--
--   IMPURE FUNCTION (file I/O)  `init_mem` reads a hex file at elaboration
--       time to populate the initial memory contents. Impure functions can
--       access external state (files); pure functions cannot. Vivado's
--       elaborator executes the same TEXTIO code GHDL does and bakes the
--       returned array straight into the inferred BRAM's INIT_xx parameters,
--       so no tool-specific INIT_FILE attribute is required.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;
use work.mem_init_pkg.all;

-- ============================================================================
-- Entity: imem_dp
-- True dual-port synchronous-read ROM for the instruction memory.
--   Port A  -- instruction fetch (driven by the PC).
--   Port B  -- data-side read access to the text region (loads from .rodata
--              or other read-only data placed in the instruction address space).
--
-- Both ports share the same underlying memory array, so a single FPGA Block
-- RAM primitive serves both accesses. Each port has its own clock-enable;
-- when the enable is low the output register holds its previous value --
-- exactly matching the Xilinx/Intel BRAM enable semantics.
-- ============================================================================

entity imem_dp is
  generic (
    WORDS    : natural := 2048;
    INIT_HEX : string  := ""  -- Optional hex image loaded at elaboration.
  );
  port (
    clk     : in  std_logic;
    -- Port A: instruction fetch.
    en_a    : in  std_logic;
    addr_a  : in  word_t;
    rdata_a : out word_t;
    -- Port B: data-side read from text region.
    en_b    : in  std_logic;
    addr_b  : in  word_t;
    rdata_b : out word_t
  );
end entity imem_dp;

architecture rtl of imem_dp is
  constant AW : natural := log2_ceil(WORDS);
  subtype mem_t is word_mem_t(WORDS - 1 downto 0);
  signal mem     : mem_t := init_mem(INIT_HEX, WORDS);
  signal raddr_a : unsigned(AW - 1 downto 0) := (others => '0');
  signal raddr_b : unsigned(AW - 1 downto 0) := (others => '0');
begin

  -- Elaboration-time guard: the explicit bit slicing below only produces the
  -- intended mod-WORDS fold when WORDS is a power of two.
  assert is_power_of_two(WORDS)
    report "imem_dp: WORDS generic must be a power of two"
    severity failure;

  -- Word-align addresses and fold into depth via explicit bit slicing.
  -- (Avoids an `integer range` + `mod WORDS` pattern that yosys-ghdl-plugin
  --  synthesizes as a subtraction instead of a bit mask.)
  raddr_a <= unsigned(addr_a(AW + 1 downto 2))
             -- synthesis translate_off
             when addr_valid(addr_a) else (others => '0')
             -- synthesis translate_on
             ;
  raddr_b <= unsigned(addr_b(AW + 1 downto 2))
             -- synthesis translate_off
             when addr_valid(addr_b) else (others => '0')
             -- synthesis translate_on
             ;

  -- Purpose: True dual-port synchronous read (single shared array). Both ports
  -- live inside a single clocked process -- the standard Vivado/Quartus template
  -- for TDP BRAM inference (UG901, "Dual-Port Block RAM"). Each port has its
  -- own enable and registered output, matching FPGA BRAM semantics.
  p_imem_dp_read : process(clk)
  begin
    if rising_edge(clk) then
      if en_a = '1' then
        rdata_a <= mem(to_integer(raddr_a));
      end if;
      if en_b = '1' then
        rdata_b <= mem(to_integer(raddr_b));
      end if;
    end if;
  end process p_imem_dp_read;

end architecture rtl;
