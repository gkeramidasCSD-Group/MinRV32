-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   PIPELINE STAGE WRAPPER  Grouping E->M registers and the memory-access
--       unit into one entity keeps the parent datapath_pipe purely structural.
--       Each wrapper becomes a named block in Vivado's schematic, which makes
--       the pipeline boundaries clearly visible during debug.
--
--   STORE-DATA PATH  The mem_access_unit aligns the store payload and
--       generates byte strobes *before* the signals reach the DMEM entity.
--       This separation keeps the DMEM model generic (it only sees word
--       writes with byte enables) while the alignment logic stays local.
-- ============================================================================

-- ============================================================================
-- Entity: memory_stage
-- Memory pipeline stage wrapper. Contains E->M pipeline registers and the
-- memory access unit (store-data alignment and byte-strobe generation).
-- Each sub-component is a named instantiation visible in Vivado's elaborated
-- design.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.core_pkg.all;

entity memory_stage is
  port (
    clk           : in  std_logic;
    rst           : in  std_logic;
    -- Pipeline control.
    MemWriteM     : in  std_logic;
    MemReadM      : in  std_logic;
    MemSizeM      : in  std_logic_vector(1 downto 0);
    -- From execute stage.
    alu_result_e  : in  word_t;
    write_data_e  : in  word_t;
    rd_e          : in  std_logic_vector(4 downto 0);
    pc_plus4_e    : in  word_t;
    -- Outputs (to hazard unit / forwarding / writeback).
    rd_m          : out std_logic_vector(4 downto 0);
    alu_result_m  : out word_t;
    pc_plus4_m    : out word_t;
    -- Data memory interface.
    dmem_addr     : out word_t;
    dmem_wdata    : out word_t;
    dmem_wstrb    : out std_logic_vector(3 downto 0);
    dmem_write_en : out std_logic;
    dmem_read_en  : out std_logic
  );
end entity memory_stage;

architecture rtl of memory_stage is
  signal alu_result_m_i    : word_t;
  signal fwd_rs2_data_m_i  : word_t;
  signal memacc_wstrb_m    : std_logic_vector(3 downto 0);
begin

  -- ====================================================================
  -- E->M Pipeline Registers
  -- ====================================================================
  em_alu_result_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => '0', stall => '0',
              d => alu_result_e, q => alu_result_m_i);

  em_write_data_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => '0', stall => '0',
              d => write_data_e, q => fwd_rs2_data_m_i);

  em_rd_reg : entity work.pipe_reg
    generic map (WIDTH => 5)
    port map (clk => clk, rst => rst, flush => '0', stall => '0',
              d => rd_e, q => rd_m);

  em_pc_plus4_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => '0', stall => '0',
              d => pc_plus4_e, q => pc_plus4_m);

  -- ====================================================================
  -- Memory Access Unit
  -- ====================================================================
  mem_access_inst : entity work.mem_access_unit
    port map (
      alu_result   => alu_result_m_i,
      rs2_data     => fwd_rs2_data_m_i,
      mem_size     => MemSizeM,
      mem_write    => MemWriteM,
      mem_read     => MemReadM,
      store_data   => dmem_wdata,
      byte_strobes => memacc_wstrb_m,
      write_en     => dmem_write_en,
      read_en      => dmem_read_en
    );

  dmem_addr  <= alu_result_m_i;
  dmem_wstrb <= memacc_wstrb_m;

  -- Output for forwarding path.
  alu_result_m <= alu_result_m_i;

end architecture rtl;
