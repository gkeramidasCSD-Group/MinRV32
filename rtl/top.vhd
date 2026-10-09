-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   TOP-LEVEL INTEGRATION  This file connects the processor core to its
--       memories. No logic is computed here beyond a one-bit registered
--       mux select -- everything else is wiring. A clean top level makes
--       it easy to swap memory models (simulation ROMs vs FPGA BRAM) or
--       add peripherals later.
--
--   GENERIC MAP  Each memory instance overrides its depth (WORDS) and
--       initialization file (INIT_HEX) through a `generic map` clause.
--       This is the VHDL mechanism for compile-time parametrization.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: top
-- Textbook-style top wrapper that connects the pipelined core to instruction
-- and data memories. This mirrors the Harris & Harris top-level naming while
-- keeping the existing repository memory models.
-- ============================================================================

entity top is
  generic (
    IMEM_WORDS     : natural := 2048;
    DMEM_WORDS     : natural := 2048;
    IMEM_INIT_FILE : string  := "";
    DMEM_INIT_FILE : string  := "";
    DMEM_BASE_ADDR : std_logic_vector(31 downto 0) := x"20000000";
    FORWARDING_ENABLE : boolean := true
  );
  port (
    clk       : in  std_logic;
    reset     : in  std_logic;
    WriteData : out std_logic_vector(31 downto 0);
    DataAdr   : out std_logic_vector(31 downto 0);
    MemWrite  : out std_logic;
    MemRead   : out std_logic;
    MemWStrb  : out std_logic_vector(3 downto 0)
  );
end entity top;

architecture structural of top is
  signal pc         : word_t;
  signal instr      : word_t;
  signal read_data  : word_t;
  signal imem_data  : word_t;
  signal dmem_rdata : word_t;

  -- Internal memory interface nets. These are driven by the core and then
  -- exposed on the top-level ports for observation.
  signal dmem_addr_i     : word_t;
  signal dmem_wdata_i    : word_t;
  signal dmem_wstrb_i    : std_logic_vector(3 downto 0);
  signal dmem_write_en_i : std_logic;
  signal dmem_read_en_i  : std_logic;

  signal imem_en    : std_logic;
  -- Registered mux-select for the IMEM/DMEM read-data path. Because both
  -- memories now use synchronous reads their outputs appear one cycle after
  -- the address is presented. We register the address comparison at the
  -- M->W boundary so the mux select aligns with the BRAM output timing.
  signal use_imem_w : std_logic := '0';

  -- MARK_DEBUG pins these nets in the post-synthesis netlist so that (a)
  -- Vivado does not merge them away and (b) they show up as selectable
  -- targets in the "Set Up Debug" wizard when inserting an ILA for on-board
  -- signature validation (see docs/vivado_instructions.md). The attribute is
  -- Vivado-specific and ignored by GHDL and other synthesis tools.
  attribute MARK_DEBUG : string;
  attribute MARK_DEBUG of pc              : signal is "true";
  attribute MARK_DEBUG of instr           : signal is "true";
  attribute MARK_DEBUG of dmem_addr_i     : signal is "true";
  attribute MARK_DEBUG of dmem_wdata_i    : signal is "true";
  attribute MARK_DEBUG of dmem_wstrb_i    : signal is "true";
  attribute MARK_DEBUG of dmem_write_en_i : signal is "true";
  attribute MARK_DEBUG of dmem_read_en_i  : signal is "true";
begin

  -- Expose core memory interface signals on the textbook-style top ports.
  WriteData <= dmem_wdata_i;
  DataAdr   <= dmem_addr_i;
  MemWrite  <= dmem_write_en_i;
  MemRead   <= dmem_read_en_i;
  MemWStrb  <= dmem_wstrb_i;

  rvpipe_inst : entity work.riscvpipe
    generic map (
      FORWARDING_ENABLE => FORWARDING_ENABLE
    )
    port map (
      clk           => clk,
      rst           => reset,
      imem_addr     => pc,
      imem_rdata    => instr,
      imem_en       => imem_en,
      dmem_addr     => dmem_addr_i,
      dmem_wdata    => dmem_wdata_i,
      dmem_rdata    => read_data,
      dmem_wstrb    => dmem_wstrb_i,
      dmem_write_en => dmem_write_en_i,
      dmem_read_en  => dmem_read_en_i
    );

  imem_dp_inst : entity work.imem_dp
    generic map (
      WORDS    => IMEM_WORDS,
      INIT_HEX => IMEM_INIT_FILE
    )
    port map (
      clk     => clk,
      en_a    => imem_en,
      addr_a  => pc,
      rdata_a => instr,
      en_b    => dmem_read_en_i,
      addr_b  => dmem_addr_i,
      rdata_b => imem_data
    );

  dmem_inst : entity work.dmem
    generic map (
      WORDS    => DMEM_WORDS,
      INIT_HEX => DMEM_INIT_FILE
    )
    port map (
      clk   => clk,
      addr  => dmem_addr_i,
      wdata => dmem_wdata_i,
      rdata => dmem_rdata,
      wstrb => dmem_wstrb_i,
      write => dmem_write_en_i,
      read  => dmem_read_en_i
    );

  -- Purpose: Register the IMEM-vs-DMEM read select. The compare is performed
  -- on the M-stage address and latched so it aligns with the synchronous BRAM
  -- output timing in W.
  p_use_imem_w_reg : process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        use_imem_w <= '0';
      -- synthesis translate_off
      elsif not addr_valid(dmem_addr_i) then
        use_imem_w <= '0';
      -- synthesis translate_on
      elsif unsigned(dmem_addr_i) < unsigned(DMEM_BASE_ADDR) then
        use_imem_w <= '1';
      else
        use_imem_w <= '0';
      end if;
    end if;
  end process p_use_imem_w_reg;

  -- Data reads below DMEM_BASE_ADDR are served from instruction memory so
  -- .rodata in the text region stays accessible to loads in simulations.
  read_data <= imem_data when use_imem_w = '1' else dmem_rdata;

end architecture structural;
