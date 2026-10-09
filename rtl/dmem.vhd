-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   BRAM with BYTE-WRITE-ENABLE  Vivado UG901 requires separate if-guards
--       for each byte lane to infer BRAM byte-write-enable primitives.
--       The direct-lane pattern used here
--       (`if wstrb(i) then mem(addr)(slice) <= data(slice)`)
--       maps to the RAMB36E1 byte-write ports.
--
--   SINGLE-PROCESS BRAM TEMPLATE  Both the synchronous read and byte-enable
--       write live in a single clocked process, matching the Vivado UG901
--       single-process BRAM template for guaranteed inference across all
--       tool versions.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;
use work.mem_init_pkg.all;

-- ============================================================================
-- Entity: dmem
-- Word-addressed data memory with byte-enable writes and synchronous read.
-- Both read and write paths are clocked, matching the FPGA Block RAM template
-- so that synthesis tools (Vivado, Quartus) infer true BRAM primitives.
--
-- In the pipelined core the BRAM read-output register acts as the Memory-to-
-- Writeback pipeline register for load data (ReadDataW). The 'read' input
-- serves as the BRAM read-enable: when deasserted the output holds its last
-- value, saving power and avoiding spurious toggles.
-- ============================================================================

entity dmem is
  generic (
    WORDS    : natural := 2048;
    INIT_HEX : string  := ""  -- Optional hex image loaded at elaboration (point at scripts/build_prog.sh *.data.hex).
  );
  port (
    clk    : in  std_logic;
    addr   : in  word_t;
    wdata  : in  word_t;
    rdata  : out word_t;
    wstrb  : in  std_logic_vector(3 downto 0);
    write  : in  std_logic;
    read   : in  std_logic
  );
end entity dmem;

architecture rtl of dmem is
  -- Simple byte-addressable RAM modeled as array of words.
  constant AW : natural := log2_ceil(WORDS);
  subtype mem_t is word_mem_t(WORDS - 1 downto 0);
  signal mem   : mem_t := init_mem(INIT_HEX, WORDS);
  signal raddr : unsigned(AW - 1 downto 0) := (others => '0');
begin

  -- Elaboration-time guard: the explicit bit slicing below only produces the
  -- intended mod-WORDS fold when WORDS is a power of two.
  assert is_power_of_two(WORDS)
    report "dmem: WORDS generic must be a power of two"
    severity failure;
  -- DMEM is word addressed: drop low 2 bits and slice the depth-wide index.
  -- (Avoids an `integer range` + `mod WORDS` pattern that yosys-ghdl-plugin
  --  synthesizes as a subtraction instead of a bit mask.)
  raddr <= unsigned(addr(AW + 1 downto 2))
           -- synthesis translate_off
           when addr_valid(addr) else (others => '0')
           -- synthesis translate_on
           ;

  -- Single-process synchronous read + byte-enable write. Merging both paths
  -- into one clocked process matches the Vivado UG901 single-process BRAM
  -- template and guarantees correct inference on all tool versions.
  -- Purpose: Single-process synchronous RAM. Performs byte-enable writes and
  -- registered reads in one clocked block for reliable BRAM inference.
  p_dmem_rw : process(clk)
  begin
    if rising_edge(clk) then
      -- Synchronous byte-enable write: individual byte lanes are guarded by
      -- wstrb bits so SB/SH/SW work without a read-modify-write variable.
      -- This direct-lane pattern is required for Xilinx BRAM byte-write-enable
      -- inference (UG901 "RAM HDL Coding Techniques").
      if write = '1' then
        if wstrb(0) = '1' then mem(to_integer(raddr))( 7 downto  0) <= wdata( 7 downto  0); end if;
        if wstrb(1) = '1' then mem(to_integer(raddr))(15 downto  8) <= wdata(15 downto  8); end if;
        if wstrb(2) = '1' then mem(to_integer(raddr))(23 downto 16) <= wdata(23 downto 16); end if;
        if wstrb(3) = '1' then mem(to_integer(raddr))(31 downto 24) <= wdata(31 downto 24); end if;
      end if;
      -- Synchronous read: the registered output maps to the M->W pipeline
      -- register for load data. When 'read' is low the output holds its
      -- previous value -- matching Xilinx/Intel BRAM enable semantics.
      if read = '1' then
        rdata <= mem(to_integer(raddr));
      end if;
    end if;
  end process p_dmem_rw;
end architecture rtl;
