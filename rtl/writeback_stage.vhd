-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   RESULT-SOURCE MUX  The writeback stage selects between ALU result, load
--       data, and PC+4 using a mux3 driven by ResultSrc_t. The enum-to-slv
--       conversion function `result_src_sel` is architecture-local, keeping
--       the package namespace clean.
--
--   LOAD EXTENSION  Byte and halfword loads must be sign- or zero-extended
--       to XLEN before they reach the register file. The load_extend_unit
--       handles this in the W stage, after the BRAM output register has
--       latched the raw memory word.
-- ============================================================================

-- ============================================================================
-- Entity: writeback_stage
-- Writeback pipeline stage wrapper. Contains M->W pipeline registers, the
-- load-extension unit, and the writeback result mux. Each sub-component is a
-- named instantiation visible in Vivado's elaborated design.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.core_pkg.all;

entity writeback_stage is
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    -- Pipeline control.
    ResultSrcW   : in  ResultSrc_t;
    MemSizeW     : in  std_logic_vector(1 downto 0);
    MemUnsignedW : in  std_logic;
    -- From memory stage.
    alu_result_m : in  word_t;
    rd_m         : in  std_logic_vector(4 downto 0);
    pc_plus4_m   : in  word_t;
    -- From data memory (BRAM registered output).
    dmem_rdata   : in  word_t;
    -- Outputs.
    rd_w         : out std_logic_vector(4 downto 0);
    wb_result_w  : out word_t
  );
end entity writeback_stage;

architecture rtl of writeback_stage is
  subtype slv2_t is std_logic_vector(1 downto 0);

  function result_src_sel(sel : ResultSrc_t) return slv2_t is
  begin
    case sel is
      when WB_ALU => return "00";
      when WB_MEM => return "01";
      when WB_PC4 => return "10";
    end case;
  end function;

  signal alu_result_w_i   : word_t;
  signal pc_plus4_w_i     : word_t;
  signal loadext_rdata_w  : word_t;
  signal result_sel_slv   : slv2_t;
begin

  -- ====================================================================
  -- M->W Pipeline Registers
  -- ====================================================================
  mw_alu_result_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => '0', stall => '0',
              d => alu_result_m, q => alu_result_w_i);

  mw_rd_reg : entity work.pipe_reg
    generic map (WIDTH => 5)
    port map (clk => clk, rst => rst, flush => '0', stall => '0',
              d => rd_m, q => rd_w);

  mw_pc_plus4_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => '0', stall => '0',
              d => pc_plus4_m, q => pc_plus4_w_i);

  -- ====================================================================
  -- Load Data Extension
  -- ====================================================================
  load_ext_inst : entity work.load_extend_unit
    port map (
      data        => dmem_rdata,
      addr_lsb    => alu_result_w_i(1 downto 0),
      mem_size    => MemSizeW,
      is_unsigned => MemUnsignedW,
      result      => loadext_rdata_w
    );

  -- ====================================================================
  -- Writeback Result Mux
  -- ====================================================================
  result_sel_slv <= result_src_sel(ResultSrcW);

  wb_mux : entity work.mux3
    generic map (WIDTH => XLEN)
    port map (
      d0 => alu_result_w_i,
      d1 => loadext_rdata_w,
      d2 => pc_plus4_w_i,
      s  => result_sel_slv,
      y  => wb_result_w
    );

end architecture rtl;
